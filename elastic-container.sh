#!/bin/bash -eu
set -o pipefail

ipvar="0.0.0.0"

# These should be set in the .env file
declare LinuxDR
declare WindowsDR
declare MacOSDR

declare COMPOSE

# Ignore following warning
# shellcheck disable=SC1091
. .env

# The stack superuser is "elastic"; allow an explicit override but never leave
# this unbound (unset -u would abort the script before any Fleet API call).
ELASTIC_USERNAME="${ELASTIC_USERNAME:-elastic}"

# Zeek integration defaults (overridable via .env)
ZEEK_ENABLED="${ZEEK_ENABLED:-0}"
ZEEK_LOG_DIR="${ZEEK_LOG_DIR:-/opt/zeek/logs/current}"

HEADERS=(
  -H "kbn-version: ${STACK_VERSION}"
  -H "kbn-xsrf: kibana"
  -H 'Content-Type: application/json'
)

# --- Secure transport helpers ------------------------------------------------
# Credentials are supplied to curl through an ephemeral netrc file instead of
# --user arguments, so the superuser password never appears in a process
# command line (/proc/<pid>/cmdline) or in `ps aux`.
# TLS is verified against the locally-extracted CA (no `curl -k`) for every
# deployment-automation call.
NETRC_FILE=""
CA_CERT=".certs/ca.crt"

init_netrc() {
  NETRC_FILE=$(mktemp "${TMPDIR:-/tmp}/elastic-container-netrc.XXXXXX")
  chmod 600 "${NETRC_FILE}"
  printf 'default login %s password %s\n' "${ELASTIC_USERNAME}" "${ELASTIC_PASSWORD}" > "${NETRC_FILE}"
}

cleanup_netrc() {
  [ -n "${NETRC_FILE}" ] && rm -f "${NETRC_FILE}"
}
trap cleanup_netrc EXIT

# Authenticated, TLS-verified curl used for all API calls. Add -f to any call
# that must succeed so an HTTP/API failure aborts (set -e + pipefail).
api_curl() {
  curl --silent --netrc-file "${NETRC_FILE}" --cacert "${CA_CERT}" "$@"
}

# Extract the CA certificate from the running Elasticsearch container so
# subsequent calls can verify TLS instead of using -k.
extract_ca() {
  mkdir -p .certs
  if ! ${COMPOSE} exec -T elasticsearch cat config/certs/ca/ca.crt > "${CA_CERT}" 2>/dev/null; then
    echo "Error: could not extract the CA certificate for verified TLS." >&2
    return 1
  fi
  chmod 644 "${CA_CERT}"
}

ensure_ca() {
  [ -s "${CA_CERT}" ] || extract_ca || exit 1
}

