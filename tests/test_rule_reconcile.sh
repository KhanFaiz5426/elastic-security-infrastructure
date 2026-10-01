#!/usr/bin/env bash
# Detection-rule reconciliation tests.
#
# Layer A: pure plan tests (lib/rule-reconcile.sh) against synthetic rule sets
#          covering every tag/flag combination in the spec (cases a–m),
#          idempotency, and (when present) the real audited live inventory.
# Layer B: reconcile_detection_rules() from elastic-container.sh executed with
#          a mocked api_curl — verifies inventory fetch, ids-scoped bulk
#          requests, zero-write idempotency, pagination, and failure handling
#          WITHOUT any live API.
# Layer C: static wiring assertions on elastic-container.sh.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "${HERE}")"
# shellcheck source=tests/lib.sh
. "${HERE}/lib.sh"
# shellcheck source=lib/rule-reconcile.sh
. "${REPO}/lib/rule-reconcile.sh"

SCRIPT="${REPO}/elastic-container.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

mk_rule() {
  # mk_rule <id> <true|false> <tags-json>
  printf '{"id":"%s","enabled":%s,"tags":%s}\n' "$1" "$2" "$3"
}

plan_has() {
  # plan_has <plan-file> <enable|disable> <id>
  jq -e --arg a "$2" --arg id "$3" '(.[$a] | index($id)) != null' "$1" > /dev/null
}

plan_len() {
  jq -r --arg a "$2" '.[$a] | length' "$1"
}

run_plan() {
  # run_plan <rules-ndjson> <win> <lin> <mac> ; writes ${TMP}/plan.json
  rule_reconcile_plan "$1" "$2" "$3" "$4" > "${TMP}/plan.json"
}

# ---------------------------------------------------------------------------
# Layer A — synthetic rule sets (a–m)
# ---------------------------------------------------------------------------

# a) Windows-only rule, disabled, all flags on -> enable
mk_rule a-win false '["OS: Windows"]' > "${TMP}/a.ndjson"
run_plan "${TMP}/a.ndjson" 1 1 1
t_assert "a: windows-only rule is enabled" plan_has "${TMP}/plan.json" enable a-win
t_equals "a: nothing to disable" "0" "$(plan_len "${TMP}/plan.json" disable)"

# b) Linux-only rule, disabled, all flags on -> enable
mk_rule b-lin false '["OS: Linux"]' > "${TMP}/b.ndjson"
run_plan "${TMP}/b.ndjson" 1 1 1
t_assert "b: linux-only rule is enabled" plan_has "${TMP}/plan.json" enable b-lin

# c) macOS-only rule, disabled, all flags on -> enable
mk_rule c-mac false '["OS: macOS"]' > "${TMP}/c.ndjson"
run_plan "${TMP}/c.ndjson" 1 1 1
t_assert "c: macos-only rule is enabled" plan_has "${TMP}/plan.json" enable c-mac

# d) Windows + Linux rule: any owning flag keeps/turns it on
mk_rule d-wl false '["OS: Windows", "OS: Linux"]' > "${TMP}/d.ndjson"
run_plan "${TMP}/d.ndjson" 0 1 0
t_assert "d: W+L rule enabled while Linux flag is on" plan_has "${TMP}/plan.json" enable d-wl
mk_rule d-wl true '["OS: Windows", "OS: Linux"]' > "${TMP}/d.ndjson"
run_plan "${TMP}/d.ndjson" 1 0 0
t_equals "d: W+L rule kept enabled while Windows flag is on (not disabled)" \
  "0" "$(plan_len "${TMP}/plan.json" disable)"

# e) Windows + macOS rule: an unrelated flag (Linux) does not rescue it
mk_rule e-wm true '["OS: Windows", "OS: macOS"]' > "${TMP}/e.ndjson"
run_plan "${TMP}/e.ndjson" 0 1 0
t_assert "e: W+M rule disabled when neither Windows nor macOS flag is on" \
  plan_has "${TMP}/plan.json" disable e-wm
run_plan "${TMP}/e.ndjson" 1 0 0
t_equals "e: W+M rule kept when Windows flag is on" "0" "$(plan_len "${TMP}/plan.json" disable)"

# f) Linux + macOS rule
mk_rule f-lm true '["OS: Linux", "OS: macOS"]' > "${TMP}/f.ndjson"
run_plan "${TMP}/f.ndjson" 1 0 0
t_assert "f: L+M rule disabled when only Windows flag is on" plan_has "${TMP}/plan.json" disable f-lm
run_plan "${TMP}/f.ndjson" 0 1 0
t_equals "f: L+M rule kept when Linux flag is on" "0" "$(plan_len "${TMP}/plan.json" disable)"

