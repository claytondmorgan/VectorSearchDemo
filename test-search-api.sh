#!/bin/bash
#
# Test script for the Java Search Service API (Product Search)
#
# Usage:
#   ./test-search-api.sh                              # localhost, non-verbose
#   ./test-search-api.sh http://my-alb.com             # custom URL, non-verbose
#   ./test-search-api.sh -v                            # localhost, verbose
#   ./test-search-api.sh -v http://my-alb.com          # custom URL, verbose
#   ./test-search-api.sh http://my-alb.com --verbose   # custom URL, verbose
#
# Flags:
#   -v, --verbose   Show curl commands, response details, timing breakdown,
#                   performance stats, and estimated AWS cost per test run
#
# Prerequisites:
#   - Java search service running
#   - Python inference service running (for /embed delegation)
#   - Database with ingested products
#   - python3 available on PATH
#

# ── Argument Parsing ──────────────────────────────────────────
VERBOSE=false
BASE_URL="http://localhost:8080"
for arg in "$@"; do
    case "$arg" in
        -v|--verbose) VERBOSE=true ;;
        *) BASE_URL="$arg" ;;
    esac
done

# ── Global State ──────────────────────────────────────────────
PASS=0
FAIL=0
WARN=0
TEST_NUM=0
TOTAL_REQUESTS=0
TOTAL_BYTES_DOWN=0
TOTAL_BYTES_UP=0
SUITE_START=$(python3 -c 'import time; print(int(time.time()*1000))')

# ── Colors ────────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
DIM='\033[2m'
NC='\033[0m'

# ── Curl write-out format (tab-separated metrics on last line) ─
CURL_FMT='\n%{http_code}\t%{time_total}\t%{size_download}\t%{size_upload}\t%{time_namelookup}\t%{time_connect}\t%{time_starttransfer}'

# ── Utility Functions ─────────────────────────────────────────

format_bytes() {
    echo "$1" | awk '{
        if ($1 >= 1048576) printf "%.1f MB", $1/1048576
        else if ($1 >= 1024) printf "%.1f KB", $1/1024
        else printf "%d B", $1
    }'
}

ms_from_s() {
    echo "$1" | awk '{printf "%d", $1 * 1000}'
}

# Parse curl response into global metric variables
parse_metrics() {
    local raw="$1"
    RESP_BODY=$(echo "$raw" | sed '$d')
    local mline
    mline=$(echo "$raw" | tail -n1)
    RESP_CODE=$(echo "$mline" | cut -f1)
    RESP_TIME_MS=$(ms_from_s "$(echo "$mline" | cut -f2)")
    RESP_BYTES_DOWN=$(echo "$mline" | cut -f3 | awk '{printf "%d", $1}')
    RESP_BYTES_UP=$(echo "$mline" | cut -f4 | awk '{printf "%d", $1}')
    RESP_DNS_MS=$(ms_from_s "$(echo "$mline" | cut -f5)")
    RESP_CONNECT_MS=$(ms_from_s "$(echo "$mline" | cut -f6)")
    RESP_TTFB_MS=$(ms_from_s "$(echo "$mline" | cut -f7)")
    TOTAL_REQUESTS=$((TOTAL_REQUESTS + 1))
    TOTAL_BYTES_DOWN=$((TOTAL_BYTES_DOWN + RESP_BYTES_DOWN))
    TOTAL_BYTES_UP=$((TOTAL_BYTES_UP + RESP_BYTES_UP))
}

# Print verbose metrics line
print_metrics() {
    if [ "$VERBOSE" = true ]; then
        echo "      HTTP $RESP_CODE | $(format_bytes $RESP_BYTES_DOWN) | ${RESP_TIME_MS}ms (dns:${RESP_DNS_MS}ms connect:${RESP_CONNECT_MS}ms ttfb:${RESP_TTFB_MS}ms)"
    fi
}

