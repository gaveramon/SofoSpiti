#!/usr/bin/env bash

# ============================================================
# Sofo Spiti - Supabase Functional Healthcheck
#
# Checks:
#   1. Auth
#   2. REST / PostgREST
#   3. Storage
#   4. Realtime
#   5. Edge Functions
#
# Requirements:
#   bash
#   curl
#   jq
#   base64
#   websocat
#
# Secrets:
#   loaded from .env
#
# Exit codes:
#   0 = all checks passed
#   1 = one or more checks failed
#   2 = configuration/dependency error
# ============================================================

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SUPABASE_HEALTHCHECK_ENV:-$SCRIPT_DIR/.env}"

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------

if [[ ! -f "$ENV_FILE" ]]; then
    echo "[ERROR] Environment file not found:"
    echo "        $ENV_FILE"
    exit 2
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

: "${SUPABASE_URL:?SUPABASE_URL is required}"
: "${SUPABASE_ANON_KEY:?SUPABASE_ANON_KEY is required}"
: "${SUPABASE_HEALTHCHECK_EMAIL:?SUPABASE_HEALTHCHECK_EMAIL is required}"
: "${SUPABASE_HEALTHCHECK_PASSWORD:?SUPABASE_HEALTHCHECK_PASSWORD is required}"
: "${SUPABASE_EDGE_FUNCTION:?SUPABASE_EDGE_FUNCTION is required}"

SUPABASE_STORAGE_BUCKET="${SUPABASE_STORAGE_BUCKET:-healthcheck}"
SUPABASE_REALTIME_TIMEOUT="${SUPABASE_REALTIME_TIMEOUT:-10}"
SUPABASE_HTTP_TIMEOUT="${SUPABASE_HTTP_TIMEOUT:-15}"

SUPABASE_URL="${SUPABASE_URL%/}"

AUTH_URL="${SUPABASE_URL}/auth/v1"
REST_URL="${SUPABASE_URL}/rest/v1"
STORAGE_URL="${SUPABASE_URL}/storage/v1"
FUNCTION_URL="${SUPABASE_URL}/functions/v1/${SUPABASE_EDGE_FUNCTION}"

# ------------------------------------------------------------
# Dependencies
# ------------------------------------------------------------

REQUIRED_COMMANDS=(
    curl
    jq
    base64
    websocat
)

for cmd in "${REQUIRED_COMMANDS[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "[ERROR] Required command not found: $cmd"
        exit 2
    fi
done

# ------------------------------------------------------------
# Runtime state
# ------------------------------------------------------------

ACCESS_TOKEN=""
USER_ID=""

TEST_ID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || date +%s)"

STORAGE_PATH="healthcheck/${TEST_ID}.txt"
STORAGE_CONTENT="sofospiti-healthcheck-${TEST_ID}"

PASSED=0
FAILED=0

# ------------------------------------------------------------
# Output helpers
# ------------------------------------------------------------

timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

pass() {
    local name="$1"
    local duration="$2"

    printf '[%s] [PASS] %-20s %s ms\n' \
        "$(timestamp)" \
        "$name" \
        "$duration"

    PASSED=$((PASSED + 1))
}

fail() {
    local name="$1"
    local message="$2"
    local duration="${3:-}"

    printf '[%s] [FAIL] %-20s %s' \
        "$(timestamp)" \
        "$name" \
        "$message"

    if [[ -n "$duration" ]]; then
        printf ' (%s ms)' "$duration"
    fi

    printf '\n'

    FAILED=$((FAILED + 1))
}

info() {
    printf '[%s] [INFO] %s\n' "$(timestamp)" "$1"
}

now_ms() {
    date +%s%3N
}

# ------------------------------------------------------------
# HTTP helper
# ------------------------------------------------------------

http_request() {
    local method="$1"
    local url="$2"
    local body="${3:-}"
    local auth="${4:-}"

    local args=(
        --silent
        --show-error
        --location
        --max-time "$SUPABASE_HTTP_TIMEOUT"
        --connect-timeout 5
        --request "$method"
        --header "apikey: ${SUPABASE_ANON_KEY}"
        --header "Content-Type: application/json"
        --write-out $'\n%{http_code}'
    )

    if [[ -n "$auth" ]]; then
        args+=(--header "Authorization: Bearer ${auth}")
    fi

    if [[ -n "$body" ]]; then
        args+=(--data "$body")
    fi

    curl "${args[@]}" "$url"
}

# ------------------------------------------------------------
# Check 1 - AUTH
# ------------------------------------------------------------