# Reject characters that would break the shell-double-quoted / JSON contexts in
# which passwords are used by the setup container (e.g. "$", backtick, quote,
# backslash would be interpreted or injected rather than treated as literal).
password_safe_chars() {
  local value="$1"
  if [[ "${value}" =~ [\$\`\"\\] ]]; then
    echo "Password contains a character that is unsafe for embedded JSON/shell payloads (\$, backtick, double-quote, or backslash)."
    return 1
  fi
  return 0
}

passphrase_reset() {
  local fail=0
  if [ -z "${ELASTIC_PASSWORD:-}" ] || [ "${ELASTIC_PASSWORD}" = "changeme" ] || [ "${ELASTIC_PASSWORD}" = "elastic" ] || [ "${ELASTIC_PASSWORD}" = "password" ]; then
    echo "ERROR: ELASTIC_PASSWORD is empty or set to a well-known default."
    echo "Please set a strong, unique password (minimum 12 characters) in the .env file."
    fail=1
  elif [ "${#ELASTIC_PASSWORD}" -lt 12 ]; then
    echo "ERROR: ELASTIC_PASSWORD must be at least 12 characters (currently ${#ELASTIC_PASSWORD})."
    echo "Please update it in the .env file."
    fail=1
  fi
  if ! password_safe_chars "${ELASTIC_PASSWORD:-}"; then
    fail=1
  fi
  if [ -z "${KIBANA_PASSWORD:-}" ] || [ "${KIBANA_PASSWORD}" = "changeme" ] || [ "${KIBANA_PASSWORD}" = "kibana" ] || [ "${KIBANA_PASSWORD}" = "password" ]; then
    echo "ERROR: KIBANA_PASSWORD is empty or set to a well-known default."
    echo "Please set a strong, unique password (minimum 12 characters) in the .env file."
    fail=1
  elif [ "${#KIBANA_PASSWORD}" -lt 12 ]; then
    echo "ERROR: KIBANA_PASSWORD must be at least 12 characters (currently ${#KIBANA_PASSWORD})."
    echo "Please update it in the .env file."
    fail=1
  fi
  if ! password_safe_chars "${KIBANA_PASSWORD:-}"; then
    fail=1
  fi
  if [ "${KIBANA_ENCRYPTION_KEY:-}" = "changeme-generate-a-random-key" ] || [ -z "${KIBANA_ENCRYPTION_KEY:-}" ]; then
    echo "ERROR: KIBANA_ENCRYPTION_KEY is still the default placeholder or empty."
    echo "Generate a random key with: openssl rand -hex 32"
    echo "Then update KIBANA_ENCRYPTION_KEY in the .env file."
    fail=1
  fi
  if [ "${fail}" -eq 1 ]; then
    exit 1
  fi
  echo "Configuration validation passed. Proceeding."
}

# Strictly validate configuration-controlled values that are interpolated into
# shell commands, curl URLs, JSON payloads and certificate SANs. Rejects values
# that could break parsing or be injected. Empty optional values are allowed.
validate_config() {
  local ok=1
  local re_ip='^((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])$'

  for var in SIEM_IP SIEM_NAT_IP; do
    val="${!var:-}"
    if [ -n "${val}" ] && ! [[ "${val}" =~ ${re_ip} ]]; then
      echo "ERROR: ${var} is not a valid IPv4 address: '${val}'"
      ok=0
    fi
  done

  if [ -n "${SIEM_PREFIX:-}" ] && ! [[ "${SIEM_PREFIX}" =~ ^([0-9]|[12][0-9]|3[0-2])$ ]]; then
    echo "ERROR: SIEM_PREFIX must be a CIDR prefix between 0 and 32 (got '${SIEM_PREFIX}')."
    ok=0
  fi

  for var in ES_PORT KIBANA_PORT FLEET_PORT; do
    val="${!var:-}"
    if [ -n "${val}" ]; then
      if ! [[ "${val}" =~ ^[0-9]+$ ]] || [ "${val}" -lt 1 ] || [ "${val}" -gt 65535 ]; then
        echo "ERROR: ${var} must be a port number between 1 and 65535 (got '${val}')."
        ok=0
      fi
    fi
  done

  if [ -n "${SIEM_IFACE:-}" ] && ! [[ "${SIEM_IFACE}" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    echo "ERROR: SIEM_IFACE contains invalid characters (got '${SIEM_IFACE}')."
    ok=0
  fi

  if ! [[ "${STACK_VERSION:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: STACK_VERSION must be a semver tag x.y.z (got '${STACK_VERSION}')."
    ok=0
  fi

  for var in ELASTIC_USERNAME KIBANA_USERNAME; do
    val="${!var:-}"
    if [ -n "${val}" ] && ! [[ "${val}" =~ ^[A-Za-z0-9_.-]+$ ]]; then
      echo "ERROR: ${var} contains invalid characters (got '${val}')."
      ok=0
    fi
  done

  # Zeek: validate log directory path when enabled
  if [ "${ZEEK_ENABLED}" = "1" ] && ! [[ "${ZEEK_LOG_DIR}" =~ ^/[A-Za-z0-9_./-]+$ ]]; then
    echo "ERROR: ZEEK_LOG_DIR must be an absolute path with safe characters (got '${ZEEK_LOG_DIR}')."
    ok=0
  fi

  if [ "${ok}" -ne 1 ]; then
    echo "Configuration validation failed. Fix the values above in .env."
    return 1
  fi
  echo "Configuration values validated."
}

check_required_apps() {
    apps=("jq" "curl")

    for app in "${apps[@]}"; do
        if ! command -v "$app" &>/dev/null; then
            echo "The application '$app' is not installed."
            exit 1
        fi
    done

    echo "All required applications are installed."
}

# Run a read-only preflight check of all deployment prerequisites.
# Returns 0 if all checks pass, 1 if any check fails.
preflight() {
  local rc=0
  local pass="[✓]"
  local fail="[✗]"

  # --- Tool checks ---
  if command -v docker &>/dev/null; then
    echo "${pass} Docker"
  else
    echo "${fail} Docker not installed"
    rc=1
  fi

  if docker compose version &>/dev/null; then
    echo "${pass} Docker Compose"
  elif command -v docker-compose &>/dev/null; then
    echo "${pass} Docker Compose (legacy)"
  else
    echo "${fail} Docker Compose not available"
    rc=1
  fi

  for tool in curl jq openssl; do
    if command -v "${tool}" &>/dev/null; then
      echo "${pass} ${tool}"
    else
      echo "${fail} ${tool} not installed"
      rc=1
    fi
  done

  # --- .env checks ---
  if [ -f .env ]; then
    echo "${pass} .env"
  else
    echo "${fail} .env file not found (copy .env.example to .env)"
    rc=1
    return ${rc}
  fi

  # Required variables (check presence without printing values)
  local required_vars=(SIEM_IP ELASTIC_PASSWORD KIBANA_PASSWORD STACK_VERSION KIBANA_ENCRYPTION_KEY ES_PORT KIBANA_PORT FLEET_PORT MEM_LIMIT)
  local missing_vars=0
  for var in "${required_vars[@]}"; do
    val="${!var:-}"
    if [ -z "${val}" ] || [[ "${val}" == "<"*">" ]]; then
      echo "${fail} Required variable ${var} is empty or still a placeholder"
      missing_vars=1
      rc=1
    fi
  done
  if [ "${missing_vars}" -eq 0 ]; then
    echo "${pass} Required variables"
  fi

  # Password strength (without printing the passwords)
  local pw_ok=1
  for pw_var in ELASTIC_PASSWORD KIBANA_PASSWORD; do
    pw_val="${!pw_var:-}"
    if [ -n "${pw_val}" ] && [ "${#pw_val}" -lt 12 ]; then
      echo "${fail} ${pw_var} must be at least 12 characters"
      pw_ok=0
      rc=1
    fi
    if [ "${pw_val}" = "changeme" ] || [ "${pw_val}" = "password" ]; then
      echo "${fail} ${pw_var} is a well-known default"
      pw_ok=0
      rc=1
    fi
  done
  if [ "${pw_ok}" -eq 1 ] && [ "${missing_vars}" -eq 0 ]; then
    echo "${pass} Password policy"
  fi

  # SIEM_IP syntax check
  if [[ "${SIEM_IP:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "${pass} SIEM_IP (${SIEM_IP})"
  elif [ -n "${SIEM_IP:-}" ]; then
    echo "${fail} SIEM_IP '${SIEM_IP}' does not look like a valid IPv4 address"
    rc=1
  fi

  # Network interface check (only if SIEM_IFACE is set to a real value)
  if [ -n "${SIEM_IFACE:-}" ] && [[ "${SIEM_IFACE}" != "<"*">" ]]; then
    if ip link show "${SIEM_IFACE}" &>/dev/null 2>&1; then
      echo "${pass} Network interface (${SIEM_IFACE})"
    else
      echo "${fail} Network interface '${SIEM_IFACE}' not found"
      rc=1
    fi
  else
    echo "${pass} Network interface (not configured, skipped)"
  fi

  # Port availability checks
  local ports_ok=1
  for port_var in ES_PORT KIBANA_PORT FLEET_PORT; do
    port_val="${!port_var:-}"
    if [ -n "${port_val}" ]; then
      # Check if something other than our own containers is using the port
      if ss -tlnp 2>/dev/null | grep -q ":${port_val} " && ! docker ps --format '{{.Ports}}' 2>/dev/null | grep -q ":${port_val}->"; then
        echo "${fail} Port ${port_val} (${port_var}) is already in use"
        ports_ok=0
        rc=1
      fi
    fi
  done
  if [ "${ports_ok}" -eq 1 ]; then
    echo "${pass} Ports (${ES_PORT}, ${KIBANA_PORT}, ${FLEET_PORT})"
  fi

  # Strict validation of interpolated config values
  if validate_config >/dev/null 2>&1; then
    echo "${pass} Config value validation"
  else
    echo "${fail} Config value validation (run start for details)"
    rc=1
  fi

  # Disk space check (minimum 20GB recommended)
  local avail_kb
  avail_kb=$(df -k . 2>/dev/null | awk 'NR==2{print $4}')
  if [ -n "${avail_kb:-}" ]; then
    local avail_gb=$(( avail_kb / 1048576 ))
    if [ "${avail_kb}" -ge 20971520 ]; then
      echo "${pass} Disk space (${avail_gb}GB available)"
    else
      echo "[⚠] Disk space: ${avail_gb}GB available, 20GB+ recommended"
    fi
  else
    echo "${pass} Disk space (could not determine, skipped)"
  fi

  # Memory check (minimum 4GB)
  if [ -f /proc/meminfo ]; then
    local mem_kb
    mem_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
    local mem_gb=$(( mem_kb / 1048576 ))
    if [ "${mem_kb}" -ge 4194304 ]; then
      echo "${pass} Memory (${mem_gb}GB available)"
    else
      echo "${fail} Memory: ${mem_gb}GB available, minimum 4GB recommended"
      rc=1
    fi
  else
    echo "${pass} Memory (could not determine, skipped)"
  fi

  echo
  if [ "${rc}" -eq 0 ]; then
    echo "All preflight checks passed."
  else
    echo "Preflight checks failed. Fix the above issues before starting."
  fi
  return ${rc}
}

# Create the script usage menu
usage() {
  cat <<EOF | sed -e 's/^  //'
  usage: ./elastic-container.sh [-v] [-u] (stage|start|stop|restart|status|preflight|update-version|help)
  actions:
    stage           downloads all necessary images to local storage
    start           runs preflight checks, then creates a container network and starts containers
    stop            stops running containers without removing them
    destroy         stops and removes the containers, the network, and volumes created
    restart         restarts all the stack containers
    status          check the status of the stack containers
    preflight       run read-only deployment prerequisite checks
    clear           clear all documents in logs and metrics indexes
    update-version  set STACK_VERSION in .env to the newest stable x.y.z tag from Docker Hub (elastic/elasticsearch)
    help            print this message
  flags:
    -v              enable verbose output
    -u              same as update-version (refreshes STACK_VERSION in .env), then exit
EOF
}

# Set STACK_VERSION in .env to the highest stable semver tag listed for elastic/elasticsearch on Docker Hub.
refresh_stack_version() {
  check_required_apps

  local hub_repo="https://hub.docker.com/v2/repositories/elastic/elasticsearch/tags"
  local page=1
  local curl_opts=(-fsSL)
  if [ "${verbose:-0}" -eq 1 ]; then
    curl_opts=(-fSL)
  fi

  local all_names=""
  echo "Querying Docker Hub for elastic/elasticsearch tags..."
  while [ "${page}" -le 40 ]; do
    local json next
    if ! json=$(curl "${curl_opts[@]}" "${hub_repo}?page_size=100&page=${page}"); then
      echo "Failed to fetch Docker Hub tags (page ${page})." >&2
      exit 1
    fi
    all_names+=$(jq -r '.results[].name' <<<"${json}")
    all_names+=$'\n'
    next=$(jq -r '.next // empty' <<<"${json}")
    [ -z "${next}" ] && break
    page=$((page + 1))
  done

  local latest
  latest=$(grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' <<<"${all_names}" | sort -V | tail -1)
  if [ -z "${latest}" ]; then
    echo "Could not find a stable semver tag (x.y.z) on Docker Hub." >&2
    exit 1
  fi

  local current
  current=$(grep -E '^STACK_VERSION=' .env | head -1 | cut -d= -f2- | tr -d '\r')
  if [ -z "${current}" ]; then
    echo "No active STACK_VERSION= line found in .env." >&2
    exit 1
  fi

  if [ "${current}" = "${latest}" ]; then
    echo "STACK_VERSION is already ${latest} (newest stable tag found on Docker Hub)."
    return 0
  fi

  case "$(uname -s)" in
    Darwin)
      sed -i '' "s/^STACK_VERSION=.*/STACK_VERSION=${latest}/" .env
      ;;
    *)
      sed -i "s/^STACK_VERSION=.*/STACK_VERSION=${latest}/" .env
      ;;
  esac

  echo "Updated STACK_VERSION in .env: ${current} -> ${latest}"
  echo "Images pull from docker.elastic.co; tags match Docker Hub elastic/elasticsearch releases."
}

# Create a function to enable the Detection Engine and load prebuilt rules in Kibana
configure_kbn() {
  MAXTRIES=15
  i=${MAXTRIES}

  while [ $i -gt 0 ]; do
    STATUS=$(curl --silent -I --cacert "${CA_CERT}" "${LOCAL_KBN_URL}" | head -n 1 | cut -d ' ' -f2)
    echo
    echo "Attempting to enable the Detection Engine and install prebuilt Detection Rules."

    if [ "${STATUS}" == "302" ]; then
      echo
      echo "Kibana is up. Proceeding."
      echo
      output=$(api_curl "${HEADERS[@]}" -XPOST "${LOCAL_KBN_URL}/api/detection_engine/index")
      [[ ${output} =~ '"acknowledged":true' ]] || (
        echo
        echo "Detection Engine setup failed :-("
        exit 1
      )

      echo "Detection engine enabled. Installing prepackaged rules."
      api_curl -f "${HEADERS[@]}" -XPUT "${LOCAL_KBN_URL}/api/detection_engine/rules/prepackaged" 1>&2

      echo
      echo "Prepackaged rules installed!"
      echo
      if [[ "${LinuxDR}" -eq 0 && "${WindowsDR}" -eq 0 && "${MacOSDR}" -eq 0 ]]; then
        echo "No detection rules enabled in the .env file, skipping detection rules enablement."
        echo
        break
      else
        echo "Enabling detection rules"
        if [ "${LinuxDR}" -eq 1 ]; then

          bulk=$(api_curl -f "${HEADERS[@]}" -X POST "${LOCAL_KBN_URL}/api/detection_engine/rules/_bulk_action" -d'
            {
              "query": "alert.attributes.tags: (\"Linux\" OR \"OS: Linux\")",
              "action": "enable"
            }
            ')
          printf '%s' "${bulk}" | jq -e '.success == true' > /dev/null || { echo "ERROR: Failed to enable Linux detection rules."; exit 1; }
          echo
          echo "Successfully enabled Linux detection rules"
        fi
        if [ "${WindowsDR}" -eq 1 ]; then

          bulk=$(api_curl -f "${HEADERS[@]}" -X POST "${LOCAL_KBN_URL}/api/detection_engine/rules/_bulk_action" -d'
            {
              "query": "alert.attributes.tags: (\"Windows\" OR \"OS: Windows\")",
              "action": "enable"
            }
            ')
          printf '%s' "${bulk}" | jq -e '.success == true' > /dev/null || { echo "ERROR: Failed to enable Windows detection rules."; exit 1; }
          echo
          echo "Successfully enabled Windows detection rules"
        fi
        if [ "${MacOSDR}" -eq 1 ]; then

          bulk=$(api_curl -f "${HEADERS[@]}" -X POST "${LOCAL_KBN_URL}/api/detection_engine/rules/_bulk_action" -d'
            {
              "query": "alert.attributes.tags: (\"macOS\" OR \"OS: macOS\")",
              "action": "enable"
            }
            ')
          printf '%s' "${bulk}" | jq -e '.success == true' > /dev/null || { echo "ERROR: Failed to enable MacOS detection rules."; exit 1; }
          echo
          echo "Successfully enabled MacOS detection rules"
        fi
      fi
      echo
      break
    else
      echo
      echo "Kibana still loading. Trying again in 40 seconds"
    fi

    sleep 40
    i=$((i - 1))
  done
  [ $i -eq 0 ] && echo "Exceeded MAXTRIES (${MAXTRIES}) to setup detection engine." && exit 1
  return 0
}

get_host_ip() {
  # Prefer the explicitly configured isolated address; fall back to any host IP.
  if [ -n "${SIEM_IP:-}" ]; then
    ipvar="${SIEM_IP}"
    return 0
  fi
  os=$(uname -s)
  if [ "${os}" == "Linux" ]; then
    ipvar=$(hostname -I | awk '{ print $1}')
  elif [ "${os}" == "Darwin" ]; then
    ipvar=$(ifconfig en0 | awk '$1 == "inet" {print $2}')
  fi
}

# Ensure Kibana has a Fleet Server host that remote agents can reach.
# FLEET_URL in docker-compose only configures the container-side URL for the
# elastic-agent process itself; the Kibana "Fleet Server host" saved object is
# what the Fleet UI and remote agents use, and KIBANA_FLEET_SETUP=1 does not
# create it. This is idempotent: if a host already points at the desired URL
# it is left alone, a host with the wrong URL is corrected, and a new host is
# only created when none exists.
configure_fleet_server_host() {
  local desired_url="https://${ipvar}:${FLEET_PORT}"
  local hosts_json existing_id first_id
  hosts_json=$(api_curl -f "${HEADERS[@]}" "${LOCAL_KBN_URL}/api/fleet/fleet_server_hosts")

  existing_id=$(printf '%s' "${hosts_json}" | jq -r --arg u "${desired_url}" '.items[] | select((.host_urls // []) | index($u)) | .id' | head -1)
  if [ -n "${existing_id}" ]; then
    echo "Fleet Server host already set to ${desired_url} (id=${existing_id})."
    return 0
  fi

  first_id=$(printf '%s' "${hosts_json}" | jq -r '.items[0].id // empty')
  if [ -n "${first_id}" ]; then
    echo "Updating Fleet Server host ${first_id} to ${desired_url}."
    printf '{"name": "fleet-server", "host_urls": ["%s"]}' "${desired_url}" | api_curl -f "${HEADERS[@]}" -XPUT "${LOCAL_KBN_URL}/api/fleet/fleet_server_hosts/${first_id}" -d @- | jq
  else
    echo "Creating Fleet Server host at ${desired_url}."
    printf '{"name": "fleet-server", "host_urls": ["%s"], "is_default": true}' "${desired_url}" | api_curl -f "${HEADERS[@]}" -XPOST "${LOCAL_KBN_URL}/api/fleet/fleet_server_hosts" -d @- | jq
  fi
}

# Resolve an agent policy id by name; empty string if it does not exist.
get_agent_policy_id() {
  api_curl -f "${HEADERS[@]}" \
    "${LOCAL_KBN_URL}/api/fleet/agent_policies?perPage=100" \
    | jq -r --arg name "$1" '.items[] | select(.name == $name) | .id' \
    | head -n 1
}

# Resolve the package policy id for an integration on a given agent policy;
# empty string if it does not exist.
get_package_policy_id() {
  api_curl -f "${HEADERS[@]}" \
    "${LOCAL_KBN_URL}/api/fleet/package_policies?perPage=100" \
    | jq -r --arg pkg "$1" --arg policy "$2" \
        '.items[] | select(.package.name == $pkg and .policy_id == $policy) | .id' \
    | head -n 1
}

# Install an integration package only if it is not already installed.
install_integration() {
  local status
  status=$(api_curl "${HEADERS[@]}" \
    "${LOCAL_KBN_URL}/api/fleet/epm/packages/$1" | jq -r '.item.status')
  if [ "${status}" = "installed" ]; then
    echo "Integration package '$1' already installed."
  else
    echo "Installing integration package '$1'."
    api_curl -f "${HEADERS[@]}" \
      -XPOST "${LOCAL_KBN_URL}/api/fleet/epm/packages/$1" > /dev/null
  fi
}

# Create an agent policy with system monitoring enabled (System integration is
# auto-added by sys_monitoring=true); returns the new policy id.
create_agent_policy() {
  local name="$1"
  printf '{"name": "%s", "description": "%s", "namespace": "%s", "monitoring_enabled": ["logs","metrics"], "inactivity_timeout": 1209600}' "${name}" "" "default" | api_curl -f "${HEADERS[@]}" -XPOST "${LOCAL_KBN_URL}/api/fleet/agent_policies?sys_monitoring=true" -d @- | jq -r '.item.id'
}

# Attach Elastic Defend (EDRComplete preset) to an agent policy if not already
# present. Query-first: an existing endpoint package policy is reused. Fleet
# requires integration policy names to be globally unique, so the display name
# is suffixed per policy to avoid a 409 conflict on multi-policy setups.
ensure_endpoint_defend() {
  local policy_id="$1"
  local display_name="$2"
  if [ -n "$(get_package_policy_id "endpoint" "${policy_id}")" ]; then
    echo "Elastic Defend already present on policy ${policy_id}, skipping."
    return
  fi
  local pkg_version
  pkg_version=$(api_curl -f -XGET "${HEADERS[@]}" "${LOCAL_KBN_URL}/api/fleet/epm/packages/endpoint" | jq -r '.item.version')
  printf "{\"name\": \"%s\", \"description\": \"%s\", \"namespace\": \"%s\", \"policy_id\": \"%s\", \"enabled\": %s, \"inputs\": [{\"enabled\": true, \"streams\": [], \"type\": \"ENDPOINT_INTEGRATION_CONFIG\", \"config\": {\"_config\": {\"value\": {\"type\": \"endpoint\", \"endpointConfig\": {\"preset\": \"EDRComplete\"}}}}}], \"package\": {\"name\": \"endpoint\", \"title\": \"Elastic Defend\", \"version\": \"${pkg_version}\"}}" "${display_name}" "" "default" "${policy_id}" "true" | api_curl -f "${HEADERS[@]}" -XPOST "${LOCAL_KBN_URL}/api/fleet/package_policies" -d @- | jq
}

# Attach the Windows integration (Sysmon/PowerShell/Defender winlog channels) to
# an agent policy if not already present. System integration already covers
# Application/Security/System + metrics, so only the winlog input is used and
# windows/metrics stays disabled. Query-first: existing policy is reused.
ensure_windows_integration() {
  local policy_id="$1"
  if [ -n "$(get_package_policy_id "windows" "${policy_id}")" ]; then
    echo "Windows integration already present on policy ${policy_id}, skipping."
    return
  fi
  install_integration "windows"
  local win_pkg_version
  win_pkg_version=$(api_curl -f -XGET "${HEADERS[@]}" "${LOCAL_KBN_URL}/api/fleet/epm/packages/windows" | jq -r '.item.version')
  cat <<EOF | api_curl -f "${HEADERS[@]}" -XPOST "${LOCAL_KBN_URL}/api/fleet/package_policies" -d @- | jq
{
  "name": "Windows",
  "description": "Windows security channels (Sysmon, PowerShell, Defender) for SOC detections",
  "namespace": "default",
  "policy_id": "${policy_id}",
  "enabled": true,
  "inputs": [
    {
      "type": "winlog",
      "enabled": true,
      "streams": [
        { "enabled": true,  "data_stream": { "dataset": "windows.sysmon_operational", "type": "logs" }, "vars": { "preserve_original_event": { "type": "bool", "value": false } } },
        { "enabled": true,  "data_stream": { "dataset": "windows.powershell_operational", "type": "logs" }, "vars": { "preserve_original_event": { "type": "bool", "value": false }, "event_id": { "type": "text", "value": "4103,4104,4105,4106,4107,4108" } } },
        { "enabled": true,  "data_stream": { "dataset": "windows.windows_defender", "type": "logs" }, "vars": { "preserve_original_event": { "type": "bool", "value": false } } },
        { "enabled": true,  "data_stream": { "dataset": "windows.powershell", "type": "logs" }, "vars": { "preserve_original_event": { "type": "bool", "value": false }, "event_id": { "type": "text", "value": "400,403,600,800" } } },
        { "enabled": false, "data_stream": { "dataset": "windows.forwarded", "type": "logs" } },
        { "enabled": false, "data_stream": { "dataset": "windows.applocker_exe_and_dll", "type": "logs" } },
        { "enabled": false, "data_stream": { "dataset": "windows.applocker_msi_and_script", "type": "logs" } },
        { "enabled": false, "data_stream": { "dataset": "windows.applocker_packaged_app_deployment", "type": "logs" } },
        { "enabled": false, "data_stream": { "dataset": "windows.applocker_packaged_app_execution", "type": "logs" } }
      ]
    }
  ],
  "package": { "name": "windows", "title": "Windows", "version": "${win_pkg_version}" }
}
EOF
}

# Create a Zeek agent policy and attach the Zeek integration if not already
# present. Query-first: existing policy/integration is reused. The operator
# must install and enroll an Elastic Agent on the Zeek host manually.
ensure_zeek_integration() {
  install_integration "zeek"
  local zeek_pkg_version
  zeek_pkg_version=$(api_curl -f -XGET "${HEADERS[@]}" "${LOCAL_KBN_URL}/api/fleet/epm/packages/zeek" | jq -r '.item.version')

  local zeek_policy_id
  zeek_policy_id=$(get_agent_policy_id "Zeek")
  if [ -z "${zeek_policy_id}" ]; then
    echo "Creating Zeek agent policy."
    zeek_policy_id=$(create_agent_policy "Zeek")
  else
    echo "Reusing existing Zeek agent policy (${zeek_policy_id})."
  fi

  if [ -n "$(get_package_policy_id "zeek" "${zeek_policy_id}")" ]; then
    echo "Zeek integration already present on policy ${zeek_policy_id}, skipping."
    return
  fi

  echo "Attaching Zeek integration to policy ${zeek_policy_id} (log_dir=${ZEEK_LOG_DIR})."
  local log_dir="${ZEEK_LOG_DIR}"
  cat <<ZEEK_EOF | api_curl -f "${HEADERS[@]}" -XPOST "${LOCAL_KBN_URL}/api/fleet/package_policies" -d @- | jq
{
  "name": "Zeek",
  "namespace": "default",
  "policy_id": "${zeek_policy_id}",
  "enabled": true,
  "inputs": [
    {
      "type": "logfile",
      "enabled": true,
      "streams": [
        { "enabled": true,  "data_stream": { "dataset": "zeek.connection",   "type": "logs" }, "vars": { "paths": { "type": "yaml", "value": ["${log_dir}/conn.log"] } } },
        { "enabled": true,  "data_stream": { "dataset": "zeek.dns",          "type": "logs" }, "vars": { "paths": { "type": "yaml", "value": ["${log_dir}/dns.log"] } } },
        { "enabled": true,  "data_stream": { "dataset": "zeek.http",         "type": "logs" }, "vars": { "paths": { "type": "yaml", "value": ["${log_dir}/http.log"] } } },
        { "enabled": true,  "data_stream": { "dataset": "zeek.ssl",          "type": "logs" }, "vars": { "paths": { "type": "yaml", "value": ["${log_dir}/ssl.log"] } } },
        { "enabled": true,  "data_stream": { "dataset": "zeek.files",        "type": "logs" }, "vars": { "paths": { "type": "yaml", "value": ["${log_dir}/files.log"] } } },
        { "enabled": true,  "data_stream": { "dataset": "zeek.ssh",          "type": "logs" }, "vars": { "paths": { "type": "yaml", "value": ["${log_dir}/ssh.log"] } } },
        { "enabled": true,  "data_stream": { "dataset": "zeek.weird",        "type": "logs" }, "vars": { "paths": { "type": "yaml", "value": ["${log_dir}/weird.log"] } } },
        { "enabled": false, "data_stream": { "dataset": "zeek.dhcp",         "type": "logs" } },
        { "enabled": false, "data_stream": { "dataset": "zeek.ntp",          "type": "logs" } },
        { "enabled": false, "data_stream": { "dataset": "zeek.notice",       "type": "logs" } },
        { "enabled": false, "data_stream": { "dataset": "zeek.dpd",          "type": "logs" } },
        { "enabled": false, "data_stream": { "dataset": "zeek.smtp",         "type": "logs" } },
        { "enabled": false, "data_stream": { "dataset": "zeek.tunnel",       "type": "logs" } },
        { "enabled": false, "data_stream": { "dataset": "zeek.pe",           "type": "logs" } },
        { "enabled": false, "data_stream": { "dataset": "zeek.signature",    "type": "logs" } },
        { "enabled": false, "data_stream": { "dataset": "zeek.traceroute",   "type": "logs" } },
        { "enabled": false, "data_stream": { "dataset": "zeek.x509",         "type": "logs" } },
        { "enabled": false, "data_stream": { "dataset": "zeek.capture_loss", "type": "logs" } },
        { "enabled": false, "data_stream": { "dataset": "zeek.dce_rpc",      "type": "logs" } },
        { "enabled": false, "data_stream": { "dataset": "zeek.ftp",          "type": "logs" } },
        { "enabled": false, "data_stream": { "dataset": "zeek.intel",        "type": "logs" } },
        { "enabled": false, "data_stream": { "dataset": "zeek.irc",          "type": "logs" } },
        { "enabled": false, "data_stream": { "dataset": "zeek.kerberos",     "type": "logs" } },
        { "enabled": false, "data_stream": { "dataset": "zeek.modbus",       "type": "logs" } },
        { "enabled": false, "data_stream": { "dataset": "zeek.mysql",        "type": "logs" } },
        { "enabled": false, "data_stream": { "dataset": "zeek.ntlm",         "type": "logs" } },
        { "enabled": false, "data_stream": { "dataset": "zeek.ocsp",         "type": "logs" } },
        { "enabled": false, "data_stream": { "dataset": "zeek.radius",       "type": "logs" } },
        { "enabled": false, "data_stream": { "dataset": "zeek.rdp",          "type": "logs" } },
        { "enabled": false, "data_stream": { "dataset": "zeek.rfb",          "type": "logs" } },
        { "enabled": false, "data_stream": { "dataset": "zeek.sip",          "type": "logs" } },
        { "enabled": false, "data_stream": { "dataset": "zeek.smb_cmd",      "type": "logs" } },
        { "enabled": false, "data_stream": { "dataset": "zeek.smb_files",    "type": "logs" } },
        { "enabled": false, "data_stream": { "dataset": "zeek.smb_mapping",  "type": "logs" } },
        { "enabled": false, "data_stream": { "dataset": "zeek.snmp",         "type": "logs" } },
        { "enabled": false, "data_stream": { "dataset": "zeek.socks",        "type": "logs" } },
        { "enabled": false, "data_stream": { "dataset": "zeek.stats",        "type": "logs" } }
      ]
    }
  ],
  "package": { "name": "zeek", "title": "Zeek", "version": "${zeek_pkg_version}" }
}
ZEEK_EOF

  echo
  echo "=== Zeek integration configured ==="
  echo "Fleet policy 'Zeek' is ready. To complete the setup:"
  echo "  1. Copy the enrollment token from Fleet → Agent policies → Zeek"
  echo "  2. Install Elastic Agent ${STACK_VERSION} on the Zeek host"
  echo "  3. Enroll with: elastic-agent install --url=https://${ipvar}:${FLEET_PORT} --enrollment-token=<token>"
  echo "  4. Verify in Kibana: Fleet → Agents shows the Zeek host as Healthy"
  echo "  5. Check data in Discover: logs-zeek.* data streams"
  echo
  echo "Note: The Zeek Fleet policy is CONFIGURED. Data ingestion depends on"
  echo "the Elastic Agent being enrolled and Zeek producing JSON logs."
  echo "==================================="
}

set_fleet_values() {
  # Always fix the Fleet output — KIBANA_FLEET_SETUP=1 causes Kibana to
  # auto-configure the output with localhost:9200 which is wrong.
  # This must run even if Fleet reports isInitialized=true.
  echo "Configuring Fleet output..."

  ensure_ca
  fingerprint=$(${COMPOSE} exec -w /usr/share/elasticsearch/config/certs/ca elasticsearch cat ca.crt | openssl x509 -noout -fingerprint -sha256 | cut -d "=" -f 2 | tr -d :)
  configure_fleet_server_host
  printf '{"hosts": ["%s"]}' "https://${ipvar}:9200" | api_curl -f "${HEADERS[@]}" -XPUT "${LOCAL_KBN_URL}/api/fleet/outputs/fleet-default-output" -d @- | jq
  printf '{"ca_trusted_fingerprint": "%s"}' "${fingerprint}" | api_curl -f "${HEADERS[@]}" -XPUT "${LOCAL_KBN_URL}/api/fleet/outputs/fleet-default-output" -d @- | jq
  printf '{"config_yaml": "%s"}' "ssl.verification_mode: certificate" | api_curl -f "${HEADERS[@]}" -XPUT "${LOCAL_KBN_URL}/api/fleet/outputs/fleet-default-output" -d @- | jq

  # Only create policies and packages if Fleet is not yet initialized
  CURRENT_SETTINGS=$(api_curl -f "${HEADERS[@]}" -X GET "${LOCAL_KBN_URL}/api/fleet/agents/setup")
  if echo "$CURRENT_SETTINGS" | grep -q '"isInitialized": true'; then
    echo "Fleet policies already exist, skipping policy creation."
    return
  fi

  echo "Fleet not initialized, creating policies..."

  # --- Windows Endpoint (System + Elastic Defend + Windows) -----------------
  # Migrate the legacy "Endpoint Policy" in place: the already-enrolled Windows
  # agent is bound to it by policy_id, so renaming keeps the agent connected and
  # its enrollment token valid (Fleet agents never reference the policy by name).
  windows_id=$(get_agent_policy_id "Windows Endpoint")
  if [ -z "${windows_id}" ]; then
    legacy_id=$(get_agent_policy_id "Endpoint Policy")
    if [ -n "${legacy_id}" ]; then
      echo "Renaming Endpoint Policy to Windows Endpoint (${legacy_id})."
      printf '{"name": "Windows Endpoint", "description": "", "namespace": "default", "monitoring_enabled": ["logs","metrics"], "inactivity_timeout": 1209600}' | api_curl -f "${HEADERS[@]}" -XPUT "${LOCAL_KBN_URL}/api/fleet/agent_policies/${legacy_id}" -d @- | jq
      windows_id="${legacy_id}"
    else
      echo "Creating Windows Endpoint (System integration auto-added via sys_monitoring=true)."
      windows_id=$(create_agent_policy "Windows Endpoint")
    fi
  else
    echo "Reusing existing Windows Endpoint (${windows_id})."
  fi

  # --- Endpoint Baseline (System + Elastic Defend, no Windows) --------------
  baseline_id=$(get_agent_policy_id "Endpoint Baseline")
  if [ -z "${baseline_id}" ]; then
    echo "Creating Endpoint Baseline (System integration auto-added via sys_monitoring=true)."
    baseline_id=$(create_agent_policy "Endpoint Baseline")
  else
    echo "Reusing existing Endpoint Baseline (${baseline_id})."
  fi

  # --- Linux Endpoint (System + Elastic Defend, no Windows) -----------------
  linux_id=$(get_agent_policy_id "Linux Endpoint")
  if [ -z "${linux_id}" ]; then
    echo "Creating Linux Endpoint (System integration auto-added via sys_monitoring=true)."
    linux_id=$(create_agent_policy "Linux Endpoint")
  else
    echo "Reusing existing Linux Endpoint (${linux_id})."
  fi

  # --- Elastic Defend on all three endpoint policies -------------------------
  # Preserves the existing EDRComplete config; query-first, so a second run
  # finds the endpoint package policy on each policy and skips. Names are
  # suffixed per policy because Fleet requires globally unique policy names.
  ensure_endpoint_defend "${windows_id}" "Elastic Defend - Windows"
  ensure_endpoint_defend "${baseline_id}" "Elastic Defend - Baseline"
  ensure_endpoint_defend "${linux_id}" "Elastic Defend - Linux"

  # --- Windows integration ONLY on the Windows Endpoint policy ---------------
  # System integration already covers Application/Security/System + metrics,
  # so only the winlog input is used and windows/metrics stays disabled.
  # Linux hosts must never receive the winlog channels.
  ensure_windows_integration "${windows_id}"

  # --- Zeek integration (optional, topology-configurable) --------------------
  if [ "${ZEEK_ENABLED}" = "1" ]; then
    ensure_zeek_integration
  fi
}

clear_documents() {
  local es_url="${LOCAL_ES_URL:-https://127.0.0.1:9200}"
  ensure_ca
  if (($(api_curl -f "${HEADERS[@]}" -X DELETE "${es_url}/_data_stream/logs-*" | grep -c "true") > 0)); then
    printf "Successfully cleared logs data stream"
  else
    printf "Failed to clear logs data stream"
  fi
  echo
  if (($(api_curl -f "${HEADERS[@]}" -X DELETE "${es_url}/_data_stream/metrics-*" | grep -c "true") > 0)); then
    printf "Successfully cleared metrics data stream"
  else
    printf "Failed to clear metrics data stream"
  fi
  echo
}

# Require an explicit typed confirmation for destructive actions so an
# accidental execution cannot wipe the stack. Safe commands stay silent.
# Usage: confirm_destructive <PROMPT_WORD> <WHAT>
confirm_destructive() {
  local word="$1"
  local what="$2"
  local answer=""
  printf "You are about to %s.\n" "${what}"
  printf "Type %s (all uppercase) to continue: " "${word}"
  if ! IFS= read -r answer; then
    echo
    echo "Aborted (no input provided)."
    exit 1
  fi
  if [ "${answer}" != "${word}" ]; then
    echo "Aborted."
    exit 1
  fi
}

# Append a timestamped line to a local action log so host-side
# administrative/destructive operations remain traceable.
log_action() {
  local log_dir=".logs"
  local log_file="${log_dir}/actions.log"
  mkdir -p "${log_dir}"
  chmod 700 "${log_dir}"
  printf '%s %s user=%s action=%s\n' "$(date -u +%FT%TZ)" "$0" "${USER:-unknown}" "$1" >> "${log_file}"
  chmod 600 "${log_file}"
}

# Logic to enable the verbose output if needed
OPTIND=1 # Reset in case getopts has been used previously in the shell.

verbose=0
update_stack_version_flag=0

while getopts "vu" opt; do
  case "$opt" in
  v)
    verbose=1
    ;;
  u)
    update_stack_version_flag=1
    ;;
  *) ;;
  esac
done

shift $((OPTIND - 1))

[ "${1:-}" = "--" ] && shift

if [ $verbose -eq 1 ]; then
  exec 3<>/dev/stderr
else
  exec 3<>/dev/null
fi

if [ "${update_stack_version_flag}" -eq 1 ]; then
  refresh_stack_version
  exit 0
fi

ACTION="${*:-help}"

if docker compose >/dev/null; then
  COMPOSE="docker compose"
elif command -v docker-compose >/dev/null; then
  COMPOSE="docker-compose"
else
  case "${ACTION}" in
  help | "update-version" | "preflight") ;;
  *)
    echo "elastic-container requires docker compose!"
    exit 2
    ;;
  esac
fi

# Prepare the ephemeral netrc used for authenticated API calls (no credentials
# in argv). Set up before any action that talks to Kibana/Elasticsearch.
init_netrc

case "${ACTION}" in

"stage")
  # Collect the Elastic, Kibana, and Elastic-Agent Docker images
  docker pull "docker.elastic.co/elasticsearch/elasticsearch:${STACK_VERSION}"
  docker pull "docker.elastic.co/kibana/kibana:${STACK_VERSION}"
  docker pull "docker.elastic.co/elastic-agent/elastic-agent:${STACK_VERSION}"
  ;;

"start")
  preflight

  passphrase_reset

  validate_config

  check_required_apps

  get_host_ip

  # The .env file holds credentials; keep it owner-readable only.
  chmod 600 .env 2>/dev/null || true

  echo "Starting Elastic Stack network and containers."

  ${COMPOSE} up -d --no-deps 

  # The security-setup container creates the configured admin users (and
  # disables the built-in elastic account when ELASTIC_USERNAME is custom).
  # Wait for it to finish so later API calls authenticate successfully.
  echo "Waiting for the Elasticsearch security setup to complete."
  if ! timeout 900 docker wait ecp-elasticsearch-security-setup > /dev/null 2>&1; then
    echo "Error: Elasticsearch security setup container did not complete cleanly (or timed out after 15 minutes)."
    exit 1
  fi

  if ! extract_ca; then
    echo "Error: failed to extract the CA certificate after setup."
    exit 1
  fi

  configure_kbn 1>&2 2>&3

  echo "Waiting 40 seconds for Fleet Server setup."
  echo

  sleep 40

  echo "Populating Fleet Settings."
  if ! fleet_out=$(set_fleet_values 2>&1); then
    echo "ERROR: Fleet settings/policy setup failed." >&2
    printf '%s\n' "${fleet_out}" >&2
    exit 1
  fi
  log_action "start"
  echo

  echo "READY SET GO!"
  echo
  echo "Browse to https://localhost:${KIBANA_PORT}"
  if [ $verbose -eq 1 ]; then
      echo "Username: ${ELASTIC_USERNAME}"
  fi
  echo
  ;;

"stop")
  echo "Stopping running containers."

  ${COMPOSE} stop 
  ;;

"destroy")
  echo "#####"
  echo "Stopping and removing the containers, network, and volumes created."
  echo "#####"
  confirm_destructive "DESTROY" "stop and remove the containers, network, and all volumes (permanent data loss)"
  log_action "destroy"
  ${COMPOSE} down -v
  ;;

"restart")
  echo "#####"
  echo "Restarting all Elastic Stack components."
  echo "#####"
  ${COMPOSE} restart elasticsearch kibana fleet-server
  ;;

"status")
  ${COMPOSE} ps | grep -v setup
  ;;

"preflight")
  preflight
  ;;

"clear")
  confirm_destructive "CLEAR" "delete all documents in the logs-* and metrics-* data streams (permanent data loss)"
  log_action "clear"
  clear_documents
  ;;

"update-version")
  refresh_stack_version
  ;;

"help")
  usage
  ;;

*)
  echo -e "Proper syntax not used. See the usage\n"
  usage
  ;;
esac

# Close FD 3
exec 3>&-