# g) all three OS tags
mk_rule g-all true '["OS: Linux", "OS: Windows", "OS: macOS"]' > "${TMP}/g.ndjson"
run_plan "${TMP}/g.ndjson" 0 0 1
t_equals "g: 3-OS rule kept while macOS flag is on" "0" "$(plan_len "${TMP}/plan.json" disable)"
run_plan "${TMP}/g.ndjson" 0 0 0
t_assert "g: 3-OS rule disabled when all flags are off" plan_has "${TMP}/plan.json" disable g-all

# h) no OS tag -> never managed, even when all flags are off
mk_rule h-notag true '["Data Source: Elastic Defend"]' > "${TMP}/h.ndjson"
run_plan "${TMP}/h.ndjson" 0 0 0
t_equals "h: no-OS-tag rule untouched (disable)" "0" "$(plan_len "${TMP}/plan.json" disable)"
t_equals "h: no-OS-tag rule untouched (enable)" "0" "$(plan_len "${TMP}/plan.json" enable)"
run_plan "${TMP}/h.ndjson" 1 1 1
t_equals "h: no-OS-tag rule untouched with all flags on" "0" "$(plan_len "${TMP}/plan.json" enable)"

# i) package-default protection: no-OS-tag default stays as-is;
#    OS-tagged default follows its flag (documented behavior)
mk_rule i-default true '[]' > "${TMP}/i.ndjson"
run_plan "${TMP}/i.ndjson" 0 0 0
t_equals "i: package-default rule without OS tag never disabled" "0" "$(plan_len "${TMP}/plan.json" disable)"
mk_rule i-pkg-os true '["OS: Linux"]' > "${TMP}/i.ndjson"
run_plan "${TMP}/i.ndjson" 1 1 1
t_equals "i: OS-tagged package default already correct (no writes)" "0" \
  "$(( $(plan_len "${TMP}/plan.json" enable) + $(plan_len "${TMP}/plan.json" disable) ))"
run_plan "${TMP}/i.ndjson" 1 0 0
t_assert "i: OS-tagged package default follows its OS flag" plan_has "${TMP}/plan.json" disable i-pkg-os

# j) already-enabled rule with flag on -> no-op
mk_rule j-on true '["OS: Windows"]' > "${TMP}/j.ndjson"
run_plan "${TMP}/j.ndjson" 1 0 0
t_equals "j: already-enabled managed rule needs no change" "0" \
  "$(( $(plan_len "${TMP}/plan.json" enable) + $(plan_len "${TMP}/plan.json" disable) ))"

# k) already-disabled rule with flag off -> no-op
mk_rule k-off false '["OS: Linux"]' > "${TMP}/k.ndjson"
run_plan "${TMP}/k.ndjson" 1 0 0
t_equals "k: already-disabled managed rule needs no change" "0" \
  "$(( $(plan_len "${TMP}/plan.json" enable) + $(plan_len "${TMP}/plan.json" disable) ))"

# l) flag transition 1 -> 0: previously enabled rule must be disabled
mk_rule l-flip true '["OS: Linux"]' > "${TMP}/l.ndjson"
run_plan "${TMP}/l.ndjson" 1 0 0
t_assert "l: transition 1->0 disables the rule" plan_has "${TMP}/plan.json" disable l-flip

# m) flag transition 0 -> 1: previously disabled rule must be enabled
mk_rule m-flip false '["OS: Linux"]' > "${TMP}/m.ndjson"
run_plan "${TMP}/m.ndjson" 1 0 0
t_equals "m: with LinuxDR=0 nothing happens" "0" "$(plan_len "${TMP}/plan.json" enable)"
run_plan "${TMP}/m.ndjson" 1 1 0
t_assert "m: transition 0->1 enables the rule" plan_has "${TMP}/plan.json" enable m-flip

# Extra: exact-tag parity with the historic KQL (bare token still matches)
mk_rule bare false '["Linux"]' > "${TMP}/bare.ndjson"
run_plan "${TMP}/bare.ndjson" 1 1 1
t_assert "extra: bare 'Linux' tag token matched" plan_has "${TMP}/plan.json" enable bare

# Extra: substring tags are NOT managed (the audit's 'indows' near-misses)
mk_rule substr true '["Windows Defender", "Data Source: Windows"]' > "${TMP}/substr.ndjson"
run_plan "${TMP}/substr.ndjson" 0 0 0
t_equals "extra: substring tags never managed (no disable)" "0" "$(plan_len "${TMP}/plan.json" disable)"

