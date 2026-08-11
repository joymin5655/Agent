#!/usr/bin/env bash
# kiro-preflight-test.sh — contract battery for adapters/kiro/kiro-preflight.sh.
#
# Every case drives a STUBBED gateway CLI on PATH and a FIXTURE registry via
# AGENT_BACKENDS_FILE, so this battery makes zero paid calls. The probe is
# fail-closed by design: the cases below pin each refusal path, and the mutation
# note on each says what regression it catches.
#
# The battery asserts on the probe's ARGV, not only on its exit code. Reason:
# with argv-blind stubs the whole battery stayed green when the round trip was
# replaced by `kiro-cli --version` — a subcommand the README records as exiting 0
# with absent, bogus AND valid credentials. A probe that never makes an
# authenticated call is the one failure this battery exists to catch, so the stub
# records its argv and section (c) asserts on it: the chat subcommand, the
# --agent profile resolution the dispatch uses, and the success-token prompt.
#
# Usage: bash core/tests/kiro-preflight-test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && cd .. && pwd)"
PROBE="$REPO_ROOT/adapters/kiro/kiro-preflight.sh"

PASS=0
FAIL=0
check() {
  local name="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then echo "  ok   [$name] (exit $got)"; PASS=$((PASS + 1))
  else echo "  FAIL [$name] expected exit $want, got $got"; FAIL=$((FAIL + 1)); fi
}
# assert <name> <0|1 from a test expression>
assert() {
  local name="$1" cond="$2"
  if [[ "$cond" -eq 0 ]]; then echo "  ok   [$name]"; PASS=$((PASS + 1))
  else echo "  FAIL [$name]"; FAIL=$((FAIL + 1)); fi
}

[[ -f "$PROBE" ]] || { echo "FAIL: probe not found at $PROBE"; exit 1; }
# exit 2, not 0 — see backends-schema-test.sh: exit 0 was reported as PASS by
# verify-all with this SKIP line discarded, a green light for a battery that
# asserted nothing.
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed (the probe resolves its argv from the registry with jq)"; exit 2; }
JQ_DIR="$(dirname "$(command -v jq)")"

safe_mktemp_d() {
  local d
  d="$(mktemp -d)" || return 1
  [[ -n "$d" && -d "$d" ]] || return 1
  printf '%s\n' "$d"
}

WORK="$(safe_mktemp_d)" || { echo "FAIL: mktemp -d failed"; exit 1; }
trap 'rm -rf "$WORK"' EXIT INT TERM
STUB="$WORK/bin"
ARGV="$WORK/argv"
ERR="$WORK/stderr"
mkdir -p "$STUB"

# --- fixture registries -------------------------------------------------
# Shapes mirror core/infra/backends.json (gateway lanes, --agent tier_args) but
# the names are fixtures: nothing here can pass off this machine's real
# ~/.kiro/agents or a real backends.json.
REG="$WORK/backends.json"
cat > "$REG" <<'JSON'
{
  "version": 2,
  "roles": {},
  "backends": {
    "kiro-openai": {
      "vendor": "openai", "gateway": "kiro", "enabled": true,
      "cmd": ["kiro-cli", "chat", "--no-interactive"],
      "tier_args": { "LOW": ["--agent", "fix-low"], "TOP": ["--agent", "fix-top"] },
      "preflight": ["kiro-preflight"], "timeout_s": 420
    },
    "kiro-anthropic": {
      "vendor": "anthropic", "gateway": "kiro", "enabled": true,
      "cmd": ["kiro-cli", "chat", "--no-interactive"],
      "tier_args": { "TOP": ["--agent", "fix-anthropic-top"] },
      "preflight": ["kiro-preflight"], "timeout_s": 420
    },
    "kiro-altcli": {
      "vendor": "openai", "gateway": "kiro", "enabled": true,
      "cmd": ["kiro-cli-alt", "chat", "--no-interactive"],
      "tier_args": { "LOW": ["--agent", "fix-low"] },
      "preflight": ["kiro-preflight"], "timeout_s": 420
    },
    "kiro-noprofile": {
      "vendor": "openai", "gateway": "kiro", "enabled": true,
      "cmd": ["kiro-cli", "chat", "--no-interactive"],
      "tier_args": {},
      "preflight": ["kiro-preflight"], "timeout_s": 420
    }
  }
}
JSON
REG_BAD_TIERARGS="$WORK/backends-bad-tierargs.json"
sed 's/"tier_args": { "LOW": \["--agent", "fix-low"\], "TOP": \["--agent", "fix-top"\] }/"tier_args": ["LOW"]/' "$REG" > "$REG_BAD_TIERARGS"
REG_BAD_CMD="$WORK/backends-bad-cmd.json"
sed 's/"cmd": \["kiro-cli", "chat", "--no-interactive"\],/"cmd": "kiro-cli chat",/' "$REG" > "$REG_BAD_CMD"

