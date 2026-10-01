#!/usr/bin/env bash
# Minimal assertion helpers shared by the test scripts (sourced, not run).

T_PASS=0
T_FAIL=0

t_assert() {
  local desc="$1"
  shift
  if "$@"; then
    T_PASS=$((T_PASS + 1))
  else
    T_FAIL=$((T_FAIL + 1))
    echo "  ASSERT FAIL: ${desc}" >&2
  fi
}

t_contains() {
  # t_contains <description> <haystack> <needle>
  local desc="$1" haystack="$2" needle="$3"
  case "${haystack}" in
  *"${needle}"*)
    T_PASS=$((T_PASS + 1))
    ;;
  *)
    T_FAIL=$((T_FAIL + 1))
    echo "  ASSERT FAIL: ${desc}" >&2
    echo "    missing: ${needle}" >&2
    ;;
  esac
}

t_not_contains() {
  # t_not_contains <description> <haystack> <needle>
  local desc="$1" haystack="$2" needle="$3"
  case "${haystack}" in
  *"${needle}"*)
    T_FAIL=$((T_FAIL + 1))
    echo "  ASSERT FAIL: ${desc}" >&2
    echo "    unexpectedly found: ${needle}" >&2
    ;;
  *)
    T_PASS=$((T_PASS + 1))
    ;;
  esac
}

t_equals() {
  # t_equals <description> <expected> <actual>
  local desc="$1" expected="$2" actual="$3"
  if [ "${expected}" = "${actual}" ]; then
    T_PASS=$((T_PASS + 1))
  else
    T_FAIL=$((T_FAIL + 1))
    echo "  ASSERT FAIL: ${desc}" >&2
    echo "    expected: ${expected}" >&2
    echo "    actual:   ${actual}" >&2
  fi
}

t_done() {
  echo "  checks: ${T_PASS} passed, ${T_FAIL} failed"
  [ "${T_FAIL}" -eq 0 ]
}
