#!/usr/bin/env bash
# antigravity-native-hooks-test.sh — W5-4: the Antigravity (agy) native-hook plugin install.
#
# agy loads hooks from a plugin folder (measured on 1.2.12: plugin.json + hooks.json).
# adapters/antigravity/install-plugin.py renders hooks.json.template with the
# ABSOLUTE checkout path and writes the folder atomically. The user's own
# ~/.gemini/config/hooks.json and settings.json (other tools register there; agy
# rewrites settings.json itself) are never read or written — this battery pins
# that with byte-for-byte cmp against pre-seeded copies.
#
# Everything runs in a scratch HOME; no agy is invoked.
#
# Usage: bash core/tests/antigravity-native-hooks-test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALLER="$REPO_ROOT/adapters/antigravity/install-plugin.py"
SETUP="$REPO_ROOT/setup.sh"

PASS=0
FAIL=0
check() {
  local name="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then echo "  ok   [$name]"; PASS=$((PASS + 1))
  else echo "  FAIL [$name] expected '$want', got '$got'"; FAIL=$((FAIL + 1)); fi
}
check_true() { local n="$1"; shift; if "$@"; then check "$n" 0 0; else check "$n" 0 1; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM
export HOME="$TMP/home"
mkdir -p "$HOME/.gemini/config" "$HOME/.gemini/antigravity-cli"
unset AGENT_ANTIGRAVITY_PLUGIN_DIR
export AGENT_SETUP_NO_DOCTOR=1

# Pre-seeded user config that must survive untouched.
cat > "$HOME/.gemini/config/hooks.json" <<'JSON'
{"herdr": {"PreToolUse": [{"matcher": "*", "hooks": [{"type": "command", "command": "/opt/herdr/hook.sh"}]}]},
 "orca-status": {"Stop": [{"type": "command", "command": "/opt/orca/status.sh"}]}}
JSON
printf '{"modelProvider": "keyring", "permissions": {"allow": ["command(git status)"]}}\n' \
  > "$HOME/.gemini/antigravity-cli/settings.json"
cp "$HOME/.gemini/config/hooks.json" "$TMP/hooks.before"
cp "$HOME/.gemini/antigravity-cli/settings.json" "$TMP/settings.before"
user_files_untouched() {
  cmp -s "$HOME/.gemini/config/hooks.json" "$TMP/hooks.before" &&
  cmp -s "$HOME/.gemini/antigravity-cli/settings.json" "$TMP/settings.before"
}

DEFAULT_DIR="$HOME/.gemini/config/plugins/agent-harness"

# hook_cmd <hooks.json> <event> -> the (single) command string for that event.
hook_cmd() {
  python3 - "$1" "$2" <<'PY'
import json, sys
e = json.load(open(sys.argv[1]))["agent-harness"][sys.argv[2]][0]
print((e.get("hooks") or [e])[0]["command"])
PY
}

echo "=== (a) fresh install to the default plugin dir ==="
out="$(python3 "$INSTALLER" --root "$REPO_ROOT" 2>&1)"; rc=$?
check "install-rc" 0 "$rc"
check_true "plugin.json-exists" test -f "$DEFAULT_DIR/plugin.json"
check_true "hooks.json-exists" test -f "$DEFAULT_DIR/hooks.json"
check "plugin-name" "agent-harness" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["name"])' "$DEFAULT_DIR/plugin.json")"
check "plugin-keys-schema-only" "description,name" "$(python3 -c 'import json,sys; print(",".join(sorted(json.load(open(sys.argv[1])))))' "$DEFAULT_DIR/plugin.json")"
# hooks.json: exact events/matchers/commands/timeouts; absolute quoted adapter path.
shape="$(python3 - "$DEFAULT_DIR/hooks.json" "$REPO_ROOT" <<'PY'
import json, os, sys
d = json.load(open(sys.argv[1])); root = sys.argv[2]
assert list(d) == ["agent-harness"], list(d)
s = d["agent-harness"]
assert sorted(s) == ["PostToolUse", "PreToolUse", "Stop"], sorted(s)
m = "run_command|write_to_file|replace_file_content|multi_replace_file_content"
# PreToolUse also guards send_command_input (text typed into a live shell); PostToolUse observes only.
matchers = {"PreToolUse": "run_command|send_command_input|write_to_file|replace_file_content|multi_replace_file_content",
            "PostToolUse": m}
