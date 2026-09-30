#!/usr/bin/env bash
# ============================================================
# Sofo Spiti - VPS Weekly Health Check
# ============================================================
#
# Install:
#   /usr/local/bin/sofospiti-weekly-check.sh
#
# Config:
#   /etc/sofospiti/weekly-check.env
#
# Metrics:
#   /var/lib/sofospiti/metrics/metrics.csv
#
# Reports:
#   /var/lib/sofospiti/reports/
#
# Functional checks:
#   - Supabase Auth
#   - Supabase REST/PostgREST
#   - Supabase Storage
#   - Supabase Realtime
#   - Supabase Edge Functions
#
# Alerts:
#   msmtp -> external SMTP provider
#
# Exit:
#   0 = OK
#   1 = WARNING / CRITICAL
#   2 = configuration error
#
# ============================================================

set -u
set -o pipefail

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------

CONFIG_FILE="/etc/sofospiti/weekly-check.env"

if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1091
    source "$CONFIG_FILE"
fi

ALERT_EMAIL="${ALERT_EMAIL:-}"
EMAIL_FROM="${EMAIL_FROM:-}"

METRICS_FILE="${METRICS_FILE:-/var/lib/sofospiti/metrics/metrics.csv}"
REPORT_DIR="${REPORT_DIR:-/var/lib/sofospiti/reports}"

BACKUP_DIR="${POSTGRES_BACKUP_DIR:-/var/backups/sofospiti/postgres}"
BACKUP_MAX_AGE_HOURS="${BACKUP_MAX_AGE_HOURS:-24}"

SCW_RCLONE_REMOTE="${SCW_RCLONE_REMOTE:-}"
SCW_BACKUP_PATH="${SCW_BACKUP_PATH:-}"

RESTORE_TEST_FILE="${RESTORE_TEST_FILE:-/var/lib/sofospiti/last-restore-test}"
RESTORE_TEST_MAX_DAYS="${RESTORE_TEST_MAX_DAYS:-30}"

EXPECTED_PUBLIC_PORTS="${EXPECTED_PUBLIC_PORTS:-22 80 443}"

SSL_HOSTNAME="${SSL_HOSTNAME:-sofospiti.gr}"
SSL_WARNING_DAYS="${SSL_WARNING_DAYS:-30}"

MIN_EXPECTED_SAMPLES="${MIN_EXPECTED_SAMPLES:-100}"

LONG_QUERY_SECONDS="${LONG_QUERY_SECONDS:-30}"

SUPABASE_FUNCTIONAL_CHECK="${SUPABASE_FUNCTIONAL_CHECK:-/opt/sofospiti/healthcheck/supabase-functional-check.sh}"

# ------------------------------------------------------------
# Historical metric thresholds
# ------------------------------------------------------------

CPU_AVG_WARNING="${CPU_AVG_WARNING:-60}"
CPU_PEAK_WARNING="${CPU_PEAK_WARNING:-75}"

RAM_AVG_WARNING="${RAM_AVG_WARNING:-75}"
RAM_PEAK_WARNING="${RAM_PEAK_WARNING:-90}"

SWAP_AVG_WARNING_MB="${SWAP_AVG_WARNING_MB:-512}"
SWAP_PEAK_WARNING_MB="${SWAP_PEAK_WARNING_MB:-2048}"

DISK_AVG_WARNING="${DISK_AVG_WARNING:-70}"
DISK_PEAK_WARNING="${DISK_PEAK_WARNING:-80}"
DISK_PEAK_CRITICAL="${DISK_PEAK_CRITICAL:-90}"

DOCKER_CPU_AVG_WARNING="${DOCKER_CPU_AVG_WARNING:-60}"
DOCKER_CPU_PEAK_WARNING="${DOCKER_CPU_PEAK_WARNING:-80}"

DOCKER_RAM_AVG_WARNING="${DOCKER_RAM_AVG_WARNING:-75}"
DOCKER_RAM_PEAK_WARNING="${DOCKER_RAM_PEAK_WARNING:-90}"

# ============================================================
# Preparation
# ============================================================

mkdir -p "$REPORT_DIR"

TMP_REPORT="$(mktemp)"
TMP_METRICS="$(mktemp)"
TMP_VALID_ROWS="$(mktemp)"

trap 'rm -f "$TMP_REPORT" "$TMP_METRICS" "$TMP_VALID_ROWS"' EXIT

STATUS="OK"
WARNINGS=0
CRITICALS=0

POSTGRES_CONTAINER=""

# ============================================================
# Helper functions
# ============================================================

timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

log() {
    echo "[$(timestamp)] $*" | tee -a "$TMP_REPORT"
}

ok() {
    log "OK       | $*"
}

warn() {
    STATUS="WARNING"
    WARNINGS=$((WARNINGS + 1))
    log "WARNING  | $*"
}

critical() {
    STATUS="CRITICAL"
    CRITICALS=$((CRITICALS + 1))
    log "CRITICAL | $*"
}

info() {
    log "INFO     | $*"
}

