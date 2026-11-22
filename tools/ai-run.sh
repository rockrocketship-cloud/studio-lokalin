#!/usr/bin/env bash
# ai-run: run Codex or Claude, log token usage to studio-lokalin/usage.json
# usage: ai-run codex <repo_dir> "<prompt>"
#        ai-run claude <repo_dir> "<prompt>"
set -euo pipefail
umask 077
export PATH="${HOME}/.local/bin:${PATH}"

USAGE_REPO="${USAGE_REPO:-${HOME}/projects/studio-lokalin}"
AI_RUN_BRANCH="${AI_RUN_BRANCH:-main}"
MAX_ENTRIES=500
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COLLECT_USAGE="$SCRIPT_DIR/collect-usage.sh"
if [[ ! -x $COLLECT_USAGE ]]; then
  COLLECT_USAGE="$SCRIPT_DIR/collect-usage"
fi
LOG_DIR="${HOME}/.cache/ai-run"
mkdir -p "${LOG_DIR}"

die() { printf 'ai-run: %s\n' "$*" >&2; exit 1; }
usage() { printf 'usage: ai-run codex <repo_dir> "<prompt>"\n       ai-run claude <repo_dir> "<prompt>"\n' >&2; exit 2; }

[[ ${1:-} == "-h" || ${1:-} == "--help" ]] && usage
[[ $# -ge 3 ]] || usage

AI_KIND="$1"
REPO_DIR="$2"
shift 2
PROMPT="$*"

case "${AI_KIND}" in
  codex|claude) ;;
  *) die "unknown AI '${AI_KIND}' (use codex or claude)" ;;
esac

[[ -d "${REPO_DIR}" ]] || die "repo_dir not a directory: ${REPO_DIR}"
REPO_DIR="$(cd "${REPO_DIR}" && pwd)"

# Truncate and redact the task label. Never keep tokens/secrets in usage.json.
sanitize_task() {
  python3 -c '
import re, sys
t = sys.stdin.read()
t = re.sub(r"ghp_[A-Za-z0-9_]+", "[redacted]", t)
t = re.sub(r"github_pat_[A-Za-z0-9_]+", "[redacted]", t)
t = re.sub(r"sk-[A-Za-z0-9_-]+", "[redacted]", t)
t = re.sub(r"sk-ant-[A-Za-z0-9_-]+", "[redacted]", t)
t = re.sub(r"(?i)(oauth[_-]?token|api[_-]?key|authorization|bearer|password|secret)[=:\s]+\S+", r"\1=[redacted]", t)
t = re.sub(r"\s+", " ", t).strip()
print(t[:80], end="")
' <<< "${PROMPT}"
}

TASK_LABEL="$(sanitize_task)"
STAMP="$(date +%Y%m%dT%H%M%S)"
OUT_FILE="$(mktemp "${LOG_DIR}/${AI_KIND}-${STAMP}-XXXXXX.out")" ||
  die "could not create private log"
# Keep only a short pointer; do not echo secrets from the log.

append_usage() {
  local usage_file="$1" ai="$2" input="$3" output="$4" total="$5" task="$6"
  python3 - "$usage_file" "$ai" "$task" "$input" "$output" "$total" "$MAX_ENTRIES" << 'PY'
import json, os, sys
from datetime import datetime, timedelta, timezone

path, ai, task, inp, out, total, max_entries = sys.argv[1:8]
inp, out, total, max_entries = int(inp), int(out), int(total), int(max_entries)

def reject_constant(_):
    raise ValueError("invalid JSON constant")

try:
    with open(path, encoding="utf-8") as f:
        raw = f.read().strip(" \t\r\n")
except FileNotFoundError:
    raw = ""

data = json.loads(raw, parse_constant=reject_constant) if raw else []
if isinstance(data, list):
    entries = data
elif isinstance(data, dict) and isinstance(data.get("entries"), list):
    entries = data["entries"]
else:
    sys.exit("unsupported usage.json structure")

wita = timezone(timedelta(hours=8))
entries.append({
    "ts": datetime.now(wita).isoformat(),
    "ai": ai,
    "task": task,
    "input": max(0, inp),
    "output": max(0, out),
    "total": max(0, total),
})
del entries[:-max_entries]
encoded = json.dumps(data, indent=2, ensure_ascii=False, allow_nan=False).encode("utf-8")
os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
with open(path, "wb") as f:
    f.write(encoded + b"\n")
PY
}

warn_usage() { printf 'ai-run: warning: %s\n' "$*" >&3; }

stage_usage() {
  [[ ! -L usage.json ]] ||
    { warn_usage "usage.json is a symbolic link"; return 1; }
  append_usage usage.json "${AI_LABEL}" "${INP}" "${OUT}" "${TOTAL}" "${TASK_LABEL}" ||
    { warn_usage "could not append usage.json"; return 1; }
  local -a limit_args=(--update-file usage.json)
  if [[ $AI_KIND == claude ]]; then
    limit_args+=(--claude-log "$OUT_FILE")
  fi
  if ! "$COLLECT_USAGE" "${limit_args[@]}" 2>&3; then
    warn_usage "could not refresh AI limits"
  fi
  git add -- usage.json ||
    { warn_usage "could not stage usage.json"; return 1; }
}

