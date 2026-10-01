#!/usr/bin/env bash
# Run every tests/test_*.sh file and summarize.
set -u
cd "$(dirname "$0")" || exit 1

ran=0
failed=0

for t in test_*.sh; do
  [ -e "${t}" ] || continue
  echo "== ${t}"
  if bash "${t}"; then
    echo "   PASS"
  else
    echo "   FAIL"
    failed=$((failed + 1))
  fi
  ran=$((ran + 1))
  echo
done

echo "Test files run: ${ran}, failed: ${failed}"
[ "${failed}" -eq 0 ]
