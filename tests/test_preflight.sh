#!/usr/bin/env bash
# Preflight and prerequisite-gate behaviour.
#
# Scenarios:
#   A  Docker missing + no .env -> full checklist with install hints (Kali)
#   A2 Docker missing + `start` -> aborts in preflight, never touches compose
#   A3 Docker missing + `stop`  -> friendly gate error (exit 2), not the old
#                                 terse "requires docker compose!"
#   B  Docker present, daemon down, no Compose v2, legacy docker-compose
#   C  Healthy host (fake Docker): full pass, exit 0
#   D  Missing .env: graceful [FAIL], no line-15 crash
#   D2 Fresh .env.example (placeholders): friendly placeholder errors
#   E  Docker present, no Compose v2 + `stop`: gate error mentioning legacy
#
# NOTE: scenario C requires >= 4GB RAM (preflight reads /proc/meminfo) and
# free ports 19200/19601/18220 on the test host.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "${HERE}")"
# shellcheck source=tests/lib.sh
. "${HERE}/lib.sh"

SCRIPT="${REPO}/elastic-container.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# Deterministic "Detected distribution" output regardless of the CI host.
KALI_FIX="${TMP}/kali.os-release"
cat >"${KALI_FIX}" <<'EOF'
PRETTY_NAME="Kali GNU/Linux Rolling"
NAME="Kali GNU/Linux"
VERSION_ID="2026.1"
ID=kali
ID_LIKE=debian
EOF

# PATH sandbox with everything preflight needs EXCEPT docker/docker-compose.
make_sandbox() {
  local bin="$1"
  local t p
  mkdir -p "${bin}"
  for t in bash dirname grep head tail cut sed awk df ss mktemp chmod rm \
    mkdir sleep date uname ip curl jq openssl env cat ls timeout; do
    p="$(command -v "${t}" 2>/dev/null)" || continue
    ln -sf "${p}" "${bin}/${t}"
  done
}

# Fully valid configuration using non-live ports (avoids colliding with a
# running stack on the test host).
write_test_env() {
  cat >"$1" <<'EOF'
SIEM_IP=192.168.50.10
SIEM_NAT_IP=
SIEM_IFACE=
SIEM_PREFIX=
LOCAL_KBN_URL=https://localhost:19601
LOCAL_ES_URL=https://localhost:19200
ELASTIC_USERNAME=elastic
ELASTIC_PASSWORD=CorrectHorseBattery99
KIBANA_USERNAME=kibana_system
KIBANA_PASSWORD=AnotherStrongPass123
STACK_VERSION=9.2.0
CLUSTER_NAME=siem-test
LICENSE=basic
ES_PORT=19200
KIBANA_PORT=19601
FLEET_PORT=18220
MEM_LIMIT=2147483648
KIBANA_ENCRYPTION_KEY=deadbeefcafe1234deadbeefcafe1234deadbeefcafe1234deadbeefcafe1234
EOF
}

# ---------------------------------------------------------------------------
# Scenario A: Docker missing + no .env (preflight)
# ---------------------------------------------------------------------------
make_sandbox "${TMP}/bin-a"
mkdir -p "${TMP}/cwd-a"
out="$(cd "${TMP}/cwd-a" &&
  PATH="${TMP}/bin-a" OS_RELEASE_FILE="${KALI_FIX}" "${SCRIPT}" preflight 2>&1)"
rc=$?

t_equals "A: preflight exits 1" "1" "${rc}"
t_contains "A: docker FAIL line" "${out}" "[FAIL] Docker Engine is not installed."
t_contains "A: no auto-install statement" "${out}" "This project does not automatically install Docker."
t_contains "A: detected distribution" "${out}" "Detected distribution: Kali GNU/Linux Rolling (ID=kali)."
t_contains "A: README section hint" "${out}" "See: README.md -> Host Prerequisites -> Docker on Kali Linux."
t_contains "A: rerun hint" "${out}" "Then rerun: ./elastic-container.sh preflight"
t_contains "A: distribution line" "${out}" "[OK] Distribution: Kali GNU/Linux Rolling (ID=kali ID_LIKE=debian)"
t_contains "A: missing .env reported" "${out}" "[FAIL] .env file not found (copy .env.example to .env)"
t_contains "A: failure summary" "${out}" "Preflight checks failed."
t_not_contains "A: old terse compose error gone" "${out}" "elastic-container requires docker compose!"
t_not_contains "A: no load-time crash" "${out}" ": line "