check_auth() {

    local start
    local end
    local duration

    start="$(now_ms)"

    local login_body
    login_body="$(jq -n \
        --arg email "$SUPABASE_HEALTHCHECK_EMAIL" \
        --arg password "$SUPABASE_HEALTHCHECK_PASSWORD" \
        '{
            email: $email,
            password: $password
        }'
    )"

    local response
    response="$(http_request \
        POST \
        "${AUTH_URL}/token?grant_type=password" \
        "$login_body"
    )"

    local http_code
    http_code="$(printf '%s\n' "$response" | tail -n1)"

    local body
    body="$(printf '%s\n' "$response" | sed '$d')"

    if [[ "$http_code" != "200" ]]; then
        fail "Auth" "login HTTP ${http_code}"
        return 1
    fi

    ACCESS_TOKEN="$(printf '%s' "$body" | jq -r '.access_token // empty')"

    if [[ -z "$ACCESS_TOKEN" ]]; then
        fail "Auth" "no access_token returned"
        return 1
    fi

    USER_ID="$(printf '%s' "$body" | jq -r '.user.id // empty')"

    if [[ -z "$USER_ID" ]]; then
        fail "Auth" "no user.id returned"
        return 1
    fi

    # Validate the JWT by asking GoTrue for the current user.
    response="$(http_request \
        GET \
        "${AUTH_URL}/user" \
        "" \
        "$ACCESS_TOKEN"
    )"

    http_code="$(printf '%s\n' "$response" | tail -n1)"
    body="$(printf '%s\n' "$response" | sed '$d')"

    if [[ "$http_code" != "200" ]]; then
        fail "Auth" "/user HTTP ${http_code}"
        return 1
    fi

    local returned_user
    returned_user="$(printf '%s' "$body" | jq -r '.id // empty')"

    if [[ "$returned_user" != "$USER_ID" ]]; then
        fail "Auth" "JWT user mismatch"
        return 1
    fi

    end="$(now_ms)"
    duration=$((end - start))

    pass "Auth" "$duration"
    return 0
}

# ------------------------------------------------------------
# Check 2 - REST / POSTGREST
# ------------------------------------------------------------

check_rest() {

    if [[ -z "$ACCESS_TOKEN" ]]; then
        fail "REST/PostgREST" "no JWT available"
        return 1
    fi

    local start
    local end
    local duration

    start="$(now_ms)"

    local response
    response="$(http_request \
        POST \
        "${REST_URL}/rpc/ping" \
        '{}' \
        "$ACCESS_TOKEN"
    )"

    local http_code
    http_code="$(printf '%s\n' "$response" | tail -n1)"

    local body
    body="$(printf '%s\n' "$response" | sed '$d')"

    if [[ "$http_code" != "200" ]]; then
        fail "REST/PostgREST" "HTTP ${http_code}"
        return 1
    fi

    local status
    status="$(printf '%s' "$body" | jq -r '.status // empty')"

    if [[ "$status" != "ok" ]]; then
        fail "REST/PostgREST" "RPC returned invalid response"
        return 1
    fi

    end="$(now_ms)"
    duration=$((end - start))

    pass "REST/PostgREST" "$duration"
    return 0
}

# ------------------------------------------------------------
# Check 3 - STORAGE
# ------------------------------------------------------------

