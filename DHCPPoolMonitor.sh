#!/bin/bash

# Technitium DHCP Pool Monitor
# Main script - can be run standalone or called by Zabbix wrapper
# Pure Bash script - requires only curl and jq

# Note: Not using set -e so we can handle errors gracefully

# Colors for output
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
SERVER_URL=""
API_TOKEN=""
SCOPE_NAME=""
JSON_OUTPUT=false
VERBOSE=false
INSECURE=false
THRESHOLD_WARNING=75
THRESHOLD_CRITICAL=90

# Usage function
usage() {
    cat << EOF
Usage: $0 --server <URL> --token <TOKEN> [OPTIONS]

Required:
    --server <URL>      Technitium server URL (e.g., http://192.168.1.1:5380, https://192.168.1.1)
    --token <TOKEN>     API authentication token

Optional:
    --scope <name>      Specific scope name to query (queries all if not specified)
    --json              Output results in JSON format
    --verbose           Show detailed debugging information
    --insecure          Allow insecure SSL connections (self-signed certificates)
    --warning <num>     Warning threshold percentage (default: 75)
    --critical <num>    Critical threshold percentage (default: 90)
    -h, --help          Show this help message

Examples:
    $0 --server http://192.168.1.1:5380 --token mytoken123
    $0 --server http://192.168.1.1:5380 --token mytoken123 --scope "Main Network"
    $0 --server https://10.10.10.5 --token mytoken --insecure
    $0 --server http://10.10.10.5 --token mytoken --verbose
    $0 --server http://10.10.10.5:5380 --token mytoken --warning 80 --critical 95

Notes:
    - Default port is 5380
    - Use http:// for no SSL, https:// for SSL, or https:// with --insecure for self-signed certs
    - Get your API token from Technitium DNS Server: Administration → Sessions → Create Token

EOF
    exit 1
}

# Verbose logging function
log_verbose() {
    if [[ "$VERBOSE" == true ]]; then
        echo -e "${BLUE}[DEBUG]${NC} $1"
    fi
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --server)
            SERVER_URL="$2"
            shift 2
            ;;
        --token)
            API_TOKEN="$2"
            shift 2
            ;;
        --scope)
            SCOPE_NAME="$2"
            shift 2
            ;;
        --json)
            JSON_OUTPUT=true
            shift
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        --insecure)
            INSECURE=true
            shift
            ;;
        --warning)
            THRESHOLD_WARNING="$2"
            shift 2
            ;;
        --critical)
            THRESHOLD_CRITICAL="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            usage
            ;;
    esac
done

# Check required arguments
if [[ -z "$SERVER_URL" ]] || [[ -z "$API_TOKEN" ]]; then
    echo -e "${RED}Error: --server and --token are required${NC}"
    usage
fi

# Remove trailing slash from server URL
SERVER_URL="${SERVER_URL%/}"

log_verbose "Server URL: $SERVER_URL"
log_verbose "API Token: ${API_TOKEN:0:10}..."
log_verbose "Warning threshold: $THRESHOLD_WARNING%"
log_verbose "Critical threshold: $THRESHOLD_CRITICAL%"

# Validate thresholds
if ! [[ "$THRESHOLD_WARNING" =~ ^[0-9]+$ ]] || [[ $THRESHOLD_WARNING -lt 0 ]] || [[ $THRESHOLD_WARNING -gt 100 ]]; then
    echo -e "${RED}Error: Warning threshold must be between 0 and 100${NC}"
    exit 1
fi

if ! [[ "$THRESHOLD_CRITICAL" =~ ^[0-9]+$ ]] || [[ $THRESHOLD_CRITICAL -lt 0 ]] || [[ $THRESHOLD_CRITICAL -gt 100 ]]; then
    echo -e "${RED}Error: Critical threshold must be between 0 and 100${NC}"
    exit 1
fi

