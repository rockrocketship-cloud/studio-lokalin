#!/usr/bin/env bash
# ai-run: run Codex or Claude, log token usage to studio-lokalin/usage.json
# usage: ai-run codex <repo_dir> "<prompt>"
#        ai-run claude <repo_dir> "<prompt>"
set -euo pipefail
export PATH="${HOME}/.local/bin:${PATH}"

USAGE_REPO="${USAGE_REPO:-${HOME}/projects/studio-lokalin}"
USAGE_FILE="${USAGE_REPO}/usage.json"
MAX_ENTRIES=500
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
[[ -d "${USAGE_REPO}/.git" ]] || die "usage repo not found: ${USAGE_REPO}"

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
OUT_FILE="${LOG_DIR}/${AI_KIND}-${STAMP}.out"
# Keep only a short pointer; do not echo secrets from the log.

append_usage() {
  local ai="$1" input="$2" output="$3" total="$4" task="$5"
  python3 - "$USAGE_FILE" "$ai" "$task" "$input" "$output" "$total" "$MAX_ENTRIES" << 'PY'
import json, os, sys
from datetime import datetime, timedelta, timezone

path, ai, task, inp, out, total, max_entries = sys.argv[1:8]
inp, out, total, max_entries = int(inp), int(out), int(total), int(max_entries)
entries = []
if os.path.exists(path):
    try:
        raw = open(path, encoding="utf-8").read().strip()
        if raw:
            data = json.loads(raw)
            if isinstance(data, list):
                entries = data
            elif isinstance(data, dict) and isinstance(data.get("entries"), list):
                entries = data["entries"]
    except Exception:
        entries = []

wita = timezone(timedelta(hours=8))
entries.append({
    "ts": datetime.now(wita).isoformat(),
    "ai": ai,
    "task": task,
    "input": max(0, inp),
    "output": max(0, out),
    "total": max(0, total),
})
entries = entries[-max_entries:]
os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
with open(path, "w", encoding="utf-8") as f:
    json.dump(entries, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
}

commit_usage() {
  # Commit and push usage.json on the current feature branch only. Never force to main.
  # If the branch is main, skip push (user must enable that later).
  git -C "${USAGE_REPO}" add -- "${USAGE_FILE}"
  if git -C "${USAGE_REPO}" diff --cached --quiet -- "${USAGE_FILE}"; then
    printf 'ai-run: usage.json unchanged, skip commit\n' >&2
    return 0
  fi
  git -C "${USAGE_REPO}" commit -m "chore: log token usage ($( [[ ${AI_KIND} == codex ]] && echo ChatGPT || echo Claude ))" -- "${USAGE_FILE}"
  local branch
  branch="$(git -C "${USAGE_REPO}" rev-parse --abbrev-ref HEAD)"
  if [[ "${branch}" == "main" || "${branch}" == "master" ]]; then
    printf 'ai-run: on %s, not pushing usage.json (enable later)\n' "${branch}" >&2
    return 0
  fi
  git -C "${USAGE_REPO}" push -u origin "${branch}"
}

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

for obj in reversed(candidates):
    if isinstance(obj, dict) and ("usage" in obj or "input_tokens" in obj):
        take_usage(obj.get("usage") or obj)
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
  python3 - "${OUT_FILE}" << 'PY' >&2
import re, sys
p=sys.argv[1]
lines=open(p, encoding="utf-8", errors="replace").read().splitlines()
red=re.compile(r"(ghp_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+|sk-(?:ant-)?[A-Za-z0-9_-]+)", re.I)
for line in lines[-40:]:
    print(red.sub("[redacted]", line))
PY
  read -r INP OUT TOTAL < <(parse_codex_tokens "${OUT_FILE}")
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
    env -u ANTHROPIC_API_KEY claude -p --output-format json --dangerously-skip-permissions "${PROMPT}"
  ) >"${OUT_FILE}" 2>&1
  rc=$?
  set -e
  # Do not print raw JSON (may be huge). Summarize result / errors only.
  python3 - "${OUT_FILE}" << 'PY' >&2
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
if cands and isinstance(cands[-1], dict):
    o=cands[-1]
    result=o.get("result") or o.get("error") or o.get("type") or ""
    if isinstance(result, str):
        print(red.sub("[redacted]", result[-2000:]))
    is_err=o.get("is_error") or o.get("type")=="error"
    print(f"claude is_error={is_err} type={o.get('type')}", file=sys.stderr)
else:
    print(red.sub("[redacted]", "\n".join(text.splitlines()[-20:])), file=sys.stderr)
PY
  read -r INP OUT TOTAL < <(parse_claude_tokens "${OUT_FILE}")
  AI_LABEL="Claude"
fi

printf 'ai-run: %s tokens input=%s output=%s total=%s exit=%s\n' "${AI_LABEL}" "${INP}" "${OUT}" "${TOTAL}" "${rc}" >&2
printf 'ai-run: log %s\n' "${OUT_FILE}" >&2

append_usage "${AI_LABEL}" "${INP}" "${OUT}" "${TOTAL}" "${TASK_LABEL}"
commit_usage

exit "${rc}"
