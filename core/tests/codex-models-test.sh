#!/usr/bin/env bash
# codex-models-test.sh — verify core/infra/codex-models.py and its session-init
# weekly advisory. No real codex binary and no network: the catalog is a
# fixture under a temp CODEX_HOME and `codex` is a PATH stub whose per-model
# behaviour is driven by FAKE_CODEX_FAIL.
#
# Contract:
#   resolve      <- list-visible, non-upgrade models of the tier family, min priority
#   check        <- exit 0 match / 10 change suggested / 2 catalog missing
#   apply        <- probe first; rewrite only the model line; backup; fall through
#   upgrade-for  <- catalog upgrade target, else family resolve, else exit 1
#   tiers file   <- shape-validated (no argv injection)
#   session-init <- weekly stamp throttle, one stderr line, stdout empty
#
# Usage: bash core/tests/codex-models-test.sh
# Exit 0: all pass. Exit 1: one or more failures.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOL="$REPO_ROOT/core/infra/codex-models.py"
HOOK="$REPO_ROOT/core/hooks/session-init.py"

PASS=0
FAIL=0
WORK="$(mktemp -d)"
trap '[[ -n "$WORK" && -d "$WORK" ]] && rm -rf "$WORK"' EXIT

ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1 — $2"; }

CH="$WORK/codex-home"
mkdir -p "$CH" "$WORK/bin" "$WORK/state"
PROBES="$WORK/probes.log"
cat > "$CH/models_cache.json" <<'JSON'
{"fetched_at":"2026-10-07T00:00:00Z","models":[
 {"slug":"gpt-6.1-sol","visibility":"list","priority":1,"upgrade":null},
 {"slug":"gpt-6-astra","visibility":"list","priority":2,"upgrade":null},
 {"slug":"gpt-6-sol","visibility":"list","priority":3,"upgrade":null},
 {"slug":"gpt-6-luna","visibility":"list","priority":4,"upgrade":null},
 {"slug":"gpt-reserve","visibility":"hide","priority":5,"upgrade":null},
 {"slug":"gpt-5.6-sol","visibility":"list","priority":5,"upgrade":{"model":"gpt-6.1-sol","retirement_at":"2026-10-14"}},
 {"slug":"gpt-5.6-luna","visibility":"list","priority":9,"upgrade":null},
 {"slug":"gpt-5.5-sol","visibility":"hide","priority":0,"upgrade":{"model":"gpt-6.1-sol"}},
 {"slug":"codex-auto-review","visibility":"hide","priority":10,"upgrade":null}
]}
JSON
cat > "$WORK/bin/codex" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$PROBES"
m=""
while [[ \$# -gt 0 ]]; do [[ "\$1" == "-m" ]] && m="\$2"; shift; done
for f in \${FAKE_CODEX_HANG:-}; do [[ "\$f" == "\$m" ]] && exec sleep 5; done
for f in \${FAKE_CODEX_USAGE:-}; do
  [[ "\$f" == "\$m" ]] && { echo "ERROR: You've hit your usage limit"; exit 1; }
done
for f in \${FAKE_CODEX_FAIL:-}; do
  [[ "\$f" == "\$m" ]] && { echo "ERROR: {\\"type\\":\\"error\\",\\"status\\":400,\\"error\\":{\\"message\\":\\"The '\$m' model is not supported when using Codex with a ChatGPT account.\\"}}"; exit 1; }
done
echo OK
EOF
chmod +x "$WORK/bin/codex"

FAILED_STATE="$WORK/state/codex-probe-failed.json"
write_profiles() {  # deep=$1 quick=$2 (also resets the probe-failure memory)
    rm -f "$FAILED_STATE"
    printf '# deep profile\nmodel = "%s"\nmodel_reasoning_effort = "high"\n# model = "commented"\n' "$1" > "$CH/deep.config.toml"
    printf 'model = "%s"\nmodel_reasoning_effort = "low"\n' "$2" > "$CH/quick.config.toml"
}

run() {  # run <args...>  (env seams pinned)
    env PATH="$WORK/bin:/usr/bin:/bin" CODEX_HOME="$CH" \
        AGENT_CODEX_TIERS_FILE="${TIERS:-$WORK/none.json}" \
        AGENT_STATE_DIR="$WORK/state" HOME="$WORK/home" \
        python3 "$TOOL" "$@"
}

# --- 1. resolve via check --json ------------------------------------------
write_profiles gpt-5.6-sol gpt-5.6-luna
out="$(run check --json 2>/dev/null)"; rc=$?
if [[ $rc -eq 10 ]] && printf '%s' "$out" | python3 -c '
import json,sys
d=json.load(sys.stdin)
t={x["tier"]:x for x in d["tiers"]} if isinstance(d.get("tiers"),list) else d["tiers"]
assert t["top"]["resolved"]=="gpt-6.1-sol", t
assert t["top"]["current"]=="gpt-5.6-sol", t
assert t["low"]["resolved"]=="gpt-6-luna", t
'; then ok "resolve — skips hide/upgrade models, min priority per family"
else bad "resolve" "rc=$rc out=$out"; fi

# --- 2. check exit codes --------------------------------------------------
write_profiles gpt-6.1-sol gpt-6-luna
run check >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]] && ok "check — all match -> 0" || bad "check match" "rc=$rc"