section() {
    echo "" | tee -a "$TMP_REPORT"
    echo "============================================================" | tee -a "$TMP_REPORT"
    echo "$*" | tee -a "$TMP_REPORT"
    echo "============================================================" | tee -a "$TMP_REPORT"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

is_number() {
    [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

# ============================================================
# HEADER
# ============================================================

log "Sofo Spiti VPS Weekly Health Check"
log "Hostname : $(hostname)"
log "Date     : $(date -R)"
log "Period   : last 7 days"

# ============================================================
# SUPABASE FUNCTIONAL CHECK
# ============================================================

section "SUPABASE FUNCTIONAL CHECK"

if [[ ! -f "$SUPABASE_FUNCTIONAL_CHECK" ]]; then

    critical "Supabase functional check script not found: ${SUPABASE_FUNCTIONAL_CHECK}"

elif [[ ! -x "$SUPABASE_FUNCTIONAL_CHECK" ]]; then

    critical "Supabase functional check script is not executable: ${SUPABASE_FUNCTIONAL_CHECK}"

else

    info "Running weekly Supabase functional validation"
    info "Checks: Auth, REST/PostgREST, Storage, Realtime, Edge Functions"

    if "$SUPABASE_FUNCTIONAL_CHECK"; then

        ok "All Supabase functional checks passed"

    else

        SUPABASE_EXIT_CODE=$?

        critical "Supabase functional check failed (exit code ${SUPABASE_EXIT_CODE})"

    fi

fi

# ============================================================
# HISTORICAL METRICS
# ============================================================

section "7-DAY INFRASTRUCTURE METRICS"

EXPECTED_COLUMNS=(
    "timestamp"
    "hostname"
    "cpu_load"
    "cpu_load_percent"
    "ram_used_percent"
    "ram_available_mb"
    "swap_used_mb"
    "disk_used_percent"
    "docker_cpu_percent"
    "docker_memory_mb"
    "docker_memory_percent"
    "docker_disk_reclaimable_mb"
)

if [[ ! -f "$METRICS_FILE" ]]; then

    critical "Metrics file does not exist: ${METRICS_FILE}"

else

    HEADER="$(head -n 1 "$METRICS_FILE" | tr -d '\r')"

    if [[ -z "$HEADER" ]]; then

        critical "Metrics file has no header"

    else

        declare -A HEADER_INDEX=()

        IFS=',' read -r -a HEADER_FIELDS <<< "$HEADER"

        HEADER_FIELD_COUNT="${#HEADER_FIELDS[@]}"

        for INDEX in "${!HEADER_FIELDS[@]}"; do

            COLUMN="${HEADER_FIELDS[$INDEX]}"
            COLUMN="${COLUMN//$'\r'/}"

            if [[ -n "$COLUMN" ]]; then
                HEADER_INDEX["$COLUMN"]="$INDEX"
            fi

        done

        MISSING_COLUMNS=0

        for COLUMN in "${EXPECTED_COLUMNS[@]}"; do

            if [[ -z "${HEADER_INDEX[$COLUMN]+x}" ]]; then
                warn "Metrics CSV missing column: ${COLUMN}"
                MISSING_COLUMNS=$((MISSING_COLUMNS + 1))
            fi

        done

        if (( MISSING_COLUMNS == 0 )); then
            ok "All expected metrics CSV columns are present"
        else
            critical "${MISSING_COLUMNS} required metrics column(s) are missing"
        fi

        # ----------------------------------------------------
        # Only process historical metrics when the schema is
        # complete enough for the analysis.
        # ----------------------------------------------------

        if (( MISSING_COLUMNS == 0 )); then

            IDX_TIMESTAMP="${HEADER_INDEX[timestamp]}"
            IDX_CPU="${HEADER_INDEX[cpu_load_percent]}"
            IDX_RAM="${HEADER_INDEX[ram_used_percent]}"
            IDX_RAM_AVAILABLE="${HEADER_INDEX[ram_available_mb]}"
            IDX_SWAP="${HEADER_INDEX[swap_used_mb]}"
            IDX_DISK="${HEADER_INDEX[disk_used_percent]}"
            IDX_DOCKER_CPU="${HEADER_INDEX[docker_cpu_percent]}"
            IDX_DOCKER_RAM="${HEADER_INDEX[docker_memory_percent]}"
            IDX_DOCKER_MEM_MB="${HEADER_INDEX[docker_memory_mb]}"
            IDX_DOCKER_RECLAIMABLE="${HEADER_INDEX[docker_disk_reclaimable_mb]}"

            CUTOFF_TS="$(date -d '7 days ago' +%s)"

            INVALID_TIMESTAMP_COUNT=0
            INVALID_ROW_COUNT=0
            VALID_ROW_COUNT=0

            CPU_VALUES=()
            RAM_VALUES=()
            RAM_AVAILABLE_VALUES=()
            SWAP_VALUES=()
            DISK_VALUES=()
            DOCKER_CPU_VALUES=()
            DOCKER_RAM_VALUES=()
            DOCKER_MEM_MB_VALUES=()
            DOCKER_RECLAIMABLE_VALUES=()

            # ------------------------------------------------
            # Read CSV
            # ------------------------------------------------

            while IFS=',' read -r -a ROW || (( ${#ROW[@]} > 0 )); do

                # Skip completely empty rows.
                if (( ${#ROW[@]} == 0 )); then
                    continue
                fi

                ALL_EMPTY=true

                for CELL in "${ROW[@]}"; do
                    CELL="${CELL//$'\r'/}"

                    if [[ -n "$CELL" ]]; then
                        ALL_EMPTY=false
                        break
                    fi
                done

                if [[ "$ALL_EMPTY" == "true" ]]; then
                    continue
                fi

                # ------------------------------------------------
                # Validate row width
                # ------------------------------------------------

                if (( ${#ROW[@]} != HEADER_FIELD_COUNT )); then
                    INVALID_ROW_COUNT=$((INVALID_ROW_COUNT + 1))
                    continue
                fi

                # ------------------------------------------------
                # Timestamp
                # ------------------------------------------------

                RAW_TIMESTAMP="${ROW[$IDX_TIMESTAMP]}"
                RAW_TIMESTAMP="${RAW_TIMESTAMP//$'\r'/}"

                if [[ -z "$RAW_TIMESTAMP" ]]; then
                    INVALID_TIMESTAMP_COUNT=$((INVALID_TIMESTAMP_COUNT + 1))
                    continue
                fi

                ROW_TS="$(date -d "$RAW_TIMESTAMP" +%s 2>/dev/null || echo 0)"

                if (( ROW_TS == 0 )); then
                    INVALID_TIMESTAMP_COUNT=$((INVALID_TIMESTAMP_COUNT + 1))
                    continue
                fi

                if (( ROW_TS < CUTOFF_TS )); then
                    continue
                fi

                VALID_ROW_COUNT=$((VALID_ROW_COUNT + 1))

                # ------------------------------------------------
                # CPU
                # ------------------------------------------------

                VALUE="${ROW[$IDX_CPU]}"
                VALUE="${VALUE//$'\r'/}"

                if awk -v v="$VALUE" \
                    'BEGIN {
                        exit !(v ~ /^[0-9]+([.][0-9]+)?$/ && v >= 0 && v <= 100)
                    }'; then
                    CPU_VALUES+=("$VALUE")
                fi

                # ------------------------------------------------
                # RAM
                # ------------------------------------------------

                VALUE="${ROW[$IDX_RAM]}"
                VALUE="${VALUE//$'\r'/}"

                if awk -v v="$VALUE" \
                    'BEGIN {
                        exit !(v ~ /^[0-9]+([.][0-9]+)?$/ && v >= 0 && v <= 100)
                    }'; then
                    RAM_VALUES+=("$VALUE")
                fi

                # ------------------------------------------------
                # RAM available
                # ------------------------------------------------

                VALUE="${ROW[$IDX_RAM_AVAILABLE]}"
                VALUE="${VALUE//$'\r'/}"

                if awk -v v="$VALUE" \
                    'BEGIN {
                        exit !(v ~ /^[0-9]+([.][0-9]+)?$/ && v >= 0)
                    }'; then
                    RAM_AVAILABLE_VALUES+=("$VALUE")
                fi

                # ------------------------------------------------
                # Swap
                # ------------------------------------------------

                VALUE="${ROW[$IDX_SWAP]}"
                VALUE="${VALUE//$'\r'/}"

                if awk -v v="$VALUE" \
                    'BEGIN {
                        exit !(v ~ /^[0-9]+([.][0-9]+)?$/ && v >= 0)
                    }'; then
                    SWAP_VALUES+=("$VALUE")
                fi

                # ------------------------------------------------
                # Disk
                # ------------------------------------------------

                VALUE="${ROW[$IDX_DISK]}"
                VALUE="${VALUE//$'\r'/}"

                if awk -v v="$VALUE" \
                    'BEGIN {
                        exit !(v ~ /^[0-9]+([.][0-9]+)?$/ && v >= 0 && v <= 100)
                    }'; then
                    DISK_VALUES+=("$VALUE")
                fi

                # ------------------------------------------------
                # Docker CPU
                # ------------------------------------------------

                VALUE="${ROW[$IDX_DOCKER_CPU]}"
                VALUE="${VALUE//$'\r'/}"

                if awk -v v="$VALUE" \
                    'BEGIN {
                        exit !(v ~ /^[0-9]+([.][0-9]+)?$/ && v >= 0)
                    }'; then
                    DOCKER_CPU_VALUES+=("$VALUE")
                fi

                # ------------------------------------------------
                # Docker RAM %
                # ------------------------------------------------

                VALUE="${ROW[$IDX_DOCKER_RAM]}"
                VALUE="${VALUE//$'\r'/}"

                if awk -v v="$VALUE" \
                    'BEGIN {
                        exit !(v ~ /^[0-9]+([.][0-9]+)?$/ && v >= 0 && v <= 100)
                    }'; then
                    DOCKER_RAM_VALUES+=("$VALUE")
                fi

                # ------------------------------------------------
                # Docker RAM MB
                # ------------------------------------------------

                VALUE="${ROW[$IDX_DOCKER_MEM_MB]}"
                VALUE="${VALUE//$'\r'/}"

                if awk -v v="$VALUE" \
                    'BEGIN {
                        exit !(v ~ /^[0-9]+([.][0-9]+)?$/ && v >= 0)
                    }'; then
                    DOCKER_MEM_MB_VALUES+=("$VALUE")
                fi

                # ------------------------------------------------
                # Docker reclaimable
                # ------------------------------------------------

                VALUE="${ROW[$IDX_DOCKER_RECLAIMABLE]}"
                VALUE="${VALUE//$'\r'/}"

                if awk -v v="$VALUE" \
                    'BEGIN {
                        exit !(v ~ /^[0-9]+([.][0-9]+)?$/ && v >= 0)
                    }'; then
                    DOCKER_RECLAIMABLE_VALUES+=("$VALUE")
                fi

            done < <(tail -n +2 "$METRICS_FILE")

            info "Valid rows in last 7 days : ${VALID_ROW_COUNT}"

            if (( INVALID_TIMESTAMP_COUNT > 0 )); then
                warn "${INVALID_TIMESTAMP_COUNT} metrics row(s) had invalid timestamps"
            fi

            if (( INVALID_ROW_COUNT > 0 )); then
                warn "${INVALID_ROW_COUNT} metrics row(s) had invalid column count"
            fi

            if (( VALID_ROW_COUNT < MIN_EXPECTED_SAMPLES )); then
                warn "Only ${VALID_ROW_COUNT} valid rows found; expected at least ${MIN_EXPECTED_SAMPLES}"
            else
                ok "Sufficient metrics samples available"
            fi

            # ----------------------------------------------------
            # Statistics helper
            # ----------------------------------------------------

            calculate_stats() {

                local NAME="$1"
                shift

                local COUNT="$#"
                local SUM="0"
                local MAX=""
                local VALUE
                local AVG

                if (( COUNT == 0 )); then
                    echo "${NAME}|0|NA|NA"
                    return
                fi

                for VALUE in "$@"; do

                    SUM="$(
                        awk \
                            -v a="$SUM" \
                            -v b="$VALUE" \
                            'BEGIN { printf "%.6f", a+b }'
                    )"

                    if [[ -z "$MAX" ]] ||
                       awk -v v="$VALUE" -v m="$MAX" \
                           'BEGIN { exit !(v > m) }'; then
                        MAX="$VALUE"
                    fi

                done

                AVG="$(
                    awk \
                        -v sum="$SUM" \
                        -v count="$COUNT" \
                        'BEGIN { printf "%.2f", sum/count }'
                )"

                echo "${NAME}|${COUNT}|${AVG}|${MAX}"
            }

            # ----------------------------------------------------
            # CPU
            # ----------------------------------------------------

            IFS='|' read -r NAME COUNT AVG MAX < <(
                calculate_stats "CPU" "${CPU_VALUES[@]}"
            )

            info "CPU load        : samples=${COUNT} avg=${AVG}% peak=${MAX}%"

            if [[ "$AVG" == "NA" ]]; then

                warn "No valid CPU metrics available"

            elif awk -v v="$MAX" -v t="$CPU_PEAK_WARNING" \
                'BEGIN { exit !(v >= t) }'; then

                warn "7-day CPU peak reached ${MAX}%"

            elif awk -v v="$AVG" -v t="$CPU_AVG_WARNING" \
                'BEGIN { exit !(v >= t) }'; then

                warn "7-day CPU average is ${AVG}%"

            else
                ok "7-day CPU usage is within limits"
            fi

            # ----------------------------------------------------
            # RAM
            # ----------------------------------------------------

            IFS='|' read -r NAME COUNT AVG MAX < <(
                calculate_stats "RAM" "${RAM_VALUES[@]}"
            )

            info "RAM usage       : samples=${COUNT} avg=${AVG}% peak=${MAX}%"

            if [[ "$AVG" == "NA" ]]; then

                warn "No valid RAM metrics available"

            elif awk -v v="$MAX" -v t="$RAM_PEAK_WARNING" \
                'BEGIN { exit !(v >= t) }'; then

                critical "7-day RAM peak reached ${MAX}%"

            elif awk -v v="$AVG" -v t="$RAM_AVG_WARNING" \
                'BEGIN { exit !(v >= t) }'; then

                warn "7-day RAM average is ${AVG}%"

            else
                ok "7-day RAM usage is within limits"
            fi

            # ----------------------------------------------------
            # RAM available
            # ----------------------------------------------------

            IFS='|' read -r NAME COUNT AVG MAX < <(
                calculate_stats "RAM_AVAILABLE" "${RAM_AVAILABLE_VALUES[@]}"
            )

            info "RAM available   : samples=${COUNT} avg=${AVG} MB peak=${MAX} MB"

            # ----------------------------------------------------
            # Swap
            # ----------------------------------------------------

            IFS='|' read -r NAME COUNT AVG MAX < <(
                calculate_stats "SWAP" "${SWAP_VALUES[@]}"
            )

            info "Swap usage      : samples=${COUNT} avg=${AVG} MB peak=${MAX} MB"

            if [[ "$AVG" != "NA" ]]; then

                if awk -v v="$MAX" -v t="$SWAP_PEAK_WARNING_MB" \
                    'BEGIN { exit !(v >= t) }'; then

                    warn "7-day swap peak reached ${MAX} MB"

                elif awk -v v="$AVG" -v t="$SWAP_AVG_WARNING_MB" \
                    'BEGIN { exit !(v >= t) }'; then

                    warn "7-day swap average is ${AVG} MB"

                else
                    ok "7-day swap usage is within limits"
                fi

            fi

            # ----------------------------------------------------
            # Disk
            # ----------------------------------------------------

            IFS='|' read -r NAME COUNT AVG MAX < <(
                calculate_stats "DISK" "${DISK_VALUES[@]}"
            )

            info "Disk usage      : samples=${COUNT} avg=${AVG}% peak=${MAX}%"

            if [[ "$AVG" == "NA" ]]; then

                warn "No valid disk metrics available"

            elif awk -v v="$MAX" -v t="$DISK_PEAK_CRITICAL" \
                'BEGIN { exit !(v >= t) }'; then

                critical "7-day disk peak reached ${MAX}%"

            elif awk -v v="$MAX" -v t="$DISK_PEAK_WARNING" \
                'BEGIN { exit !(v >= t) }'; then

                warn "7-day disk peak reached ${MAX}%"

            elif awk -v v="$AVG" -v t="$DISK_AVG_WARNING" \
                'BEGIN { exit !(v >= t) }'; then

                warn "7-day disk average is ${AVG}%"

            else
                ok "7-day disk usage is within limits"
            fi

            # ----------------------------------------------------
            # Docker CPU
            # ----------------------------------------------------

            IFS='|' read -r NAME COUNT AVG MAX < <(
                calculate_stats "DOCKER_CPU" "${DOCKER_CPU_VALUES[@]}"
            )

            info "Docker CPU      : samples=${COUNT} avg=${AVG}% peak=${MAX}%"

            if [[ "$AVG" != "NA" ]]; then

                if awk -v v="$MAX" -v t="$DOCKER_CPU_PEAK_WARNING" \
                    'BEGIN { exit !(v >= t) }'; then

                    warn "7-day Docker CPU peak reached ${MAX}%"

                elif awk -v v="$AVG" -v t="$DOCKER_CPU_AVG_WARNING" \
                    'BEGIN { exit !(v >= t) }'; then

                    warn "7-day Docker CPU average is ${AVG}%"

                else
                    ok "7-day Docker CPU usage is within limits"
                fi

            else
                warn "No valid Docker CPU metrics available"
            fi

            # ----------------------------------------------------
            # Docker RAM %
            # ----------------------------------------------------

            IFS='|' read -r NAME COUNT AVG MAX < <(
                calculate_stats "DOCKER_RAM" "${DOCKER_RAM_VALUES[@]}"
            )

            info "Docker RAM      : samples=${COUNT} avg=${AVG}% peak=${MAX}%"

            if [[ "$AVG" != "NA" ]]; then

                if awk -v v="$MAX" -v t="$DOCKER_RAM_PEAK_WARNING" \
                    'BEGIN { exit !(v >= t) }'; then

                    critical "7-day Docker RAM peak reached ${MAX}%"

                elif awk -v v="$AVG" -v t="$DOCKER_RAM_AVG_WARNING" \
                    'BEGIN { exit !(v >= t) }'; then

                    warn "7-day Docker RAM average is ${AVG}%"

                else
                    ok "7-day Docker RAM usage is within limits"
                fi

            else
                warn "No valid Docker RAM metrics available"
            fi

            # ----------------------------------------------------
            # Docker memory MB
            # ----------------------------------------------------

            IFS='|' read -r NAME COUNT AVG MAX < <(
                calculate_stats "DOCKER_MEMORY_MB" "${DOCKER_MEM_MB_VALUES[@]}"
            )

            info "Docker memory   : samples=${COUNT} avg=${AVG} MB peak=${MAX} MB"

            # ----------------------------------------------------
            # Docker reclaimable
            # ----------------------------------------------------

            IFS='|' read -r NAME COUNT AVG MAX < <(
                calculate_stats "DOCKER_RECLAIMABLE" "${DOCKER_RECLAIMABLE_VALUES[@]}"
            )

            info "Docker reclaimable disk : samples=${COUNT} avg=${AVG} MB peak=${MAX} MB"

        fi
    fi
fi

# ============================================================
# DOCKER DEEP CHECK
# ============================================================

section "DOCKER DEEP CHECK"

if ! command_exists docker; then

    critical "Docker is not installed"

elif ! docker info >/dev/null 2>&1; then

    critical "Docker daemon is not responding"

else

    ok "Docker daemon is responding"

    DOCKER_VERSION="$(
        docker version --format '{{.Server.Version}}' \
        2>/dev/null || true
    )"

    if [[ -n "$DOCKER_VERSION" ]]; then
        info "Docker server version : ${DOCKER_VERSION}"
    fi

    CONTAINER_COUNT="$(
        docker ps -a -q 2>/dev/null | wc -l
    )"

    RUNNING_COUNT="$(
        docker ps -q 2>/dev/null | wc -l
    )"

    STOPPED_COUNT="$(
        docker ps -a --filter "status=exited" -q 2>/dev/null | wc -l
    )"

    info "Containers : ${CONTAINER_COUNT}"
    info "Running    : ${RUNNING_COUNT}"
    info "Stopped    : ${STOPPED_COUNT}"

    if (( STOPPED_COUNT > 0 )); then
        warn "${STOPPED_COUNT} stopped Docker container(s)"
    else
        ok "No stopped Docker containers"
    fi

    # --------------------------------------------------------
    # Health status
    # --------------------------------------------------------

    while IFS= read -r CONTAINER_NAME; do

        [[ -z "$CONTAINER_NAME" ]] && continue

        HEALTH="$(
            docker inspect \
                --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
                "$CONTAINER_NAME" \
                2>/dev/null || echo "unknown"
        )"

        case "$HEALTH" in

            unhealthy)
                critical "Container ${CONTAINER_NAME} is unhealthy"
                ;;

            starting)
                warn "Container ${CONTAINER_NAME} healthcheck is still starting"
                ;;

            healthy)
                ok "Container ${CONTAINER_NAME} healthcheck is healthy"
                ;;

            none)
                info "Container ${CONTAINER_NAME} has no Docker healthcheck"
                ;;

            *)
                warn "Unable to determine health of ${CONTAINER_NAME}"
                ;;

        esac

        RESTART_COUNT="$(
            docker inspect \
                --format '{{.RestartCount}}' \
                "$CONTAINER_NAME" \
                2>/dev/null || echo 0
        )"

        if [[ "$RESTART_COUNT" =~ ^[0-9]+$ ]]; then

            info "${CONTAINER_NAME} restart count : ${RESTART_COUNT}"

            if (( RESTART_COUNT >= 10 )); then
                critical "${CONTAINER_NAME} has restarted ${RESTART_COUNT} times"
            elif (( RESTART_COUNT >= 3 )); then
                warn "${CONTAINER_NAME} has restarted ${RESTART_COUNT} times"
            else
                ok "${CONTAINER_NAME} restart count is normal"
            fi

        fi

    done < <(docker ps -a --format '{{.Names}}' 2>/dev/null)

    # --------------------------------------------------------
    # Docker volumes
    # --------------------------------------------------------

    VOLUME_COUNT="$(
        docker volume ls -q 2>/dev/null | wc -l
    )"

    info "Docker volumes : ${VOLUME_COUNT}"

    if docker system df -v >/dev/null 2>&1; then
        ok "Detailed Docker disk/volume information available"
    else
        warn "Unable to inspect detailed Docker disk usage"
    fi

    if docker system df >/dev/null 2>&1; then
        docker system df | tee -a "$TMP_REPORT"
    else
        warn "Unable to retrieve Docker system disk usage"
    fi

    # --------------------------------------------------------
    # PostgreSQL container
    # --------------------------------------------------------

    POSTGRES_CONTAINER="$(
        docker ps \
            --format '{{.Names}}' 2>/dev/null |
        grep -Ei 'postgres|supabase-db' |
        head -n 1 || true
    )