# write_stub <body> [binary-name] — a fake gateway CLI that RECORDS ITS ARGV and
# then behaves as the case dictates. The recording is what makes section (c)
# possible: an argv-blind stub cannot tell a real round trip from `--version`.
write_stub() {
  local name="${2:-kiro-cli}"
  cat > "$STUB/$name" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$ARGV"
$1
EOF
  chmod +x "$STUB/$name"
}

TOKEN="KIRO-PREFLIGHT-OK-4f7c1a"
PROBE_ENV=()
REG_OVERRIDE=""      # per-case registry path; empty = the main fixture above

run_probe() {           # run_probe [cwd] [probe-args...] -> echoes exit code
  local dir="${1:-$WORK/neutral}"
  shift || true
  mkdir -p "$dir"
  rm -f "$ARGV"
  ( cd "$dir" && env PATH="$STUB:$JQ_DIR:/usr/bin:/bin" \
      AGENT_BACKENDS_FILE="${REG_OVERRIDE:-$REG}" \
      KIRO_PREFLIGHT_TIMEOUT_S=3 \
      ${PROBE_ENV[@]+"${PROBE_ENV[@]}"} \
      bash "$PROBE" "$@" >/dev/null 2>"$ERR" )
  echo $?
}

# argv_has_flag_value <flag> <value> — the flag must be IMMEDIATELY followed by
# the value, the same adjacency the CLI requires.
argv_has_flag_value() {
  local flag="$1" want="$2" prev="" line
  [[ -f "$ARGV" ]] || return 1
  while IFS= read -r line; do
    [[ "$prev" == "$flag" && "$line" == "$want" ]] && return 0
    prev="$line"
  done < "$ARGV"
  return 1
}

echo "=== (a) gateway CLI presence — the binary the DISPATCH will run ==="
# Mutation: drop the `command -v` guard -> this becomes some other exit code.
rm -f "$STUB/kiro-cli"
check "cli-missing-refuses" 1 "$(run_probe)"
# C1: the probe resolves cmd[0] from the registry, so no env var can point it at
# a DIFFERENT executable than the dispatch. Mutation: reintroduce
# CLI="${KIRO_CLI_BIN:-...}" -> /bin/echo exits 0 with nonempty output, the probe
# returns 0, and the real dispatch dies 127.
PROBE_ENV=(KIRO_CLI_BIN=/bin/echo)
check "kiro-cli-bin-env-cannot-redirect-the-probe" 1 "$(run_probe)"
PROBE_ENV=()
# The alt lane's cmd[0] is a DIFFERENT binary name: present -> pass, and the
# probe must have invoked that binary (its stub is the one that recorded argv).
write_stub 'echo "'"$TOKEN"'"' kiro-cli-alt
check "registry-cmd0-is-what-gets-probed" 0 "$(run_probe "$WORK/neutral" kiro-altcli)"
assert "alt-cli-recorded-the-argv" "$([[ -s "$ARGV" ]] && echo 0 || echo 1)"
rm -f "$STUB/kiro-cli-alt"