# ---------------------------------------------------------------------------
# Scenario A2: Docker missing + `start` -> abort inside preflight
# ---------------------------------------------------------------------------
out="$(cd "${TMP}/cwd-a" &&
  PATH="${TMP}/bin-a" OS_RELEASE_FILE="${KALI_FIX}" "${SCRIPT}" start 2>&1)"
rc=$?

t_equals "A2: start exits 1" "1" "${rc}"
t_contains "A2: docker FAIL line" "${out}" "[FAIL] Docker Engine is not installed."
t_contains "A2: no auto-install statement" "${out}" "This project does not automatically install Docker."
t_not_contains "A2: never reaches compose" "${out}" "Starting Elastic Stack"
t_not_contains "A2: never reaches READY" "${out}" "READY SET GO"

# ---------------------------------------------------------------------------
# Scenario A3: Docker missing + `stop` -> friendly gate error (exit 2)
# ---------------------------------------------------------------------------
out="$(cd "${TMP}/cwd-a" &&
  PATH="${TMP}/bin-a" OS_RELEASE_FILE="${KALI_FIX}" "${SCRIPT}" stop 2>&1)"
rc=$?

t_equals "A3: stop exits 2" "2" "${rc}"
t_contains "A3: gate ERROR header" "${out}" "ERROR: Docker Engine is not installed."
t_contains "A3: detected distribution" "${out}" "Detected distribution: Kali GNU/Linux Rolling (ID=kali)."
t_not_contains "A3: old terse compose error gone" "${out}" "elastic-container requires docker compose!"

# ---------------------------------------------------------------------------
# Scenario B: Docker present, daemon down, no Compose v2, legacy binary
# ---------------------------------------------------------------------------
make_sandbox "${TMP}/bin-b"
cat >"${TMP}/bin-b/docker" <<'EOF'
#!/bin/bash
case "${1:-}" in
  compose) exit 1 ;;
  info) exit 1 ;;
  ps) exit 1 ;;
  --version) echo "Docker version 28.0.0-fake, build fake" ; exit 0 ;;
  *) exit 0 ;;
esac
EOF
cat >"${TMP}/bin-b/docker-compose" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "${TMP}/bin-b/docker" "${TMP}/bin-b/docker-compose"
mkdir -p "${TMP}/cwd-b"
write_test_env "${TMP}/cwd-b/.env"

out="$(cd "${TMP}/cwd-b" &&
  PATH="${TMP}/bin-b" OS_RELEASE_FILE="${KALI_FIX}" "${SCRIPT}" preflight 2>&1)"
rc=$?

t_equals "B: preflight exits 1" "1" "${rc}"
t_contains "B: daemon FAIL" "${out}" "[FAIL] Docker Engine is installed but the daemon is not reachable"
t_contains "B: compose v2 FAIL" "${out}" "[FAIL] Docker Compose v2 plugin is not available."
t_contains "B: legacy binary note" "${out}" "A legacy 'docker-compose' (v1) binary was found"
t_contains "B: expected command" "${out}" "Expected: docker compose version"
t_contains "B: ports skipped while daemon down" "${out}" "[WARN] Ports: skipped (Docker daemon unreachable"
t_contains "B: failure summary" "${out}" "Preflight checks failed."

# ---------------------------------------------------------------------------
# Scenario C: healthy host with fake Docker -> full pass
# ---------------------------------------------------------------------------
make_sandbox "${TMP}/bin-c"
cat >"${TMP}/bin-c/docker" <<'EOF'
#!/bin/bash
case "${1:-}" in
  compose)
    if [ "${2:-}" = "version" ]; then
      echo "Docker Compose version v2.99.0-fake"
      exit 0
    fi
    exit 1
    ;;
  info) exit 0 ;;
  ps) exit 0 ;;
  --version) echo "Docker version 28.0.0-fake, build fake" ; exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "${TMP}/bin-c/docker"
