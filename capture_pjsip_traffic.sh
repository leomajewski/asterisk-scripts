#!/bin/bash

# ==============================================================================
# PJSIP TRAFFIC CAPTURE
#
# Captures SIP/RTP traffic for a single PJSIP endpoint or all endpoints in a
# named group. IPs are resolved live from Asterisk (not from config), so the
# capture always follows the current registered contact.
#
# Usage:
#   ./capture_pjsip_traffic.sh <ENDPOINT_NUMBER>   capture a single endpoint
#   ./capture_pjsip_traffic.sh <GROUP_NAME>         capture all endpoints in a group
#
# Requirements:
#   - tcpdump (with write permission to OUTPUT_DIR)
#   - Asterisk with PJSIP (pjsip show endpoint)
#   - Run as a user with permission to execute: asterisk -rx
# ==============================================================================

# ------------------------------------------------------------------------------
# CONFIGURATION
# ------------------------------------------------------------------------------
OUTPUT_DIR="/var/log/voip-captures"         # Where .pcap files are stored
CONF_FILE="/etc/asterisk/pjsip.conf"        # PJSIP config (used for group lookups)
GROUP_FIELD="named_call_group"              # Field that assigns endpoints to groups
ENDPOINT_PATTERN="^\[[0-9]\{4\}\]"         # Regex matching endpoint section headers
MAX_DURATION=$((7 * 24 * 60 * 60))         # Auto-stop after 7 days (seconds)
ROTATE_INTERVAL=86400                       # New .pcap file every N seconds (default: 1 day)
# ------------------------------------------------------------------------------

ARG=$1

if [ -z "$ARG" ]; then
    echo "Usage:"
    echo "  $0 <endpoint_number>   capture traffic for a single endpoint"
    echo "  $0 <group_name>        capture traffic for all endpoints in a group"
    echo ""
    echo "Examples:"
    echo "  $0 1001"
    echo "  $0 branch-east"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

resolve_ip() {
    asterisk -rx "pjsip show endpoint $1" \
        | grep -i "Contact: " \
        | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b" \
        | head -n 1
}

# ── Detect mode: numeric = single endpoint, string = group ────────────────────

if [[ "$ARG" =~ ^[0-9]+$ ]]; then

    # ── SINGLE ENDPOINT MODE ──────────────────────────────────────────────────
    ENDPOINT=$ARG
    MODE="endpoint"
    LABEL="$ENDPOINT"

    echo "Looking up current IP for endpoint $ENDPOINT..."
    IP=$(resolve_ip "$ENDPOINT")

    if [ -z "$IP" ]; then
        echo "ERROR: Could not resolve IP for endpoint $ENDPOINT."
        exit 1
    fi

    IP_LIST="$IP"
    TCPDUMP_FILTER="host $IP"

    echo "  Endpoint : $ENDPOINT"
    echo "  IP       : $IP"

else

    # ── GROUP MODE ────────────────────────────────────────────────────────────
    GROUP=$ARG
    MODE="group"
    LABEL="$GROUP"

    if [ ! -f "$CONF_FILE" ]; then
        echo "ERROR: Config file not found: $CONF_FILE"
        exit 1
    fi

    echo "Looking up endpoints in group '$GROUP'..."
    ENDPOINT_LIST=$(grep -B 40 "${GROUP_FIELD}=${GROUP}" "$CONF_FILE" \
        | grep "$ENDPOINT_PATTERN" | tr -d '[]' | sort -u)

    if [ -z "$ENDPOINT_LIST" ]; then
        echo "ERROR: Group '$GROUP' not found or has no endpoints."
        echo "Tip: Use './check_pjsip_group.sh --help' to list available groups."
        exit 1
    fi

    echo ""
    echo "  Endpoints found: $(echo "$ENDPOINT_LIST" | wc -w)"
    echo ""
    echo "  Resolving registered IPs..."

    IPS_RAW=""
    for EP in $ENDPOINT_LIST; do
        IP=$(resolve_ip "$EP")
        if [ -n "$IP" ]; then
            printf "  OK  endpoint %-8s -> %s\n" "$EP" "$IP"
            IPS_RAW="$IPS_RAW $IP"
        else
            printf "  --  endpoint %-8s -> not registered (skipped)\n" "$EP"
        fi
    done

    # Deduplicate IPs — endpoints in the same group often share one public NAT IP
    IP_LIST=$(echo "$IPS_RAW" | tr ' ' '\n' | sort -u | grep -v '^$')

    if [ -z "$IP_LIST" ]; then
        echo ""
        echo "ERROR: No endpoints in group '$GROUP' are currently registered."
        exit 1
    fi

    IP_COUNT=$(echo "$IP_LIST" | wc -l)
    echo ""
    echo "  Unique IPs to capture: $IP_COUNT"
    echo "$IP_LIST" | while read -r ip; do echo "    -> $ip"; done
    echo ""

    # Build tcpdump filter: "host IP1 or host IP2 or ..."
    TCPDUMP_FILTER=$(echo "$IP_LIST" | tr '\n' ' ' | sed 's/ $//' \
        | sed 's/ / or host /g' | sed 's/^/host /')