fi

# ============================================================
# POSTGRESQL
# ============================================================

section "POSTGRESQL"

if [[ -n "$POSTGRES_CONTAINER" ]]; then

    ok "PostgreSQL container: ${POSTGRES_CONTAINER}"

    PG_VERSION="$(
        docker exec "$POSTGRES_CONTAINER" \
        psql -U postgres -d postgres -tAc 'SELECT version();' \
        2>/dev/null || true
    )"

    if [[ -n "$PG_VERSION" ]]; then
        info "PostgreSQL : ${PG_VERSION}"
    else
        warn "PostgreSQL version query failed"
    fi

    DB_SIZE_OUTPUT="$(
        docker exec "$POSTGRES_CONTAINER" \
        psql -U postgres -d postgres -tAc \
        "SELECT datname || '|' || pg_size_pretty(pg_database_size(datname))
         FROM pg_database
         WHERE datallowconn = true
         ORDER BY pg_database_size(datname) DESC;" \
        2>/dev/null || true
    )"

    if [[ -n "$DB_SIZE_OUTPUT" ]]; then

        while IFS='|' read -r DB_NAME DB_SIZE; do
            [[ -z "$DB_NAME" ]] && continue
            info "Database ${DB_NAME}: ${DB_SIZE}"
        done <<< "$DB_SIZE_OUTPUT"

    else
        warn "Unable to retrieve database sizes"
    fi

    PG_CONNECTIONS="$(
        docker exec "$POSTGRES_CONTAINER" \
        psql -U postgres -d postgres -tAc \
        "SELECT count(*) FROM pg_stat_activity;" \
        2>/dev/null || true
    )"

    if [[ "$PG_CONNECTIONS" =~ ^[0-9]+$ ]]; then

        info "PostgreSQL connections : ${PG_CONNECTIONS}"

        if (( PG_CONNECTIONS >= 150 )); then
            warn "PostgreSQL has ${PG_CONNECTIONS} active connections"
        else
            ok "PostgreSQL connection count is normal"
        fi

    else
        warn "Unable to determine PostgreSQL connections"
    fi

    LONG_QUERY_OUTPUT="$(
        docker exec "$POSTGRES_CONTAINER" \
        psql -U postgres -d postgres -tAc \
        "SELECT pid || '|' ||
                round(EXTRACT(EPOCH FROM (now() - query_start)))::bigint || '|' ||
                left(regexp_replace(query, '[[:space:]]+', ' ', 'g'), 120)
         FROM pg_stat_activity
         WHERE state <> 'idle'
           AND query_start IS NOT NULL
           AND now() - query_start > interval '${LONG_QUERY_SECONDS} seconds'
         ORDER BY query_start;" \
        2>/dev/null || true
    )"

    if [[ -n "$LONG_QUERY_OUTPUT" ]]; then

        critical "Long-running PostgreSQL query detected"

        while IFS='|' read -r PID DURATION QUERY; do
            info "PID=${PID} duration=${DURATION}s query=${QUERY}"
        done <<< "$LONG_QUERY_OUTPUT"

    else
        ok "No PostgreSQL query longer than ${LONG_QUERY_SECONDS}s"
    fi

