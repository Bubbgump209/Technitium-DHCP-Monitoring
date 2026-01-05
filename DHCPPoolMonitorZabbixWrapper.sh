#!/bin/bash
# Zabbix Wrapper for Technitium DHCP Pool Monitor
# Usage: DHCPPoolMonitorZabbixWrapper.sh <server> <token> <scope> <metric> [insecure]

# Show help if requested
if [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]] || [[ $# -lt 4 ]]; then
    cat << EOF
Zabbix Wrapper for Technitium DHCP Pool Monitor

Usage: $0 <server> <token> <scope> <metric> [insecure]

Parameters:
  server      Technitium server URL (e.g., https://10.10.10.5)
  token       API authentication token
  scope       DHCP scope name (e.g., LAN, Guest, Chromebooks)
  metric      Metric to retrieve (see below)
  insecure    Optional: Use "insecure" for self-signed SSL certificates

Available Metrics:
  usage_percent         Pool utilization percentage (0-100)
  active_leases         Number of active dynamic leases
  available_addresses   Available addresses in pool
  active_pool_size      Total usable pool size
  total_range           Total addresses in range
  excluded_addresses    Number of excluded addresses
  reserved_addresses    Number of reserved addresses

Examples:
  # Get pool usage percentage
  $0 https://10.10.10.5 mytoken123 LAN usage_percent insecure

  # Get active lease count
  $0 https://10.10.10.5 mytoken123 Guest active_leases insecure

  # Get available addresses (HTTP without SSL)
  $0 http://10.10.10.5:5380 mytoken123 Chromebooks available_addresses

Zabbix Item Key Format:
  DHCPPoolMonitorZabbixWrapper.sh[https://10.10.10.5,{$TOKEN},LAN,usage_percent,insecure]

Notes:
  - Returns a single numeric value suitable for Zabbix monitoring
  - Returns 0 on error or if no data is available
  - Requires jq to be installed
  - Main script (DHCPPoolMonitor.sh) must be in the same directory

EOF
    exit 0
fi

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
    if [[ -n "$VALUE" ]] && [[ "$VALUE" != "null" ]]; then
        echo "$VALUE"
    else
        echo 0
    fi
else
    echo 0
fi