write_profiles gpt-6.1-sol gpt-5.6-luna
run check >/dev/null 2>&1; rc=$?
[[ $rc -eq 10 ]] && ok "check — drift -> 10" || bad "check drift" "rc=$rc"

rm -f "$CH/quick.config.toml"
write_profiles gpt-6.1-sol x; rm -f "$CH/quick.config.toml"
run check >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]] && ok "check — absent profile skipped -> 0" || bad "check absent profile" "rc=$rc"

mv "$CH/models_cache.json" "$CH/models_cache.json.hold"
run check >/dev/null 2>"$WORK/err"; rc=$?
[[ $rc -eq 2 && -s "$WORK/err" ]] && ok "check — catalog missing -> 2 with stderr message" || bad "check no catalog" "rc=$rc"
mv "$CH/models_cache.json.hold" "$CH/models_cache.json"

# --- 3. apply -------------------------------------------------------------
write_profiles gpt-5.6-sol gpt-6-luna
cp "$CH/deep.config.toml" "$WORK/deep.before"
: > "$PROBES"
run apply --tier top --yes >/dev/null 2>"$WORK/err"; rc=$?
exp="$(sed 's/^model = "gpt-5.6-sol"/model = "gpt-6.1-sol"/' "$WORK/deep.before")"
bak=("$CH"/deep.config.toml.bak-*)
if [[ $rc -eq 0 && "$(cat "$CH/deep.config.toml")" == "$exp" ]] \
   && [[ -f "${bak[0]}" ]] && cmp -s "${bak[0]}" "$WORK/deep.before" \
   && [[ "$(wc -l < "$PROBES" | tr -d ' ')" == "1" ]] \
   && grep -q -- "-m gpt-6.1-sol" "$PROBES" && grep -q -- "-s read-only" "$PROBES"; then
    ok "apply — probe passed, only the model line rewritten, backup identical to original"
else bad "apply success" "rc=$rc probes=$(cat "$PROBES") $(head -3 "$WORK/err")"; fi

# second apply the same day must not clobber the existing backup
write_profiles gpt-5.6-sol gpt-6-luna
run apply --tier top --yes >/dev/null 2>&1
n=$(ls "$CH"/deep.config.toml.bak-* | wc -l | tr -d ' ')
[[ "$n" -ge 2 ]] && ok "apply — same-day backup not clobbered" || bad "apply backup suffix" "count=$n"

# low tier untouched when --tier top
[[ "$(head -n1 "$CH/quick.config.toml")" == 'model = "gpt-6-luna"' ]] && ok "apply --tier top leaves quick alone" || bad "tier scope" "quick changed"