else

    critical "No running PostgreSQL container detected"

fi

# ============================================================
# Sofo Spiti DATABASE
# ============================================================

section "Sofo Spiti DATABASE"

if [[ -n "$POSTGRES_CONTAINER" ]]; then

    TELEMETRY_EXISTS="$(
        docker exec "$POSTGRES_CONTAINER" \
        psql -U postgres -d postgres -tAc \
        "SELECT to_regclass('public.device_telemetry') IS NOT NULL;" \
        2>/dev/null || true
    )"

    if [[ "$TELEMETRY_EXISTS" == "t" ]]; then

        TELEMETRY_COUNT="$(
            docker exec "$POSTGRES_CONTAINER" \
            psql -U postgres -d postgres -tAc \
            "SELECT count(*) FROM public.device_telemetry;" \
            2>/dev/null || true
        )"

        info "device_telemetry rows : ${TELEMETRY_COUNT}"

        TELEMETRY_OLD="$(
            docker exec "$POSTGRES_CONTAINER" \
            psql -U postgres -d postgres -tAc \
            "SELECT count(*)
             FROM public.device_telemetry
             WHERE created_at < now() - interval '7 days';" \
            2>/dev/null || true
        )"

        if [[ "$TELEMETRY_OLD" =~ ^[0-9]+$ ]]; then

            info "Telemetry older than 7 days : ${TELEMETRY_OLD}"

            if (( TELEMETRY_OLD > 0 )); then
                warn "Telemetry older than 7 days remains"
            else
                ok "Telemetry retention is within 7 days"
            fi

        else
            warn "Unable to check telemetry retention"
        fi

    else
        info "public.device_telemetry does not exist"
    fi

    WEBHOOK_EXISTS="$(
        docker exec "$POSTGRES_CONTAINER" \
        psql -U postgres -d postgres -tAc \
        "SELECT to_regclass('public.external_webhooks') IS NOT NULL;" \
        2>/dev/null || true
    )"

    if [[ "$WEBHOOK_EXISTS" == "t" ]]; then

        WEBHOOK_COUNT="$(
            docker exec "$POSTGRES_CONTAINER" \
            psql -U postgres -d postgres -tAc \
            "SELECT count(*) FROM public.external_webhooks;" \
            2>/dev/null || true
        )"

        info "external_webhooks rows : ${WEBHOOK_COUNT}"

        if [[ "$WEBHOOK_COUNT" =~ ^[0-9]+$ ]]; then
            ok "Webhook table is accessible"
        else
            warn "Unable to count external_webhooks"
        fi

    else
        info "public.external_webhooks does not exist"
    fi

