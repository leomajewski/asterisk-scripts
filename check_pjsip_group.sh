#!/bin/bash

# ==============================================================================
# PJSIP GROUP LATENCY CHECKER - Asterisk Native
#
# Tests real Layer-7 SIP latency for all PJSIP endpoints belonging to a
# named group, bypassing firewalls by using Asterisk's own SIP stack.
# Collects N samples per endpoint and reports averaged RTT with quality
# classification and online/offline status.
#
# Usage:
#   ./check_pjsip_group.sh <GROUP_NAME>
#   ./check_pjsip_group.sh --help
#
# Requirements:
#   - Asterisk with PJSIP (pjsip qualify, pjsip show endpoint)
#   - Run as a user with permission to execute: asterisk -rx
# ==============================================================================

export LC_NUMERIC="C"

# ------------------------------------------------------------------------------
# CONFIGURATION — adjust these to match your environment
# ------------------------------------------------------------------------------
CONF_FILE="/etc/asterisk/pjsip.conf"   # PJSIP config file to discover groups
GROUP_FIELD="named_call_group"          # Field that assigns endpoints to groups
ENDPOINT_PATTERN="^\[[0-9]\{4\}\]"     # Regex matching endpoint section headers
NUM_SAMPLES=10                          # Number of qualify probes per endpoint
INTERVAL=1                             # Seconds between probes
# Latency thresholds (ms)
THRESHOLD_CRITICAL=200
THRESHOLD_SLOW=100
# ------------------------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

show_help() {
    echo -e "${YELLOW}PJSIP Group Latency Checker${NC}"
    echo -e "Usage: $0 [OPTIONS] <GROUP_NAME>"
    echo ""
    echo -e "${CYAN}DESCRIPTION:${NC}"
    echo "  Runs Layer-7 latency tests (via Asterisk pjsip qualify) against all"
    echo "  endpoints in a named group. Collects $NUM_SAMPLES samples for averaged RTT."
    echo ""
    echo -e "${CYAN}OPTIONS:${NC}"
    echo "  -h, --help     Show this help and list available groups."
    echo ""
    echo -e "${CYAN}GROUPS FOUND IN SYSTEM:${NC}"

    if [ -f "$CONF_FILE" ]; then
        GROUPS=$(grep "${GROUP_FIELD}=" "$CONF_FILE" | cut -d'=' -f2 | sort -u)
        if [ -z "$GROUPS" ]; then
            echo "  (No groups configured)"
        else
            echo "$GROUPS" | while read -r line; do echo "  - $line"; done
        fi
    else
        echo -e "${RED}  Error: Config file not found: $CONF_FILE${NC}"
    fi

    echo ""
    echo -e "${CYAN}STATUS LEGEND:${NC}"
    echo "  ${GREEN}ONLINE${NC}     (Registered)   | ${RED}OFFLINE${NC}   (Unreachable)"
    echo "  ${GREEN}EXCELLENT${NC}  (<${THRESHOLD_SLOW}ms)         | ${YELLOW}SLOW${NC}      (${THRESHOLD_SLOW}-${THRESHOLD_CRITICAL}ms)"
    echo "  ${RED}CRITICAL${NC}   (>${THRESHOLD_CRITICAL}ms)        | ${YELLOW}UNSTABLE${NC}  (Packet loss)"
    echo ""
}

# --- ARGUMENT PARSING ---
if [[ "$1" == "--help" ]] || [[ "$1" == "-h" ]]; then
    show_help
    exit 0
fi

if [ -z "$1" ]; then
    echo -e "${RED}Error: GROUP_NAME not specified.${NC}"
    echo "Use '$0 --help' to list available groups."
    exit 1
fi

GROUP=$1
TEMP_DIR="/tmp/pjsip_check_$(date +%s)"
mkdir -p "$TEMP_DIR"

echo -e "${YELLOW}$(printf '%.0s-' {1..100})${NC}"
echo -e "LATENCY REPORT (N=$NUM_SAMPLES samples) — Group: ${GREEN}$GROUP${NC}"
echo -e "${YELLOW}$(printf '%.0s-' {1..100})${NC}"

# Discover endpoints belonging to the group:
# Looks backwards up to 40 lines from the group= tag to find the [endpoint] header
ENDPOINT_LIST=$(grep -B 40 "${GROUP_FIELD}=${GROUP}" "$CONF_FILE" | grep "$ENDPOINT_PATTERN" | tr -d '[]' | sort -u)

if [ -z "$ENDPOINT_LIST" ]; then
    echo -e "${RED}ERROR: Group '$GROUP' not found or has no endpoints.${NC}"
    echo "Tip: Use '$0 --help' to see exact group names."
    rm -rf "$TEMP_DIR"
    exit 1
fi