# fall-through
write_profiles gpt-5.6-sol gpt-6-luna
: > "$PROBES"
FAKE_CODEX_FAIL="gpt-6.1-sol" run apply --tier top --yes >/dev/null 2>&1; rc=$?
if [[ $rc -eq 0 ]] && grep -q '^model = "gpt-6-sol"$' "$CH/deep.config.toml" \
   && [[ "$(wc -l < "$PROBES" | tr -d ' ')" == "2" ]]; then
    ok "apply — failed probe falls through to next candidate"
else bad "apply fall-through" "rc=$rc $(grep '^model' "$CH/deep.config.toml") probes=$(wc -l < "$PROBES")"; fi

# all fail
write_profiles gpt-5.6-sol gpt-6-luna
cp "$CH/deep.config.toml" "$WORK/deep.before"
rm -f "$CH"/deep.config.toml.bak-*
FAKE_CODEX_FAIL="gpt-6.1-sol gpt-6-sol" run apply --tier top --yes >/dev/null 2>&1; rc=$?
if [[ $rc -eq 1 ]] && cmp -s "$CH/deep.config.toml" "$WORK/deep.before" \
   && ! ls "$CH"/deep.config.toml.bak-* >/dev/null 2>&1; then
    ok "apply — all probes fail -> exit 1, nothing written"
else bad "apply all fail" "rc=$rc"; fi

# non-TTY without --yes
write_profiles gpt-5.6-sol gpt-6-luna
: > "$PROBES"
run apply --tier top </dev/null >/dev/null 2>&1; rc=$?
if [[ $rc -eq 3 && ! -s "$PROBES" ]]; then ok "apply — no TTY and no --yes -> exit 3, no probe run"
else bad "apply consent" "rc=$rc probes=$(cat "$PROBES")"; fi

# --- 4. upgrade-for -------------------------------------------------------
out="$(run upgrade-for gpt-5.6-sol 2>/dev/null)"; rc=$?
[[ $rc -eq 0 && "$out" == "gpt-6.1-sol" ]] && ok "upgrade-for — catalog upgrade.model" || bad "upgrade-for field" "rc=$rc out=$out"
out="$(run upgrade-for gpt-9-luna 2>/dev/null)"; rc=$?
[[ $rc -eq 0 && "$out" == "gpt-6-luna" ]] && ok "upgrade-for — family fallback" || bad "upgrade-for family" "rc=$rc out=$out"
out="$(run upgrade-for gpt-6-astra 2>/dev/null)"; rc=$?
[[ $rc -eq 1 && -z "$out" ]] && ok "upgrade-for — no other candidate in family -> empty, exit 1" || bad "upgrade-for none" "rc=$rc out=$out"
out="$(run upgrade-for 'gpt;rm' 2>/dev/null)"; rc=$?
[[ $rc -ne 0 && -z "$out" ]] && ok "upgrade-for — rejects malformed id" || bad "upgrade-for shape" "rc=$rc out=$out"

# --- 4b. probe-failure memory ---------------------------------------------
write_profiles gpt-5.6-sol gpt-6-luna
FAKE_CODEX_FAIL="gpt-6.1-sol gpt-6-sol" run apply --tier top --yes >/dev/null 2>&1
if python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
assert set(d)=={"gpt-6.1-sol","gpt-6-sol"}, d
' "$FAILED_STATE" 2>/dev/null; then ok "apply — failed probes recorded in state file"
else bad "probe memory write" "$(cat "$FAILED_STATE" 2>&1)"; fi
run check >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]] && ok "check — recently failed candidates excluded, no endless nag" || bad "check after failure" "rc=$rc"