fi

# ============================================================
# BACKUPS
# ============================================================

section "BACKUPS"

# ------------------------------------------------------------
# Local backup
# ------------------------------------------------------------

if [[ -d "$BACKUP_DIR" ]]; then

    LATEST_BACKUP="$(
        find "$BACKUP_DIR" \
            -type f \
            -printf '%T@ %p\n' \
            2>/dev/null |
        sort -nr |
        head -n 1
    )"

    if [[ -n "$LATEST_BACKUP" ]]; then

        BACKUP_TIMESTAMP="${LATEST_BACKUP%% *}"
        BACKUP_FILE="${LATEST_BACKUP#* }"

        NOW_TS="$(date +%s)"

        BACKUP_AGE_HOURS="$(
            awk \
                -v now="$NOW_TS" \
                -v ts="$BACKUP_TIMESTAMP" \
                'BEGIN { printf "%.1f", (now-ts)/3600 }'
        )"

        info "Latest local backup : ${BACKUP_FILE}"
        info "Backup age          : ${BACKUP_AGE_HOURS} hours"

        if awk \
            -v age="$BACKUP_AGE_HOURS" \
            -v max="$BACKUP_MAX_AGE_HOURS" \
            'BEGIN { exit !(age > max) }'; then

            critical "Latest local backup is too old"

        else
            ok "Latest local backup is recent"
        fi

        BACKUP_SIZE_BYTES="$(
            stat -c '%s' "$BACKUP_FILE" 2>/dev/null || echo 0
        )"

        if [[ "$BACKUP_SIZE_BYTES" =~ ^[0-9]+$ ]]; then

            BACKUP_SIZE_MB="$(
                awk \
                    -v b="$BACKUP_SIZE_BYTES" \
                    'BEGIN { printf "%.1f", b/1024/1024 }'
            )"

            info "Latest backup size : ${BACKUP_SIZE_MB} MB"

            if (( BACKUP_SIZE_BYTES == 0 )); then
                critical "Latest backup file is empty"
            else
                ok "Latest backup file is non-empty"
            fi

        fi

    else
        critical "No local PostgreSQL backups found"
    fi

