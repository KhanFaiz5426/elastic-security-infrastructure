#!/bin/bash
set -eo pipefail

STATE_DIR="/usr/share/elastic-agent/state"

# Check if the agent is already enrolled by looking for fleet.enc in the state directory.
# If fleet.enc exists and is non-empty, the agent has a valid enrollment identity
# that must be reused to avoid creating duplicate Fleet Server agents in Kibana.
if [ -f "$STATE_DIR/fleet.enc" ] && [ -s "$STATE_DIR/fleet.enc" ]; then
    echo "fleet-entrypoint: Fleet agent already enrolled (fleet.enc found). Skipping re-enrollment."
    unset FLEET_ENROLL
    unset FLEET_SERVER_ENABLE
    unset KIBANA_FLEET_SETUP
else
    echo "fleet-entrypoint: Fleet agent not enrolled. Performing initial enrollment."
fi

# Load the service token from the isolated fleet-certs volume if available.
# This provides least-privilege ES authentication for Fleet Server.
TOKEN_FILE="${FLEET_SERVER_SERVICE_TOKEN_PATH:-}"
if [ -n "${TOKEN_FILE}" ] && [ -f "${TOKEN_FILE}" ] && [ -s "${TOKEN_FILE}" ]; then
    FLEET_SERVER_SERVICE_TOKEN="$(cat "${TOKEN_FILE}")"
    export FLEET_SERVER_SERVICE_TOKEN
    unset FLEET_SERVER_SERVICE_TOKEN_PATH
    echo "fleet-entrypoint: Loaded Fleet Server service token from ${TOKEN_FILE}."
elif [ -n "${TOKEN_FILE}" ]; then
    echo "fleet-entrypoint: WARNING: Service token file ${TOKEN_FILE} not found or empty. Fleet Server may fail to authenticate."
fi

# Execute the original elastic-agent container entrypoint
exec /usr/bin/tini -- /usr/local/bin/docker-entrypoint "$@"
