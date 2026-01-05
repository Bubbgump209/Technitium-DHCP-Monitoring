#!/bin/bash
# Zabbix Wrapper for Technitium DHCP Pool Monitor
# Usage: DHCPPoolMonitorZabbixWrapper.sh <server> <token> <scope> <metric> [insecure]

SERVER="$1"
TOKEN="$2"
SCOPE="$3"
METRIC="$4"  # active_leases, available_addresses, usage_percent, active_pool_size
INSECURE="$5"  # "insecure" or empty

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Build command with optional --insecure flag
CMD="$SCRIPT_DIR/DHCPPoolMonitor.sh --server \"$SERVER\" --token \"$TOKEN\" --scope \"$SCOPE\" --json"

if [[ "$INSECURE" == "insecure" ]]; then
    CMD="$CMD --insecure"
fi

# Run the main script and get JSON output
RESULT=$(bash -c "$CMD" 2>/dev/null)

# Parse the specific metric from JSON
if [[ -n "$RESULT" ]]; then
    VALUE=$(echo "$RESULT" | jq -r ".scope_0.$METRIC" 2>/dev/null)
    if [[ -n "$VALUE" ]] && [[ "$VALUE" != "null" ]] && [[ "$VALUE" != "0" ]]; then
        echo "$VALUE"
    else
        echo 0
    fi
else
    echo 0
fi