else
    critical "Backup directory does not exist: ${BACKUP_DIR}"
fi

# ------------------------------------------------------------
# External Scaleway backup
# ------------------------------------------------------------

if [[ -n "$SCW_RCLONE_REMOTE" ]] &&
   [[ -n "$SCW_BACKUP_PATH" ]]; then

    if command_exists rclone; then

        info "Checking external backup: ${SCW_RCLONE_REMOTE}:${SCW_BACKUP_PATH}"

        if RCLONE_LIST="$(
            rclone lsf \
                "${SCW_RCLONE_REMOTE}:${SCW_BACKUP_PATH}" \
                --files-only \
                2>/dev/null
        )"; then

            if [[ -n "$RCLONE_LIST" ]]; then
                ok "External Scaleway backup is accessible"
            else
                critical "External backup location is empty"
            fi

        else
            critical "Unable to access external backup location"
        fi

    else
        warn "rclone is not installed; external backup cannot be checked"
    fi

else
    info "External Scaleway backup check is not configured"
fi

# ============================================================
# RESTORE TEST
# ============================================================

section "BACKUP RESTORE TEST"

if [[ -f "$RESTORE_TEST_FILE" ]]; then

    RESTORE_TEST_DATE="$(cat "$RESTORE_TEST_FILE" 2>/dev/null || true)"

    if [[ "$RESTORE_TEST_DATE" =~ ^[0-9]+$ ]]; then

        NOW_TS="$(date +%s)"

        AGE_DAYS="$(
            awk \
                -v now="$NOW_TS" \
                -v test="$RESTORE_TEST_DATE" \
                'BEGIN { printf "%.1f", (now-test)/86400 }'
        )"

        info "Last restore test age : ${AGE_DAYS} days"

        if awk \
            -v age="$AGE_DAYS" \
            -v max="$RESTORE_TEST_MAX_DAYS" \
            'BEGIN { exit !(age > max) }'; then

            warn "Backup restore test is older than ${RESTORE_TEST_MAX_DAYS} days"

        else
            ok "Backup restore test is recent"
        fi

    else
        warn "Restore test marker contains invalid timestamp"
    fi