# Extra: non-OS tag only -> untouched
mk_rule ds true '["Data Source: Auditd Manager"]' > "${TMP}/ds.ndjson"
run_plan "${TMP}/ds.ndjson" 0 0 0
t_equals "extra: Data-Source-only rule untouched" "0" "$(plan_len "${TMP}/plan.json" disable)"

# Extra: OS-managed despite unrelated extra tags
mk_rule jamf false '["OS: macOS", "Data Source: Jamf"]' > "${TMP}/jamf.ndjson"
run_plan "${TMP}/jamf.ndjson" 1 0 1
t_assert "extra: rule with extra tags still OS-managed" plan_has "${TMP}/plan.json" enable jamf

# Idempotency: apply a plan, re-plan -> zero changes both ways
cat > "${TMP}/idem.ndjson" <<'EOF'
{"id":"idem-1","enabled":true,"tags":["OS: Windows"]}
{"id":"idem-2","enabled":false,"tags":["OS: Linux"]}
{"id":"idem-3","enabled":true,"tags":["OS: Linux","OS: Windows"]}
{"id":"idem-4","enabled":true,"tags":[]}
{"id":"idem-5","enabled":true,"tags":["OS: macOS"]}
EOF
run_plan "${TMP}/idem.ndjson" 1 1 0
t_equals "idempotency: plan enables exactly idem-2" \
  '["idem-2"]' "$(jq -c .enable "${TMP}/plan.json")"
t_equals "idempotency: plan disables exactly idem-5" \
  '["idem-5"]' "$(jq -c .disable "${TMP}/plan.json")"
# simulate applying the plan
jq -c --slurpfile plan "${TMP}/plan.json" '
  . as $r
  | ($plan[0].enable + $plan[0].disable) as $changed
  | .enabled = (if ($changed | index($r.id)) != null then (.enabled | not) else .enabled end)
' "${TMP}/idem.ndjson" > "${TMP}/idem-after.ndjson"
run_plan "${TMP}/idem-after.ndjson" 1 1 0
t_equals "idempotency: second run has no enables" "0" "$(plan_len "${TMP}/plan.json" enable)"
t_equals "idempotency: second run has no disables" "0" "$(plan_len "${TMP}/plan.json" disable)"

# Bulk request body builder
body="$(rule_bulk_action_body enable '["x1","x2"]')"
t_assert "body: valid JSON" bash -c 'printf "%s" "$1" | jq -e . > /dev/null' _ "${body}"
t_equals "body: action" "enable" "$(jq -r .action <<<"${body}")"
t_equals "body: ids" '["x1","x2"]' "$(jq -c .ids <<<"${body}")"
if rule_bulk_action_body delete '["x"]' 2>/dev/null; then
  t_assert "body: rejects unknown action" false
else
  t_assert "body: rejects unknown action" true
fi

# Real audited inventory (read-only evidence file; optional)
LIVE_NDJSON="/tmp/opencode/audit/rules_all.json"
if [ -f "${LIVE_NDJSON}" ]; then
  run_plan "${LIVE_NDJSON}" 1 1 1
  t_equals "live: 1/1/1 produces zero writes (matches deployed state)" "0" \
    "$(( $(plan_len "${TMP}/plan.json" enable) + $(plan_len "${TMP}/plan.json" disable) ))"
  t_equals "live: managed scope is the audited 1195" "1195" "$(jq -r .managed "${TMP}/plan.json")"
  run_plan "${LIVE_NDJSON}" 1 0 0
  t_equals "live: 1/0/0 disables exactly the audited 577" "577" "$(plan_len "${TMP}/plan.json" disable)"
  ep_id="$(jq -r 'select(.name == "Endpoint Security (Elastic Defend)") | .id' "${LIVE_NDJSON}")"
  t_equals "live: package-default rule never in disable list" "0" \
    "$(jq --arg id "${ep_id}" '[.disable[] | select(. == $id)] | length' "${TMP}/plan.json")"
fi

# ---------------------------------------------------------------------------
# Layer B — reconcile_detection_rules() with a mocked api_curl
# ---------------------------------------------------------------------------

# Extract the function verbatim from the script (read-only).
eval "$(sed -n '/^reconcile_detection_rules() {/,/^}/p' "${SCRIPT}")" || {
  echo "  ASSERT FAIL: could not extract reconcile_detection_rules()" >&2
}

HEADERS=(-H "kbn-xsrf: kibana")
LOCAL_KBN_URL="https://mock-kibana.local"
RECONCILE_TMP=""
export TMPDIR="${TMP}"
BULK_LOG="${TMP}/bulk.ndjson"
FIND_LOG="${TMP}/find.log"
: > "${BULK_LOG}"
: > "${FIND_LOG}"