if [[ $THRESHOLD_CRITICAL -le $THRESHOLD_WARNING ]]; then
    echo -e "${RED}Error: Critical threshold must be greater than warning threshold${NC}"
    exit 1
fi

# Check dependencies
if ! command -v curl &> /dev/null; then
    echo -e "${RED}Error: curl is required but not installed${NC}"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo -e "${RED}Error: jq is required but not installed${NC}"
    echo "Install it with: apt install jq, brew install jq, or equivalent"
    exit 1
fi

log_verbose "Dependencies check passed"

# Set curl options
CURL_OPTS=""
if [[ "$INSECURE" == true ]]; then
    CURL_OPTS="-k"
    log_verbose "Using --insecure mode for self-signed certificates"
fi

# Function to convert IP address to integer
ip_to_int() {
    local ip=$1
    local a b c d
    IFS=. read -r a b c d <<< "$ip"
    echo $((a * 256 ** 3 + b * 256 ** 2 + c * 256 + d))
}

# Function to calculate IP range size
ip_range_size() {
    local start_ip=$1
    local end_ip=$2
    local start_int=$(ip_to_int "$start_ip")
    local end_int=$(ip_to_int "$end_ip")
    echo $((end_int - start_int + 1))
}

# Function to check if an IP is in an excluded range
ip_in_excluded_range() {
    local ip=$1
    local exclusions=$2
    
    if [[ -z "$exclusions" ]]; then
        return 1  # No exclusions, IP is not excluded
    fi
    
    local ip_int=$(ip_to_int "$ip")
    
    # Parse exclusions (format: "start1-end1,start2-end2,...")
    IFS=',' read -ra EXCL_ARRAY <<< "$exclusions"
    for excl in "${EXCL_ARRAY[@]}"; do
        local start_ip="${excl%-*}"
        local end_ip="${excl#*-}"
        local start_int=$(ip_to_int "$start_ip")
        local end_int=$(ip_to_int "$end_ip")
        
        if [[ $ip_int -ge $start_int ]] && [[ $ip_int -le $end_int ]]; then
            return 0  # IP is in this excluded range
        fi
    done
    
    return 1  # IP is not in any excluded range
}

# Get all scopes
if [[ "$JSON_OUTPUT" != true ]]; then
    echo "Querying Technitium DHCP server at $SERVER_URL..."
fi
log_verbose "Making API call to /api/dhcp/scopes/list"

# Make API call with detailed error handling
HTTP_CODE=$(curl $CURL_OPTS -s -w "%{http_code}" -o /tmp/scopes_response.json \
    "$SERVER_URL/api/dhcp/scopes/list?token=$API_TOKEN" 2>/tmp/curl_error.txt)

CURL_EXIT=$?
log_verbose "Curl exit code: $CURL_EXIT"
log_verbose "HTTP response code: $HTTP_CODE"

# Check if curl command succeeded
if [[ $CURL_EXIT -ne 0 ]]; then
    echo -e "${RED}Error: Failed to connect to server${NC}"
    echo -e "${RED}Curl exit code: $CURL_EXIT${NC}"
    if [[ -f /tmp/curl_error.txt ]] && [[ -s /tmp/curl_error.txt ]]; then
        echo -e "${RED}Details: $(cat /tmp/curl_error.txt)${NC}"
    fi
    echo ""
    echo "Possible causes:"
    echo "  - Server is not reachable at $SERVER_URL"
    echo "  - SSL/TLS certificate issues (try using http:// instead of https://)"
    echo "  - Firewall blocking the connection"
    echo "  - Wrong port number (default is 5380)"
    echo ""
    echo "Tips:"
    echo "  - Try: $0 --server http://10.10.10.5:5380 --token $API_TOKEN"
    echo "  - Verify server is running: curl http://10.10.10.5:5380"
    exit 1
fi

# Read response
SCOPES_RESPONSE=$(cat /tmp/scopes_response.json)
log_verbose "Response length: ${#SCOPES_RESPONSE} bytes"