# ── Header ────────────────────────────────────────────────────
echo "=============================================="
echo "Java Search Service API Tests"
echo "Base URL: $BASE_URL"
[ "$VERBOSE" = true ] && echo "Mode:     VERBOSE"
echo "=============================================="
echo ""

# ── Test Functions ────────────────────────────────────────────

run_test() {
    local name="$1"
    local method="$2"
    local endpoint="$3"
    local data="$4"
    local expected_status="$5"
    local check_field="$6"
    local check_value="$7"

    ((TEST_NUM++))

    if [ "$VERBOSE" = true ]; then
        echo ""
        echo -e "  ${CYAN}[$TEST_NUM] $name${NC}"
        if [ "$method" == "GET" ]; then
            echo "      \$ curl -s \"${BASE_URL}${endpoint}\""
        else
            echo "      \$ curl -s -X POST \"${BASE_URL}${endpoint}\" \\"
            echo "          -H \"Content-Type: application/json\" \\"
            echo "          -d '$data'"
        fi
    else
        printf "%-50s" "$name"
    fi

    local response
    if [ "$method" == "GET" ]; then
        response=$(curl -s -w "$CURL_FMT" "$BASE_URL$endpoint")
    else
        response=$(curl -s -w "$CURL_FMT" -X POST "$BASE_URL$endpoint" \
            -H "Content-Type: application/json" \
            -d "$data")
    fi

    parse_metrics "$response"
    print_metrics

    if [ "$RESP_CODE" != "$expected_status" ]; then
        if [ "$VERBOSE" = true ]; then
            echo "      Response: $RESP_BODY"
            echo -e "      ${RED}FAIL${NC} (expected HTTP $expected_status, got $RESP_CODE)"
        else
            echo -e "${RED}FAIL${NC} (expected HTTP $expected_status, got $RESP_CODE)"
            echo "  Response: $RESP_BODY"
        fi
        ((FAIL++))
        return 1
    fi

    if [ -n "$check_field" ]; then
        local actual_value
        actual_value=$(echo "$RESP_BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$check_field', 'MISSING'))" 2>/dev/null)
        if [ "$actual_value" != "$check_value" ]; then
            if [ "$VERBOSE" = true ]; then
                echo "      Check: $check_field = \"$actual_value\" (expected \"$check_value\")"
                echo -e "      ${RED}FAIL${NC}"
            else
                echo -e "${RED}FAIL${NC} ($check_field: expected '$check_value', got '$actual_value')"
            fi
            ((FAIL++))
            return 1
        fi
        [ "$VERBOSE" = true ] && echo "      Check: $check_field = \"$check_value\" ✓"
    fi

    if [ "$VERBOSE" = true ]; then
        echo -e "      ${GREEN}PASS${NC}"
    else
        echo -e "${GREEN}PASS${NC}"
    fi
    ((PASS++))
    return 0
}