# --- PER-ENDPOINT TEST FUNCTION (runs in background) ---
test_endpoint() {
    local ENDPOINT=$1
    local SUM_LAT=0
    local VALID=0
    local ERRORS=0

    for i in $(seq 1 $NUM_SAMPLES); do
        asterisk -rx "pjsip qualify $ENDPOINT" > /dev/null 2>&1
        sleep $INTERVAL

        DATA=$(asterisk -rx "pjsip show endpoint $ENDPOINT")

        if echo "$DATA" | grep -qE "Avail|Reachable"; then
            CONTACT=$(echo "$DATA" | grep "Contact:" | grep -E "Avail|Reachable")
            RTT=$(echo "$CONTACT" | sed -nE 's/.*(Avail|Reachable)[[:space:]]+([0-9.]+).*/\2/p')
            [ -z "$RTT" ] && RTT=$(echo "$CONTACT" | awk '{print $NF}')

            if [[ "$RTT" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                RTT_INT=$(echo "$RTT" | cut -d. -f1)
                SUM_LAT=$((SUM_LAT + RTT_INT))
                VALID=$((VALID + 1))
            fi
        else
            ERRORS=$((ERRORS + 1))
        fi
    done

    FINAL=$(asterisk -rx "pjsip show endpoint $ENDPOINT")

    if [ "$VALID" -gt 0 ]; then
        AVG=$((SUM_LAT / VALID))
        TIMESTAMP=$(date "+%H:%M:%S")

        # Extract public IP from Contact URI
        RAW_URI=$(echo "$FINAL" | grep "Contact:" | grep "sip:" | head -n 1)
        PUB_IP=$(echo "$RAW_URI" | grep -o "sip:[^ ]*" | cut -d';' -f1 | sed 's/sip:.*@//')

        # Quality classification
        if   [ "$AVG" -gt "$THRESHOLD_CRITICAL" ]; then QUALITY="CRITICAL"; QCOL=$RED
        elif [ "$AVG" -gt "$THRESHOLD_SLOW" ];     then QUALITY="SLOW";     QCOL=$YELLOW
        else                                             QUALITY="EXCELLENT"; QCOL=$GREEN
        fi

        [ "$ERRORS" -gt 0 ] && QUALITY="UNSTABLE ($ERRORS/$NUM_SAMPLES losses)" && QCOL=$YELLOW

        echo "$ENDPOINT|ONLINE|$AVG|$QUALITY|$PUB_IP|$QCOL|$TIMESTAMP" > "$TEMP_DIR/$ENDPOINT"
    else
        echo "$ENDPOINT|OFFLINE|---|---|---|---|---" > "$TEMP_DIR/$ENDPOINT"
    fi
}

# Launch all endpoint tests in parallel
for EP in $ENDPOINT_LIST; do test_endpoint "$EP" & done

WAIT_TIME=$((NUM_SAMPLES * INTERVAL + 2))
echo -n "Collecting $NUM_SAMPLES samples per endpoint (wait ~${WAIT_TIME}s): [ "
for i in $(seq "$WAIT_TIME" -1 1); do echo -n "."; sleep 1; done
echo " ]"
wait

# --- RESULTS TABLE ---
echo -e "${YELLOW}$(printf '%.0s-' {1..100})${NC}"
printf "%-12s %-10s %-14s %-30s %-22s %-10s\n" "ENDPOINT" "STATUS" "AVG(${NUM_SAMPLES})" "QUALITY" "PUBLIC IP" "SEEN AT"

sort -n "$TEMP_DIR"/* | while IFS='|' read -r ep st lat ql pub qc time; do
    if [ "$st" == "OFFLINE" ]; then
        printf "%-12s %-10s %-14s %-30s %-22s %-10s\n" "$ep" "OFFLINE" "---" "---" "---" "---"
    else
        printf "%-12s %-10s %-14s %b%-30s%b %-22s %-10s\n" "$ep" "$st" "${lat}ms" "$qc" "$ql" "$NC" "$pub" "$time"
    fi
done

TOTAL=$(ls "$TEMP_DIR" | wc -l)
ONLINE=$(grep "|ONLINE|" "$TEMP_DIR"/* | wc -l)
AVG_ALL=$(grep "|ONLINE|" "$TEMP_DIR"/* | awk -F'|' '{sum+=$3} END {if (NR>0) printf "%.0f", sum/NR}')

echo -e "${YELLOW}$(printf '%.0s-' {1..100})${NC}"
echo "Total Endpoints: $TOTAL | Online: $ONLINE"
[ -n "$AVG_ALL" ] && echo "Overall Average Latency: ${AVG_ALL}ms"
echo -e "${YELLOW}$(printf '%.0s-' {1..100})${NC}"

rm -rf "$TEMP_DIR"
