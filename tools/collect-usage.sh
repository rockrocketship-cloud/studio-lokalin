#!/usr/bin/env bash
set -euo pipefail
set +x
export PATH="${HOME}/.local/bin:${PATH}"

USAGE_REPO="${USAGE_REPO:-${HOME}/projects/studio-lokalin}"
AI_RUN_BRANCH="${AI_RUN_BRANCH:-main}"
tool_name=collect-usage
commit_message="chore: update AI usage limits"
grok_only=0
probe=0
dry_run=0
update_file=
claude_log=
percent=
reset_arg=
has_percent=0
has_reset=0

usage() {
  if ((grok_only)); then
    printf 'usage: set-grokbot-usage <percent> [resets_at]\n' >&2
  else
    printf 'usage: collect-usage [--probe] [--grokbot PCT [RESET_ISO|null]] [--claude-log FILE] [--update-file PATH] [--dry-run]\n' >&2
  fi
  exit 2
}

if [[ ${1-} == --set-grokbot-usage ]]; then
  shift
  tool_name=set-grokbot-usage
  commit_message="chore: update GrokBot weekly usage"
  grok_only=1
  [[ $# == 1 || $# == 2 ]] || usage
  set -- --grokbot "$@"
fi

while (($#)); do
  case "$1" in
    --probe) probe=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    --claude-log|--update-file)
      [[ $# -ge 2 && -n $2 && $2 != --* ]] || usage
      if [[ $1 == --claude-log ]]; then claude_log=$2; else update_file=$2; fi
      shift 2
      ;;
    --grokbot)
      [[ $# -ge 2 ]] || usage
      has_percent=1
      percent=$2
      has_reset=0
      shift 2
      if (($#)) && { ((grok_only)) || [[ $1 != --* ]]; }; then
        has_reset=1
        reset_arg=$1
        shift
      fi
      ;;
    *) usage ;;
  esac
done

warn() { printf '%s: warning: %s\n' "$tool_name" "$*" >&2; }
warn_usage() { warn "$*" 2>&3; }

rewrite_usage() {
  python3 - "$tool_name" "$has_percent" "$percent" "$has_reset" "$reset_arg" \
    "$grok_only" "$dry_run" "$claude_log" "$@" <<'PYTHON'
import json
import math
import re
import sys
import tempfile
from datetime import datetime
from decimal import Decimal, InvalidOperation
from pathlib import Path
from zoneinfo import ZoneInfo

tool, has_percent, percent_arg, has_reset, reset_arg, grok_only, dry_run, claude_log, *paths = sys.argv[1:]
wita = ZoneInfo("Asia/Makassar")
now = datetime.now(wita).isoformat()
cache = Path.home() / ".cache/ai-run/claude-limits.json"
keys = ("grokbot", "chatgpt_limits", "claude_limits")


def warn(message):
    print(f"{tool}: warning: {message}", file=sys.stderr)


def fail(message):
    sys.exit(f"{tool}: {message}")


def reject_constant(_):
    raise ValueError("invalid JSON constant")


def load(path):
    return json.loads(path.read_text(encoding="utf-8"), parse_constant=reject_constant)


def write(path, data):
    encoded = json.dumps(data, indent=2, ensure_ascii=False, allow_nan=False) + "\n"
    mode = path.stat().st_mode & 0o777 if path.exists() else None
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent, delete=False) as output:
        temp = Path(output.name)
        try:
            output.write(encoded)
            output.close()
            if mode is not None:
                temp.chmod(mode)
            temp.replace(path)
        finally:
            temp.unlink(missing_ok=True)


def object_value(value):
    return value if isinstance(value, dict) else {}


def timestamp(value):
    try:
        if isinstance(value, str):
            parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
            return parsed if parsed.tzinfo else parsed.replace(tzinfo=wita)
        if type(value) in (int, float):
            return datetime.fromtimestamp(value, wita)
    except (ValueError, OverflowError, OSError):
        pass
    return None


def iso(value):
    parsed = timestamp(value)
    return parsed.astimezone(wita).isoformat() if parsed is not None else None


def percentage(value, scale=1):
    if type(value) is int or (type(value) is float and math.isfinite(value)):
        bounded = max(0, min(100 / scale, value))
        return float(Decimal(str(bounded)) * scale) if scale != 1 else float(bounded)
    return None


def events(path, marker):
    with path.open(encoding="utf-8", errors="replace") as lines:
        for line in lines:
            if marker not in line:
                continue
            try:
                event = json.loads(line)
            except ValueError:
                continue
            if isinstance(event, dict):
                yield event


def codex_limits():
    newest = None
    limits = None
    sessions = Path.home() / ".codex/sessions"
    rollouts = []
    for path in sessions.glob("*/*/*/rollout-*.jsonl"):
        try:
            rollouts.append((path.stat().st_mtime_ns, path))
        except OSError:
            continue
    for _, path in sorted(rollouts, reverse=True)[:20]:
        try:
            for event in events(path, '"rate_limits"'):
                payload = object_value(event.get("payload"))
                candidate = payload.get("rate_limits")
                if payload.get("type") != "token_count" or not isinstance(candidate, dict):
                    continue
                observed = timestamp(event.get("timestamp"))
                if observed is not None and (newest is None or observed > newest):
                    newest, limits = observed, candidate
        except OSError:
            continue

    if limits is None:
        return None
    windows = {}
    for name in ("primary", "secondary"):
        window = object_value(limits.get(name))
        minutes = window.get("window_minutes")
        key = {300: "five_hour", 10080: "weekly"}.get(minutes) if type(minutes) in (int, float) else None
        used = percentage(window.get("used_percent"))
        if key and used is not None:
            windows[key] = {"used_percent": used, "window_minutes": int(minutes),
                            "resets_at": iso(window.get("resets_at"))}
    if windows:
        plan = limits.get("plan_type")
        return {"source": "codex-cli", "plan": plan if isinstance(plan, str) else None, **windows,
                "observed_at": newest.astimezone(wita).isoformat()}


def claude_limits():
    if not claude_log:
        try:
            snapshot = object_value(load(cache))
            observed = iso(snapshot.get("observed_at"))
            if snapshot.get("source") == "claude-code" and observed:
                windows = {}
                for key in ("five_hour", "weekly"):
                    window = object_value(snapshot.get(key))
                    used = percentage(window.get("used_percent"))
                    if used is not None:
                        status = window.get("status")
                        windows[key] = {"used_percent": used, "resets_at": iso(window.get("resets_at")),
                                        "status": status if isinstance(status, str) else None}
                if windows:
                    return {"source": "claude-code", **windows, "observed_at": observed}
        except (OSError, ValueError):
            pass
        return None

    path = Path(claude_log)
    snapshot = None
    try:
        modified = iso(path.stat().st_mtime)
        for event in events(path, '"rate_limit_event"'):
            if event.get("type") != "rate_limit_event":
                continue
            info = object_value(event.get("rate_limit_info"))
            unified = object_value(info.get("unifiedWindows"))
            windows = {}
            for source, key in (("five_hour", "five_hour"), ("seven_day", "weekly")):
                window = object_value(unified.get(source))
                utilization = percentage(window.get("utilization"))
                if utilization is not None and utilization > 1:
                    warn("Claude utilization exceeds 1; treating it as a percent")
                    used = utilization
                else:
                    used = percentage(utilization, 100)
                if used is not None:
                    status = window.get("status", info.get("status"))
                    windows[key] = {"used_percent": used, "resets_at": iso(window.get("resetsAt")),
                                    "status": status if isinstance(status, str) else None}
            if windows:
                snapshot = {**(snapshot or {}), "source": "claude-code", **windows,
                            "observed_at": iso(event.get("timestamp")) or modified}
    except OSError:
        return None
    if snapshot and dry_run == "0":
        try:
            cache.parent.mkdir(parents=True, exist_ok=True)
            previous = {}
            try:
                previous = object_value(load(cache))
            except (OSError, ValueError):
                pass
            previous_time = timestamp(previous.get("observed_at"))
            if previous_time is None or timestamp(snapshot["observed_at"]) >= previous_time:
                previous_windows = {key: previous[key] for key in ("five_hour", "weekly")
                                    if previous.get("source") == "claude-code" and key in previous}
                write(cache, {**previous_windows, **snapshot})
        except (OSError, ValueError):
            warn("could not cache Claude limits")
    return snapshot


def grokbot_values(percent_arg, reset_arg):
    try:
        if not re.fullmatch(r"[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?", percent_arg):
            raise InvalidOperation
        percent = Decimal(percent_arg)
    except InvalidOperation:
        percent = Decimal("NaN")
    if not percent.is_finite() or not 0 <= percent <= 100:
        fail("percent must be a finite number from 0 to 100")

    reset = None
    if reset_arg is not None and reset_arg != "null":
        try:
            if not re.search(r"[T ]\d{2}", reset_arg):
                raise ValueError
            # fromisoformat normalizes overflowing offset minutes and seconds.
            clock = re.split(r"[T ]", reset_arg, maxsplit=1)[1]
            offset = re.search(r"[+-][0-9]{2}:?([0-9]{2})(?::?([0-9]{2})(?:[.,][0-9]+)?)?$", clock)
            if offset and any(int(part) >= 60 for part in offset.groups() if part):
                raise ValueError
            iso_value = reset_arg[:-1] + "+00:00" if reset_arg.endswith("Z") else reset_arg
            value = datetime.fromisoformat(iso_value)
            reset = (value if value.tzinfo else value.replace(tzinfo=wita)).isoformat()
        except ValueError:
            fail("resets_at must be an ISO-8601 datetime or null")
    return float(percent), reset


if has_percent == "1":
    percent, reset = grokbot_values(percent_arg, reset_arg if has_reset == "1" else None)

if not paths:
    sys.exit(0)

path = Path(paths[0])
if path.is_symlink():
    fail("usage.json is a symbolic link")
try:
    data = load(path)
except FileNotFoundError:
    data = {"entries": []}
except (OSError, ValueError):
    fail("could not read valid usage.json")
if isinstance(data, list):
    data = {"entries": data}
elif not isinstance(data, dict) or not isinstance(data.get("entries"), list):
    fail("unsupported usage.json structure")

updates = {}
if has_percent == "1":
    if has_reset == "0":
        reset = object_value(data.get("grokbot")).get("resets_at")
    updates["grokbot"] = {"weekly_percent": percent, "resets_at": reset}
if grok_only == "0":
    for key, label, read in (("chatgpt_limits", "ChatGPT", codex_limits),
                             ("claude_limits", "Claude", claude_limits)):
        snapshot = read()
        if snapshot is None:
            warn(f"{label} limits unavailable")
            continue
        previous = object_value(data.get(key))
        previous_windows = {name: previous[name] for name in ("five_hour", "weekly") if name in previous}
        updates[key] = {**previous_windows, **snapshot}

changed = False
for key, limits in updates.items():
    previous = object_value(data.get(key))
    if limits != {field: value for field, value in previous.items() if field != "updated_at"}:
        data[key] = {**limits, "updated_at": now}
        changed = True
if dry_run == "1":
    print(json.dumps({key: data[key] for key in keys if key in data}, indent=2, ensure_ascii=False))
elif changed:
    try:
        write(path, data)
    except (OSError, ValueError):
        fail("could not write valid usage.json")

if grok_only == "0":
    for key, label in zip(keys, ("GrokBot", "ChatGPT", "Claude")):
        limits = object_value(data.get(key))
        windows = [("weekly", limits, "weekly_percent")] if key == "grokbot" else [
            (name, object_value(limits.get(name)), "used_percent") for name in ("five_hour", "weekly")
        ]
        summary = []
        for name, window, field in windows:
            used = percentage(window.get(field))
            if used is None:
                continue
            reset = timestamp(window.get("resets_at"))
            clock = reset.astimezone(wita).strftime("%d %b %H:%M WITA") if reset else "unknown"
            summary.append(f"{'5h' if name == 'five_hour' else 'weekly'} {used:g}% (reset {clock})")
        if summary:
            print(f"{label}: {', '.join(summary)}", file=sys.stderr)
PYTHON
}

stage_usage() {
  local tracked
  tracked="$(git ls-files --stage -- usage.json)" ||
    { warn_usage "could not check usage.json file mode"; return 1; }
  if [[ -L usage.json || $tracked == '120000 '* ]]; then
    warn_usage "usage.json is a symbolic link"
    return 1
  fi
  if ! rewrite_usage usage.json 2>&3; then
    warn_usage "could not update usage.json"
    return 1
  fi
  git add -- usage.json ||
    { warn_usage "could not stage usage.json"; return 1; }
}

rebase_usage() {
  local previous_base
  previous_base="$(git rev-parse HEAD^)" ||
    { warn_usage "could not find the parent of the usage commit"; return 1; }
  timeout -k 5s 60s git fetch --no-tags origin "refs/heads/${AI_RUN_BRANCH}" ||
    { warn_usage "could not fetch the target branch before push"; return 1; }
  if git -c rerere.enabled=false rebase FETCH_HEAD; then
    [[ "$previous_base" != "$(git rev-parse FETCH_HEAD)" ]] || return 0
    # Reapply the requested values on the latest file even after a clean merge.
    # An explicitly supplied reset may have matched the old base, leaving no diff.
  elif [[ -n "$(git ls-files -u -- usage.json)" ]] && git rebase --abort; then
    warn_usage "rebase conflicted in usage.json; rebuilding on the fetched branch"
  else
    warn_usage "could not rebase the usage commit"
    return 1
  fi
  git checkout --detach FETCH_HEAD && stage_usage &&
    { git diff --cached --quiet -- usage.json || git commit -m "${message}" -- usage.json; } ||
    { warn_usage "could not rebuild the usage commit on the fetched branch"; return 1; }
}

commit_usage() (
  export GIT_TERMINAL_PROMPT=0
  export GIT_ASKPASS=/bin/true
  export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh} -o BatchMode=yes"

  local temp repo fetch_url push_url push_result push_status identity value
  local message="$commit_message"

  command -v timeout >/dev/null ||
    { warn_usage "timeout is required to sync usage.json"; return 1; }

  # Keep all checkout and index changes inside a disposable clone.
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
  unset GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
  repo="$(cd -- "${USAGE_REPO}" && pwd -P)" &&
    fetch_url="$(git -C "${repo}" remote get-url origin)" &&
    push_url="$(git -C "${repo}" remote get-url --push origin)" ||
    { warn_usage "could not read origin from the usage repo"; return 1; }
  case "${fetch_url}" in /*|*:*) ;; *) fetch_url="${repo}/${fetch_url}" ;; esac
  case "${push_url}" in /*|*:*) ;; *) push_url="${repo}/${push_url}" ;; esac

  git check-ref-format "refs/heads/${AI_RUN_BRANCH}" ||
    { warn_usage "invalid AI_RUN_BRANCH"; return 1; }
  temp="$(mktemp -d)" ||
    { warn_usage "could not create a temporary directory"; return 1; }
  trap 'rm -rf -- "${temp}" || warn_usage "could not remove temporary usage clone"' EXIT
  trap 'exit 1' HUP INT TERM

  timeout -k 5s 60s git -c core.hooksPath=/dev/null clone --quiet --single-branch --branch "${AI_RUN_BRANCH}" -- "${fetch_url}" "${temp}/repo" &&
    cd -- "${temp}/repo" &&
    git remote set-url --push origin "${push_url}" &&
    git config core.hooksPath /dev/null &&
    git config commit.gpgsign false ||
    { warn_usage "could not set up the temporary usage clone"; return 1; }
  for identity in user.name user.email; do
    if value="$(git -C "${repo}" config --get "${identity}")"; then
      git config "${identity}" "${value}" ||
        { warn_usage "could not set the usage commit identity"; return 1; }
    fi
  done

  stage_usage || return 1
  if git diff --cached --quiet -- usage.json; then
    printf '%s: usage.json unchanged, skip commit and push\n' "$tool_name" >&3
    return 0
  fi
  git commit -m "${message}" -- usage.json ||
    { warn_usage "could not commit usage.json"; return 1; }

  rebase_usage || return 1
  if push_result="$(LC_ALL=C timeout -k 5s 60s git push --no-follow-tags --porcelain origin "HEAD:refs/heads/${AI_RUN_BRANCH}")"; then
    return 0
  else
    push_status=$?
  fi
  if [[ ${push_status} == 124 || ${push_status} == 137 ]]; then
    warn_usage "push timed out"
    return 1
  fi
  # Porcelain reports a race as either non-fast-forward or fetch first.
  case "${push_result}" in
    *$'\t[rejected] (non-fast-forward)'*|*$'\t[rejected] (fetch first)'*)
      rebase_usage || return 1
      timeout -k 5s 60s git push --no-follow-tags origin "HEAD:refs/heads/${AI_RUN_BRANCH}" ||
        { warn_usage "could not push usage.json after retry"; return 1; }
      ;;
    *) warn_usage "could not push usage.json"; return 1 ;;
  esac
) 3>&2 >/dev/null 2>/dev/null

# Validate operator input before probing or cloning.
rewrite_usage
if ((probe)); then
  probe_dir="$(mktemp -d)" || { warn "could not create probe directory"; probe_dir=; }
  if [[ -n $probe_dir ]]; then
    trap 'rm -rf -- "$probe_dir"' EXIT
    if ! timeout -k 5s 120s env -u OPENAI_API_KEY codex exec --skip-git-repo-check \
      -C "$probe_dir" "Reply with just: ok" </dev/null >/dev/null 2>&1; then
      warn "Codex probe failed"
    fi
    if (
      cd -- "$probe_dir" || exit 1
      CLAUDE_CODE_OAUTH_TOKEN="$(cat "${HOME}/.claude/oauth_token")" || exit 1
      export CLAUDE_CODE_OAUTH_TOKEN
      exec timeout -k 5s 120s env -u ANTHROPIC_API_KEY claude -p "Reply with just: ok" \
        --model haiku --output-format stream-json --verbose
    ) </dev/null >"$probe_dir/claude.jsonl" 2>/dev/null; then
      claude_log="${claude_log:-$probe_dir/claude.jsonl}"
    else
      warn "Claude probe failed"
    fi
  fi
fi

if [[ -n $update_file ]] || ((dry_run)); then
  rewrite_usage "${update_file:-$USAGE_REPO/usage.json}"
else
  commit_usage
fi
