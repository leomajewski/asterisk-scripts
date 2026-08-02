#                           ___________ _
#                      __/   .::::.-'-(/-/)
#                    _/:  .::::.-' .-'\/\_`,
#                   /:  .::::./   -._-.  d\|
#                    /: (""""/    '.  (__/||
#                     \::).-'  -._  \/ \\/\|
#             __ _ .-'`)/  '-'. . '. |  (i_O
#         .-'      \       -'      '\|
#    _ _./      .-'|       '.  (    \\
# .-'   :      '_  \         '-'\  /|/
#/      )\_      '- )_________.-|_/^\
#(   .-'   )-._-:  /        \(/\'-._ `.
# (   )  _//_/|:  /          `\()   `\_\
#  ( (   \()^_/)_/             )/      \\
#   )     \\ \(_)             //        )\
#         _o\ \\\            (o_       |__\
#         \ /  \\\__          )_\
#               ^)__\

#!/bin/bash

# ==============================================================================
# CDR CALL HISTORY - Asterisk / FreePBX Native
#
# Queries the local CDR (Call Detail Records) database for a single PJSIP
# endpoint or all endpoints in a named group, and prints a paginated table
# with source/destination, duration, disposition, and - for failed or
# unanswered calls - a best-effort diagnosis correlated from the Asterisk
# log (Q.850 hangup cause when available, otherwise a pattern match against
# common failure messages).
#
# Usage:
#   ./cdr_call_history.sh <ENDPOINT_NUMBER|GROUP_NAME> [PAGE_SIZE] [--external]
#   ./cdr_call_history.sh --help
#
# Requirements:
#   - Asterisk/FreePBX with a CDR MySQL/MariaDB backend (asteriskcdrdb)
#   - mysql client configured for passwordless access (~/.my.cnf or socket auth)
#   - Read access to the Asterisk log directory for diagnosis lookups
# ==============================================================================

export LC_NUMERIC="C"
export LANG=C.UTF-8

# ------------------------------------------------------------------------------
# CONFIGURATION - adjust these to match your environment
# ------------------------------------------------------------------------------
CONF_FILE="/etc/asterisk/pjsip.conf"   # PJSIP config file to discover groups
GROUP_FIELD="named_call_group"          # Field that assigns endpoints to groups
ENDPOINT_PATTERN="^\[[0-9]\{4\}\]"     # Regex matching endpoint section headers
LOG_DIR="/var/log/asterisk"             # Asterisk log directory (full, full.1, ...)
CDR_DB="asteriskcdrdb"                  # CDR database name
DEFAULT_PAGE_SIZE=15                    # Rows per page when not specified
# ------------------------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

show_help() {
    echo -e "${YELLOW}CDR Call History${NC}"
    echo -e "Usage: $0 <ENDPOINT_NUMBER|GROUP_NAME> [PAGE_SIZE] [--external]"
    echo ""
    echo -e "${CYAN}DESCRIPTION:${NC}"
    echo "  Queries the CDR table for a single endpoint or a named group and shows"
    echo "  call history (source/destination, duration, status, and diagnosis for"
    echo "  failed/unanswered calls), newest first."
    echo ""
    echo -e "${CYAN}OPTIONS:${NC}"
    echo "  PAGE_SIZE      Rows per page (default: $DEFAULT_PAGE_SIZE)"
    echo "  --external     Only outbound calls dialed with a trunk-access prefix"
    echo "                 (e.g. 0 + area code + number). Adjust EXTERNAL_CLAUSE"
    echo "                 below to match your own dialplan convention."
    echo ""
    echo -e "${CYAN}EXAMPLES:${NC}"
    echo "  $0 1001 15"
    echo "  $0 branch-east 20"
    echo "  $0 branch-east --external"
    echo ""
}

EXTERNAL_FILTER=0
POSITIONAL=()
for A in "$@"; do
    if [[ "$A" == "--external" ]]; then
        EXTERNAL_FILTER=1
    elif [[ "$A" == "--help" ]] || [[ "$A" == "-h" ]]; then
        show_help
        exit 0
    else
        POSITIONAL+=("$A")
    fi
done

ARG="${POSITIONAL[0]}"
PAGE_SIZE="${POSITIONAL[1]:-$DEFAULT_PAGE_SIZE}"
OFFSET=0

