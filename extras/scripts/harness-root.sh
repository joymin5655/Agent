#!/usr/bin/env bash
# harness-root.sh — print the agent-harness (core) root for agent-harness-extras skills.
#
# The extras plugin ships skills only; the infra scripts and registries they drive
# (core/infra/backends.json, manager-audit.sh, telemetry-digest.sh, ...) live in the
# core plugin. A plugin cannot read outside its own cached root, so resolve the core
# root explicitly, first hit wins:
#   1. $AGENT_HARNESS_ROOT                        (explicit override)
#   2. <extras root>/..                           (extras/ inside a checkout / --plugin-dir)
#   3. sibling plugin-cache entry                 (<cache>/agent/agent-harness/<version>, the
#                                                  extras' own version first, else the highest)
# The current directory is deliberately NOT a candidate: the result is used as an
# execution root, so a random repo that happens to carry core/infra/ must not qualify.
# A candidate counts only if it carries the whole marker set below.
# Exit 0 + path on stdout; exit 1 + hint on stderr when nothing resolves.
set -u
EXTRAS_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

is_core() {
  [[ -n "${1:-}" ]] || return 1
  local f
  for f in core/infra/backends.json core/infra/manager-audit.sh core/infra/telemetry-digest.sh .claude-plugin/plugin.json; do
    [[ -f "$1/$f" ]] || return 1
  done
}

for c in "${AGENT_HARNESS_ROOT:-}" "$EXTRAS_ROOT/.."; do
  if is_core "$c"; then (cd "$c" && pwd); exit 0; fi
done

# plugin cache: <cache>/<marketplace>/agent-harness-extras/<ver> -> <cache>/<marketplace>/agent-harness/<ver>
ver="$(basename "$EXTRAS_ROOT")"
core_parent="$(dirname "$(dirname "$EXTRAS_ROOT")")/agent-harness"
if is_core "$core_parent/$ver"; then echo "$core_parent/$ver"; exit 0; fi
if [[ -d "$core_parent" ]]; then
  best="$(ls -1 "$core_parent" 2>/dev/null | sort -V | tail -n 1)"
  if is_core "$core_parent/$best"; then echo "$core_parent/$best"; exit 0; fi
fi

echo "harness-root: agent-harness core not found — install it (/plugin install agent-harness@agent), or set AGENT_HARNESS_ROOT to a harness checkout" >&2
exit 1