rebase_usage() {
  timeout -k 5s 60s git fetch --no-tags origin "refs/heads/${AI_RUN_BRANCH}" ||
    { warn_usage "could not fetch the target branch before push"; return 1; }
  if git rebase FETCH_HEAD; then
    return 0
  fi

  # Both runs can append at the same spot. Rebuild our entry on the fetched file if that conflicts.
  if [[ -n "$(git ls-files -u -- usage.json)" ]] &&
    git rebase --abort && git checkout --detach FETCH_HEAD; then
    warn_usage "rebase conflicted in usage.json; rebuilding the entry on the fetched branch"
    stage_usage && git commit -m "${message}" -- usage.json ||
      { warn_usage "could not rebuild the usage commit after a rebase conflict"; return 1; }
  else
    warn_usage "could not rebase the usage commit"
    return 1
  fi
}

commit_usage() (
  export GIT_TERMINAL_PROMPT=0
  export GIT_ASKPASS=/bin/true
  export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh} -o BatchMode=yes"

  local temp repo fetch_url push_url push_result push_status identity value
  local message="chore: log token usage (${AI_LABEL})"

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
    if value="$(git -C "${repo}" config --local --get "${identity}")"; then
      git config "${identity}" "${value}" ||
        { warn_usage "could not set the usage commit identity"; return 1; }
    fi
  done

  stage_usage || return 1
  if git diff --cached --quiet -- usage.json; then
    printf 'ai-run: usage.json unchanged, skip commit and push\n' >&3
    return 0
  fi
  git commit -m "${message}" -- usage.json ||
    { warn_usage "could not commit usage.json"; return 1; }

  rebase_usage || return 1
  if push_result="$(LC_ALL=C timeout -k 5s 60s git push --porcelain origin "HEAD:refs/heads/${AI_RUN_BRANCH}")"; then
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
      timeout -k 5s 60s git push origin "HEAD:refs/heads/${AI_RUN_BRANCH}" ||
        { warn_usage "could not push usage.json after retry"; return 1; }
      ;;
    *) warn_usage "could not push usage.json"; return 1 ;;
  esac
) 3>&2 >/dev/null 2>/dev/null

parse_codex_tokens() {
  python3 - "$1" << 'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
# Prefer the last "tokens used" figure.
patterns = [
    r"tokens used[:\s]+([0-9][0-9,]*)",
    r"total[_ ]tokens[:\s]+([0-9][0-9,]*)",
    r'"total_tokens"\s*:\s*([0-9]+)',
]
total = 0
for pat in patterns:
    ms = list(re.finditer(pat, text, re.I))
    if ms:
        total = int(ms[-1].group(1).replace(",", ""))
        break
inp = out = 0
mi = re.findall(r'(?:input[_ ]tokens|prompt[_ ]tokens)[:\s"]+([0-9][0-9,]*)', text, re.I)
mo = re.findall(r'(?:output[_ ]tokens|completion[_ ]tokens)[:\s"]+([0-9][0-9,]*)', text, re.I)
if mi: inp = int(mi[-1].replace(",", ""))
if mo: out = int(mo[-1].replace(",", ""))
if total == 0 and (inp or out):
    total = inp + out
print(f"{inp} {out} {total}")
PY
}

parse_claude_tokens() {
  python3 - "$1" << 'PY'
import json, re, sys
text = open(sys.argv[1], encoding="utf-8", errors="replace").read().strip()
inp = out = cache_read = cache_create = 0
obj = None
# File may contain leading logs; find the last JSON object.
candidates = []
dec = json.JSONDecoder()
i, n = 0, len(text)
while i < n:
    if text[i] == "{":
        try:
            obj, end = dec.raw_decode(text, i)
            candidates.append(obj)
            i = end
            continue
        except json.JSONDecodeError:
            pass
    i += 1

def take_usage(u):
    global inp, out, cache_read, cache_create
    if not isinstance(u, dict):
        return
    inp = int(u.get("input_tokens") or u.get("input") or 0)
    out = int(u.get("output_tokens") or u.get("output") or 0)
    cache_read = int(u.get("cache_read_input_tokens") or 0)
    cache_create = int(
        u.get("cache_creation_input_tokens")
        or (u.get("cache_creation") or {}).get("ephemeral_5m_input_tokens")
        or 0
    )
    if isinstance(u.get("cache_creation"), dict):
        cache_create = int(u["cache_creation"].get("ephemeral_5m_input_tokens") or 0) + int(
            u["cache_creation"].get("ephemeral_1h_input_tokens") or 0
        )

results = [obj for obj in candidates if isinstance(obj, dict) and obj.get("type") == "result"]
result_usage = results[-1].get("usage") if results else None
for obj in reversed(results[-1:] if result_usage else candidates):
    if not isinstance(obj, dict):
        continue
    message = obj.get("message")
    usage = obj.get("usage") or (message.get("usage") if isinstance(message, dict) else None)
    if usage or "input_tokens" in obj:
        take_usage(usage or obj)
        break
else:
    # Fallback regex if JSON parse failed.
    def last_int(pat):
        ms = re.findall(pat, text)
        return int(ms[-1]) if ms else 0
    inp = last_int(r'"input_tokens"\s*:\s*([0-9]+)')
    out = last_int(r'"output_tokens"\s*:\s*([0-9]+)')
    cache_read = last_int(r'"cache_read_input_tokens"\s*:\s*([0-9]+)')
    cache_create = last_int(r'"cache_creation_input_tokens"\s*:\s*([0-9]+)')

# Count cache tokens on the input side.
inp = inp + cache_read + cache_create
total = inp + out
print(f"{inp} {out} {total}")
PY
}