adapter = os.path.join(root, "adapters/antigravity/adapter.sh")
for ev in ("PreToolUse", "PostToolUse"):
    assert len(s[ev]) == 1 and s[ev][0]["matcher"] == matchers[ev], (ev, s[ev])
    assert len(s[ev][0]["hooks"]) == 1
    h = s[ev][0]["hooks"][0]
    assert h == {"type": "command", "command": f'"{adapter}" {ev}', "timeout": 30}, h
assert s["Stop"] == [{"type": "command", "command": f'"{adapter}" Stop', "timeout": 30}], s["Stop"]
assert os.path.isabs(adapter) and os.access(adapter, os.X_OK), adapter
assert "{{" not in open(sys.argv[1]).read()
print("OK")
PY
)" || shape="ERR"
check "hooks-shape-and-absolute-adapter" "OK" "$shape"
check_true "user-hooks-and-settings-untouched" user_files_untouched

echo "=== (b) second install is a no-op (content + mtime unchanged) ==="
before_h="$(cksum < "$DEFAULT_DIR/hooks.json")"; before_p="$(cksum < "$DEFAULT_DIR/plugin.json")"
sleep 1.1
mt_h="$(stat -f %m "$DEFAULT_DIR/hooks.json" 2>/dev/null || stat -c %Y "$DEFAULT_DIR/hooks.json")"
mt_p="$(stat -f %m "$DEFAULT_DIR/plugin.json" 2>/dev/null || stat -c %Y "$DEFAULT_DIR/plugin.json")"
out="$(python3 "$INSTALLER" --root "$REPO_ROOT" 2>&1)"; rc=$?
check "reinstall-rc" 0 "$rc"
check_true "reinstall-says-up-to-date" test "$(printf '%s' "$out" | grep -c 'up-to-date')" -ge 2
check "hooks-content-same" "$before_h" "$(cksum < "$DEFAULT_DIR/hooks.json")"
check "plugin-content-same" "$before_p" "$(cksum < "$DEFAULT_DIR/plugin.json")"
check "hooks-mtime-same" "$mt_h" "$(stat -f %m "$DEFAULT_DIR/hooks.json" 2>/dev/null || stat -c %Y "$DEFAULT_DIR/hooks.json")"
check "plugin-mtime-same" "$mt_p" "$(stat -f %m "$DEFAULT_DIR/plugin.json" 2>/dev/null || stat -c %Y "$DEFAULT_DIR/plugin.json")"
check "no-tmp-litter" "0" "$(find "$DEFAULT_DIR" -name '*.tmp*' -o -name '.*tmp*' | wc -l | tr -d ' ')"

echo "=== (c) a changed root rewrites hooks.json (idempotent per content, not per existence) ==="
ALT="$TMP/alt root"; mkdir -p "$ALT/adapters/antigravity"
cp "$REPO_ROOT/adapters/antigravity/hooks.json.template" "$REPO_ROOT/adapters/antigravity/plugin.json" "$ALT/adapters/antigravity/"
printf '#!/bin/sh\n' > "$ALT/adapters/antigravity/adapter.sh"; chmod +x "$ALT/adapters/antigravity/adapter.sh"
python3 "$INSTALLER" --root "$ALT" >/dev/null 2>&1; rc=$?
check "alt-root-rc" 0 "$rc"
check "alt-root-rendered" "\"$ALT/adapters/antigravity/adapter.sh\" PreToolUse" "$(hook_cmd "$DEFAULT_DIR/hooks.json" PreToolUse)"
python3 "$INSTALLER" --root "$REPO_ROOT" >/dev/null 2>&1

echo "=== (d) --dry-run writes nothing ==="
DRY="$TMP/dry/agent-harness"
out="$(python3 "$INSTALLER" --root "$REPO_ROOT" --target "$DRY" --dry-run 2>&1)"; rc=$?
check "dry-run-rc" 0 "$rc"
check_true "dry-run-no-dir" test ! -e "$TMP/dry"
check_true "dry-run-says-would" grep -qi "would" <<<"$out"