write_profiles gpt-6-sol gpt-6-luna
printf '{"gpt-6.1-sol":"%s"}' "$(date +%Y-%m-%d)" > "$FAILED_STATE"
run check >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]] && ok "check — next candidate equal to pin -> no suggestion" || bad "next candidate" "rc=$rc"
out="$(run upgrade-for gpt-5.6-terra 2>/dev/null)"
[[ "$out" != "gpt-6.1-sol" ]] && ok "upgrade-for — honours probe-failure memory" || bad "upgrade-for memory" "out=$out"

printf '{"gpt-6.1-sol":"2020-01-01"}' > "$FAILED_STATE"
run check >/dev/null 2>&1; rc=$?
[[ $rc -eq 10 ]] && ok "check — entry older than TTL is ignored again" || bad "ttl expiry" "rc=$rc"
AGENT_CODEX_PROBE_FAIL_TTL_DAYS=1000000 run check >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]] && ok "check — TTL seam respected" || bad "ttl seam" "rc=$rc"

run apply --tier top --yes >/dev/null 2>&1
if grep -q '^model = "gpt-6.1-sol"$' "$CH/deep.config.toml" && ! grep -q 'gpt-6.1-sol' "$FAILED_STATE"; then
    ok "apply — successful probe clears that model's failure entry"
else bad "probe memory clear" "$(cat "$FAILED_STATE")"; fi

write_profiles gpt-6-sol gpt-6-luna
printf 'not json{' > "$FAILED_STATE"
run check >/dev/null 2>&1; rc=$?
[[ $rc -eq 10 ]] && ok "check — corrupt state file treated as empty" || bad "corrupt state" "rc=$rc"

# --- 4c. review fixes ----------------------------------------------------
# missing / single-quoted model line
write_profiles gpt-6-sol gpt-6-luna
printf 'model_reasoning_effort = "high"\n' > "$CH/deep.config.toml"
out="$(run check --json 2>/dev/null)"; rc=$?
if [[ $rc -eq 0 ]] && printf '%s' "$out" | grep -q 'no model line'; then ok "check — profile without a model line is noted, not suggested"
else bad "no model line" "rc=$rc out=$out"; fi
cp "$CH/deep.config.toml" "$WORK/deep.nomodel"; : > "$PROBES"
run apply --tier top --yes >/dev/null 2>&1
if cmp -s "$CH/deep.config.toml" "$WORK/deep.nomodel" && [[ ! -s "$PROBES" ]]; then ok "apply — no model line: no probe, no write"
else bad "apply no model line" "probes=$(cat "$PROBES")"; fi

printf "model = 'gpt-5.6-sol'\nmodel_reasoning_effort = 'high'\n" > "$CH/deep.config.toml"
run apply --tier top --yes >/dev/null 2>&1
if [[ "$(head -n1 "$CH/deep.config.toml")" == "model = 'gpt-6.1-sol'" ]]; then ok "apply — single-quoted model line rewritten, quote style kept"
else bad "single quote" "$(head -n1 "$CH/deep.config.toml")"; fi

# probe tri-state
write_profiles gpt-5.6-sol gpt-6-luna
cp "$CH/deep.config.toml" "$WORK/deep.before"; : > "$PROBES"
FAKE_CODEX_USAGE="gpt-6.1-sol" run apply --tier top --yes >/dev/null 2>&1; rc=$?
if [[ $rc -eq 1 && ! -e "$FAILED_STATE" && "$(wc -l < "$PROBES" | tr -d ' ')" == "1" ]] \
   && cmp -s "$CH/deep.config.toml" "$WORK/deep.before"; then
    ok "apply — usage-limit probe is inconclusive: stops, nothing recorded or written"
else bad "inconclusive usage" "rc=$rc probes=$(wc -l < "$PROBES")"; fi

AGENT_CODEX_PROBE_TIMEOUT_S=1 FAKE_CODEX_HANG="gpt-6.1-sol" run apply --tier top --yes >/dev/null 2>&1; rc=$?
[[ $rc -eq 1 && ! -e "$FAILED_STATE" ]] && ok "apply — probe timeout not recorded" || bad "timeout probe" "rc=$rc"