run_search_test() {
    local name="$1"
    local query="$2"
    local extra_params="$3"
    local min_results="$4"
    local check_similarity="$5"

    ((TEST_NUM++))

    # Build the request body
    local data
    if [ -n "$extra_params" ]; then
        data="{\"query\": \"$query\", $extra_params}"
    else
        data="{\"query\": \"$query\"}"
    fi

    if [ "$VERBOSE" = true ]; then
        echo ""
        echo -e "  ${CYAN}[$TEST_NUM] $name${NC}"
        echo "      \$ curl -s -X POST \"${BASE_URL}/api/search\" \\"
        echo "          -H \"Content-Type: application/json\" \\"
        echo "          -d '$data'"
    else
        printf "%-50s" "$name"
    fi

    local response
    response=$(curl -s -w "$CURL_FMT" -X POST "$BASE_URL/api/search" \
        -H "Content-Type: application/json" \
        -d "$data")

    parse_metrics "$response"
    print_metrics

    if [ "$RESP_CODE" != "200" ]; then
        if [ "$VERBOSE" = true ]; then
            echo "      Response: $RESP_BODY"
            echo -e "      ${RED}FAIL${NC} (HTTP $RESP_CODE)"
        else
            echo -e "${RED}FAIL${NC} (HTTP $RESP_CODE)"
            echo "  Response: $RESP_BODY"
        fi
        ((FAIL++))
        return 1
    fi

    local num_results
    num_results=$(echo "$RESP_BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('total_results', 0))" 2>/dev/null)

    if [ "$num_results" -lt "$min_results" ]; then
        if [ "$VERBOSE" = true ]; then
            echo "      Results: $num_results (expected >= $min_results)"
            echo -e "      ${RED}FAIL${NC}"
        else
            echo -e "${RED}FAIL${NC} (expected >= $min_results results, got $num_results)"
        fi
        ((FAIL++))
        return 1
    fi

    if [ "$check_similarity" == "true" ]; then
        local similarity_check
        similarity_check=$(echo "$RESP_BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
results = d.get('results', [])
if not results:
    print('NO_RESULTS')
else:
    scores = [r.get('similarity', 0) for r in results]
    if any(s < 0 or s > 1 for s in scores):
        print('INVALID_RANGE')
    elif scores != sorted(scores, reverse=True):
        print('NOT_SORTED')
    else:
        print('OK')
" 2>/dev/null)

        if [ "$similarity_check" != "OK" ] && [ "$similarity_check" != "NO_RESULTS" ]; then
            if [ "$VERBOSE" = true ]; then
                echo "      Similarity check: $similarity_check"
                echo -e "      ${RED}FAIL${NC}"
            else
                echo -e "${RED}FAIL${NC} (similarity check: $similarity_check)"
            fi
            ((FAIL++))
            return 1
        fi
    fi

    local api_latency
    api_latency=$(echo "$RESP_BODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('latency_ms', 'n/a'))" 2>/dev/null)

    if [ "$VERBOSE" = true ]; then
        echo "      Results: $num_results | API latency: ${api_latency}ms"
        if [ "$num_results" -gt 0 ]; then
            local top_hit
            top_hit=$(echo "$RESP_BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
r = d['results'][0]
title = r.get('title', 'N/A')[:60]
sim = r.get('similarity', 0)
print(f'{title} (similarity: {sim:.3f})')
" 2>/dev/null)
            echo "      Top hit: $top_hit"
        fi
        echo -e "      ${GREEN}PASS${NC} ($num_results results)"
    else
        echo -e "${GREEN}PASS${NC} ($num_results results)"
    fi
    ((PASS++))
    return 0
}

# ── Status-only test (for edge cases) ─────────────────────────

run_status_test() {
    local name="$1"
    local endpoint="$2"
    local data="$3"
    local expected_status="$4"

    ((TEST_NUM++))

    if [ "$VERBOSE" = true ]; then
        echo ""
        echo -e "  ${CYAN}[$TEST_NUM] $name${NC}"
        echo "      \$ curl -s -X POST \"${BASE_URL}${endpoint}\" \\"
        echo "          -H \"Content-Type: application/json\" \\"
        echo "          -d '$data'"
    else
        printf "%-50s" "$name"
    fi

    local response
    response=$(curl -s -w "$CURL_FMT" -X POST "$BASE_URL$endpoint" \
        -H "Content-Type: application/json" \
        -d "$data")

    parse_metrics "$response"
    print_metrics

    if [ "$RESP_CODE" == "$expected_status" ]; then
        if [ "$VERBOSE" = true ]; then
            echo -e "      ${GREEN}PASS${NC}"
        else
            echo -e "${GREEN}PASS${NC}"
        fi
        ((PASS++))
    else
        if [ "$VERBOSE" = true ]; then
            echo -e "      ${RED}FAIL${NC} (expected $expected_status, got $RESP_CODE)"
        else
            echo -e "${RED}FAIL${NC} (expected $expected_status, got $RESP_CODE)"
        fi
        ((FAIL++))
    fi
}

# ══════════════════════════════════════════════════════════════
#  TESTS
# ══════════════════════════════════════════════════════════════

echo "--- Health & Info Endpoints ---"
if [ "$VERBOSE" = true ]; then
    echo -e "    ${DIM}Verify product search service is healthy and embedding model is loaded${NC}"
fi
echo ""

run_test "GET /api/health returns 200" \
    "GET" "/api/health" "" "200" "status" "healthy"

run_test "GET /api/info returns 200" \
    "GET" "/api/info" "" "200" "service" "LLM Vector Search Engine"

echo ""
echo "--- Basic Search Tests ---"
if [ "$VERBOSE" = true ]; then
    echo -e "    ${DIM}Semantic vector search using all-MiniLM-L6-v2 embeddings (384-dim).${NC}"
    echo -e "    ${DIM}Tests basic search functionality with various top_k values.${NC}"
fi
echo ""

run_search_test "Basic search query" \
    "comfortable shoes" "" 1 true

run_search_test "Search with top_k=5" \
    "running shoes" "\"top_k\": 5" 1 true

run_search_test "Search with top_k=1" \
    "laptop computer" "\"top_k\": 1" 1 true

run_search_test "Search with top_k=20" \
    "electronics" "\"top_k\": 20" 1 true

echo ""
echo "--- Search Field Tests ---"
if [ "$VERBOSE" = true ]; then
    echo -e "    ${DIM}Test content vs title embedding search fields.${NC}"
fi
echo ""

run_search_test "Search by content (default)" \
    "waterproof jacket for hiking" "\"search_field\": \"content\"" 1 true

run_search_test "Search by title" \
    "running shoes" "\"search_field\": \"title\"" 1 true

echo ""
echo "--- Similarity Threshold Tests ---"
if [ "$VERBOSE" = true ]; then
    echo -e "    ${DIM}Filter results by minimum cosine similarity score (0.0 to 1.0).${NC}"
    echo -e "    ${DIM}Higher thresholds return fewer but more relevant results.${NC}"
fi
echo ""

run_search_test "Search with low threshold (0.1)" \
    "kitchen appliances" "\"similarity_threshold\": 0.1" 1 true

run_search_test "Search with medium threshold (0.3)" \
    "kitchen appliances" "\"similarity_threshold\": 0.3" 0 true

run_search_test "Search with high threshold (0.5)" \
    "kitchen appliances" "\"similarity_threshold\": 0.5" 0 true

echo ""
echo "--- Semantic Search Tests ---"
if [ "$VERBOSE" = true ]; then
    echo -e "    ${DIM}Natural language queries testing semantic understanding.${NC}"
    echo -e "    ${DIM}Queries describe intent rather than exact product names.${NC}"
fi
echo ""

run_search_test "Semantic: gift for cooking enthusiast" \
    "gift for someone who loves cooking" "" 1 true

run_search_test "Semantic: budget electronics" \
    "cheap affordable electronics under 50 dollars" "" 1 true

run_search_test "Semantic: outdoor activity gear" \
    "equipment for hiking camping outdoor adventures" "" 1 true

run_search_test "Semantic: work from home setup" \
    "home office desk chair computer accessories" "" 1 true

run_search_test "Semantic: fitness and health" \
    "workout exercise gym fitness equipment" "" 1 true

echo ""
echo "--- Edge Cases & Error Handling ---"
if [ "$VERBOSE" = true ]; then
    echo -e "    ${DIM}Validate input validation, error responses, and unusual query handling.${NC}"
fi
echo ""

run_status_test "Empty query returns 400" \
    "/api/search" '{"query": ""}' "400"

run_status_test "Missing query field returns 400" \
    "/api/search" '{"top_k": 5}' "400"

run_status_test "Whitespace-only query returns 400" \
    "/api/search" '{"query": "   "}' "400"

run_search_test "Long query (100+ chars)" \
    "I am looking for a really good product that is high quality and affordable and will last a long time and is perfect for everyday use" "" 0 true

run_search_test "Query with special characters" \
    "laptop & computer (accessories)" "" 0 true

run_search_test "Query with unicode" \
    "café coffee maker électronique" "" 0 true

echo ""
echo "--- Response Structure Tests ---"
if [ "$VERBOSE" = true ]; then
    echo -e "    ${DIM}Validate JSON response schema for both wrapper and result objects.${NC}"
fi
echo ""

# ── Response has required fields ──
((TEST_NUM++))
if [ "$VERBOSE" = true ]; then
    echo ""
    echo -e "  ${CYAN}[$TEST_NUM] Response has required fields${NC}"
    echo "      \$ curl -s -X POST \"${BASE_URL}/api/search\" \\"
    echo "          -H \"Content-Type: application/json\" \\"
    echo "          -d '{\"query\": \"test product\", \"top_k\": 3}'"
else
    printf "%-50s" "Response has required fields"
fi

response=$(curl -s -w "$CURL_FMT" -X POST "$BASE_URL/api/search" \
    -H "Content-Type: application/json" \
    -d '{"query": "test product", "top_k": 3}')
parse_metrics "$response"
print_metrics

fields_check=$(echo "$RESP_BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
required = ['query', 'search_field', 'total_results', 'results', 'latency_ms']
missing = [f for f in required if f not in d]
if missing:
    print('MISSING: ' + ', '.join(missing))
else:
    print('OK')
" 2>/dev/null)

if [ "$fields_check" == "OK" ]; then
    [ "$VERBOSE" = true ] && echo "      Fields: query, search_field, total_results, results, latency_ms ✓"
    if [ "$VERBOSE" = true ]; then
        echo -e "      ${GREEN}PASS${NC}"
    else
        echo -e "${GREEN}PASS${NC}"
    fi
    ((PASS++))
else
    if [ "$VERBOSE" = true ]; then
        echo -e "      ${RED}FAIL${NC} ($fields_check)"
    else
        echo -e "${RED}FAIL${NC} ($fields_check)"
    fi
    ((FAIL++))
fi

# ── Result objects have required fields ──
((TEST_NUM++))
if [ "$VERBOSE" = true ]; then
    echo ""
    echo -e "  ${CYAN}[$TEST_NUM] Result objects have required fields${NC}"
    echo "      (reusing response from previous test)"
else
    printf "%-50s" "Result objects have required fields"
fi

result_fields_check=$(echo "$RESP_BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
results = d.get('results', [])
if not results:
    print('NO_RESULTS')
else:
    required = ['id', 'title', 'similarity']
    for i, r in enumerate(results):
        missing = [f for f in required if f not in r]
        if missing:
            print(f'Result {i} missing: ' + ', '.join(missing))
            sys.exit(0)
    print('OK')
" 2>/dev/null)

if [ "$result_fields_check" == "OK" ] || [ "$result_fields_check" == "NO_RESULTS" ]; then
    [ "$VERBOSE" = true ] && echo "      Fields: id, title, similarity ✓"
    if [ "$VERBOSE" = true ]; then
        echo -e "      ${GREEN}PASS${NC}"
    else
        echo -e "${GREEN}PASS${NC}"
    fi
    ((PASS++))
else
    if [ "$VERBOSE" = true ]; then
        echo -e "      ${RED}FAIL${NC} ($result_fields_check)"
    else
        echo -e "${RED}FAIL${NC} ($result_fields_check)"
    fi
    ((FAIL++))
fi

# ── Latency is reasonable ──
((TEST_NUM++))
if [ "$VERBOSE" = true ]; then
    echo ""
    echo -e "  ${CYAN}[$TEST_NUM] Response latency is reasonable (<5s)${NC}"
    echo "      (reusing response from previous test)"
else
    printf "%-50s" "Response latency is reasonable (<5s)"
fi

latency_check=$(echo "$RESP_BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
latency = d.get('latency_ms', 999999)
if latency < 5000:
    print(f'OK:{latency}')
else:
    print(f'TOO_SLOW:{latency}')
" 2>/dev/null)

latency_val=$(echo "$latency_check" | cut -d: -f2)

if [[ "$latency_check" == OK:* ]]; then
    [ "$VERBOSE" = true ] && echo "      API latency: ${latency_val}ms (< 5000ms threshold)"
    if [ "$VERBOSE" = true ]; then
        echo -e "      ${GREEN}PASS${NC}"
    else
        echo -e "${GREEN}PASS${NC}"
    fi
    ((PASS++))
else
    [ "$VERBOSE" = true ] && echo "      API latency: ${latency_val}ms (exceeds 5000ms threshold)"
    if [ "$VERBOSE" = true ]; then
        echo -e "      ${YELLOW}WARN${NC} (${latency_val}ms)"
    else
        echo -e "${YELLOW}WARN${NC} (TOO_SLOW: ${latency_val}ms)"
    fi
    ((WARN++))
    ((PASS++))  # Don't fail on slow, just warn
fi

echo ""
echo "--- Performance Tests ---"
if [ "$VERBOSE" = true ]; then
    echo -e "    ${DIM}Run 10 sequential product searches to measure throughput and latency distribution.${NC}"
fi
echo ""

((TEST_NUM++))
if [ "$VERBOSE" = true ]; then
    echo -e "  ${CYAN}[$TEST_NUM] 10 sequential searches${NC}"
else
    printf "%-50s" "10 sequential searches complete"
fi

total_latency=0
all_passed=true
latencies=()

for i in {1..10}; do
    perf_response=$(curl -s -w "$CURL_FMT" -X POST "$BASE_URL/api/search" \
        -H "Content-Type: application/json" \
        -d "{\"query\": \"test query number $i\", \"top_k\": 5}")

    parse_metrics "$perf_response"

    latency=$(echo "$RESP_BODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('latency_ms', 0))" 2>/dev/null)

    if [ -z "$latency" ] || [ "$latency" == "0" ]; then
        all_passed=false
        [ "$VERBOSE" = true ] && echo -e "      Query $i/10: \"test query number $i\" ... ${RED}FAILED${NC}"
        break
    fi

    latencies+=("$latency")
    total_latency=$((total_latency + latency))

    if [ "$VERBOSE" = true ]; then
        num_r=$(echo "$RESP_BODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('total_results', 0))" 2>/dev/null)
        echo "      Query $i/10: \"test query number $i\" ... ${latency}ms | ${num_r} results | wall: ${RESP_TIME_MS}ms | $(format_bytes $RESP_BYTES_DOWN)"
    fi
done

if [ "$all_passed" == true ]; then
    avg_latency=$((total_latency / 10))

    if [ "$VERBOSE" = true ]; then
        perf_stats=$(python3 -c "
import sys
latencies = [${latencies[0]}$(printf ',%s' "${latencies[@]:1}")]
latencies.sort()
print(f'{min(latencies)}|{max(latencies)}|{latencies[int(len(latencies)*0.95)]}')
")
        perf_min=$(echo "$perf_stats" | cut -d'|' -f1)
        perf_max=$(echo "$perf_stats" | cut -d'|' -f2)
        perf_p95=$(echo "$perf_stats" | cut -d'|' -f3)
        echo "      ────────────────────────────────────────"
        echo "      Avg: ${avg_latency}ms | Min: ${perf_min}ms | Max: ${perf_max}ms | P95: ${perf_p95}ms"
        echo -e "      ${GREEN}PASS${NC} (avg ${avg_latency}ms)"
    else
        echo -e "${GREEN}PASS${NC} (avg ${avg_latency}ms)"
    fi
    ((PASS++))
else
    if [ "$VERBOSE" = true ]; then
        echo -e "      ${RED}FAIL${NC}"
    else
        echo -e "${RED}FAIL${NC}"
    fi
    ((FAIL++))
fi

# ══════════════════════════════════════════════════════════════
#  RESULTS
# ══════════════════════════════════════════════════════════════

SUITE_END=$(python3 -c 'import time; print(int(time.time()*1000))')
SUITE_DURATION_MS=$((SUITE_END - SUITE_START))
SUITE_DURATION_S=$(echo "$SUITE_DURATION_MS" | awk '{printf "%.1f", $1/1000}')

echo ""
echo "=============================================="
echo "Test Results"
echo "=============================================="
echo -e "Passed: ${GREEN}$PASS${NC}"
echo -e "Failed: ${RED}$FAIL${NC}"
if [ "$WARN" -gt 0 ]; then
    echo -e "Warnings: ${YELLOW}$WARN${NC}"
fi
echo ""

if [ "$VERBOSE" = true ]; then
    echo "=============================================="
    echo "Performance Summary"
    echo "=============================================="
    echo "  Total tests:       $((PASS + FAIL))"
    echo "  Total requests:    $TOTAL_REQUESTS"
    echo "  Data downloaded:   $(format_bytes $TOTAL_BYTES_DOWN)"
    echo "  Data uploaded:     $(format_bytes $TOTAL_BYTES_UP)"
    echo "  Suite duration:    ${SUITE_DURATION_S}s"
    echo ""
    echo "=============================================="
    echo "AWS Cost Estimate"
    echo "=============================================="
    python3 -c "
requests = $TOTAL_REQUESTS
bytes_down = $TOTAL_BYTES_DOWN
bytes_up = $TOTAL_BYTES_UP
duration_ms = $SUITE_DURATION_MS

duration_s = max(duration_ms / 1000.0, 1)
duration_hr = duration_s / 3600.0

# ALB LCU calculation (us-east-1: \$0.008/LCU-hour)
# Dimension 1: New connections — 25 new conn/s per LCU
conn_per_s = requests / duration_s
lcu_conn = conn_per_s / 25.0

# Dimension 2: Processed bytes — 1 GB/hr per LCU
total_bytes = bytes_down + bytes_up
bytes_per_hr = total_bytes / duration_hr if duration_hr > 0 else 0
lcu_bytes = bytes_per_hr / (1024**3)

# Dimension 3: Rule evaluations — 1000/s per LCU (assume 2 rules per req)
rules_per_s = (requests * 2) / duration_s
lcu_rules = rules_per_s / 1000.0

# Billed LCU = max across all dimensions
lcu = max(lcu_conn, lcu_bytes, lcu_rules)
alb_cost = lcu * duration_hr * 0.008

# Data transfer out: \$0.09/GB (first 10 TB, us-east-1)
dt_cost = (bytes_down / (1024**3)) * 0.09

total_cost = alb_cost + dt_cost

def fmt_b(b):
    if b >= 1048576: return f'{b/1048576:.1f} MB'
    if b >= 1024: return f'{b/1024:.1f} KB'
    return f'{b} B'

print(f'  Requests:          {requests}')
print(f'  Data transferred:  {fmt_b(bytes_down)} down / {fmt_b(bytes_up)} up')
print(f'  Test duration:     {duration_s:.1f}s')
print(f'  ALB LCU peak:      {lcu:.4f} ({lcu_conn:.4f} conn, {lcu_bytes:.6f} bytes, {lcu_rules:.6f} rules)')
print(f'')
print(f'  ALB processing:    \${alb_cost:.8f}')
print(f'  Data transfer out: \${dt_cost:.8f}')
print(f'  ECS Fargate:       \$0.00 (fixed cost, already running)')
print(f'  RDS PostgreSQL:    \$0.00 (fixed cost, already running)')
print(f'  ────────────────────────────────')
print(f'  Test run total:    \${total_cost:.8f}')
print(f'')
if total_cost < 0.01:
    print(f'  Effectively free — less than 1 cent per test run.')
print(f'')
print(f'  Note: Fixed infrastructure costs (~\$0.07-0.15/hr) apply')
print(f'  continuously regardless of whether tests are running.')
print(f'  (ALB \$0.0225/hr + ECS Fargate ~\$0.03-0.05/hr + RDS ~\$0.017/hr)')
"
    echo ""
fi

if [ $FAIL -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed.${NC}"
    exit 1
fi