echo "=== (e) foreign plugin dir: refused and untouched ==="
FOREIGN="$TMP/foreign/other"; mkdir -p "$FOREIGN"
printf '{"name": "someone-elses-plugin"}\n' > "$FOREIGN/plugin.json"
printf '{"x": 1}\n' > "$FOREIGN/hooks.json"
cp -R "$FOREIGN" "$TMP/foreign.before"
python3 "$INSTALLER" --root "$REPO_ROOT" --target "$FOREIGN" >/dev/null 2>&1; rc=$?
check "foreign-install-refused" 1 "$rc"
check_true "foreign-untouched" diff -r "$FOREIGN" "$TMP/foreign.before"
python3 "$INSTALLER" --root "$REPO_ROOT" --target "$FOREIGN" --uninstall >/dev/null 2>&1; rc=$?
check "foreign-uninstall-refused" 1 "$rc"
check_true "foreign-still-untouched" diff -r "$FOREIGN" "$TMP/foreign.before"
# Non-empty dir with no manifest is not ours either.
NOMAN="$TMP/noman"; mkdir -p "$NOMAN"; printf 'keep\n' > "$NOMAN/notes.txt"
python3 "$INSTALLER" --root "$REPO_ROOT" --target "$NOMAN" >/dev/null 2>&1; rc=$?
check "manifestless-nonempty-refused" 1 "$rc"
check "manifestless-untouched" "keep" "$(cat "$NOMAN/notes.txt")"; check_true "manifestless-no-new-files" test "$(find "$NOMAN" -mindepth 1 | wc -l | tr -d ' ')" -eq 1
# Target that is a regular file.
printf 'file\n' > "$TMP/afile"
python3 "$INSTALLER" --root "$REPO_ROOT" --target "$TMP/afile" >/dev/null 2>&1; rc=$?
check "file-target-refused" 1 "$rc"
check "file-target-untouched" "file" "$(cat "$TMP/afile")"

echo "=== (f) unsafe root refused; nothing written ==="
# Every bad-named root is a REAL, complete checkout fixture, so the only thing that can refuse it
# is the character / absolute-path check (a missing adapter.sh would refuse it anyway and hide a
# regression in that check).
mkroot() {
  mkdir -p "$1/adapters/antigravity"
  cp "$REPO_ROOT/adapters/antigravity/hooks.json.template" "$REPO_ROOT/adapters/antigravity/plugin.json" "$1/adapters/antigravity/"
  printf '#!/bin/sh\n' > "$1/adapters/antigravity/adapter.sh"; chmod +x "$1/adapters/antigravity/adapter.sh"
}
# shellcheck disable=SC2016  # literal $ and backtick are the point
for bad in 'quo"te' $'new\nline' 'dol$lar' 'back`tick' 'back\slash'; do
  BADT="$TMP/badt"; rm -rf "$BADT"
  mkroot "$TMP/$bad"
  err="$(python3 "$INSTALLER" --root "$TMP/$bad" --target "$BADT" 2>&1 >/dev/null)"; rc=$?
  check "unsafe-root-refused[$(printf '%q' "$bad")]" 1 "$rc"
  check_true "unsafe-root-nothing-written[$(printf '%q' "$bad")]" test ! -e "$BADT"
  check_true "unsafe-root-reason-is-the-char-check[$(printf '%q' "$bad")]" grep -q "shell-active" <<<"$err"
done
# Mutation self-check: with the character guard emptied the same fixture installs (rc 0), so the
# loop above really is what pins the guard.
MUT="$TMP/installer-mutant.py"
sed 's/^UNSAFE_ROOT_CHARS = .*/UNSAFE_ROOT_CHARS = set()/' "$INSTALLER" > "$MUT"
python3 "$MUT" --root "$TMP/quo\"te" --target "$TMP/badt-mut" >/dev/null 2>&1; rc=$?
check "unsafe-root-guard-is-load-bearing" 0 "$rc"
python3 "$INSTALLER" --root "$TMP/does-not-exist" --target "$TMP/badt2" >/dev/null 2>&1; rc=$?
check "missing-adapter-root-refused" 1 "$rc"
# A relative root that DOES hold a complete checkout is refused for being relative.
REL="$TMP/relbase"; mkroot "$REL/relative/path"
err="$(cd "$REL" && python3 "$INSTALLER" --root "relative/path" --target "$TMP/badt3" 2>&1 >/dev/null)"; rc=$?
check "relative-root-refused" 1 "$rc"
check_true "relative-root-reason" grep -q "not an absolute path" <<<"$err"

