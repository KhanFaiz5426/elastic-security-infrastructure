#!/usr/bin/env bash
# Detection-rule reconciliation (pure computation — no API calls, no installs).
#
# Decides which rules must be enabled/disabled so the rule state in Kibana
# matches the declared OS flags (WindowsDR / LinuxDR / MacOSDR) from .env.
#
# Contract:
#   * Managed scope  = a rule whose tags contain at least one of the exact OS
#     tag tokens this repository has always matched:
#         Windows: "Windows", "OS: Windows"
#         Linux:   "Linux",   "OS: Linux"
#         macOS:   "macOS",   "OS: macOS"
#     (Exact whole-tag membership only — substring tags such as
#      "Windows Defender" or "…indows" are NOT managed.)
#   * Managed rule + at least one owning OS flag set to 1  -> enabled
#   * Managed rule + no owning OS flag set to 1            -> disabled
#   * Rule outside the managed OS scope (including rules with no OS tag,
#     e.g. the package-default "Endpoint Security (Elastic Defend)") -> never
#     touched; package-defined state is preserved.
#   * Multi-OS rule (several OS tags): stays enabled while ANY of its OS
#     flags is 1; only disabled when NONE of its OS flags is 1.
#
# Inputs are NDJSON (one rule object per line) with at least:
#   {"id": "...", "enabled": true|false, "tags": ["...", ...]}
# which is exactly what `jq -c '.data[]'` emits from the Kibana rules _find
# response (GET /api/detection_engine/rules/_find).

# Print the reconcile plan as JSON:
#   {"total": N, "managed": N, "enable": [ids], "disable": [ids]}
#   enable  = managed, currently disabled, at least one owning flag = 1
#   disable = managed, currently enabled, no owning flag = 1
rule_reconcile_plan() {
  local rules_ndjson="$1"
  local win_flag="$2"
  local lin_flag="$3"
  local mac_flag="$4"

  jq -c -s \
    --argjson win "${win_flag}" \
    --argjson lin "${lin_flag}" \
    --argjson mac "${mac_flag}" '
    def managed_and_desired:
      (.tags // []) as $t
      | {
          win: (($t | index("Windows")) != null or ($t | index("OS: Windows")) != null),
          lin: (($t | index("Linux"))   != null or ($t | index("OS: Linux"))   != null),
          mac: (($t | index("macOS"))   != null or ($t | index("OS: macOS"))   != null)
        }
      | { managed: (.win or .lin or .mac),
          desired: ((.win and $win == 1) or (.lin and $lin == 1) or (.mac and $mac == 1)) };
    [ .[]
      | ({ id, enabled: (.enabled == true) } + managed_and_desired)
    ] as $rules
    | {
        total:   ($rules | length),
        managed: ([$rules[] | select(.managed)] | length),
        enable:  [$rules[] | select(.managed and (.enabled | not) and .desired) | .id],
        disable: [$rules[] | select(.managed and .enabled and (.desired | not)) | .id]
      }
  ' "${rules_ndjson}"
}

# Build the _bulk_action request body for an ids-scoped change:
#   rule_bulk_action_body enable  '["id1","id2"]'  ->  {"ids":[...],"action":"enable"}
# The caller must only invoke this with a non-empty id list.
rule_bulk_action_body() {
  local action="$1"
  local ids_json="$2"

  case "${action}" in
  enable | disable) ;;
  *)
    echo "rule_bulk_action_body: action must be enable or disable (got '${action}')" >&2
    return 1
    ;;
  esac
  jq -n -c --arg action "${action}" --argjson ids "${ids_json}" \
    '{ids: $ids, action: $action}'
}
