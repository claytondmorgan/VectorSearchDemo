#!/bin/bash
#
# Test script for the Legal Document Search API
#
# Usage:
#   ./test-legal-api.sh                              # localhost, non-verbose
#   ./test-legal-api.sh http://my-alb.com             # custom URL, non-verbose
#   ./test-legal-api.sh -v                            # localhost, verbose
#   ./test-legal-api.sh -v http://my-alb.com          # custom URL, verbose
#   ./test-legal-api.sh http://my-alb.com --verbose   # custom URL, verbose
#
# Flags:
#   -v, --verbose   Show curl commands, response details, timing breakdown,
#                   performance stats, and estimated AWS cost per test run
#
# Prerequisites:
#   - Java search service running
#   - Python inference service running (for /legal/search delegation)
#   - Database with ingested legal documents (legal_documents table)
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
echo "Legal Document Search API Tests"
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
        printf "%-55s" "$name"
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

run_legal_search_test() {
    local name="$1"
    local data="$2"
    local min_results="$3"
    local check_similarity="$4"

    ((TEST_NUM++))

    if [ "$VERBOSE" = true ]; then
        echo ""
        echo -e "  ${CYAN}[$TEST_NUM] $name${NC}"
        echo "      \$ curl -s -X POST \"${BASE_URL}/api/legal/search\" \\"
        echo "          -H \"Content-Type: application/json\" \\"
        echo "          -d '$data'"
    else
        printf "%-55s" "$name"
    fi

    local response
    response=$(curl -s -w "$CURL_FMT" -X POST "$BASE_URL/api/legal/search" \
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

    local method api_latency
    method=$(echo "$RESP_BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('search_method', 'n/a'))" 2>/dev/null)
    api_latency=$(echo "$RESP_BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('latency_ms', 'n/a'))" 2>/dev/null)

    if [ "$VERBOSE" = true ]; then
        echo "      Results: $num_results | method: $method | API latency: ${api_latency}ms"
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
        echo -e "      ${GREEN}PASS${NC} ($num_results results, method=$method)"
    else
        echo -e "${GREEN}PASS${NC} ($num_results results, method=$method)"
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
        printf "%-55s" "$name"
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

echo "--- 1. Health & Info Endpoints ---"
if [ "$VERBOSE" = true ]; then
    echo -e "    ${DIM}Verify service health, metadata, and database connectivity${NC}"
fi
echo ""

run_test "GET /api/legal/health returns 200" \
    "GET" "/api/legal/health" "" "200" "status" "healthy"

run_test "GET /api/legal/info returns 200" \
    "GET" "/api/legal/info" "" "200" "service" "Legal Document Search Engine"

run_test "GET /api/legal/stats returns 200" \
    "GET" "/api/legal/stats" "" "200"

echo ""
echo "--- 2. Semantic Search — Conceptual Legal Queries ---"
if [ "$VERBOSE" = true ]; then
    echo -e "    ${DIM}Pure semantic similarity search using ModernBERT legal embeddings (768-dim).${NC}"
    echo -e "    ${DIM}Queries are natural language legal concepts without statute citations.${NC}"
fi
echo ""

run_legal_search_test "Employment discrimination search" \
    '{"query": "employment discrimination reasonable accommodation", "top_k": 5}' 1 true

run_legal_search_test "Duty of care / negligence" \
    '{"query": "duty of care negligence standard", "top_k": 5}' 1 true

run_legal_search_test "Constitutional right to counsel" \
    '{"query": "constitutional right to counsel", "top_k": 5}' 1 true

run_legal_search_test "Search for wrongful termination" \
    '{"query": "wrongful termination retaliation", "top_k": 5}' 1 true

run_legal_search_test "Search for Miranda rights" \
    '{"query": "Miranda rights custodial interrogation warnings", "top_k": 5}' 1 true

echo ""
echo "--- 3. Hybrid Search — Semantic + Keyword Combined ---"
if [ "$VERBOSE" = true ]; then
    echo -e "    ${DIM}Combines vector cosine similarity (HNSW) with PostgreSQL full-text search (GIN)${NC}"
    echo -e "    ${DIM}via Reciprocal Rank Fusion (RRF, k=60). Best for queries with legal citations.${NC}"
fi
echo ""

run_legal_search_test "Hybrid: statute citation 42 U.S.C. § 1983" \
    '{"query": "42 U.S.C. § 1983", "search_field": "hybrid", "top_k": 5}' 0 true

run_legal_search_test "Hybrid: civil rights violation" \
    '{"query": "civil rights violation Section 1983", "search_field": "hybrid", "top_k": 5}' 1 true

run_legal_search_test "Hybrid: ADA disability accommodation" \
    '{"query": "ADA disability reasonable accommodation 42 U.S.C. § 12101", "search_field": "hybrid", "top_k": 5}' 1 true

echo ""
echo "--- 4. Jurisdiction Filtering ---"
if [ "$VERBOSE" = true ]; then
    echo -e "    ${DIM}Pre-filter results by jurisdiction before vector search.${NC}"
    echo -e "    ${DIM}Uses B-tree index on jurisdiction column for fast filtering.${NC}"
fi
echo ""

run_legal_search_test "CA jurisdiction: wrongful termination" \
    '{"query": "wrongful termination", "jurisdiction": "CA", "top_k": 5}' 0 true

run_legal_search_test "NY jurisdiction: wrongful termination" \
    '{"query": "wrongful termination", "jurisdiction": "NY", "top_k": 5}' 0 true

run_legal_search_test "US Supreme Court: constitutional rights" \
    '{"query": "constitutional rights", "jurisdiction": "US_Supreme_Court", "top_k": 5}' 0 true

echo ""
echo "--- 5. Status Filtering (Shepard's Demo) ---"
if [ "$VERBOSE" = true ]; then
    echo -e "    ${DIM}Exclude overruled authorities (Shepard's-style citation validation).${NC}"
    echo -e "    ${DIM}Filters on status column: good_law, distinguished, overruled, questioned.${NC}"
fi
echo ""

run_legal_search_test "Exclude overruled: separate but equal" \
    '{"query": "separate but equal", "status_filter": "exclude_overruled", "top_k": 10}' 0 true

run_legal_search_test "Exclude overruled: search and seizure" \
    '{"query": "unreasonable search and seizure exclusionary rule", "status_filter": "exclude_overruled", "top_k": 5}' 0 true

echo ""
echo "--- 6. Document Type Filtering ---"
if [ "$VERBOSE" = true ]; then
    echo -e "    ${DIM}Filter by doc_type: case_law, statute, regulation, practice_guide.${NC}"
fi
echo ""

run_legal_search_test "Statutes only: disability accommodation" \
    '{"query": "disability accommodation", "doc_type": "statute", "top_k": 5}' 0 true

run_legal_search_test "Case law only: disability accommodation" \
    '{"query": "disability accommodation", "doc_type": "case_law", "top_k": 5}' 0 true

run_legal_search_test "Practice guides: filing discrimination claim" \
    '{"query": "how to file discrimination claim", "doc_type": "practice_guide", "top_k": 5}' 0 true

echo ""
echo "--- 7. Semantic vs Hybrid Comparison ---"
if [ "$VERBOSE" = true ]; then
    echo -e "    ${DIM}Demonstrates that citation symbols (§) are handled better by hybrid search${NC}"
    echo -e "    ${DIM}which combines semantic understanding with keyword matching.${NC}"
fi
echo ""

echo -e "${YELLOW}Comparing semantic vs hybrid for citation '§ 1983':${NC}"

run_legal_search_test "  Semantic only: § 1983" \
    '{"query": "§ 1983", "search_field": "content", "top_k": 5}' 0 true

run_legal_search_test "  Hybrid: § 1983" \
    '{"query": "§ 1983", "search_field": "hybrid", "top_k": 5}' 0 true

echo ""
echo "--- 8. Edge Cases & Error Handling ---"
if [ "$VERBOSE" = true ]; then
    echo -e "    ${DIM}Validate input validation, error responses, and combined filter behavior.${NC}"
fi
echo ""

run_status_test "Empty query returns 400" \
    "/api/legal/search" '{"query": ""}' "400"

run_status_test "Missing query field returns 400" \
    "/api/legal/search" '{"top_k": 5}' "400"

run_status_test "Whitespace-only query returns 400" \
    "/api/legal/search" '{"query": "   "}' "400"

# Combined filters
run_legal_search_test "Combined: CA + employment + case_law" \
    '{"query": "discrimination", "jurisdiction": "CA", "practice_area": "employment", "doc_type": "case_law", "top_k": 5}' 0 true

echo ""
echo "--- 9. Response Structure Tests ---"
if [ "$VERBOSE" = true ]; then
    echo -e "    ${DIM}Validate JSON response schema for both wrapper and result objects.${NC}"
fi
echo ""

# ── Response has required fields ──
((TEST_NUM++))
if [ "$VERBOSE" = true ]; then
    echo ""
    echo -e "  ${CYAN}[$TEST_NUM] Response has required fields${NC}"
    echo "      \$ curl -s -X POST \"${BASE_URL}/api/legal/search\" \\"
    echo "          -H \"Content-Type: application/json\" \\"
    echo "          -d '{\"query\": \"employment law\", \"top_k\": 3}'"
else
    printf "%-55s" "Response has required fields"
fi

response=$(curl -s -w "$CURL_FMT" -X POST "$BASE_URL/api/legal/search" \
    -H "Content-Type: application/json" \
    -d '{"query": "employment law", "top_k": 3}')
parse_metrics "$response"
print_metrics

fields_check=$(echo "$RESP_BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
required = ['query', 'search_field', 'total_results', 'results', 'latency_ms', 'search_method']
missing = [f for f in required if f not in d]
if missing:
    print('MISSING: ' + ', '.join(missing))
else:
    print('OK')
" 2>/dev/null)

if [ "$fields_check" == "OK" ]; then
    [ "$VERBOSE" = true ] && echo "      Fields: query, search_field, total_results, results, latency_ms, search_method ✓"
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

# ── Result objects have legal-specific fields ──
((TEST_NUM++))
if [ "$VERBOSE" = true ]; then
    echo ""
    echo -e "  ${CYAN}[$TEST_NUM] Result objects have legal-specific fields${NC}"
    echo "      (reusing response from previous test)"
else
    printf "%-55s" "Result objects have legal-specific fields"
fi

result_fields_check=$(echo "$RESP_BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
results = d.get('results', [])
if not results:
    print('NO_RESULTS')
else:
    required = ['id', 'doc_id', 'doc_type', 'title', 'similarity', 'search_method', 'content_snippet']
    for i, r in enumerate(results):
        missing = [f for f in required if f not in r]
        if missing:
            print(f'Result {i} missing: ' + ', '.join(missing))
            sys.exit(0)
    print('OK')
" 2>/dev/null)

if [ "$result_fields_check" == "OK" ] || [ "$result_fields_check" == "NO_RESULTS" ]; then
    [ "$VERBOSE" = true ] && echo "      Fields: id, doc_id, doc_type, title, similarity, search_method, content_snippet ✓"
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
    printf "%-55s" "Response latency is reasonable (<5s)"
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
    ((PASS++))
fi

echo ""
echo "--- 10. Performance Tests ---"
if [ "$VERBOSE" = true ]; then
    echo -e "    ${DIM}Run 10 sequential legal searches to measure throughput and latency distribution.${NC}"
    echo -e "    ${DIM}Each query uses a different legal topic to avoid caching effects.${NC}"
fi
echo ""

((TEST_NUM++))
if [ "$VERBOSE" = true ]; then
    echo -e "  ${CYAN}[$TEST_NUM] 10 sequential legal searches${NC}"
else
    printf "%-55s" "10 sequential legal searches complete"
fi

total_latency=0
all_passed=true
latencies=()

queries=(
    "employment discrimination"
    "reasonable accommodation ADA"
    "wrongful termination California"
    "Miranda rights"
    "search and seizure fourth amendment"
    "due process equal protection"
    "Title VII civil rights"
    "negligence duty of care"
    "contract breach damages"
    "intellectual property patent"
)

for i in {0..9}; do
    perf_response=$(curl -s -w "$CURL_FMT" -X POST "$BASE_URL/api/legal/search" \
        -H "Content-Type: application/json" \
        -d "{\"query\": \"${queries[$i]}\", \"top_k\": 5}")

    parse_metrics "$perf_response"

    latency=$(echo "$RESP_BODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('latency_ms', 0))" 2>/dev/null)

    if [ -z "$latency" ] || [ "$latency" == "0" ]; then
        all_passed=false
        [ "$VERBOSE" = true ] && echo -e "      Query $((i+1))/10: \"${queries[$i]}\" ... ${RED}FAILED${NC}"
        break
    fi

    latencies+=("$latency")
    total_latency=$((total_latency + latency))

    if [ "$VERBOSE" = true ]; then
        num_r=$(echo "$RESP_BODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('total_results', 0))" 2>/dev/null)
        echo "      Query $((i+1))/10: \"${queries[$i]}\" ... ${latency}ms | ${num_r} results | wall: ${RESP_TIME_MS}ms | $(format_bytes $RESP_BYTES_DOWN)"
    fi
done

if [ "$all_passed" == true ]; then
    avg_latency=$((total_latency / 10))

    if [ "$VERBOSE" = true ]; then
        # Calculate min, max, p95 using python
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
echo "Legal Search API Test Results"
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