check_storage() {

    if [[ -z "$ACCESS_TOKEN" ]]; then
        fail "Storage" "no JWT available"
        return 1
    fi

    local start
    local end
    local duration

    start="$(now_ms)"

    local upload_url
    upload_url="${STORAGE_URL}/object/${SUPABASE_STORAGE_BUCKET}/${STORAGE_PATH}"

    local response
    response="$(
        curl \
            --silent \
            --show-error \
            --location \
            --max-time "$SUPABASE_HTTP_TIMEOUT" \
            --connect-timeout 5 \
            --request POST \
            --header "apikey: ${SUPABASE_ANON_KEY}" \
            --header "Authorization: Bearer ${ACCESS_TOKEN}" \
            --header "Content-Type: text/plain" \
            --header "x-upsert: false" \
            --data "$STORAGE_CONTENT" \
            --write-out $'\n%{http_code}' \
            "$upload_url"
    )"

    local http_code
    http_code="$(printf '%s\n' "$response" | tail -n1)"

    if [[ "$http_code" != "200" && "$http_code" != "201" ]]; then
        fail "Storage" "upload HTTP ${http_code}"
        return 1
    fi

    # --------------------------------------------------------
    # Download
    # --------------------------------------------------------

    local temp_file
    temp_file="$(mktemp)"

    response="$(
        curl \
            --silent \
            --show-error \
            --location \
            --max-time "$SUPABASE_HTTP_TIMEOUT" \
            --connect-timeout 5 \
            --request GET \
            --header "apikey: ${SUPABASE_ANON_KEY}" \
            --header "Authorization: Bearer ${ACCESS_TOKEN}" \
            --output "$temp_file" \
            --write-out '%{http_code}' \
            "$upload_url"
    )"

    http_code="$response"

    if [[ "$http_code" != "200" ]]; then
        rm -f "$temp_file"

        # Attempt cleanup.
        curl \
            --silent \
            --show-error \
            --location \
            --max-time "$SUPABASE_HTTP_TIMEOUT" \
            --request DELETE \
            --header "apikey: ${SUPABASE_ANON_KEY}" \
            --header "Authorization: Bearer ${ACCESS_TOKEN}" \
            "$upload_url" \
            >/dev/null 2>&1 || true

        fail "Storage" "download HTTP ${http_code}"
        return 1
    fi

    local downloaded_content
    downloaded_content="$(cat "$temp_file")"

    rm -f "$temp_file"

    if [[ "$downloaded_content" != "$STORAGE_CONTENT" ]]; then

        curl \
            --silent \
            --show-error \
            --location \
            --max-time "$SUPABASE_HTTP_TIMEOUT" \
            --request DELETE \
            --header "apikey: ${SUPABASE_ANON_KEY}" \
            --header "Authorization: Bearer ${ACCESS_TOKEN}" \
            "$upload_url" \
            >/dev/null 2>&1 || true

        fail "Storage" "downloaded content mismatch"
        return 1
    fi

    # --------------------------------------------------------
    # Delete
    # --------------------------------------------------------

    response="$(
        curl \
            --silent \
            --show-error \
            --location \
            --max-time "$SUPABASE_HTTP_TIMEOUT" \
            --connect-timeout 5 \
            --request DELETE \
            --header "apikey: ${SUPABASE_ANON_KEY}" \
            --header "Authorization: Bearer ${ACCESS_TOKEN}" \
            --write-out $'\n%{http_code}' \
            "$upload_url"
    )"

    http_code="$(printf '%s\n' "$response" | tail -n1)"

    if [[ "$http_code" != "200" ]]; then
        fail "Storage" "delete HTTP ${http_code}"
        return 1
    fi

    end="$(now_ms)"
    duration=$((end - start))

    pass "Storage" "$duration"
    return 0
}

# ------------------------------------------------------------
# Check 4 - REALTIME
# ------------------------------------------------------------

check_realtime() {

    if [[ -z "$ACCESS_TOKEN" ]]; then
        fail "Realtime" "no JWT available"
        return 1
    fi

    local start
    local end
    local duration

    start="$(now_ms)"

    local realtime_url

    realtime_url="${SUPABASE_URL}"
    realtime_url="${realtime_url/http:\/\//ws:\/\/}"
    realtime_url="${realtime_url/https:\/\//wss:\/\/}"

    realtime_url="${realtime_url}/realtime/v1/websocket?apikey=${SUPABASE_ANON_KEY}&vsn=1.0.0"

    local output_file
    local pid

    output_file="$(mktemp)"

    # --------------------------------------------------------
    # WebSocket client
    #
    # websocat keeps the connection open while the Bash script
    # sends the subscribe message through stdin.
    # --------------------------------------------------------

    {
        sleep 1

        printf '%s\n' \
            "$(jq -cn \
                --arg token "$ACCESS_TOKEN" \
                '{
                    topic: "realtime:healthcheck",
                    event: "phx_join",
                    payload: {
                        config: {
                            broadcast: {
                                self: false
                            },
                            presence: {
                                key: ""
                            },
                            postgres_changes: [
                                {
                                    event: "INSERT",
                                    schema: "healthcheck",
                                    table: "realtime_test"
                                }
                            ]
                        },
                        access_token: $token
                    },
                    ref: "1"
                }'
            )"

        sleep 2

        # ----------------------------------------------------
        # Trigger actual PostgreSQL INSERT.
        # ----------------------------------------------------

        local insert_body

        insert_body="$(jq -n \
            --arg test_id "$TEST_ID" \
            '{
                test_id: $test_id
            }'
        )"

        curl \
            --silent \
            --show-error \
            --location \
            --max-time "$SUPABASE_HTTP_TIMEOUT" \
            --request POST \
            --header "apikey: ${SUPABASE_ANON_KEY}" \
            --header "Authorization: Bearer ${ACCESS_TOKEN}" \
            --header "Content-Type: application/json" \
            --data "$insert_body" \
            "${REST_URL}/realtime_test" \
            >/dev/null 2>&1 || true

        sleep "$SUPABASE_REALTIME_TIMEOUT"

    } | timeout "$((SUPABASE_REALTIME_TIMEOUT + 8))" \
        websocat "$realtime_url" \
        >"$output_file" 2>/dev/null &

    pid=$!

    wait "$pid" 2>/dev/null || true

    # --------------------------------------------------------
    # Check received event
    # --------------------------------------------------------

    if grep -q "\"test_id\":\"${TEST_ID}\"" "$output_file"; then

        rm -f "$output_file"

        end="$(now_ms)"
        duration=$((end - start))

        pass "Realtime" "$duration"
        return 0
    fi

    # --------------------------------------------------------
    # Cleanup test row
    # --------------------------------------------------------

    curl \
        --silent \
        --show-error \
        --location \
        --max-time "$SUPABASE_HTTP_TIMEOUT" \
        --request DELETE \
        --header "apikey: ${SUPABASE_ANON_KEY}" \
        --header "Authorization: Bearer ${ACCESS_TOKEN}" \
        "${REST_URL}/realtime_test?test_id=eq.${TEST_ID}" \
        >/dev/null 2>&1 || true

    rm -f "$output_file"

    fail "Realtime" "no PostgreSQL realtime event received"
    return 1
}