echo "=== (g) uninstall removes only our dir ==="
python3 "$INSTALLER" --root "$REPO_ROOT" --uninstall >/dev/null 2>&1; rc=$?
check "uninstall-rc" 0 "$rc"
check_true "our-dir-gone" test ! -e "$DEFAULT_DIR"
check_true "plugins-parent-kept" test -d "$HOME/.gemini/config/plugins"
check_true "user-hooks-and-settings-untouched-after-uninstall" user_files_untouched
python3 "$INSTALLER" --root "$REPO_ROOT" --uninstall >/dev/null 2>&1; rc=$?
check "uninstall-when-absent-rc" 0 "$rc"
# A user file added inside our dir survives (only our two files are removed).
python3 "$INSTALLER" --root "$REPO_ROOT" >/dev/null 2>&1
printf 'mine\n' > "$DEFAULT_DIR/extra.txt"
python3 "$INSTALLER" --root "$REPO_ROOT" --uninstall >/dev/null 2>&1; rc=$?
check "uninstall-extra-rc" 0 "$rc"
check "extra-file-kept" "mine" "$(cat "$DEFAULT_DIR/extra.txt" 2>/dev/null)"
check_true "our-files-gone" test ! -e "$DEFAULT_DIR/hooks.json" -a ! -e "$DEFAULT_DIR/plugin.json"
# The half-uninstalled folder (user file kept) must stay ours: uninstall again and reinstall both work.
python3 "$INSTALLER" --root "$REPO_ROOT" --uninstall >/dev/null 2>&1; rc=$?
check "uninstall-again-after-extra-rc" 0 "$rc"
python3 "$INSTALLER" --root "$REPO_ROOT" >/dev/null 2>&1; rc=$?
check "reinstall-after-extra-rc" 0 "$rc"
check_true "reinstall-after-extra-restores-files" test -f "$DEFAULT_DIR/hooks.json" -a -f "$DEFAULT_DIR/plugin.json"
check "reinstall-after-extra-keeps-file" "mine" "$(cat "$DEFAULT_DIR/extra.txt" 2>/dev/null)"
SETUP_HOME_OUT="$(bash "$SETUP" --antigravity 2>&1)"; rc=$?
check "setup-after-partial-uninstall-rc" 0 "$rc"
# A clean uninstall leaves no marker behind: the folder goes away entirely.
rm -f "$DEFAULT_DIR/extra.txt"
python3 "$INSTALLER" --root "$REPO_ROOT" --uninstall >/dev/null 2>&1
check_true "clean-uninstall-removes-marker-and-dir" test ! -e "$DEFAULT_DIR"
rm -rf "$DEFAULT_DIR"

echo "=== (h) AGENT_ANTIGRAVITY_PLUGIN_DIR overrides the default target ==="
OVR="$TMP/ovr/agent-harness"
AGENT_ANTIGRAVITY_PLUGIN_DIR="$OVR" python3 "$INSTALLER" --root "$REPO_ROOT" >/dev/null 2>&1; rc=$?
check "env-target-rc" 0 "$rc"
check_true "env-target-installed" test -f "$OVR/hooks.json"
check_true "default-target-not-created" test ! -e "$DEFAULT_DIR"
python3 "$INSTALLER" --root "$REPO_ROOT" --target "$OVR" --uninstall >/dev/null 2>&1

echo "=== (i) setup.sh --antigravity installs the plugin + prints opt-in guidance ==="
SETUP_OUT="$(bash "$SETUP" --antigravity 2>&1)"; rc=$?
check "setup-rc" 0 "$rc"
check_true "setup-installed-plugin" test -f "$DEFAULT_DIR/hooks.json"
check "setup-hooks-abs-adapter" "\"$REPO_ROOT/adapters/antigravity/adapter.sh\" Stop" "$(hook_cmd "$DEFAULT_DIR/hooks.json" Stop)"
# shellcheck disable=SC2016  # the guidance prints a literal "$USER"
check_true "guidance-keychain-cmd" grep -qF 'security add-generic-password -a "$USER" -s gemini-api-key -w' <<<"$SETUP_OUT"
check_true "guidance-auth-env" grep -qF 'ANTIGRAVITY_AUTH=apikey' <<<"$SETUP_OUT"
check_true "guidance-model-provider" grep -qF '"modelProvider": "gemini"' <<<"$SETUP_OUT"
check_true "guidance-deny-rules" grep -qi 'permissions.deny' <<<"$SETUP_OUT"
check_true "guidance-not-applied" grep -qi 'not applied\|never applied\|does not modify\|you apply' <<<"$SETUP_OUT"
check_true "user-hooks-and-settings-untouched-after-setup" user_files_untouched
# The guidance never carries a key value.
check_true "guidance-has-no-real-key" test "$(grep -cE 'AIza[0-9A-Za-z_-]{20,}' <<<"$SETUP_OUT")" -eq 0
SETUP_OUT2="$(bash "$SETUP" --antigravity 2>&1)"; rc=$?
check "setup-rerun-rc" 0 "$rc"
check_true "setup-rerun-up-to-date" grep -q 'up-to-date' <<<"$SETUP_OUT2"