else
    warn "No restore test marker found"
fi

# ============================================================
# SYSTEM / SECURITY
# ============================================================

section "SYSTEM / SECURITY"

# ------------------------------------------------------------
# OOM
# ------------------------------------------------------------

OOM_EVENTS="$(
    journalctl \
        -k \
        --since "7 days ago" \
        --no-pager \
        2>/dev/null |
    grep -Ei \
        'out of memory|oom-killer|killed process|memory cgroup out of memory' |
    wc -l
)"

info "OOM events in last 7 days : ${OOM_EVENTS}"

if [[ "$OOM_EVENTS" =~ ^[0-9]+$ ]] && (( OOM_EVENTS > 0 )); then
    critical "OOM/memory pressure events detected during the last 7 days"
else
    ok "No OOM events detected"
fi

# ------------------------------------------------------------
# SSH
# ------------------------------------------------------------

SSH_FAILURES="$(
    journalctl \
        --since "7 days ago" \
        --no-pager \
        2>/dev/null |
    grep -Ei \
        'sshd.*(failed password|authentication failure|invalid user|failed publickey)' |
    wc -l
)"

info "SSH authentication failures in 7 days : ${SSH_FAILURES}"

if [[ "$SSH_FAILURES" =~ ^[0-9]+$ ]] && (( SSH_FAILURES > 0 )); then
    warn "${SSH_FAILURES} SSH authentication failures detected"
else
    ok "No SSH authentication failures detected"
fi

if command_exists sshd; then

    SSH_ROOT_LOGIN="$(
        sshd -T 2>/dev/null |
        awk '$1=="permitrootlogin" {print $2}'
    )"

    SSH_PASSWORD_AUTH="$(
        sshd -T 2>/dev/null |
        awk '$1=="passwordauthentication" {print $2}'
    )"

    info "PermitRootLogin       : ${SSH_ROOT_LOGIN:-unknown}"
    info "PasswordAuthentication: ${SSH_PASSWORD_AUTH:-unknown}"

    if [[ "$SSH_ROOT_LOGIN" == "yes" ]]; then
        warn "Direct root SSH login is enabled"
    else
        ok "Direct root SSH login is disabled"
    fi

    if [[ "$SSH_PASSWORD_AUTH" == "yes" ]]; then
        warn "SSH password authentication is enabled"
    else
        ok "SSH password authentication is disabled"
    fi

fi

# ------------------------------------------------------------
# NTP
# ------------------------------------------------------------

if command_exists timedatectl; then

    NTP_SYNC="$(
        timedatectl show \
            -p NTPSynchronized \
            --value \
            2>/dev/null || true
    )"

    info "NTP synchronized : ${NTP_SYNC:-unknown}"

    if [[ "$NTP_SYNC" == "yes" ]]; then
        ok "System clock is synchronized"
    else
        warn "System clock synchronization is not confirmed"
    fi

fi

# ------------------------------------------------------------
# Debian updates
# ------------------------------------------------------------

if command_exists apt; then

    UPDATES_AVAILABLE="$(
        apt list --upgradable 2>/dev/null |
        grep -v '^Listing...' |
        grep -v '^$' |
        wc -l
    )"

    info "Debian package updates available : ${UPDATES_AVAILABLE}"

    if [[ "$UPDATES_AVAILABLE" =~ ^[0-9]+$ ]]; then

        if (( UPDATES_AVAILABLE > 0 )); then
            warn "${UPDATES_AVAILABLE} Debian package update(s) available"
        else
            ok "Debian packages are up to date"
        fi

    fi

