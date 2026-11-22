#!/usr/bin/env bash
# Record GrokBot weekly quota usage in the published usage.json.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
collector="$script_dir/collect-usage.sh"
if [[ ! -x $collector ]]; then
  collector="${HOME}/bin/collect-usage"
fi
exec "$collector" --set-grokbot-usage "$@"