fi

# ── Start capture ─────────────────────────────────────────────────────────────

SESSION_ID=$(date +%Y%m%d_%H%M%S)
FILE_PREFIX="capture_${LABEL}_${SESSION_ID}"

if ls "${OUTPUT_DIR}/${FILE_PREFIX}"*.pcap 1>/dev/null 2>&1; then
    echo "ERROR: A file for this session already exists. Aborting."
    exit 1
fi

tcpdump -i any -n -s 0 \
    -G "$ROTATE_INTERVAL" \
    -w "${OUTPUT_DIR}/${FILE_PREFIX}_%Y%m%d_%H%M%S.pcap" \
    $TCPDUMP_FILTER > /dev/null 2>&1 &
TCPDUMP_PID=$!

echo ""
echo "Capture started (new file every $((ROTATE_INTERVAL / 3600))h, auto-stop after 7 days)"
if [ "$MODE" = "group" ]; then
    echo "Group: $GROUP | IPs: $(echo $IP_LIST | tr '\n' ' ') | Session: $SESSION_ID"
else
    echo "Endpoint: $ENDPOINT | IP: $IP | Session: $SESSION_ID"
fi
echo "Press [S] to stop early."
echo "----------------------------------------------------------------------"

START_TIME=$(date +%s)
LINES_TO_MOVE=0

stop_capture() {
    echo ""
    echo "Stopping capture..."
    kill -INT $TCPDUMP_PID 2>/dev/null
    wait $TCPDUMP_PID 2>/dev/null
    echo "Done. Files saved to $OUTPUT_DIR"
    exit 0
}

trap stop_capture SIGINT

while true; do
    [ $LINES_TO_MOVE -gt 0 ] && echo -en "\e[${LINES_TO_MOVE}A"

    ELAPSED=$(( $(date +%s) - START_TIME ))
    REMAINING=$((MAX_DURATION - ELAPSED))

    if [ $REMAINING -le 0 ]; then
        echo -e "\e[K7-day limit reached. Stopping capture."
        stop_capture
    fi

    REM_D=$((REMAINING / 86400))
    REM_H=$(((REMAINING % 86400) / 3600))
    REM_M=$(((REMAINING % 3600) / 60))
    REM_S=$((REMAINING % 60))

    printf "\e[KTime remaining: %02d days %02dh:%02dm:%02ds\n" $REM_D $REM_H $REM_M $REM_S
    echo -e "\e[K"
    echo -e "\e[KFiles in this session:"

    FILES=$(ls -lhrt "${OUTPUT_DIR}/${FILE_PREFIX}"*.pcap 2>/dev/null)

    if [ -z "$FILES" ]; then
        echo -e "\e[K  (waiting for first file...)"
        FILE_COUNT=1
    else
        FILE_COUNT=$(echo "$FILES" | wc -l)
        echo "$FILES" | awk '{printf "\033[K  %-70s  %s\n", $9, $5}'
    fi

    LINES_TO_MOVE=$((3 + FILE_COUNT))

    read -t 1 -rsn1 input
    [[ "$input" =~ ^[Ss]$ ]] && stop_capture
done