rc=0
if [[ "${AI_KIND}" == "codex" ]]; then
  set +e
  env -u OPENAI_API_KEY codex exec --dangerously-bypass-approvals-and-sandbox -C "${REPO_DIR}" "${PROMPT}" >"${OUT_FILE}" 2>&1
  rc=$?
  set -e
  # Show a short tail only; never dump credentials if they leaked into a log.
  python3 - "${OUT_FILE}" << 'PY' >&2 || printf 'ai-run: warning: could not summarize command output\n' >&2
import re, sys
p=sys.argv[1]
lines=open(p, encoding="utf-8", errors="replace").read().splitlines()
red=re.compile(r"(ghp_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+|sk-(?:ant-)?[A-Za-z0-9_-]+)", re.I)
for line in lines[-40:]:
    print(red.sub("[redacted]", line))
PY
  if ! read -r INP OUT TOTAL < <(parse_codex_tokens "${OUT_FILE}" 2>/dev/null); then
    printf 'ai-run: warning: could not parse token usage\n' >&2
    exit "${rc}"
  fi
  AI_LABEL="ChatGPT"
else
  if [[ ! -f "${HOME}/.claude/oauth_token" ]]; then
    die "missing ~/.claude/oauth_token"
  fi
  # Token stays in the environment only; never printed.
  set +e
  (
    export CLAUDE_CODE_OAUTH_TOKEN
    CLAUDE_CODE_OAUTH_TOKEN="$(cat "${HOME}/.claude/oauth_token")"
    cd "${REPO_DIR}"
    env -u ANTHROPIC_API_KEY claude -p --output-format stream-json --verbose --dangerously-skip-permissions "${PROMPT}"
  ) >"${OUT_FILE}" 2>&1
  rc=$?
  set -e
  # Do not print raw JSON (may be huge). Summarize result / errors only.
  python3 - "${OUT_FILE}" << 'PY' >&2 || printf 'ai-run: warning: could not summarize command output\n' >&2
import json, re, sys
text=open(sys.argv[1], encoding="utf-8", errors="replace").read()
red=re.compile(r"(ghp_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+|sk-(?:ant-)?[A-Za-z0-9_-]+)", re.I)
# Print a short result snippet if present.
dec=json.JSONDecoder()
obj=None
i,n=0,len(text)
cands=[]
while i<n:
    if text[i]=="{":
        try:
            o,end=dec.raw_decode(text,i)
            cands.append(o)
            i=end
            continue
        except json.JSONDecodeError:
            pass
    i+=1
results = [obj for obj in cands if isinstance(obj, dict) and obj.get("type") == "result"]
if results or (cands and isinstance(cands[-1], dict)):
    o = (results or cands)[-1]
    result=o.get("result") or o.get("error") or o.get("type") or ""
    if isinstance(result, str):
        print(red.sub("[redacted]", result[-2000:]))
    is_err=o.get("is_error") or o.get("type")=="error"
    print(f"claude is_error={is_err} type={o.get('type')}", file=sys.stderr)
else:
    print(red.sub("[redacted]", "\n".join(text.splitlines()[-20:])), file=sys.stderr)
PY
  if ! read -r INP OUT TOTAL < <(parse_claude_tokens "${OUT_FILE}" 2>/dev/null); then
    printf 'ai-run: warning: could not parse token usage\n' >&2
    exit "${rc}"
  fi
  AI_LABEL="Claude"
fi

printf 'ai-run: %s tokens input=%s output=%s total=%s exit=%s\n' "${AI_LABEL}" "${INP}" "${OUT}" "${TOTAL}" "${rc}" >&2
printf 'ai-run: log %s\n' "${OUT_FILE}" >&2

commit_usage || :

exit "${rc}"