mkdir -p "${TMP}/cwd-c"
write_test_env "${TMP}/cwd-c/.env"

out="$(cd "${TMP}/cwd-c" &&
  PATH="${TMP}/bin-c" OS_RELEASE_FILE="${KALI_FIX}" "${SCRIPT}" preflight 2>&1)"
rc=$?

t_equals "C: preflight exits 0" "0" "${rc}"
t_contains "C: success summary" "${out}" "All preflight checks passed."
t_contains "C: docker OK" "${out}" "[OK] Docker Engine (Docker version 28.0.0-fake"
t_contains "C: compose v2 OK" "${out}" "[OK] Docker Compose v2 (Docker Compose version v2.99.0-fake)"
t_contains "C: ports OK" "${out}" "[OK] Ports (19200, 19601, 18220)"
t_contains "C: required vars OK" "${out}" "[OK] Required variables"
t_contains "C: .env OK" "${out}" "[OK] .env"

# ---------------------------------------------------------------------------
# Scenario D: missing .env must be a friendly [FAIL], not a load-time crash
# ---------------------------------------------------------------------------
mkdir -p "${TMP}/cwd-d"
out="$(cd "${TMP}/cwd-d" && "${SCRIPT}" preflight 2>&1)"
rc=$?

t_equals "D: preflight exits 1" "1" "${rc}"
t_contains "D: friendly missing .env" "${out}" "[FAIL] .env file not found (copy .env.example to .env)"
t_contains "D: still prints distribution" "${out}" "[OK] Distribution:"
t_contains "D: reaches the summary" "${out}" "Preflight checks failed."
t_not_contains "D: no line-15 crash" "${out}" ": line "

# ---------------------------------------------------------------------------
# Scenario D2: fresh copy of .env.example -> placeholder errors, no crash
# ---------------------------------------------------------------------------
mkdir -p "${TMP}/cwd-d2"
cp "${REPO}/.env.example" "${TMP}/cwd-d2/.env"
out="$(cd "${TMP}/cwd-d2" && "${SCRIPT}" preflight 2>&1)"
rc=$?

t_equals "D2: preflight exits 1" "1" "${rc}"
t_contains "D2: placeholder reported" "${out}" "SIEM_IP is empty or still a placeholder"
t_contains "D2: reaches the summary" "${out}" "Preflight checks failed."
t_not_contains "D2: no load-time crash" "${out}" ": line "

# ---------------------------------------------------------------------------
# Scenario E: Docker present, no Compose v2 + `stop` -> gate error (exit 2)
# ---------------------------------------------------------------------------
make_sandbox "${TMP}/bin-e"
cat >"${TMP}/bin-e/docker" <<'EOF'
#!/bin/bash
case "${1:-}" in
  compose) exit 1 ;;
  info) exit 0 ;;
  ps) exit 0 ;;
  --version) echo "Docker version 28.0.0-fake, build fake" ; exit 0 ;;
  *) exit 0 ;;
esac
EOF
cat >"${TMP}/bin-e/docker-compose" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "${TMP}/bin-e/docker" "${TMP}/bin-e/docker-compose"
mkdir -p "${TMP}/cwd-e"

out="$(cd "${TMP}/cwd-e" &&
  PATH="${TMP}/bin-e" OS_RELEASE_FILE="${KALI_FIX}" "${SCRIPT}" stop 2>&1)"
rc=$?

t_equals "E: stop exits 2" "2" "${rc}"
t_contains "E: gate ERROR header" "${out}" "ERROR: Docker Compose v2 is not available"
t_contains "E: expected command" "${out}" "Expected: docker compose version"
t_contains "E: legacy binary note" "${out}" "A legacy 'docker-compose' (v1) binary was found"
t_not_contains "E: old terse compose error gone" "${out}" "elastic-container requires docker compose!"

t_done
