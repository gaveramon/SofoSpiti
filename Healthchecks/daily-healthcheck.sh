#!/usr/bin/env bash

# ============================================================
# Sofo Spiti VPS Health Check
# Debian 13 / Netcup VPS
#
# Checks:
# - System uptime/load
# - CPU
# - RAM
# - Disk
# - Docker
# - Supabase functional services:
#     * Auth
#     * REST/PostgREST
#     * Storage
#     * Realtime
#     * Edge Functions
# - PostgreSQL
# - Database sizes
# - PostgreSQL connections
# - Long-running PostgreSQL queries
#
# Alerts:
# - Email via msmtp -> Infomaniak SMTP
#
# Exit codes:
#   0 = OK
#   1 = WARNING/CRITICAL
#   2 = Configuration error
# ============================================================

set -u

CONFIG_FILE="/etc/sofospiti/healthcheck.env"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Configuration file not found: $CONFIG_FILE"
    exit 2
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

if [[ -z "${ALERT_EMAIL:-}" ]]; then
    echo "ERROR: ALERT_EMAIL is not configured."
    exit 2
fi

if [[ -z "${EMAIL_FROM:-}" ]]; then
    echo "ERROR: EMAIL_FROM is not configured."
    exit 2
fi

HOSTNAME="$(hostname)"
DATE_NOW="$(date '+%Y-%m-%d %H:%M:%S')"

REPORT_FILE="$(mktemp /tmp/sofospiti-healthcheck.XXXXXX)"

OVERALL_STATUS="OK"

cleanup() {
    rm -f "$REPORT_FILE"
}

trap cleanup EXIT

set_status() {
    local new_status="$1"

    case "$new_status" in
        CRITICAL)
            OVERALL_STATUS="CRITICAL"
            ;;
        WARNING)
            if [[ "$OVERALL_STATUS" != "CRITICAL" ]]; then
                OVERALL_STATUS="WARNING"
            fi
            ;;
    esac
}

section() {
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
}