echo "=== (j) setup --doctor row: NONE -> OK -> BROKEN ==="
DOC_HOME="$TMP/dochome"; mkdir -p "$DOC_HOME"
doc_row() { HOME="$DOC_HOME" bash "$SETUP" --doctor 2>&1 | grep -F 'antigravity native hooks' || true; }
row="$(doc_row)"
check_true "doctor-row-present-none" test -n "$row"
check_true "doctor-none-not-fail" test "$(grep -c 'FAIL' <<<"$row")" -eq 0
check_true "doctor-none-says-not-installed" grep -qi 'not installed' <<<"$row"
HOME="$DOC_HOME" AGENT_SETUP_NO_DOCTOR=1 bash "$SETUP" --antigravity >/dev/null 2>&1
row="$(doc_row)"
check_true "doctor-ok" grep -q '\[PASS' <<<"$row"
check_true "doctor-ok-mentions-path" grep -q 'plugins/agent-harness' <<<"$row"
# BROKEN: the wired adapter is not executable (mutate a throwaway checkout copy).
CK="$TMP/checkout"; mkdir -p "$CK"
git -C "$REPO_ROOT" ls-files -z -co --exclude-standard | (cd "$REPO_ROOT" && xargs -0 -I{} cp --parents {} "$CK" 2>/dev/null) || true
if [[ ! -f "$CK/setup.sh" ]]; then
  # macOS cp lacks --parents: fall back to tar.
  rm -rf "$CK"; mkdir -p "$CK"
  (cd "$REPO_ROOT" && git ls-files -z -co --exclude-standard | tar --null -T - -cf - 2>/dev/null) | tar -xf - -C "$CK"
fi
BH="$TMP/brokenhome"; mkdir -p "$BH"
HOME="$BH" AGENT_SETUP_NO_DOCTOR=1 bash "$CK/setup.sh" --antigravity >/dev/null 2>&1
chmod -x "$CK/adapters/antigravity/adapter.sh"
row="$(HOME="$BH" bash "$CK/setup.sh" --doctor 2>&1 | grep -F 'antigravity native hooks' || true)"
check_true "doctor-broken-fail" grep -q '\[FAIL' <<<"$row"
check_true "doctor-broken-names-adapter" grep -q 'adapter.sh' <<<"$row"
HOME="$BH" bash "$CK/setup.sh" --doctor >/dev/null 2>&1; rc=$?
check "doctor-broken-exit-1" 1 "$rc"
# Unreadable hooks.json in our dir is BROKEN, not OK.
chmod +x "$CK/adapters/antigravity/adapter.sh"
printf '{not json' > "$BH/.gemini/config/plugins/agent-harness/hooks.json"
row="$(HOME="$BH" bash "$CK/setup.sh" --doctor 2>&1 | grep -F 'antigravity native hooks' || true)"
check_true "doctor-bad-json-fail" grep -q '\[FAIL' <<<"$row"
# A foreign plugin dir is NONE for us (never reported as ours / never FAIL).
FH="$TMP/foreignhome"; mkdir -p "$FH/.gemini/config/plugins/agent-harness"
printf '{"name":"not-ours"}\n' > "$FH/.gemini/config/plugins/agent-harness/plugin.json"
row="$(HOME="$FH" bash "$SETUP" --doctor 2>&1 | grep -F 'antigravity native hooks' || true)"
check_true "doctor-foreign-not-fail" test "$(grep -c 'FAIL' <<<"$row")" -eq 0

echo
echo "antigravity-native-hooks: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