# Check HTTP response code
if [[ "$HTTP_CODE" != "200" ]]; then
    echo -e "${RED}Error: HTTP $HTTP_CODE response from server${NC}"
    if [[ "$HTTP_CODE" == "000" ]]; then
        echo "Could not connect to server - check URL and network connectivity"
        echo "  - Verify the server address: $SERVER_URL"
        echo "  - Check if you're using http:// (not https://)"
        echo "  - Confirm port 5380 is correct"
    elif [[ "$HTTP_CODE" == "401" ]]; then
        echo "Unauthorized - check your API token"
        echo "  - Token used: ${API_TOKEN:0:20}..."
        echo "  - Get token from: Technitium DNS Server → Settings → API → Tokens"
    elif [[ "$HTTP_CODE" == "403" ]]; then
        echo "Forbidden - API token may not have sufficient permissions"
    elif [[ "$HTTP_CODE" == "404" ]]; then
        echo "Not found - check server URL and API endpoint"
        echo "  - Is the Technitium DNS Server running?"
        echo "  - Try accessing: $SERVER_URL in your browser"
    elif [[ "$HTTP_CODE" == "500" ]]; then
        echo "Server error - check Technitium server logs"
    fi
    echo ""
    echo "Response body:"
    echo "$SCOPES_RESPONSE"
    exit 1
fi

# Check if response is empty
if [[ -z "$SCOPES_RESPONSE" ]]; then
    echo -e "${RED}Error: Empty response from server${NC}"
    echo "The server returned an empty response"
    exit 1
fi

# Check if response is valid JSON
if ! echo "$SCOPES_RESPONSE" | jq empty 2>/dev/null; then
    echo -e "${RED}Error: Invalid JSON response from server${NC}"
    echo "Response received:"
    echo "$SCOPES_RESPONSE"
    echo ""
    echo "This might mean:"
    echo "  - The URL is not pointing to a Technitium DNS Server"
    echo "  - You're hitting a web server or firewall instead"
    exit 1
fi

log_verbose "JSON validation passed"

# Check for API errors
if echo "$SCOPES_RESPONSE" | jq -e '.status == "error"' &> /dev/null; then
    ERROR_MSG=$(echo "$SCOPES_RESPONSE" | jq -r '.errorMessage // "Unknown error"')
    echo -e "${RED}API Error: $ERROR_MSG${NC}"
    echo ""
    echo "Full response:"
    echo "$SCOPES_RESPONSE" | jq '.'
    exit 1
fi

# Get scope names
SCOPE_NAMES=$(echo "$SCOPES_RESPONSE" | jq -r '.response.scopes[].name' 2>/dev/null)

if [[ -z "$SCOPE_NAMES" ]]; then
    echo "No scopes found on server"
    echo ""
    echo "Server response:"
    echo "$SCOPES_RESPONSE" | jq '.'
    echo ""
    echo "This might mean:"
    echo "  - No DHCP scopes have been configured yet"
    echo "  - You need to create a scope in Technitium DNS Server"
    exit 0
fi

SCOPE_COUNT=$(echo "$SCOPE_NAMES" | wc -l)
log_verbose "Found $SCOPE_COUNT scope(s)"

# Array to store results for JSON output
declare -a RESULTS=()