# ------------------------------------------------------------
# Check 5 - EDGE FUNCTION
# ------------------------------------------------------------

check_edge_function() {

    if [[ -z "$ACCESS_TOKEN" ]]; then
        fail "Edge Function" "no JWT available"
        return 1
    fi

    local start
    local end
    local duration

    start="$(now_ms)"

    local response

    response="$(
        curl \
            --silent \
            --show-error \
            --location \
            --max-time "$SUPABASE_HTTP_TIMEOUT" \
            --connect-timeout 5 \
            --request POST \
            --header "apikey: ${SUPABASE_ANON_KEY}" \
            --header "Authorization: Bearer ${ACCESS_TOKEN}" \
            --header "Content-Type: application/json" \
            --data '{}' \
            --write-out $'\n%{http_code}' \
            "$FUNCTION_URL"
    )"

    local http_code
    http_code="$(printf '%s\n' "$response" | tail -n1)"

    local body
    body="$(printf '%s\n' "$response" | sed '$d')"

    if [[ "$http_code" != "200" ]]; then
        fail "Edge Function" "HTTP ${http_code}"
        return 1
    fi

    local status
    status="$(printf '%s' "$body" | jq -r '.status // empty')"

    if [[ "$status" != "ok" ]]; then
        fail "Edge Function" "invalid response"
        return 1
    fi

    end="$(now_ms)"
    duration=$((end - start))

    pass "Edge Function" "$duration"
    return 0
}

# ------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------

cleanup() {

    if [[ -z "$ACCESS_TOKEN" ]]; then
        return 0
    fi

    # Remove possible Realtime test row.
    curl \
        --silent \
        --show-error \
        --location \
        --max-time 5 \
        --request DELETE \
        --header "apikey: ${SUPABASE_ANON_KEY}" \
        --header "Authorization: Bearer ${ACCESS_TOKEN}" \
        "${REST_URL}/realtime_test?test_id=eq.${TEST_ID}" \
        >/dev/null 2>&1 || true

    # Remove possible storage object.
    curl \
        --silent \
        --show-error \
        --location \
        --max-time 5 \
        --request DELETE \
        --header "apikey: ${SUPABASE_ANON_KEY}" \
        --header "Authorization: Bearer ${ACCESS_TOKEN}" \
        "${STORAGE_URL}/object/${SUPABASE_STORAGE_BUCKET}/${STORAGE_PATH}" \
        >/dev/null 2>&1 || true
}

trap cleanup EXIT

# ------------------------------------------------------------
# Main
# ------------------------------------------------------------

echo
echo "============================================================"
echo " Sofo Spiti - Supabase Functional Healthcheck"
echo "============================================================"
echo
echo "Supabase: ${SUPABASE_URL}"
echo "Started : $(timestamp)"
echo

check_auth
check_rest
check_storage
check_realtime
check_edge_function

echo
echo "============================================================"
echo " Result"
echo "============================================================"
echo
echo "Passed: ${PASSED}"
echo "Failed: ${FAILED}"
echo

if [[ "$FAILED" -eq 0 ]]; then
    echo "SUPABASE FUNCTIONAL STATUS: PASS"
    echo
    exit 0
else
    echo "SUPABASE FUNCTIONAL STATUS: FAIL"
    echo
    exit 1
fi