if [ -z "$ARG" ]; then
    show_help
    exit 1
fi

# Adjust to match how outbound trunk calls are dialed in your dialplan
EXTERNAL_CLAUSE="dst LIKE '0%' AND LENGTH(dst) > 4"

if [[ "$ARG" =~ ^[0-9]+$ ]]; then
    ENDPOINT=$ARG
    LABEL="endpoint \033[1;36m$ENDPOINT\033[0m"
    if [ "$EXTERNAL_FILTER" -eq 1 ]; then
        WHERE_CLAUSE="src = '$ENDPOINT' AND $EXTERNAL_CLAUSE"
    else
        WHERE_CLAUSE="src = '$ENDPOINT' OR dst = '$ENDPOINT'"
    fi
else
    GROUP=$ARG

    if [ ! -f "$CONF_FILE" ]; then
        echo -e "${RED}Error: Config file not found: $CONF_FILE${NC}"
        exit 1
    fi

    ENDPOINT_LIST=$(grep -B 40 "${GROUP_FIELD}=${GROUP}" "$CONF_FILE" | grep "$ENDPOINT_PATTERN" | tr -d '[]' | sort -u)

    if [ -z "$ENDPOINT_LIST" ]; then
        echo -e "${RED}ERROR: Group '$GROUP' not found or has no endpoints.${NC}"
        echo "Tip: Use './check_pjsip_group.sh --help' to see exact group names."
        exit 1
    fi

    ENDPOINT_COUNT=$(echo "$ENDPOINT_LIST" | wc -w)
    LABEL="group \033[1;36m$GROUP\033[0m ($ENDPOINT_COUNT endpoints)"

    SQL_LIST=$(echo "$ENDPOINT_LIST" | tr ' ' '\n' | grep -v '^$' | sed "s/.*/'&'/" | tr '\n' ',' | sed 's/,$//')
    if [ "$EXTERNAL_FILTER" -eq 1 ]; then
        WHERE_CLAUSE="src IN ($SQL_LIST) AND $EXTERNAL_CLAUSE"
    else
        WHERE_CLAUSE="src IN ($SQL_LIST) OR dst IN ($SQL_LIST)"
    fi
fi

[ "$EXTERNAL_FILTER" -eq 1 ] && LABEL="$LABEL \033[2m(external calls only)\033[0m"

FAILURE_PATTERNS='is now Unreachable|No compatible codecs|Unable to determine contacts from empty aor list|Service Unavailable|No Route to Destination|Disconnecting channel for lack of RTP activity'
PROGRESS_PATTERNS='is making progress|is ringing|Remote UNKNOWN'
LOG_CACHE=""

# Pre-filters the log files down to just the lines relevant for diagnosis
# (hangup causes + failure/progress patterns), so the per-call greps below
# don't have to scan full, mostly-irrelevant log files on every lookup.
prepare_log_cache() {
    [ -n "$LOG_CACHE" ] && return
    mapfile -t LOG_FILES < <(ls -tr "$LOG_DIR"/full* 2>/dev/null)
    if [ "${#LOG_FILES[@]}" -eq 0 ]; then
        LOG_CACHE="/dev/null"
        return
    fi
    LOG_CACHE=$(mktemp /tmp/cdr_call_history_log.XXXXXX)
    trap '[ -n "$LOG_CACHE" ] && [ -f "$LOG_CACHE" ] && rm -f "$LOG_CACHE"' EXIT
    local CACHE_PATTERN="HANGUP CAUSE: [0-9]+|$FAILURE_PATTERNS|$PROGRESS_PATTERNS"
    for FILE in "${LOG_FILES[@]}"; do
        if [[ "$FILE" == *.gz ]]; then zcat "$FILE"; else cat "$FILE"; fi
    done | grep -E "$CACHE_PATTERN" > "$LOG_CACHE"
}