{
    echo "Sofo Spiti VPS Health Check"
    echo
    echo "Hostname : $HOSTNAME"
    echo "Date     : $DATE_NOW"
    echo "Status   : checking..."

    # --------------------------------------------------------
    # SYSTEM
    # --------------------------------------------------------

    section "SYSTEM"

    echo "Uptime:"
    uptime

    echo
    echo "Load average:"
    cat /proc/loadavg

    # --------------------------------------------------------
    # CPU
    # --------------------------------------------------------

    section "CPU"

    VCPU="$(nproc)"
    LOAD1="$(awk '{print $1}' /proc/loadavg)"

    echo "vCPU       : $VCPU"
    echo "Load 1 min : $LOAD1"

    CPU_LOAD_PERCENT="$(awk -v load="$LOAD1" -v cpu="$VCPU" \
        'BEGIN { printf "%.1f", (load / cpu) * 100 }')"

    echo "Load/vCPU  : ${CPU_LOAD_PERCENT}%"

    if awk -v value="$CPU_LOAD_PERCENT" 'BEGIN { exit !(value >= 75) }'; then
        echo "CPU status : CRITICAL"
        set_status "CRITICAL"
    elif awk -v value="$CPU_LOAD_PERCENT" 'BEGIN { exit !(value >= 50) }'; then
        echo "CPU status : WARNING"
        set_status "WARNING"
    else
        echo "CPU status : OK"
    fi

    # --------------------------------------------------------
    # RAM
    # --------------------------------------------------------

    section "MEMORY"

    read -r TOTAL_RAM USED_RAM FREE_RAM AVAILABLE_RAM <<< \
        "$(free -m | awk '/^Mem:/ {print $2, $3, $4, $7}')"

    RAM_USED_PERCENT="$(awk \
        -v used="$USED_RAM" \
        -v total="$TOTAL_RAM" \
        'BEGIN { printf "%.1f", (used / total) * 100 }')"

    RAM_AVAILABLE_PERCENT="$(awk \
        -v available="$AVAILABLE_RAM" \
        -v total="$TOTAL_RAM" \
        'BEGIN { printf "%.1f", (available / total) * 100 }')"

    echo "Total RAM       : ${TOTAL_RAM} MB"
    echo "Used RAM        : ${USED_RAM} MB"
    echo "Available RAM   : ${AVAILABLE_RAM} MB"
    echo "RAM used        : ${RAM_USED_PERCENT}%"
    echo "RAM available   : ${RAM_AVAILABLE_PERCENT}%"

    if awk -v value="$RAM_USED_PERCENT" 'BEGIN { exit !(value >= 90) }'; then
        echo "RAM status      : CRITICAL"
        set_status "CRITICAL"
    elif awk -v value="$RAM_USED_PERCENT" 'BEGIN { exit !(value >= 75) }'; then
        echo "RAM status      : WARNING"
        set_status "WARNING"
    else
        echo "RAM status      : OK"
    fi

    # --------------------------------------------------------
    # DISK
    # --------------------------------------------------------

    section "DISK"

    DISK_USED_PERCENT="$(df -P / | awk 'NR==2 {gsub("%","",$5); print $5}')"
    DISK_AVAILABLE="$(df -h / | awk 'NR==2 {print $4}')"

    echo "Root filesystem used      : ${DISK_USED_PERCENT}%"
    echo "Root filesystem available : ${DISK_AVAILABLE}"

    if [[ "$DISK_USED_PERCENT" -ge 90 ]]; then
        echo "Disk status               : CRITICAL"
        set_status "CRITICAL"
    elif [[ "$DISK_USED_PERCENT" -ge 75 ]]; then
        echo "Disk status               : WARNING"
        set_status "WARNING"
    else
        echo "Disk status               : OK"
    fi

    # --------------------------------------------------------
    # DOCKER
    # --------------------------------------------------------

    section "DOCKER"

    if ! command -v docker >/dev/null 2>&1; then
        echo "Docker status : CRITICAL"
        echo "Docker command not found."
        set_status "CRITICAL"
    elif ! docker info >/dev/null 2>&1; then
        echo "Docker status : CRITICAL"
        echo "Docker daemon is unavailable."
        set_status "CRITICAL"
    else
        echo "Docker version:"
        docker --version

        echo
        echo "Running containers:"
        docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

        echo
        echo "Container resource usage:"
        docker stats --no-stream \
            --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}'

        echo
        echo "Docker disk usage:"
        docker system df
    fi

    # --------------------------------------------------------
    # SUPABASE FUNCTIONAL CHECK
    # --------------------------------------------------------

    section "SUPABASE FUNCTIONAL CHECK"

    SUPABASE_FUNCTIONAL_CHECK="/opt/sofospiti/healthcheck/supabase-functional-check.sh"

    if [[ ! -f "$SUPABASE_FUNCTIONAL_CHECK" ]]; then

        echo "Supabase functional status : CRITICAL"
        echo "Functional check script not found:"
        echo "$SUPABASE_FUNCTIONAL_CHECK"

        set_status "CRITICAL"

    elif [[ ! -x "$SUPABASE_FUNCTIONAL_CHECK" ]]; then

        echo "Supabase functional status : CRITICAL"
        echo "Functional check script is not executable:"
        echo "$SUPABASE_FUNCTIONAL_CHECK"

        set_status "CRITICAL"

    else

        echo "Running functional checks:"
        echo
        echo "  1. Auth"
        echo "  2. REST/PostgREST"
        echo "  3. Storage"
        echo "  4. Realtime"
        echo "  5. Edge Functions"
        echo

        if "$SUPABASE_FUNCTIONAL_CHECK"; then

            echo
            echo "Supabase functional status : OK"

        else

            SUPABASE_CHECK_EXIT_CODE=$?

            echo
            echo "Supabase functional status : CRITICAL"
            echo "Functional check exit code : ${SUPABASE_CHECK_EXIT_CODE}"

            set_status "CRITICAL"

        fi
    fi

    # --------------------------------------------------------
    # POSTGRESQL
    # --------------------------------------------------------

    section "POSTGRESQL"

    PG_CONTAINER="$(docker ps \
        --format '{{.Names}}' 2>/dev/null |
        grep -Ei 'postgres|supabase-db' |
        head -n 1 || true)"

    if [[ -z "$PG_CONTAINER" ]]; then
        echo "PostgreSQL status : CRITICAL"
        echo "No running PostgreSQL container found."
        set_status "CRITICAL"
    else
        echo "Container         : $PG_CONTAINER"

        PG_VERSION="$(docker exec "$PG_CONTAINER" \
            psql -U postgres -d postgres -tAc 'SELECT version();' \
            2>/dev/null || true)"

        if [[ -z "$PG_VERSION" ]]; then
            echo "PostgreSQL status : CRITICAL"
            echo "PostgreSQL is not responding."
            set_status "CRITICAL"
        else
            echo "PostgreSQL version:"
            echo "$PG_VERSION"

            # ------------------------------------------------
            # DATABASE SIZES
            # ------------------------------------------------

            echo
            echo "Database sizes:"

            docker exec "$PG_CONTAINER" \
                psql -U postgres -d postgres -c \
                "SELECT datname,
                        pg_size_pretty(pg_database_size(datname)) AS size
                 FROM pg_database
                 WHERE datallowconn = true
                 ORDER BY pg_database_size(datname) DESC;" \
                2>/dev/null || true

            # ------------------------------------------------
            # CONNECTIONS
            # ------------------------------------------------

            echo
            echo "Active PostgreSQL connections:"

            CONNECTIONS="$(
                docker exec "$PG_CONTAINER" \
                    psql -U postgres -d postgres -tAc \
                    "SELECT count(*) FROM pg_stat_activity;" \
                    2>/dev/null || echo "0"
            )"

            echo "Connections : $CONNECTIONS"

            if [[ "$CONNECTIONS" =~ ^[0-9]+$ ]]; then
                if [[ "$CONNECTIONS" -ge 180 ]]; then
                    echo "Connection status : CRITICAL"
                    set_status "CRITICAL"
                elif [[ "$CONNECTIONS" -ge 120 ]]; then
                    echo "Connection status : WARNING"
                    set_status "WARNING"
                else
                    echo "Connection status : OK"
                fi
            fi

            # ------------------------------------------------
            # LONG RUNNING QUERIES
            # ------------------------------------------------

            echo
            echo "Queries running longer than 30 seconds:"

            LONG_QUERIES="$(
                docker exec "$PG_CONTAINER" \
                    psql -U postgres -d postgres -tAc \
                    "SELECT count(*)
                     FROM pg_stat_activity
                     WHERE state <> 'idle'
                       AND query_start IS NOT NULL
                       AND now() - query_start > interval '30 seconds';" \
                    2>/dev/null || echo "0"
            )"

            echo "Long-running queries : $LONG_QUERIES"

            if [[ "$LONG_QUERIES" =~ ^[0-9]+$ ]]; then
                if [[ "$LONG_QUERIES" -ge 5 ]]; then
                    echo "Query status         : CRITICAL"
                    set_status "CRITICAL"
                elif [[ "$LONG_QUERIES" -ge 1 ]]; then
                    echo "Query status         : WARNING"
                    set_status "WARNING"
                else
                    echo "Query status         : OK"
                fi
            fi
        fi
    fi

    # --------------------------------------------------------
    # FINAL STATUS
    # --------------------------------------------------------

    section "FINAL STATUS"

    echo "Overall status: $OVERALL_STATUS"

    echo
    echo "Health check completed."

} > "$REPORT_FILE"

