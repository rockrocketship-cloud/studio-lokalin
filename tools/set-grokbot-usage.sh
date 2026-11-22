#!/usr/bin/env bash
# Record GrokBot weekly quota usage in the published usage.json.
set -euo pipefail

USAGE_REPO="${USAGE_REPO:-${HOME}/projects/studio-lokalin}"
AI_RUN_BRANCH="${AI_RUN_BRANCH:-main}"

if [[ $# -lt 1 || $# -gt 2 ]]; then
  printf 'usage: set-grokbot-usage <percent> [resets_at]\n' >&2
  exit 2
fi

rewrite_usage() {
  python3 - "$@" <<'PYTHON'
import json
import re
import sys
from datetime import datetime
from decimal import Decimal, InvalidOperation
from pathlib import Path
from zoneinfo import ZoneInfo

wita = ZoneInfo("Asia/Makassar")
percent_arg, reset_arg, has_reset, *paths = sys.argv[1:]

try:
    if not re.fullmatch(r"[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?", percent_arg):
        raise InvalidOperation
    percent = Decimal(percent_arg)
except InvalidOperation:
    percent = Decimal("NaN")
if not percent.is_finite() or not 0 <= percent <= 100:
    sys.exit("set-grokbot-usage: percent must be a finite number from 0 to 100")

reset = None
if has_reset == "2" and reset_arg != "null":
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
        sys.exit("set-grokbot-usage: resets_at must be an ISO-8601 datetime or null")

if not paths:
    sys.exit(0)

path = Path(paths[0])
if path.is_symlink():
    sys.exit("usage.json is a symbolic link")

def reject_constant(_):
    raise ValueError("invalid JSON constant")

try:
    data = json.loads(path.read_text(encoding="utf-8"), parse_constant=reject_constant)
except FileNotFoundError:
    data = {"entries": []}
except (OSError, ValueError):
    sys.exit("could not read valid usage.json")

if isinstance(data, list):
    data = {"entries": data}
elif not isinstance(data, dict) or not isinstance(data.get("entries"), list):
    sys.exit("unsupported usage.json structure")

previous = data.get("grokbot")
if has_reset == "1" and isinstance(previous, dict):
    reset = previous.get("resets_at")
data["grokbot"] = {
    "weekly_percent": float(percent),
    "resets_at": reset,
    "updated_at": datetime.now(wita).isoformat(),
}
try:
    encoded = json.dumps(data, indent=2, ensure_ascii=False, allow_nan=False).encode("utf-8")
    path.write_bytes(encoded + b"\n")
except (OSError, ValueError):
    sys.exit("could not write valid usage.json")
PYTHON
}

percent="$1"
reset_arg="${2-}"
argument_count="$#"
rewrite_usage "$percent" "$reset_arg" "$argument_count"

warn_usage() { printf 'set-grokbot-usage: warning: %s\n' "$*" >&3; }

stage_usage() {
  local tracked
  tracked="$(git ls-files --stage -- usage.json)" ||
    { warn_usage "could not check usage.json file mode"; return 1; }
  if [[ -L usage.json || $tracked == '120000 '* ]]; then
    warn_usage "usage.json is a symbolic link"
    return 1
  fi
  local error
  if ! error="$(rewrite_usage "$percent" "$reset_arg" "$argument_count" usage.json 2>&1)"; then
    case "$error" in
      "usage.json is a symbolic link"|"could not read valid usage.json"|"unsupported usage.json structure"|"could not write valid usage.json")
        warn_usage "$error" ;;
      *) warn_usage "could not update usage.json" ;;
    esac
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
  git checkout --detach FETCH_HEAD && stage_usage && git commit -m "${message}" -- usage.json ||
    { warn_usage "could not rebuild the usage commit on the fetched branch"; return 1; }
}

commit_usage() (
  export GIT_TERMINAL_PROMPT=0
  export GIT_ASKPASS=/bin/true
  export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh} -o BatchMode=yes"

  local temp repo fetch_url push_url push_result push_status identity value
  local message="chore: update GrokBot weekly usage"

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
    printf 'set-grokbot-usage: usage.json unchanged, skip commit and push\n' >&3
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

commit_usage