mkdir -p "$WORK/nocodex-bin"
env PATH="$WORK/nocodex-bin:/usr/bin:/bin" CODEX_HOME="$CH" AGENT_CODEX_TIERS_FILE="$WORK/none.json" \
    AGENT_STATE_DIR="$WORK/state" HOME="$WORK/home" python3 "$TOOL" apply --tier top --yes >/dev/null 2>&1; rc=$?
[[ $rc -eq 1 && ! -e "$FAILED_STATE" ]] && ok "apply — missing codex binary not recorded" || bad "oserror probe" "rc=$rc"

# stop at the current pin
write_profiles gpt-6-sol gpt-6-luna
cp "$CH/deep.config.toml" "$WORK/deep.before"; : > "$PROBES"; rm -f "$CH"/deep.config.toml.bak-*
FAKE_CODEX_FAIL="gpt-6.1-sol" run apply --tier top --yes >/dev/null 2>&1; rc=$?
if [[ $rc -eq 0 && "$(wc -l < "$PROBES" | tr -d ' ')" == "1" ]] && cmp -s "$CH/deep.config.toml" "$WORK/deep.before" \
   && ! ls "$CH"/deep.config.toml.bak-* >/dev/null 2>&1; then
    ok "apply — reaching the current pin stops: no probe of it, no backup, no rewrite"
else bad "stop at pin" "rc=$rc probes=$(wc -l < "$PROBES")"; fi

# upgrade-for
out="$(run upgrade-for gpt-6.1-sol 2>/dev/null)"; rc=$?
[[ $rc -eq 0 && "$out" == "gpt-6-sol" ]] && ok "upgrade-for — top candidate itself unsupported -> next candidate" || bad "upgrade top" "rc=$rc out=$out"
rm -f "$FAILED_STATE"; printf '{"gpt-6.1-sol":"%s"}' "$(date +%Y-%m-%d)" > "$FAILED_STATE"
out="$(run upgrade-for gpt-5.6-sol 2>/dev/null)"; rc=$?
[[ $rc -eq 0 && "$out" == "gpt-6-sol" ]] && ok "upgrade-for — explicit upgrade.model respects failure memory" || bad "upgrade memory" "rc=$rc out=$out"
rm -f "$FAILED_STATE"

# effort filter + hostile slugs
cp "$CH/models_cache.json" "$WORK/cache.keep"
python3 - "$CH/models_cache.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
for m in d["models"]:
    if m["slug"]=="gpt-6.1-sol": m["supported_reasoning_levels"]=[{"effort":"low"},{"effort":"medium"}]
    if m["slug"]=="gpt-6-sol": m["supported_reasoning_levels"]=["low","medium","high"]
d["models"]+= [{"slug":"-oops-sol","visibility":"list","priority":0,"upgrade":None},
               {"slug":"a\"b-sol","visibility":"list","priority":0,"upgrade":None}]
json.dump(d,open(p,"w"))
PY
write_profiles gpt-5.6-sol gpt-6-luna
out="$(run check --json 2>/dev/null)"
if printf '%s' "$out" | python3 -c '
import json,sys
t={x["tier"]:x for x in json.load(sys.stdin)["tiers"]}
assert t["top"]["resolved"]=="gpt-6-sol", t
'; then ok "effort filter + hostile slugs — high effort skips gpt-6.1-sol; -oops-sol and a\"b-sol dropped"
else bad "effort/slug" "out=$out"; fi
cp "$WORK/cache.keep" "$CH/models_cache.json"

# OSError -> clean exit
write_profiles gpt-5.6-sol gpt-6-luna
chmod 000 "$CH/deep.config.toml"
run check >/dev/null 2>"$WORK/err"; rc=$?
chmod 644 "$CH/deep.config.toml"
if [[ $rc -eq 1 ]] && grep -q '^codex-models:' "$WORK/err" && ! grep -q Traceback "$WORK/err"; then ok "OSError -> clean message, exit 1"
else bad "oserror clean" "rc=$rc $(head -2 "$WORK/err")"; fi

