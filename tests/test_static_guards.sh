#!/usr/bin/env bash
# Static regression guards for the fresh-deployment (Kali/Docker) failure mode.
#
# The original incident: docs told operators to configure Docker's Ubuntu apt
# repository on Kali with `$(lsb_release -cs)` -> suite "kali-rolling" -> 404
# and docker-ce could not install. These guards make sure the mistakes can
# never creep back in:
#   * deployment scripts never install Docker (or add Docker repositories)
#   * scripts carry the friendly no-auto-install / [OK]-[FAIL] guidance
#   * README/Guide document every supported distribution, including the
#     explicit "do not add Docker's Ubuntu repo to Kali" warning
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "${HERE}")"
# shellcheck source=tests/lib.sh
. "${HERE}/lib.sh"

DEPLOY_SCRIPTS=(
  "${REPO}/elastic-container.sh"
  "${REPO}/fleet-entrypoint.sh"
  "${REPO}/set-static-ip.sh"
  "${REPO}/lib/host-distro.sh"
)

# --- 1. Deployment scripts must never install Docker or configure its repos ---
forbidden_pattern='download\.docker\.com|get\.docker\.com|lsb_release|kali-rolling'
pkgmgr_install_pattern='(apt|apt-get|dnf|yum|pacman|zypper)[^|;&]*(install|-S)[^|;&]*(docker|containerd)'
curl_pipe_pattern='curl[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba)?sh'

for script in "${DEPLOY_SCRIPTS[@]}"; do
  name="$(basename "${script}")"
  t_assert "${name}: no Docker repository URLs / lsb_release / kali-rolling suite" \
    bash -c '! grep -Eq "$0" "$1"' "${forbidden_pattern}" "${script}"
  t_assert "${name}: no package-manager Docker install commands" \
    bash -c '! grep -Eiq "$0" "$1"' "${pkgmgr_install_pattern}" "${script}"
  t_assert "${name}: no curl-piped shell installs" \
    bash -c '! grep -Eq "$0" "$1"' "${curl_pipe_pattern}" "${script}"
done

# --- 2. elastic-container.sh carries the required guidance/marker strings ---
ec="${REPO}/elastic-container.sh"
t_assert "preflight states Docker is never auto-installed" \
  grep -q "does not automatically install Docker" "${ec}"
t_assert "preflight uses [OK] marker" grep -q 'pass="\[OK\]"' "${ec}"
t_assert "preflight uses [FAIL] marker" grep -q 'fail="\[FAIL\]"' "${ec}"
t_assert "preflight reports the distribution" grep -q "Distribution:" "${ec}"
t_assert "script sources the distro-detection library" \
  grep -q "lib/host-distro.sh" "${ec}"
t_assert "gate gives an explicit Compose v2 expectation" \
  grep -q "Expected: docker compose version" "${ec}"

# --- 3. Preflight must diagnose failures instead of guessing ----------------
t_assert "script shows the real 'docker info' error line" \
  grep -q "docker info says:" "${ec}"
t_assert "script detects stale docker-group sessions" \
  grep -q "IS listed in the docker group" "${ec}"
t_assert "script offers the sg docker workaround" \
  grep -q "sg docker -c" "${ec}"
t_assert "script prints a distro-aware tool install hint" \
  grep -q "print_tool_install_hint" "${ec}"
t_assert "apt tool hint present" \
  grep -qF 'Install: sudo apt install -y ${tools}' "${ec}"

# --- 4. README documents every distribution + the Kali warning --------------
readme="${REPO}/README.md"
for heading in "### Ubuntu" "### Debian" "### Kali" "### Fedora" "### RHEL" \
  "### Rocky" "### AlmaLinux" "### Arch" "### macOS"; do
  t_assert "README has ${heading} section" grep -q -- "${heading}" "${readme}"
done
t_assert "README warns about the Ubuntu repo on Kali" \
  grep -q "download.docker.com/linux/ubuntu" "${readme}"
t_assert "README names the bogus kali-rolling suite" \
  grep -q "kali-rolling" "${readme}"
t_assert "README mentions Debian stable codename (trixie)" \
  grep -q "trixie" "${readme}"
t_assert "README documents the Compose v2 verification" \
  grep -q "docker compose version" "${readme}"
t_assert "README no longer uses the old newgrp one-liner" \
  bash -c '! grep -q "newgrp" "$0"' "${readme}"
t_assert "README documents how to install the host tools" \
  grep -q "apt install -y jq" "${readme}"

# --- 5. Deployment guide Phase 0 = host prerequisites ------------------------
guide="${REPO}/ELASTIC-SECURITY-DEPLOYMENT-GUIDE.md"
t_assert "guide Phase 0 heading renamed to Host Prerequisites" \
  grep -q "# PHASE 0 — HOST PREREQUISITES" "${guide}"
t_assert "guide no longer has the old Phase 0 heading" \
  bash -c '! grep -q "# PHASE 0 — PREREQUISITES" "$0"' "${guide}"
t_assert "guide TOC links the new Phase 0 anchor" \
  grep -q "\[Phase 0 — Host Prerequisites\](#phase-0--host-prerequisites)" "${guide}"
t_assert "guide warns about the Ubuntu repo on Kali" \
  grep -q "download.docker.com/linux/ubuntu" "${guide}"
t_assert "guide verifies Compose v2" grep -q "docker compose version" "${guide}"
t_assert "guide has per-distro Docker sections" \
  grep -q "### Docker on Kali Linux" "${guide}"
t_assert "guide documents how to install the host tools" \
  grep -q "apt install -y jq" "${guide}"
t_assert "guide explains the stale docker-group session" \
  grep -q "sg docker -c" "${guide}"

t_done