# Mock: serves rules NDJSON from MOCK_FIND_DATA as a _find response and
# records every _bulk_action request body. MOCK_FIND_TOTAL overrides .total
# (to exercise pagination) and MOCK_FIND_PAGE2 supplies page 2 data.
api_curl() {
  local url="" body="" prev="" page=1 data_file total
  while [ "$#" -gt 0 ]; do
    case "$1" in
    -d)
      prev="d"
      ;;
    *)
      if [ "${prev}" = "d" ]; then
        body="$1"
        prev=""
      fi
      case "$1" in
      http*) url="$1" ;;
      esac
      ;;
    esac
    shift
  done
  case "${url}" in
  *_find*)
    page="$(sed -n 's/.*[?&]page=\([0-9][0-9]*\).*/\1/p' <<<"${url}")"
    [ -n "${page}" ] || page=1
    echo "find page=${page}" >> "${FIND_LOG}"
    data_file="${MOCK_FIND_DATA}"
    if [ "${page}" = "2" ] && [ -n "${MOCK_FIND_PAGE2:-}" ]; then
      data_file="${MOCK_FIND_PAGE2}"
    fi
    total="${MOCK_FIND_TOTAL:-$(wc -l < "${data_file}")}"
    jq -R -s --argjson total "${total}" \
      '{data: (split("\n") | map(select(length > 0) | fromjson)), total: $total}' \
      "${data_file}"
    ;;
  *_bulk_action*)
    printf '%s\n' "${body}" >> "${BULK_LOG}"
    printf '{"success":true,"rules_count":0}\n'
    ;;
  *)
    echo "api_curl mock: unexpected URL ${url}" >&2
    return 1
    ;;
  esac
}

# B1: state already matches flags 1/1/1 -> zero bulk calls (idempotent)
: > "${BULK_LOG}"
: > "${FIND_LOG}"
cat > "${TMP}/b1.ndjson" <<'EOF'
{"id":"b1-win","enabled":true,"tags":["OS: Windows"]}
{"id":"b1-lin","enabled":true,"tags":["OS: Linux"]}
{"id":"b1-def","enabled":true,"tags":[]}
EOF
MOCK_FIND_DATA="${TMP}/b1.ndjson"
WindowsDR=1
LinuxDR=1
MacOSDR=1
out="$(reconcile_detection_rules)"
rc=$?
t_equals "B1: exits 0" "0" "${rc}"
t_equals "B1: zero bulk calls when state already matches" "0" "$(wc -l < "${BULK_LOG}")"
t_contains "B1: idempotent message" "${out}" "no changes (idempotent)"
t_contains "B1: scanned summary" "${out}" "Scanned 3 installed rules (2 in the OS-managed scope)"

# B2: flag 1 -> 0 transition disables exactly the right rules
: > "${BULK_LOG}"
cat > "${TMP}/b2.ndjson" <<'EOF'
{"id":"b2-win","enabled":true,"tags":["OS: Windows"]}
{"id":"b2-lin","enabled":true,"tags":["OS: Linux"]}
{"id":"b2-both","enabled":true,"tags":["OS: Linux","OS: Windows"]}
{"id":"b2-def","enabled":true,"tags":[]}
EOF
MOCK_FIND_DATA="${TMP}/b2.ndjson"
WindowsDR=1
LinuxDR=0
MacOSDR=0
out="$(reconcile_detection_rules)"
rc=$?
t_equals "B2: exits 0" "0" "${rc}"
t_equals "B2: exactly one bulk call" "1" "$(wc -l < "${BULK_LOG}")"
t_equals "B2: disables only the Linux-only rule" '["b2-lin"]' \
  "$(jq -c '.ids' <<<"$(head -1 "${BULK_LOG}")")"
t_equals "B2: bulk action is disable" "disable" "$(jq -r '.action' <<<"$(head -1 "${BULK_LOG}")")"
t_contains "B2: disabled count reported" "${out}" "Disabled 1 rule(s)"

# B3: transition 0 -> 1 enables, with valid enable request body
: > "${BULK_LOG}"
cat > "${TMP}/b3.ndjson" <<'EOF'
{"id":"b3-win","enabled":true,"tags":["OS: Windows"]}
{"id":"b3-lin","enabled":false,"tags":["OS: Linux"]}
{"id":"b3-def","enabled":true,"tags":[]}
EOF
MOCK_FIND_DATA="${TMP}/b3.ndjson"
WindowsDR=1
LinuxDR=1
MacOSDR=1
out="$(reconcile_detection_rules)"
rc=$?
t_equals "B3: exits 0" "0" "${rc}"
t_equals "B3: exactly one bulk call" "1" "$(wc -l < "${BULK_LOG}")"
t_equals "B3: enables the Linux rule" '["b3-lin"]' "$(jq -c '.ids' <<<"$(head -1 "${BULK_LOG}")")"
t_equals "B3: bulk action is enable" "enable" "$(jq -r '.action' <<<"$(head -1 "${BULK_LOG}")")"
t_assert "B3: request body is valid JSON" \
  bash -c 'printf "%s" "$1" | jq -e . > /dev/null' _ "$(head -1 "${BULK_LOG}")"