# Q.850 hangup causes, as logged by a custom "HANGUP CAUSE: N" line in the
# dialplan (only present if your own dialplan logs it - safe to leave the
# table as-is otherwise, diagnosis just falls back to pattern matching).
# NORMAL_CAUSES are expected outcomes (caller hung up before answer / rang
# without being picked up); anything else is a real technical failure.
declare -A CAUSE_LABEL=(
    [16]="Normal clearing"
    [19]="Rang, no answer"
    [26]="Rang, no answer"
    [1]="Unallocated number"
    [3]="No route"
    [17]="Busy"
    [18]="No user response"
    [21]="Call rejected"
    [22]="Number changed"
    [27]="Destination out of order"
    [28]="Invalid number format"
    [34]="No circuit/channel available"
    [38]="Network out of order"
    [41]="Temporary failure"
    [42]="Switching equipment congestion"
    [44]="Requested channel unavailable"
    [127]="Interworking (unspecified)"
    [0]="Unspecified"
)
NORMAL_CAUSES="16 19 26"

cause_label() {
    if [ -n "${CAUSE_LABEL[$1]}" ]; then
        echo "${CAUSE_LABEL[$1]}"
    else
        echo "Uncatalogued"
    fi
}

is_normal_cause() {
    case " $NORMAL_CAUSES " in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}

# Maps a raw log message (matched from FAILURE_PATTERNS) to a short label.
failure_label() {
    case "$1" in
        *Unreachable*) echo "Endpoint unreachable" ;;
        *"compatible codecs"*) echo "No compatible codec" ;;
        *"empty aor list"*) echo "No registered contact" ;;
        *"Service Unavailable"*) echo "Service unavailable" ;;
        *"No Route"*) echo "No route" ;;
        *"lack of RTP"*) echo "No audio (RTP timeout)" ;;
        *) echo "$1" ;;
    esac
}

# Returns "CAUSE|DESCRIPTION" separated by a pipe.
# Trunk channel names (e.g. IAX2/trunk-25112) get reused across unrelated
# calls on different days, so the log grep is always bounded to a time
# window close to the CDR's own calldate.
diagnose_call() {
    local DSTCHANNEL="$1" DST_ENDPOINT="$2" DISPOSITION="$3" CALLDATE="$4"

    if [ "$DISPOSITION" != "NO ANSWER" ] && [ "$DISPOSITION" != "FAILED" ]; then
        echo "---|---"
        return
    fi

    prepare_log_cache

    local EPOCH_CALL START END
    EPOCH_CALL=$(date -d "$CALLDATE" +%s 2>/dev/null)
    if [ -n "$EPOCH_CALL" ]; then
        START=$(date -d "@$((EPOCH_CALL - 30))" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)
        END=$(date -d "@$((EPOCH_CALL + 900))" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)
    fi

    if [ -n "$DSTCHANNEL" ]; then
        local ALL_LINES WINDOW CAUSE ERROR_LINE REASON LABEL_TXT
        ALL_LINES=$(grep -F "$DSTCHANNEL" "$LOG_CACHE")
        if [ -n "$ALL_LINES" ]; then
            WINDOW=$(echo "$ALL_LINES" | awk -v start="$START" -v end="$END" '{
                ts = substr($0, 2, 19)
                if (ts >= start && ts <= end) print
            }')
        fi
        if [ -n "$WINDOW" ]; then
            CAUSE=$(echo "$WINDOW" | grep -oE 'HANGUP CAUSE: [0-9]+' | grep -oE '[0-9]+$' | tail -n1)
            if [ -n "$CAUSE" ]; then
                LABEL_TXT=$(cause_label "$CAUSE")
                if is_normal_cause "$CAUSE"; then
                    echo "$CAUSE|$LABEL_TXT"
                else
                    echo "$CAUSE|Error: $LABEL_TXT"
                fi
                return
            fi

            ERROR_LINE=$(echo "$WINDOW" | grep -E "$FAILURE_PATTERNS" | head -n1)
            if [ -n "$ERROR_LINE" ]; then
                REASON=$(echo "$ERROR_LINE" | grep -oE "$FAILURE_PATTERNS" | head -n1)
                echo "---|Error: $(failure_label "$REASON")"
                return
            fi
            if echo "$WINDOW" | grep -qE "$PROGRESS_PATTERNS"; then
                echo "---|Rang, no answer"
                return
            fi
            echo "---|Possible rejection"
            return
        fi
    fi

    if [[ "$DST_ENDPOINT" =~ ^[0-9]{4}$ ]]; then
        local ERROR_LINE REASON
        ERROR_LINE=$(grep -E "(Endpoint $DST_ENDPOINT |$DST_ENDPOINT/sip:|sip:$DST_ENDPOINT@|PJSIP/$DST_ENDPOINT-)" "$LOG_CACHE" \
            | awk -v start="$START" -v end="$END" '{ ts = substr($0, 2, 19); if (ts >= start && ts <= end) print }' \
            | grep -E "$FAILURE_PATTERNS" | head -n1)
        if [ -n "$ERROR_LINE" ]; then
            REASON=$(echo "$ERROR_LINE" | grep -oE "$FAILURE_PATTERNS" | head -n1)
            echo "---|Error: $(failure_label "$REASON")"
            return
        fi
    fi

    echo "---|No log entry found"
}