# Process each scope
while IFS= read -r scope; do
    # Skip if we're filtering for a specific scope
    if [[ -n "$SCOPE_NAME" ]] && [[ "$scope" != "$SCOPE_NAME" ]]; then
        log_verbose "Skipping scope '$scope' (filtered)"
        continue
    fi
    
    log_verbose "Processing scope: $scope"
    
    # Get scope details
    SCOPE_URL="$SERVER_URL/api/dhcp/scopes/get?token=$API_TOKEN&name=$(printf %s "$scope" | jq -sRr @uri)"
    log_verbose "Fetching scope details from: $SCOPE_URL"
    
    HTTP_CODE=$(curl $CURL_OPTS -s -w "%{http_code}" -o /tmp/scope_details.json \
        "$SCOPE_URL" 2>/dev/null)
    
    if [[ "$HTTP_CODE" != "200" ]]; then
        echo -e "${RED}Warning: Failed to get details for scope '$scope' (HTTP $HTTP_CODE)${NC}"
        continue
    fi
    
    SCOPE_DETAILS=$(cat /tmp/scope_details.json)
    
    if ! echo "$SCOPE_DETAILS" | jq empty 2>/dev/null; then
        echo -e "${RED}Warning: Invalid JSON response for scope '$scope'${NC}"
        continue
    fi
    
    # Extract scope information
    START_IP=$(echo "$SCOPE_DETAILS" | jq -r '.response.startingAddress')
    END_IP=$(echo "$SCOPE_DETAILS" | jq -r '.response.endingAddress')
    NETWORK=$(echo "$SCOPE_DETAILS" | jq -r '.response.networkAddress')
    SUBNET_MASK=$(echo "$SCOPE_DETAILS" | jq -r '.response.subnetMask')
    ENABLED=$(echo "$SCOPE_DETAILS" | jq -r '.response.enabled // "unknown"')
    
    # If network is null, derive it from the start IP (assume /24 if mask is 255.255.255.0)
    if [[ "$NETWORK" == "null" ]] && [[ "$SUBNET_MASK" == "255.255.255.0" ]]; then
        NETWORK=$(echo "$START_IP" | cut -d. -f1-3).0
    fi
    
    log_verbose "  Range: $START_IP - $END_IP"
    log_verbose "  Enabled value from API: '$ENABLED'"
    
    # Calculate total addresses in range
    TOTAL_RANGE=$(ip_range_size "$START_IP" "$END_IP")
    log_verbose "  Total range: $TOTAL_RANGE addresses"
    
    # Calculate excluded addresses and build exclusion list for filtering
    EXCLUDED_COUNT=0
    EXCLUSIONS_DETAIL=""
    EXCLUSION_RANGES=""  # For filtering leases
    EXCLUSIONS=$(echo "$SCOPE_DETAILS" | jq -c '.response.exclusions[]?' 2>/dev/null)
    while IFS= read -r exclusion; do
        if [[ -n "$exclusion" ]]; then
            EXCL_START=$(echo "$exclusion" | jq -r '.startingAddress')
            EXCL_END=$(echo "$exclusion" | jq -r '.endingAddress')
            EXCL_SIZE=$(ip_range_size "$EXCL_START" "$EXCL_END")
            EXCLUDED_COUNT=$((EXCLUDED_COUNT + EXCL_SIZE))
            EXCLUSIONS_DETAIL="${EXCLUSIONS_DETAIL}  • ${EXCL_START}-${EXCL_END} (${EXCL_SIZE} addresses)\n"
            
            # Add to exclusion ranges for lease filtering
            if [[ -z "$EXCLUSION_RANGES" ]]; then
                EXCLUSION_RANGES="${EXCL_START}-${EXCL_END}"
            else
                EXCLUSION_RANGES="${EXCLUSION_RANGES},${EXCL_START}-${EXCL_END}"
            fi
            
            log_verbose "  Exclusion: $EXCL_START-$EXCL_END ($EXCL_SIZE addresses)"
        fi
    done <<< "$EXCLUSIONS"
    
    # Count reservations (reservedLeases in API) and check which are in excluded ranges
    RESERVATIONS_COUNT=0
    RESERVATIONS_IN_EXCLUDED=0
    RESERVATIONS_OUTSIDE_EXCLUDED=0
    RESERVED_LEASES=$(echo "$SCOPE_DETAILS" | jq -c '.response.reservedLeases[]?' 2>/dev/null)
    
    while IFS= read -r reserved; do
        if [[ -n "$reserved" ]]; then
            RESERVATIONS_COUNT=$((RESERVATIONS_COUNT + 1))
            RESERVED_IP=$(echo "$reserved" | jq -r '.address')
            
            # Check if this reservation is in an excluded range
            if ip_in_excluded_range "$RESERVED_IP" "$EXCLUSION_RANGES"; then
                RESERVATIONS_IN_EXCLUDED=$((RESERVATIONS_IN_EXCLUDED + 1))
                log_verbose "  Reservation in excluded range: $RESERVED_IP"
            else
                RESERVATIONS_OUTSIDE_EXCLUDED=$((RESERVATIONS_OUTSIDE_EXCLUDED + 1))
                log_verbose "  Reservation outside excluded ranges: $RESERVED_IP"
            fi
        fi
    done <<< "$RESERVED_LEASES"
    
    log_verbose "  Total reservations: $RESERVATIONS_COUNT (In excluded: $RESERVATIONS_IN_EXCLUDED, Outside excluded: $RESERVATIONS_OUTSIDE_EXCLUDED)"
    
    # Calculate active pool size (subtract only reservations outside excluded ranges)
    ACTIVE_POOL=$((TOTAL_RANGE - EXCLUDED_COUNT - RESERVATIONS_OUTSIDE_EXCLUDED))
    log_verbose "  Active pool: $ACTIVE_POOL addresses"
    
    # Get leases for this scope
    LEASES_URL="$SERVER_URL/api/dhcp/leases/list?token=$API_TOKEN&scopeName=$(printf %s "$scope" | jq -sRr @uri)"
    log_verbose "  Fetching leases from: $LEASES_URL"
    
    HTTP_CODE=$(curl $CURL_OPTS -s -w "%{http_code}" -o /tmp/leases_response.json \
        "$LEASES_URL" 2>/dev/null)
    
    if [[ "$HTTP_CODE" != "200" ]]; then
        echo -e "${YELLOW}Warning: Failed to get leases for scope '$scope' (HTTP $HTTP_CODE), assuming 0 leases${NC}"
        ACTIVE_LEASES=0
    else
        LEASES_RESPONSE=$(cat /tmp/leases_response.json)
        
        if ! echo "$LEASES_RESPONSE" | jq empty 2>/dev/null; then
            echo -e "${YELLOW}Warning: Invalid JSON in leases response for scope '$scope', assuming 0 leases${NC}"
            ACTIVE_LEASES=0
        else
            # Count dynamic leases only for THIS scope, excluding those in excluded ranges
            ACTIVE_LEASES=0
            LEASES=$(echo "$LEASES_RESPONSE" | jq -c ".response.leases[]? | select(.type == \"Dynamic\" and .scope == \"$scope\")" 2>/dev/null)
            
            while IFS= read -r lease; do
                if [[ -n "$lease" ]]; then
                    LEASE_IP=$(echo "$lease" | jq -r '.address')
                    
                    # Check if this IP is in an excluded range
                    if ! ip_in_excluded_range "$LEASE_IP" "$EXCLUSION_RANGES"; then
                        ACTIVE_LEASES=$((ACTIVE_LEASES + 1))
                    else
                        log_verbose "  Skipping lease in excluded range: $LEASE_IP"
                    fi
                fi
            done <<< "$LEASES"
            
            log_verbose "  Active leases (in pool only): $ACTIVE_LEASES"
        fi
    fi
    
    # Calculate available addresses
    AVAILABLE=$((ACTIVE_POOL - ACTIVE_LEASES))
    
    # Calculate usage percentage
    if [[ $ACTIVE_POOL -gt 0 ]]; then
        USAGE_PERCENT=$(awk "BEGIN {printf \"%.2f\", ($ACTIVE_LEASES / $ACTIVE_POOL) * 100}")
    else
        USAGE_PERCENT="0.00"
    fi
    
    log_verbose "  Usage: $USAGE_PERCENT%"
    
    # Store for JSON output
    if [[ "$JSON_OUTPUT" == true ]]; then
        # Ensure enabled value is properly quoted for JSON
        if [[ "$ENABLED" == "true" ]] || [[ "$ENABLED" == "false" ]]; then
            ENABLED_JSON="$ENABLED"
        else
            ENABLED_JSON="\"$ENABLED\""
        fi
        RESULTS+=("{\"scope_name\":\"$scope\",\"subnet\":\"$NETWORK\",\"subnet_mask\":\"$SUBNET_MASK\",\"enabled\":$ENABLED_JSON,\"total_range\":$TOTAL_RANGE,\"excluded_addresses\":$EXCLUDED_COUNT,\"reserved_addresses\":$RESERVATIONS_COUNT,\"reservations_in_excluded\":$RESERVATIONS_IN_EXCLUDED,\"reservations_outside_excluded\":$RESERVATIONS_OUTSIDE_EXCLUDED,\"active_pool_size\":$ACTIVE_POOL,\"active_leases\":$ACTIVE_LEASES,\"available_addresses\":$AVAILABLE,\"usage_percent\":$USAGE_PERCENT,\"start_address\":\"$START_IP\",\"end_address\":\"$END_IP\"}")
    else
        # Human-readable output
        echo -e "\n======================================================================"
        echo -e "SCOPE: ${BLUE}$scope${NC}"
        echo -e "======================================================================"
        echo -e "Subnet: $NETWORK/$SUBNET_MASK"
        echo -e "Range: $START_IP - $END_IP"
        echo -e "\n--- Pool Calculation ---"
        echo -e "Total addresses in range: $TOTAL_RANGE"
        echo -e "Excluded addresses: $EXCLUDED_COUNT"
        if [[ -n "$EXCLUSIONS_DETAIL" ]]; then
            echo -e "$EXCLUSIONS_DETAIL"
        fi
        echo -e "Reserved addresses: $RESERVATIONS_COUNT"
        if [[ $RESERVATIONS_COUNT -gt 0 ]]; then
            echo -e "  • In excluded ranges: $RESERVATIONS_IN_EXCLUDED"
            echo -e "  • Outside excluded ranges: $RESERVATIONS_OUTSIDE_EXCLUDED"
        fi
        echo -e "Active pool size: ${GREEN}$ACTIVE_POOL${NC}"
        echo -e "\n--- Usage Statistics ---"
        echo -e "Active dynamic leases: $ACTIVE_LEASES"
        echo -e "Available addresses: $AVAILABLE"
        
        # Color-code usage percentage
        USAGE_INT=${USAGE_PERCENT%.*}
        if [[ $USAGE_INT -ge $THRESHOLD_CRITICAL ]]; then
            echo -e "Pool utilization: ${RED}${USAGE_PERCENT}%${NC}"
            echo -e "\n${RED}⚠️  WARNING: Pool usage is critically high! (≥${THRESHOLD_CRITICAL}%)${NC}"
        elif [[ $USAGE_INT -ge $THRESHOLD_WARNING ]]; then
            echo -e "Pool utilization: ${YELLOW}${USAGE_PERCENT}%${NC}"
            echo -e "\n${YELLOW}⚠️  NOTICE: Pool usage is elevated (≥${THRESHOLD_WARNING}%)${NC}"
        else
            echo -e "Pool utilization: ${GREEN}${USAGE_PERCENT}%${NC}"
        fi
    fi
    
done <<< "$SCOPE_NAMES"

# Output JSON if requested
if [[ "$JSON_OUTPUT" == true ]]; then
    echo "{"
    for i in "${!RESULTS[@]}"; do
        echo "  \"scope_$i\": ${RESULTS[$i]}"
        if [[ $i -lt $((${#RESULTS[@]} - 1)) ]]; then
            echo ","
        fi
    done
    echo "}"
fi

# Clean up temp files
rm -f /tmp/scopes_response.json /tmp/scope_details.json /tmp/leases_response.json /tmp/curl_error.txt

if [[ "$JSON_OUTPUT" != true ]]; then
    echo ""
fi
log_verbose "Script completed successfully"
