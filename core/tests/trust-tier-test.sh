#!/usr/bin/env bash
# trust-tier-test.sh — verify core/hooks/trust_tier.py per-project tier detection.
#
# Contract under test (fail-closed):
#   personal <- git remote origin owner in trust.list owners, OR workspace root
#               under a trust.list path prefix
#   collab   <- everything else: no trust file, unparseable lines, no/unknown
#               remote, repo-side downgrade marker, escalation attempts, errors
#
# The trust file is pinned via AGENT_TRUST_FILE (test seam) so the battery never
# touches the real ~/.agent/trust.list. Workspaces are throwaway mktemp git
# repos; remotes are added with `git remote add` (no network).
#
# Usage: bash core/tests/trust-tier-test.sh
# Exit 0: all pass. Exit 1: one or more failures.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODULE="$REPO_ROOT/core/hooks/trust_tier.py"

PASS=0
FAIL=0

WORK="$(mktemp -d)"
trap '[[ -n "$WORK" && -d "$WORK" ]] && rm -rf "$WORK"' EXIT

TRUST="$WORK/trust.list"
NOFILE="$WORK/does-not-exist.list"

ok()  { echo "  ok   [$1]"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL [$1] $2"; FAIL=$((FAIL + 1)); }

# detect <trust-file> <root> -> DETECTED
detect() {
  DETECTED="$(AGENT_TRUST_FILE="$1" python3 "$MODULE" --detect "$2" 2>/dev/null)"
}

# expect <name> <trust-file> <root> <personal|collab>
expect() {
  local name="$1" trust="$2" root="$3" want="$4"
  detect "$trust" "$root"
  if [[ "$DETECTED" == "$want" ]]; then
    ok "$name (expected=$want)"
  else
    bad "$name" "expected=$want got='$DETECTED'"
  fi
}

# mkrepo <dir> [remote-url]
mkrepo() {
  local dir="$1" url="${2:-}"
  mkdir -p "$dir"
  git -C "$dir" init -q
  [[ -n "$url" ]] && git -C "$dir" remote add origin "$url"
}

# ---------------------------------------------------------------------------
# fixtures
# ---------------------------------------------------------------------------

cat > "$TRUST" <<'EOF'
# trusted owners and paths
owner Example-Owner
EOF
printf 'path %s/trusted-zone\n' "$WORK" >> "$TRUST"

mkrepo "$WORK/owned-https"  "https://github.com/example-owner/some-repo.git"
mkrepo "$WORK/owned-ssh"    "git@github.com:Example-Owner/some-repo.git"
mkrepo "$WORK/owned-sshurl" "ssh://git@github.com/example-owner/some-repo"
mkrepo "$WORK/foreign"      "https://github.com/other-org/some-repo.git"
mkrepo "$WORK/no-remote"
mkdir -p "$WORK/trusted-zone/project" "$WORK/untrusted-zone/project"

echo "=== fail-closed: nothing trusted without a trust list ==="
expect "a1-no-trust-file-collab"   "$NOFILE" "$WORK/owned-https" collab
expect "a2-missing-root-collab"    "$TRUST"  "$WORK/nope"        collab

echo
echo "=== owner matching (remote URL forms, case-insensitive) ==="
expect "b1-https-owner-personal"   "$TRUST" "$WORK/owned-https"  personal
expect "b2-scp-ssh-owner-personal" "$TRUST" "$WORK/owned-ssh"    personal
expect "b3-ssh-url-owner-personal" "$TRUST" "$WORK/owned-sshurl" personal
expect "b4-foreign-owner-collab"   "$TRUST" "$WORK/foreign"      collab
expect "b5-no-remote-collab"       "$TRUST" "$WORK/no-remote"    collab

echo
echo "=== path prefix matching (covers no-remote personal dirs) ==="
expect "c1-under-trusted-path-personal" "$TRUST" "$WORK/trusted-zone/project"   personal
expect "c2-outside-trusted-path-collab" "$TRUST" "$WORK/untrusted-zone/project" collab
mkrepo "$WORK/trusted-zone/foreign-clone" "https://github.com/other-org/some-repo.git"
expect "c3-foreign-remote-blocks-path-grant" "$TRUST" "$WORK/trusted-zone/foreign-clone" collab

echo
echo "=== repo-side marker: downgrade only, never escalate ==="
mkdir -p "$WORK/owned-https/.agent" "$WORK/foreign/.agent"
echo "collab" > "$WORK/owned-https/.agent/trust-tier"
expect "d1-repo-downgrade-wins"    "$TRUST" "$WORK/owned-https" collab
echo "personal" > "$WORK/foreign/.agent/trust-tier"
expect "d2-repo-escalation-ignored" "$TRUST" "$WORK/foreign"    collab
rm -f "$WORK/owned-https/.agent/trust-tier"
expect "d3-marker-removed-personal-again" "$TRUST" "$WORK/owned-https" personal

echo
echo "=== degraded inputs stay collab (never crash, never trust) ==="
printf 'owner\npath relative/not/abs\ngarbage line without meaning\n' > "$WORK/broken.list"
expect "e1-broken-trust-file-collab" "$WORK/broken.list" "$WORK/owned-https" collab
printf '\xef\xbb\xbb\x00binary\x01junk' > "$WORK/binary.list"
expect "e2-binary-trust-file-collab" "$WORK/binary.list" "$WORK/owned-https" collab

echo
echo "=== CLI contract ==="
detect "$TRUST" "$WORK/owned-https"
if [[ "$DETECTED" == "personal" || "$DETECTED" == "collab" ]]; then
  ok "f1-cli-prints-bare-tier"
else
  bad "f1-cli-prints-bare-tier" "got '$DETECTED'"
fi
AGENT_TRUST_FILE="$TRUST" python3 "$MODULE" >/dev/null 2>&1
if [[ $? -eq 2 ]]; then ok "f2-no-args-usage-rc2"; else bad "f2-no-args-usage-rc2" "expected rc 2"; fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
