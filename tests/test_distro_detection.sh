#!/usr/bin/env bash
# Distro detection: 9 representative /etc/os-release fixtures + missing file.
# Expected output fields (pipe separated):
#   PRESENT|ID|ID_LIKE|PRETTY|FAMILY|PKG_MGR|SECTION
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "${HERE}")"
# shellcheck source=tests/lib.sh
. "${HERE}/lib.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

detect() {
  local fixture="$1"
  (
    OS_RELEASE_FILE="${fixture}"
    # shellcheck source=lib/host-distro.sh
    . "${REPO}/lib/host-distro.sh"
    if ! host_detect_distro; then
      echo "DETECT_FAILED"
      exit 0
    fi
    printf '%s|%s|%s|%s|%s|%s|%s' \
      "${HOST_OS_PRESENT}" "${HOST_OS_ID}" "${HOST_OS_ID_LIKE}" \
      "${HOST_OS_PRETTY}" "${HOST_OS_FAMILY}" "${HOST_OS_PKG_MGR}" \
      "${HOST_OS_SECTION}"
  )
}

fixture() {
  # fixture <name> <<EOF ... EOF
  cat >"${TMP}/$1.os-release"
}

fixture ubuntu <<'EOF'
NAME="Ubuntu"
VERSION="24.04.3 LTS (Noble Numbat)"
ID=ubuntu
ID_LIKE=debian
PRETTY_NAME="Ubuntu 24.04.3 LTS"
VERSION_ID="24.04"
UBUNTU_CODENAME=noble
EOF

fixture debian <<'EOF'
PRETTY_NAME="Debian GNU/Linux 13 (trixie)"
NAME="Debian GNU/Linux"
VERSION_ID="13"
VERSION="13 (trixie)"
ID=debian
EOF

fixture kali <<'EOF'
PRETTY_NAME="Kali GNU/Linux Rolling"
NAME="Kali GNU/Linux"
VERSION_ID="2026.1"
VERSION="2026.1"
ID=kali
ID_LIKE=debian
ANSI_COLOR="1;31"
EOF

fixture fedora <<'EOF'
NAME="Fedora Linux"
VERSION="44 (Workstation Edition)"
ID=fedora
VERSION_ID="44"
PRETTY_NAME="Fedora Linux 44"
EOF

fixture rhel <<'EOF'
NAME="Red Hat Enterprise Linux"
VERSION="9.5 (Plow)"
ID="rhel"
ID_LIKE="fedora"
VERSION_ID="9.5"
PRETTY_NAME="Red Hat Enterprise Linux 9.5 (Plow)"
EOF

# Single-quoted values (also exercises quote handling)
fixture rocky <<'EOF'
NAME='Rocky Linux'
VERSION='9.5 (Blue Onyx)'
ID='rocky'
ID_LIKE='rhel centos fedora'
VERSION_ID='9.5'
PRETTY_NAME='Rocky Linux 9.5 (Blue Onyx)'
EOF

fixture almalinux <<'EOF'
NAME="AlmaLinux"
VERSION="9.5 (Walrein)"
ID="almalinux"
ID_LIKE="rhel centos fedora"
VERSION_ID="9.5"
PRETTY_NAME="AlmaLinux 9.5 (Walrein)"
EOF

fixture arch <<'EOF'
NAME="Arch Linux"
PRETTY_NAME="Arch Linux"
ID=arch
BUILD_ID=rolling
EOF

fixture unknown <<'EOF'
NAME="Nonsuch OS"
ID=nonsuch
PRETTY_NAME="Nonsuch OS 1.0"
VERSION_ID="1.0"
EOF

out="$(detect "${TMP}/ubuntu.os-release")"
t_equals "ubuntu mapping" \
  "1|ubuntu|debian|Ubuntu 24.04.3 LTS|debian|apt|Ubuntu" "${out}"

out="$(detect "${TMP}/debian.os-release")"
t_equals "debian mapping" \
  "1|debian||Debian GNU/Linux 13 (trixie)|debian|apt|Debian" "${out}"

out="$(detect "${TMP}/kali.os-release")"
t_equals "kali mapping (Kali must resolve to debian/apt, never an Ubuntu suite)" \
  "1|kali|debian|Kali GNU/Linux Rolling|debian|apt|Kali Linux" "${out}"

out="$(detect "${TMP}/fedora.os-release")"
t_equals "fedora mapping" \
  "1|fedora||Fedora Linux 44|rhel|dnf|Fedora" "${out}"

out="$(detect "${TMP}/rhel.os-release")"
t_equals "rhel mapping" \
  "1|rhel|fedora|Red Hat Enterprise Linux 9.5 (Plow)|rhel|dnf|RHEL" "${out}"

out="$(detect "${TMP}/rocky.os-release")"
t_equals "rocky mapping (single-quoted values)" \
  "1|rocky|rhel centos fedora|Rocky Linux 9.5 (Blue Onyx)|rhel|dnf|Rocky Linux" "${out}"

out="$(detect "${TMP}/almalinux.os-release")"
t_equals "almalinux mapping" \
  "1|almalinux|rhel centos fedora|AlmaLinux 9.5 (Walrein)|rhel|dnf|AlmaLinux" "${out}"

out="$(detect "${TMP}/arch.os-release")"
t_equals "arch mapping" \
  "1|arch||Arch Linux|arch|pacman|Arch Linux" "${out}"

out="$(detect "${TMP}/unknown.os-release")"
t_equals "unknown distribution stays unknown" \
  "1|nonsuch||Nonsuch OS 1.0|unknown|unknown|" "${out}"

out="$(detect "${TMP}/does-not-exist.os-release")"
t_equals "missing os-release file reports failure" "DETECT_FAILED" "${out}"

# Summary helper (used by preflight output)
summary="$(
  OS_RELEASE_FILE="${TMP}/kali.os-release"
  # shellcheck source=lib/host-distro.sh
  . "${REPO}/lib/host-distro.sh"
  host_detect_distro
  host_distro_summary
)"
t_equals "host_distro_summary for Kali" \
  "Kali GNU/Linux Rolling (ID=kali ID_LIKE=debian)" "${summary}"

t_done