fi

# ============================================================
# NETWORK
# ============================================================

section "NETWORK"

DNS_TEST_HOST="${DNS_TEST_HOST:-cloudflare.com}"

if getent hosts "$DNS_TEST_HOST" >/dev/null 2>&1; then
    ok "DNS resolution works"
else
    critical "DNS resolution failed"
fi

if command_exists curl; then

    if curl \
        --silent \
        --show-error \
        --max-time 10 \
        --head \
        https://1.1.1.1 \
        >/dev/null 2>&1; then

        ok "Outbound HTTPS connectivity works"

    else
        warn "Outbound HTTPS connectivity failed"
    fi

    HTTP_STATUS="$(
        curl \
            --silent \
            --show-error \
            --location \
            --max-time 10 \
            --output /dev/null \
            --write-out '%{http_code}' \
            "https://${SSL_HOSTNAME}" \
            2>/dev/null || echo "000"
    )"

    info "HTTPS ${SSL_HOSTNAME} : HTTP ${HTTP_STATUS}"

    if [[ "$HTTP_STATUS" =~ ^[23][0-9][0-9]$ ]]; then
        ok "HTTPS endpoint responds"
    elif [[ "$HTTP_STATUS" == "000" ]]; then
        warn "HTTPS endpoint could not be reached"
    else
        warn "HTTPS endpoint returned HTTP ${HTTP_STATUS}"
    fi

fi

# ============================================================
# LISTENING PORTS
# ============================================================

section "LISTENING PORTS"

if command_exists ss; then

    LISTENING_PORTS="$(
        ss -lntup 2>/dev/null |
        awk 'NR>1 {
            split($5,a,":")
            port=a[length(a)]
            if (port ~ /^[0-9]+$/)
                print port
        }' |
        sort -nu
    )"

    while IFS= read -r PORT; do

        [[ -z "$PORT" ]] && continue

        EXPECTED="no"

        for EXPECTED_PORT in $EXPECTED_PUBLIC_PORTS; do

            if [[ "$PORT" == "$EXPECTED_PORT" ]]; then
                EXPECTED="yes"
                break
            fi

        done

        if [[ "$EXPECTED" == "yes" ]]; then
            info "Expected listening port : ${PORT}"
        else
            warn "Unexpected listening TCP port : ${PORT}"
        fi

    done <<< "$LISTENING_PORTS"

fi

# ============================================================
# SSL
# ============================================================

section "SSL"

if command_exists openssl; then

    CERT_END_DATE="$(
        echo |
        openssl s_client \
            -connect "${SSL_HOSTNAME}:443" \
            -servername "$SSL_HOSTNAME" \
            2>/dev/null |
        openssl x509 -noout -enddate 2>/dev/null |
        sed 's/^notAfter=//'
    )"

    if [[ -n "$CERT_END_DATE" ]]; then

        CERT_END_TS="$(date -d "$CERT_END_DATE" +%s 2>/dev/null || echo 0)"
        NOW_TS="$(date +%s)"

        if (( CERT_END_TS > 0 )); then

            CERT_DAYS_LEFT="$(
                awk \
                    -v end="$CERT_END_TS" \
                    -v now="$NOW_TS" \
                    'BEGIN { printf "%.0f", (end-now)/86400 }'
            )"

            info "Certificate expires : ${CERT_END_DATE}"
            info "Days remaining      : ${CERT_DAYS_LEFT}"

            if (( CERT_DAYS_LEFT <= 0 )); then
                critical "SSL certificate has expired"
            elif (( CERT_DAYS_LEFT <= SSL_WARNING_DAYS )); then
                warn "SSL certificate expires in ${CERT_DAYS_LEFT} days"
            else
                ok "SSL certificate is valid"
            fi

        else
            warn "Unable to parse SSL certificate expiry"
        fi

    else
        warn "Unable to retrieve SSL certificate"
    fi

fi

# ============================================================
# FINAL STATUS
# ============================================================

section "FINAL STATUS"

info "Warnings  : ${WARNINGS}"
info "Criticals : ${CRITICALS}"
info "Status    : ${STATUS}"

echo "" | tee -a "$TMP_REPORT"

case "$STATUS" in

    OK)
        echo "RESULT: OK" | tee -a "$TMP_REPORT"
        ;;

    WARNING)
        echo "RESULT: WARNING" | tee -a "$TMP_REPORT"
        ;;

    CRITICAL)
        echo "RESULT: CRITICAL" | tee -a "$TMP_REPORT"
        ;;

esac

# ------------------------------------------------------------
# Save report
# ------------------------------------------------------------

REPORT_FILE="${REPORT_DIR}/weekly-$(date '+%G-W%V').txt"

cp "$TMP_REPORT" "$REPORT_FILE"
chmod 600 "$REPORT_FILE"

# ============================================================
# EMAIL ALERT
# ============================================================

if [[ "$STATUS" != "OK" ]]; then

    if command_exists msmtp &&
       [[ -n "$ALERT_EMAIL" ]] &&
       [[ -n "$EMAIL_FROM" ]]; then

        SUBJECT="[Sofo Spiti] Weekly VPS ${STATUS} - $(hostname)"

        {
            echo "From: ${EMAIL_FROM}"
            echo "To: ${ALERT_EMAIL}"
            echo "Subject: ${SUBJECT}"
            echo "Date: $(date -R)"
            echo "MIME-Version: 1.0"
            echo "Content-Type: text/plain; charset=UTF-8"
            echo
            cat "$TMP_REPORT"
        } | msmtp "$ALERT_EMAIL"

        if [[ $? -eq 0 ]]; then
            info "Weekly alert email sent to ${ALERT_EMAIL}"
        else
            warn "Failed to send weekly alert email"
        fi

    else
        warn "msmtp/email configuration unavailable"
    fi

fi

# ============================================================
# EXIT
# ============================================================

if [[ "$STATUS" == "OK" ]]; then
    exit 0
else
    exit 1
fi