echo -e "\nFetching call history for $LABEL...\n"

BORDER="+$(printf '%*s' 21 '' | tr ' ' '-')+$(printf '%*s' 17 '' | tr ' ' '-')+$(printf '%*s' 17 '' | tr ' ' '-')+$(printf '%*s' 8 '' | tr ' ' '-')+$(printf '%*s' 8 '' | tr ' ' '-')+$(printf '%*s' 13 '' | tr ' ' '-')+$(printf '%*s' 7 '' | tr ' ' '-')+$(printf '%*s' 34 '' | tr ' ' '-')+$(printf '%*s' 21 '' | tr ' ' '-')+$(printf '%*s' 21 '' | tr ' ' '-')+"

echo "$BORDER"
printf "| %-19.19s | %-15.15s | %-15.15s | %-6.6s | %-6.6s | %-11.11s | %-5.5s | %-32.32s | %-19.19s | %-19.19s |\n" \
    "Date/Time" "Source" "Destination" "Dur." "Talk" "Status" "Cause" "Diagnosis" "Source Chan" "Dest Chan"
echo "$BORDER"

while true; do
    # Fields joined with CHAR(31) (Unit Separator) instead of relying on
    # mysql's default TAB separator: when a field comes back empty (e.g.
    # dstchannel on queue/Local-channel calls), two consecutive TABs make
    # bash's "read" (with default IFS) collapse the delimiters and drop the
    # empty field, shifting every following column. CHAR(31) doesn't collapse.
    RESULT=$(mysql -N -B -D "$CDR_DB" -e "
    SELECT CONCAT_WS(CHAR(31),
        calldate,
        src,
        dst,
        channel,
        dstchannel,
        CONCAT(FLOOR(duration/60), 'm ', MOD(duration,60), 's'),
        CONCAT(FLOOR(billsec/60), 'm ', MOD(billsec,60), 's'),
        disposition
    )
    FROM cdr
    WHERE $WHERE_CLAUSE
    ORDER BY calldate DESC
    LIMIT $PAGE_SIZE OFFSET $OFFSET;
    ")

    if [ -z "$RESULT" ]; then
        echo "$BORDER"
        echo -e "No more records."
        exit 0
    fi

    while IFS=$'\x1f' read -r calldate src dst chan dchan dur talk disposition; do
        [ -z "$calldate" ] && continue

        color=""
        case "$disposition" in
            ANSWERED) color="\033[1;32m" ;;
            "NO ANSWER") color="\033[1;33m" ;;
            FAILED|BUSY) color="\033[1;31m" ;;
        esac

        IFS='|' read -r cause diagnosis <<< "$(diagnose_call "$dchan" "$dst" "$disposition" "$calldate")"
        dchannel="${dchan:-"---"}"

        printf "| %-19.19s | %-15.15s | %-15.15s | %-6.6s | %-6.6s | ${color}%-11.11s\033[0m | %-5.5s | %-32.32s | %-19.19s | %-19.19s |\n" \
            "$calldate" "$src" "$dst" "$dur" "$talk" "$disposition" "$cause" "$diagnosis" "$chan" "$dchannel"
    done <<< "$RESULT"

    while true; do
        echo -en "Press [ENTER] for more calls, or [S] to quit: "
        read -rsn1 choice

        if [[ "$choice" =~ ^[Ss]$ ]]; then
            echo -e "\r\e[K$BORDER"
            echo -e "Done."
            exit 0
        elif [[ -z "$choice" ]]; then
            echo -en "\r\e[K"
            break
        else
            echo -en "\r\e[K"
        fi
    done

    OFFSET=$((OFFSET + PAGE_SIZE))
done