# --- 5. tiers file --------------------------------------------------------
write_profiles gpt-5.6-sol gpt-5.6-luna
printf '{"top":"astra","low":"luna","extra":"--ignored"}' > "$WORK/tiers.json"
out="$(TIERS="$WORK/tiers.json" run check --json 2>/dev/null)"; rc=$?
if printf '%s' "$out" | grep -q 'gpt-6-astra'; then ok "tiers file — top=astra honoured, unknown keys ignored"
else bad "tiers custom" "rc=$rc out=$out"; fi
for badv in '--foo' 'sol; rm' 'SOL' ''; do
    printf '{"top":"%s"}' "$badv" > "$WORK/tiers.json"
    : > "$PROBES"
    TIERS="$WORK/tiers.json" run apply --yes >/dev/null 2>"$WORK/err"; rc=$?
    if [[ $rc -eq 2 && ! -s "$PROBES" && -s "$WORK/err" ]]; then ok "tiers file — rejects '$badv'"
    else bad "tiers reject '$badv'" "rc=$rc"; fi
done

# --- 6. session-init weekly advisory --------------------------------------
write_profiles gpt-5.6-sol gpt-6-luna
HOOKCWD="$WORK/cwd"; mkdir -p "$HOOKCWD"
STAMP="$WORK/state/codex-catalog-check"
run_hook() {  # run_hook [extra-env...]
    ( cd "$HOOKCWD" && env PATH="$WORK/bin:/usr/bin:/bin" CODEX_HOME="$CH" \
        AGENT_CODEX_TIERS_FILE="$WORK/none.json" AGENT_STATE_DIR="$WORK/state" \
        HOME="$WORK/home" "$@" python3 "$HOOK" </dev/null >"$WORK/hook.out" 2>"$WORK/hook.err" )
}
rm -f "$STAMP"
run_hook; rc=$?
if [[ $rc -eq 0 && ! -s "$WORK/hook.out" && -f "$STAMP" ]] \
   && [[ "$(grep -c 'codex:' "$WORK/hook.err")" == "1" ]] \
   && grep -q 'gpt-5.6-sol' "$WORK/hook.err" && grep -q 'gpt-6.1-sol' "$WORK/hook.err" \
   && grep -q 'codex-models.py apply' "$WORK/hook.err"; then
    ok "session-init — stale stamp: one advisory line, stdout empty, stamp touched"
else bad "advisory" "rc=$rc out=$(cat "$WORK/hook.out") err=$(cat "$WORK/hook.err")"; fi

run_hook
if ! grep -q 'codex:' "$WORK/hook.err"; then ok "session-init — fresh stamp: check not run"
else bad "throttle" "advisory repeated"; fi

touch -t 202001010000 "$STAMP"
write_profiles gpt-6.1-sol gpt-6-luna
run_hook
if ! grep -q 'codex:' "$WORK/hook.err" && [[ "$(find "$STAMP" -mtime -1 | wc -l | tr -d ' ')" == "1" ]]; then
    ok "session-init — stale stamp, no drift: silent, stamp refreshed"
else bad "no-drift" "err=$(cat "$WORK/hook.err")"; fi

rm -f "$STAMP"; mv "$CH/models_cache.json" "$CH/models_cache.json.hold"
run_hook; rc=$?
if [[ $rc -eq 0 && ! -e "$STAMP" ]] && ! grep -q 'codex:' "$WORK/hook.err"; then
    ok "session-init — no catalog: skipped entirely"
else bad "no-catalog skip" "rc=$rc"; fi
mv "$CH/models_cache.json.hold" "$CH/models_cache.json"

echo
echo "codex-models-test: $PASS pass, $FAIL fail"
[[ $FAIL -eq 0 ]]