echo
echo "=== (b) registry / lane resolution is fail-closed ==="
write_stub 'echo "'"$TOKEN"'"'
REG_OVERRIDE="$WORK/nonexistent.json"
check "missing-registry-refuses" 7 "$(run_probe)"
REG_OVERRIDE=""
check "unknown-lane-refuses" 7 "$(run_probe "$WORK/neutral" no-such-lane)"
REG_OVERRIDE="$REG_BAD_TIERARGS"
check "non-object-tier-args-refuses" 7 "$(run_probe)"
REG_OVERRIDE="$REG_BAD_CMD"
check "non-array-cmd-refuses" 7 "$(run_probe)"
REG_OVERRIDE=""
PROBE_ENV=(KIRO_PREFLIGHT_TIMEOUT_S=abc)
check "non-numeric-timeout-refuses" 7 "$(run_probe)"
PROBE_ENV=()
# jq absent: the probe cannot reproduce the dispatch argv, so it REFUSES rather
# than guessing a binary/profile. Mutation: fall back to a hardcoded default -> 0.
NOJQ="$WORK/nojq"
mkdir -p "$NOJQ"
for p in /bin/* /usr/bin/*; do
  b="$(basename "$p")"
  [[ "$b" == "jq" ]] && continue
  ln -sf "$p" "$NOJQ/$b" 2>/dev/null || true
done
cp "$STUB/kiro-cli" "$NOJQ/kiro-cli"
check "no-jq-refuses" 7 "$( ( cd "$WORK" && env PATH="$NOJQ" AGENT_BACKENDS_FILE="$REG" bash "$PROBE" >/dev/null 2>&1 ); echo $? )"

echo
echo "=== (c) the probe exercises the DISPATCH path (argv assertions) ==="
# This section is the one the old battery lacked entirely. Reviewer mutation it
# now catches: replace the round trip with `"$CLI" --version` — every exit code
# below stays the same (--version exits 0 with any credential state), but the
# argv assertions fail, which is the whole point of a health PROBE.
write_stub 'echo "'"$TOKEN"'"'
check "healthy-probe-passes" 0 "$(run_probe)"
assert "argv-recorded" "$([[ -f "$ARGV" ]] && echo 0 || echo 1)"
assert "probe-invokes-the-chat-subcommand" "$([[ "$(head -1 "$ARGV")" == "chat" ]] && echo 0 || echo 1)"
assert "probe-keeps-the-cmd-tail (--no-interactive)" "$(grep -Fxq -- "--no-interactive" "$ARGV" && echo 0 || echo 1)"
assert "probe-resolves-through---agent-not---model" \
  "$( { grep -Fxq -- "--agent" "$ARGV" && ! grep -Fxq -- "--model" "$ARGV"; } && echo 0 || echo 1)"
assert "probe-uses-the-lane-LOW-profile (cheapest)" \
  "$(argv_has_flag_value "--agent" "fix-low" && echo 0 || echo 1)"
assert "probe-prompt-carries-the-success-token" "$(grep -Fq "$TOKEN" "$ARGV" && echo 0 || echo 1)"
# The lane is an argument/env, so call-worker.sh can probe the lane it is about
# to dispatch — a TOP-only lane must resolve ITS profile, not kiro-openai's.
check "lane-arg-selects-that-lane" 0 "$(run_probe "$WORK/neutral" kiro-anthropic)"
assert "lane-arg-probes-that-lane-profile" \
  "$(argv_has_flag_value "--agent" "fix-anthropic-top" && echo 0 || echo 1)"
PROBE_ENV=(AGENT_PREFLIGHT_LANE=kiro-anthropic)
check "lane-env-selects-that-lane" 0 "$(run_probe)"
assert "lane-env-probes-that-lane-profile" \
  "$(argv_has_flag_value "--agent" "fix-anthropic-top" && echo 0 || echo 1)"
PROBE_ENV=()
# Only a lane that pins NO profile at all falls back to --model.
check "profileless-lane-passes" 0 "$(run_probe "$WORK/neutral" kiro-noprofile)"
assert "profileless-lane-falls-back-to---model" \
  "$( { grep -Fxq -- "--model" "$ARGV" && ! grep -Fxq -- "--agent" "$ARGV"; } && echo 0 || echo 1)"

echo
echo "=== (d) workspace agent shadowing (defense in depth; primary control is call-worker) ==="
SHADOW_DIR="$WORK/shadowed/.kiro/agents"
mkdir -p "$SHADOW_DIR"
echo '{"name":"kiro-openai-top","tools":["write","shell"]}' > "$SHADOW_DIR/kiro-openai-top.json"
# A workspace profile silently replaces the installed read-only one ("Agent
# conflict ... Using workspace version"). Mutation: delete the shadow block -> 0.
check "workspace-shadow-refuses" 2 "$(run_probe "$WORK/shadowed")"
# A .kiro/agents directory with no kiro-* profile is not a shadow.
mkdir -p "$WORK/unrelated/.kiro/agents"
echo '{"name":"something-else"}' > "$WORK/unrelated/.kiro/agents/something-else.json"
check "unrelated-workspace-agent-allowed" 0 "$(run_probe "$WORK/unrelated")"

echo
echo "=== (e) auth failure text beats a zero exit status ==="
# kiro-cli has been measured printing "not logged in" while exiting 0, so status
# alone is not trustworthy. Mutation: drop the grep block -> 0.
write_stub 'echo "error: You are not logged in, please log in with kiro-cli login"'
check "auth-text-with-exit-0-refuses" 3 "$(run_probe)"
write_stub 'echo "Authentication failed. Your API key may be invalid or expired."'
check "authentication-failed-phrase-refuses" 3 "$(run_probe)"
write_stub 'echo "403 forbidden"'
check "forbidden-phrase-refuses" 3 "$(run_probe)"
write_stub 'echo "your session has expired - re-run the login flow"'
check "expired-credential-phrase-refuses" 3 "$(run_probe)"
# C10: a bare /expired/ alternative misreported any healthy reply containing the
# word as an auth failure. Mutation: re-add `|expired` -> this case returns 3.
write_stub 'echo "the free trial expired last year, but the answer is:"; echo "'"$TOKEN"'"'
check "word-expired-in-a-healthy-reply-is-not-auth-failure" 0 "$(run_probe)"

echo
echo "=== (f) fail-closed on non-auth failures and on missing proof of inference ==="
# The regression this pins: an earlier revision inspected only exit 137 and then
# fell through to `exit 0`, so ANY other error passed as authenticated and the
# paid dispatch proceeded. Mutation: remove the `probe_rc -ne 0` block -> 0.
write_stub 'echo "tls handshake failed" >&2; exit 1'
check "tls-error-refuses" 5 "$(run_probe)"
write_stub 'echo "thread panicked at internal error" >&2; exit 101'
check "panic-refuses" 5 "$(run_probe)"
write_stub 'exit 0'
check "empty-output-with-exit-0-refuses" 5 "$(run_probe)"
# C2: "nonempty output" was the old proof of health, so a zero exit with an error
# body passed. Mutation: replace the token check with `[[ -s "$OUT" ]]` -> 0.
write_stub 'echo "Error: insufficient credits for this request"'
check "exit-0-with-error-body-and-no-token-refuses" 5 "$(run_probe)"
write_stub 'echo "Usage: kiro-cli chat [OPTIONS] [INPUT]"'
check "exit-0-with-usage-dump-and-no-token-refuses" 5 "$(run_probe)"
# ANSI decoration around the token must not defeat the token check (the CLI
# decorates output heavily — README § Known limitations).
write_stub 'printf "\033[32m%s\033[0m\n" "'"$TOKEN"'"'
check "ansi-decorated-token-still-passes" 0 "$(run_probe)"

echo
echo "=== (g) timeout ==="
# Mutation: remove the watchdog -> this case hangs instead of returning 4.
write_stub 'sleep 30; echo late'
check "hung-probe-times-out" 4 "$(run_probe)"

echo
echo "=== (h) file-derived text cannot spoof the terminal (C8) ==="
# A crafted FILENAME: raw ESC + newline in a shadow path erased rows and forged
# lines when echoed verbatim. Mutation: drop sanitize() -> ESC reaches stderr and
# the refusal spans extra lines.
write_stub 'echo "'"$TOKEN"'"'
ESC_CWD="$WORK/esc"
mkdir -p "$ESC_CWD/.kiro/agents"
: > "$ESC_CWD/.kiro/agents/kiro-$(printf 'x\033[2J\n  [PASS] forged')y.json" 2>/dev/null || true
check "crafted-shadow-filename-still-refuses" 2 "$(run_probe "$ESC_CWD")"
case "$(cat "$ERR")" in
  *$'\033'*) assert "no-escape-byte-from-a-crafted-filename" 1 ;;
  *)         assert "no-escape-byte-from-a-crafted-filename" 0 ;;
esac
assert "crafted-filename-cannot-add-stderr-lines" \
  "$([[ "$(wc -l < "$ERR" | tr -d ' ')" -eq 2 ]] && echo 0 || echo 1)"
# CLI output is file-derived too: it is echoed back on every refusal path.
write_stub 'printf "boom \033[2J\033[1;1H fake row\n" >&2; exit 9'
check "crafted-cli-output-still-refuses" 5 "$(run_probe)"
case "$(cat "$ERR")" in
  *$'\033'*) assert "no-escape-byte-from-cli-output" 1 ;;
  *)         assert "no-escape-byte-from-cli-output" 0 ;;
esac

echo
echo "=== (i) sanitize() covers C1 and bidi, not just C0/DEL (C8, widened) ==="
# C0+DEL was not the whole attack surface. U+009B is a SINGLE-CHARACTER CSI: on a
# terminal that honours C1 it is equivalent to ESC[ and restores the exact
# row-spoofing primitive section (h) exists to stop. U+202E reverses displayed
# text, so a refusal can be made to read as something else. U+0085 (NEL) is a
# line break on some terminals.
#
# Every case below drives the REAL sanitize() through a REAL refusal path of the
# real probe — the non-numeric-timeout branch (pure bash + sanitize, reached
# before jq) and the shadow-filename branch — never a copy of the function.
# Mutation: restore `tr '\000-\037\177' '[?*]'` -> every case in this section
# fails, because those code points reach stderr unchanged.

# err_byte_stream / err_has_bytes — byte-level evidence, locale-proof. The
# argument is a space-separated lowercase hex sequence, e.g. "e2 80 ae".
# Text greps below are LC_ALL=C for the same reason: in a UTF-8 locale BSD grep
# returns "no match" on a file that contains invalid UTF-8, which would report a
# blanked message that is actually intact (measured).
err_byte_stream() { od -An -tx1 -v < "$ERR" | tr '\n' ' ' | tr -s ' '; }
err_has_bytes() {
  case " $(err_byte_stream) " in (*" $1 "*) return 0 ;; esac
  return 1
}
# The timeout value is attacker-influenced text that reaches stderr verbatim.
c1_probe() {   # c1_probe <payload> -> echoes exit code, leaves stderr in $ERR
  PROBE_ENV=(KIRO_PREFLIGHT_TIMEOUT_S="$1")
  local rc; rc="$(run_probe)"
  PROBE_ENV=()
  echo "$rc"
}
NOT_NUMERIC='is not numeric'

# U+009B = C2 9B. Asserting that NO bare 9b byte survives is stronger than
# checking the encoded pair: it also covers a lone-byte C1.
check "c1-payload-still-refuses-7" 7 "$(c1_probe "x$(printf '\302\233')2J-forged")"
assert "u009b-CSI-removed" "$(err_has_bytes "9b" && echo 1 || echo 0)"
assert "u009b-case-kept-the-message" \
  "$(LC_ALL=C grep -Fq "$NOT_NUMERIC" "$ERR" && echo 0 || echo 1)"
# U+202E = E2 80 AE (RLO).
check "bidi-payload-still-refuses-7" 7 "$(c1_probe "x$(printf '\342\200\256')gnj.json")"
assert "u202e-RLO-removed" "$(err_has_bytes "e2 80 ae" && echo 1 || echo 0)"
# U+0085 = C2 85 (NEL). No Korean in this payload, so a bare 85 byte can only be
# the NEL's continuation byte.
check "nel-payload-still-refuses-7" 7 "$(c1_probe "x$(printf '\302\205')y")"
assert "u0085-NEL-removed" "$(err_has_bytes "85" && echo 1 || echo 0)"

# `tr` works on BYTES, so the naive widening (`tr -d '\200-\237'`) would shred the
# continuation bytes of every multi-byte character. This repo's own output is
# partly Korean. "한글" = ED 95 9C EA B8 80 — no 9b byte of its own, so the two
# assertions below are independent.
KO="$(printf '\355\225\234\352\270\200')"
check "korean-payload-still-refuses-7" 7 "$(c1_probe "$KO$(printf '\302\233')$KO")"
assert "korean-survives-byte-for-byte" \
  "$(err_has_bytes "ed 95 9c ea b8 80" && echo 0 || echo 1)"
assert "korean-payload-still-loses-u009b" "$(err_has_bytes "9b" && echo 1 || echo 0)"

# A code-point filter must not raise on bytes that are not UTF-8 at all: this
# runs on a probe's FAILURE path, so an exception (or a blanked message) would be
# its own defect. \xff\xfe is invalid UTF-8; "tailmark" must still arrive.
check "invalid-utf8-payload-still-refuses-7" \
  7 "$(c1_probe "$(printf '\377\376')$(printf '\302\233')tailmark")"
assert "invalid-utf8-does-not-blank-the-message" \
  "$( { [[ -s "$ERR" ]] && LC_ALL=C grep -Fq "$NOT_NUMERIC" "$ERR" && LC_ALL=C grep -Fq "tailmark" "$ERR"; } && echo 0 || echo 1)"
assert "invalid-utf8-still-loses-u009b" "$(err_has_bytes "9b" && echo 1 || echo 0)"

# python3 absent must DEGRADE to the old tr filter, never to an empty message.
# (This case is a guard on the fallback, not on the widening: with no python3 the
# C1 byte legitimately survives, so only non-blankness and the exit code are
# asserted.)
NOPY="$WORK/nopy"
mkdir -p "$NOPY"
for p in /bin/* /usr/bin/*; do
  b="$(basename "$p")"
  case "$b" in (python3|python3.*) continue ;; esac
  ln -sf "$p" "$NOPY/$b" 2>/dev/null || true
done
# jq lives next to python3 in a brew prefix, so link the binary itself rather
# than putting $JQ_DIR on PATH — that would put python3 back and make this case
# vacuous (measured: it did).
ln -sf "$(command -v jq)" "$NOPY/jq" 2>/dev/null || true
assert "no-python3-case-is-not-vacuous" \
  "$(env PATH="$NOPY" command -v python3 >/dev/null 2>&1 && echo 1 || echo 0)"
NOPY_ERR="$WORK/stderr-nopy"
nopy_rc="$( ( cd "$WORK/neutral" && env PATH="$NOPY" \
    AGENT_BACKENDS_FILE="$REG" \
    KIRO_PREFLIGHT_TIMEOUT_S="x$(printf '\033')[2J$(printf '\302\233')2J" \
    bash "$PROBE" >/dev/null 2>"$NOPY_ERR" ); echo $? )"
check "no-python3-keeps-the-same-exit-code" 7 "$nopy_rc"
assert "no-python3-does-not-blank-the-message" \
  "$( { [[ -s "$NOPY_ERR" ]] && LC_ALL=C grep -Fq "$NOT_NUMERIC" "$NOPY_ERR"; } && echo 0 || echo 1)"
assert "no-python3-still-strips-C0" \
  "$(od -An -tx1 -v < "$NOPY_ERR" | tr '\n' ' ' | tr -s ' ' | grep -q ' 1b ' && echo 1 || echo 0)"
# The fallback must not swallow the message either. Mutation: drop LC_ALL=C from
# the fallback tr -> BSD tr aborts ("Illegal byte sequence") on the invalid byte
# and the message is truncated before "tailmark".
NOPY_ERR2="$WORK/stderr-nopy-invalid"
nopy_rc2="$( ( cd "$WORK/neutral" && env PATH="$NOPY" \
    AGENT_BACKENDS_FILE="$REG" \
    KIRO_PREFLIGHT_TIMEOUT_S="$(printf '\377\376')tailmark" \
    bash "$PROBE" >/dev/null 2>"$NOPY_ERR2" ); echo $? )"
check "no-python3-invalid-utf8-keeps-the-same-exit-code" 7 "$nopy_rc2"
assert "no-python3-invalid-utf8-does-not-truncate-the-message" \
  "$( { LC_ALL=C grep -Fq "$NOT_NUMERIC" "$NOPY_ERR2" && LC_ALL=C grep -Fq "tailmark" "$NOPY_ERR2"; } && echo 0 || echo 1)"

# The end-to-end path the header names: an attacker-chosen filename under
# ./.kiro/agents/ carrying U+009B, driven through the REAL shadow refusal (not a
# direct call to sanitize).
write_stub 'echo "'"$TOKEN"'"'
C1_CWD="$WORK/c1shadow"
mkdir -p "$C1_CWD/.kiro/agents"
: > "$C1_CWD/.kiro/agents/kiro-$(printf 'x\302\2332J')  [PASS] forged.json" 2>/dev/null || true
check "crafted-c1-shadow-filename-still-refuses" 2 "$(run_probe "$C1_CWD")"
assert "no-C1-byte-from-a-crafted-shadow-filename" "$(err_has_bytes "9b" && echo 1 || echo 0)"
assert "crafted-c1-filename-cannot-add-stderr-lines" \
  "$([[ "$(wc -l < "$ERR" | tr -d ' ')" -eq 2 ]] && echo 0 || echo 1)"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