t_contains "B3: enabled count reported" "${out}" "Enabled 1 rule(s)"

# B4: all flags 0 -> managed rules disabled, no-tag rule untouched
: > "${BULK_LOG}"
cat > "${TMP}/b4.ndjson" <<'EOF'
{"id":"b4-lin","enabled":true,"tags":["OS: Linux"]}
{"id":"b4-mac","enabled":true,"tags":["OS: macOS"]}
{"id":"b4-def","enabled":true,"tags":[]}
EOF
MOCK_FIND_DATA="${TMP}/b4.ndjson"
WindowsDR=0
LinuxDR=0
MacOSDR=0
out="$(reconcile_detection_rules)"
t_equals "B4: disables exactly the two OS-managed rules" '["b4-lin","b4-mac"]' \
  "$(jq -c '.ids' <<<"$(head -1 "${BULK_LOG}")")"

# B5: pagination — total > per_page triggers a second _find call
: > "${BULK_LOG}"
: > "${FIND_LOG}"
cat > "${TMP}/b5-p1.ndjson" <<'EOF'
{"id":"b5-r1","enabled":false,"tags":["OS: Windows"]}
{"id":"b5-r2","enabled":false,"tags":["OS: Linux"]}
EOF
printf '{"id":"b5-r3","enabled":false,"tags":["OS: macOS"]}\n' > "${TMP}/b5-p2.ndjson"
MOCK_FIND_DATA="${TMP}/b5-p1.ndjson"
MOCK_FIND_PAGE2="${TMP}/b5-p2.ndjson"
MOCK_FIND_TOTAL=15000
WindowsDR=1
LinuxDR=1
MacOSDR=1
out="$(reconcile_detection_rules)"
rc=$?
t_equals "B5: exits 0" "0" "${rc}"
t_equals "B5: two inventory pages fetched" "2" "$(wc -l < "${FIND_LOG}")"
t_contains "B5: all 3 rules scanned" "${out}" "Scanned 3 installed rules"
unset MOCK_FIND_PAGE2 MOCK_FIND_TOTAL

# B6: broken _find response -> contained failure (exit 1), no bulk calls
: > "${BULK_LOG}"
api_curl() {
  printf '{"error":"nope"}'
  return 0
}
if (reconcile_detection_rules > /dev/null 2>&1); then
  t_assert "B6: broken _find response fails with exit 1" false
else
  t_assert "B6: broken _find response fails with exit 1" true
fi
t_equals "B6: no bulk call after broken inventory" "0" "$(wc -l < "${BULK_LOG}")"

# ---------------------------------------------------------------------------
# Layer C — static wiring assertions
# ---------------------------------------------------------------------------

t_assert "C: script sources lib/rule-reconcile.sh" \
  grep -q "lib/rule-reconcile.sh" "${SCRIPT}"
t_assert "C: script defines reconcile_detection_rules" \
  grep -q "^reconcile_detection_rules() {" "${SCRIPT}"
c_calls="$(grep -c "reconcile_detection_rules" "${SCRIPT}")"
t_assert "C: reconcile function defined and called" test "${c_calls}" -ge 2
t_assert "C: prebuilt installation preserved (prepackaged)" \
  grep -q "rules/prepackaged" "${SCRIPT}"
t_assert "C: uses ids-scoped _bulk_action (enable + disable)" \
  test "$(grep -c "_bulk_action" "${SCRIPT}")" -ge 2
t_not_contains "C: old KQL enable-only blocks removed (single source of truth)" \
  "$(cat "${SCRIPT}")" "alert.attributes.tags"
t_assert "C: lib keeps exact tag tokens (OS: Windows)" \
  grep -q '"OS: Windows"' "${REPO}/lib/rule-reconcile.sh"
t_assert "C: lib keeps exact tag tokens (OS: Linux)" \
  grep -q '"OS: Linux"' "${REPO}/lib/rule-reconcile.sh"
t_assert "C: lib keeps exact tag tokens (OS: macOS)" \
  grep -q '"OS: macOS"' "${REPO}/lib/rule-reconcile.sh"

t_done
