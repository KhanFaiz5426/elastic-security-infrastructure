#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

usage() {
  echo "Usage: $0 [--apply]"
  echo "  Prints the netplan config for the SIEM host's isolated NIC, built from"
  echo "  SIEM_IP / SIEM_IFACE / SIEM_PREFIX in .env (defaults to dry-run)."
  echo "  Run with --apply to write /etc/netplan/99-siem-static.yaml and apply (needs sudo)."
}

if [ "${1:-}" == "--apply" ]; then
  APPLY=1
elif [ -n "${1:-}" ]; then
  usage
  exit 1
else
  APPLY=0
fi

set -a
# shellcheck disable=SC1091
. ./.env
set +a

IFACE="${SIEM_IFACE:-}"
IP="${SIEM_IP:-}"
PREFIX="${SIEM_PREFIX:-24}"

if [ -z "${IP}" ]; then
  echo "SIEM_IP is not set in .env" >&2
  exit 1
fi

if [ -z "${IFACE}" ]; then
  echo "SIEM_IFACE is not set in .env. Run 'ip link show' to find your interface name." >&2
  exit 1
fi

CONFIG=$(
  cat <<EOF
network:
  version: 2
  ethernets:
    ${IFACE}:
      dhcp4: no
      addresses: [${IP}/${PREFIX}]
      # No gateway on the isolated segment. Internet stays on the NAT NIC
      # (default route) so packages/Docker images keep working.
EOF
)

if [ "${APPLY}" -ne 1 ]; then
  echo "--- /etc/netplan/99-siem-static.yaml (dry run) ---"
  echo "${CONFIG}"
  echo "--- review, then re-run with --apply ---"
  exit 0
fi

echo "${CONFIG}" | sudo tee /etc/netplan/99-siem-static.yaml >/dev/null
sudo netplan apply
echo "Applied. ${IFACE}:"
ip -4 addr show "${IFACE}" || true