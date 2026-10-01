#!/usr/bin/env bash
# Host distribution detection (read-only, informational).
#
# Parses /etc/os-release WITHOUT sourcing it (no code execution) and maps the
# distribution to a human-readable name, an ID/ID_LIKE summary, a family, and
# the package manager an operator would use to install prerequisites manually.
#
# IMPORTANT: nothing here ever installs software or adds package repositories.
# This project does not install Docker. The results are used for preflight
# reporting and to point the operator at the right README/Guide install
# section for THEIR distribution.
#
# Overridable for tests:
#   OS_RELEASE_FILE=/path/to/fake-os-release   (default: /etc/os-release)
#
# Populated by host_detect_distro():
#   HOST_OS_PRESENT    1 if a usable os-release was found (or macOS), else 0
#   HOST_OS_ID         ID field          (e.g. ubuntu, kali, fedora, arch)
#   HOST_OS_ID_LIKE    ID_LIKE field     (e.g. debian, "rhel centos fedora")
#   HOST_OS_PRETTY     PRETTY_NAME field (e.g. "Kali GNU/Linux Rolling")
#   HOST_OS_VERSION_ID VERSION_ID field  (e.g. 24.04)
#   HOST_OS_FAMILY     debian | rhel | arch | suse | macos | unknown
#   HOST_OS_PKG_MGR    apt | dnf | pacman | zypper | brew | unknown
#   HOST_OS_SECTION    README "Docker on <SECTION>" heading hint ("" = generic)

HOST_OS_PRESENT=0
HOST_OS_ID="unknown"
HOST_OS_ID_LIKE=""
HOST_OS_PRETTY="Unknown Linux"
HOST_OS_VERSION_ID=""
HOST_OS_FAMILY="unknown"
HOST_OS_PKG_MGR="unknown"
HOST_OS_SECTION=""

# Print the value of KEY= from an os-release style file. Handles single or
# double quoted values. Never evaluates the file contents.
host_os_release_field() {
  local key="$1"
  local file="$2"
  local line value
  line="$(grep -E "^${key}=" "${file}" 2>/dev/null | head -n 1)" || true
  [ -n "${line}" ] || return 0
  value="${line#*=}"
  if [ "${value#\"}" != "${value}" ] && [ "${value%\"}" != "${value}" ]; then
    value="${value#\"}"
    value="${value%\"}"
  elif [ "${value#\'}" != "${value}" ] && [ "${value%\'}" != "${value}" ]; then
    value="${value#\'}"
    value="${value%\'}"
  fi
  printf '%s' "${value}"
}

# Map ID / ID_LIKE to a family, package manager, and README section hint.
# ID is checked first, then each ID_LIKE token in order.
host_map_family() {
  local id="$1"
  local id_like="$2"
  local token
  local found=0
  for token in ${id} ${id_like}; do
    case "${token}" in
    ubuntu | debian | kali | raspbian | linuxmint | pop | elementary | parrot)
      HOST_OS_FAMILY="debian"
      HOST_OS_PKG_MGR="apt"
      found=1
      break
      ;;
    rhel | centos | fedora | rocky | almalinux | ol | amzn | scientific)
      HOST_OS_FAMILY="rhel"
      HOST_OS_PKG_MGR="dnf"
      found=1
      break
      ;;
    arch | manjaro | endeavouros | artix)
      HOST_OS_FAMILY="arch"
      HOST_OS_PKG_MGR="pacman"
      found=1
      break
      ;;
    sles | suse | opensuse* | sled)
      HOST_OS_FAMILY="suse"
      HOST_OS_PKG_MGR="zypper"
      found=1
      break
      ;;
    esac
  done
  [ "${found}" -eq 1 ] || return 0

  case "${id}" in
  ubuntu) HOST_OS_SECTION="Ubuntu" ;;
  debian) HOST_OS_SECTION="Debian" ;;
  kali) HOST_OS_SECTION="Kali Linux" ;;
  fedora) HOST_OS_SECTION="Fedora" ;;
  rhel) HOST_OS_SECTION="RHEL" ;;
  rocky) HOST_OS_SECTION="Rocky Linux" ;;
  almalinux) HOST_OS_SECTION="AlmaLinux" ;;
  centos) HOST_OS_SECTION="CentOS" ;;
  arch) HOST_OS_SECTION="Arch Linux" ;;
  *)
    case "${HOST_OS_FAMILY}" in
    debian) HOST_OS_SECTION="Debian / Kali Linux" ;;
    rhel) HOST_OS_SECTION="RHEL / Rocky Linux / AlmaLinux" ;;
    arch) HOST_OS_SECTION="Arch Linux" ;;
    *) HOST_OS_SECTION="" ;;
    esac
    ;;
  esac
}

host_detect_distro() {
  local os_release="${OS_RELEASE_FILE:-/etc/os-release}"

  HOST_OS_PRESENT=0
  HOST_OS_ID="unknown"
  HOST_OS_ID_LIKE=""
  HOST_OS_PRETTY="Unknown Linux"
  HOST_OS_VERSION_ID=""
  HOST_OS_FAMILY="unknown"
  HOST_OS_PKG_MGR="unknown"
  HOST_OS_SECTION=""

  if [ ! -r "${os_release}" ]; then
    # No os-release: recognize macOS (Docker Desktop) before giving up.
    if [ "$(uname -s 2>/dev/null || echo unknown)" = "Darwin" ]; then
      HOST_OS_PRESENT=1
      HOST_OS_ID="macos"
      HOST_OS_PRETTY="macOS (Docker Desktop)"
      HOST_OS_FAMILY="macos"
      HOST_OS_PKG_MGR="brew"
      HOST_OS_SECTION="macOS"
      return 0
    fi
    return 1
  fi

  HOST_OS_PRESENT=1
  HOST_OS_ID="$(host_os_release_field ID "${os_release}")"
  HOST_OS_ID_LIKE="$(host_os_release_field ID_LIKE "${os_release}")"
  HOST_OS_PRETTY="$(host_os_release_field PRETTY_NAME "${os_release}")"
  HOST_OS_VERSION_ID="$(host_os_release_field VERSION_ID "${os_release}")"

  [ -n "${HOST_OS_ID}" ] || HOST_OS_ID="unknown"
  [ -n "${HOST_OS_PRETTY}" ] || HOST_OS_PRETTY="${HOST_OS_ID}"

  host_map_family "${HOST_OS_ID}" "${HOST_OS_ID_LIKE}"
  return 0
}

# One-line summary, e.g.: Kali GNU/Linux Rolling (ID=kali ID_LIKE=debian)
host_distro_summary() {
  local summary="${HOST_OS_PRETTY} (ID=${HOST_OS_ID}"
  if [ -n "${HOST_OS_ID_LIKE}" ]; then
    summary="${summary} ID_LIKE=${HOST_OS_ID_LIKE}"
  fi
  summary="${summary})"
  printf '%s' "${summary}"
}