# ------------------------------------------------------------
# PRINT REPORT
# ------------------------------------------------------------

cat "$REPORT_FILE"

# ------------------------------------------------------------
# EMAIL ALERT
# ------------------------------------------------------------

if [[ "$OVERALL_STATUS" != "OK" ]]; then

    SUBJECT="[Sofo Spiti] VPS ${OVERALL_STATUS} - ${HOSTNAME}"

    {
        echo "From: ${EMAIL_FROM}"
        echo "To: ${ALERT_EMAIL}"
        echo "Subject: ${SUBJECT}"
        echo "Date: $(date -R)"
        echo "MIME-Version: 1.0"
        echo "Content-Type: text/plain; charset=UTF-8"
        echo
        cat "$REPORT_FILE"
    } | msmtp "$ALERT_EMAIL"

    SMTP_EXIT_CODE=$?

    if [[ "$SMTP_EXIT_CODE" -eq 0 ]]; then
        echo
        echo "Alert email sent to: ${ALERT_EMAIL}"
    else
        echo
        echo "WARNING: Could not send alert email."
        echo "msmtp exit code: ${SMTP_EXIT_CODE}"
    fi
fi

# ------------------------------------------------------------
# EXIT CODE
# ------------------------------------------------------------

if [[ "$OVERALL_STATUS" == "OK" ]]; then
    exit 0
else
    exit 1
fi
