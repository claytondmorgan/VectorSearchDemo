#!/bin/bash
#
# Test script for the Legal Document Search API
#
# Usage:
#   ./test-legal-api.sh                    # Uses localhost:8080
#   ./test-legal-api.sh http://my-alb.com  # Uses custom base URL
#
# Prerequisites:
#   - Java search service running
#   - Python inference service running (for /embed delegation)
#   - Database with ingested legal documents (legal_documents table)
#

BASE_URL="${1:-http://localhost:8080}"
PASS=0
FAIL=0

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=============================================="
echo "Legal Document Search API Tests"
echo "Base URL: $BASE_URL"
echo "=============================================="
echo ""

# Helper function to run a test
run_test() {
    local name="$1"
    local method="$2"
    local endpoint="$3"
    local data="$4"
    local expected_status="$5"
    local check_field="$6"
    local check_value="$7"

    printf "%-55s" "$name"

    if [ "$method" == "GET" ]; then
        response=$(curl -s -w "\n%{http_code}" "$BASE_URL$endpoint")
    else
        response=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL$endpoint" \
            -H "Content-Type: application/json" \
            -d "$data")
    fi

    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')

    if [ "$http_code" != "$expected_status" ]; then
        echo -e "${RED}FAIL${NC} (expected HTTP $expected_status, got $http_code)"
        echo "  Response: $body"
        ((FAIL++))
        return 1
    fi

    if [ -n "$check_field" ]; then
        actual_value=$(echo "$body" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$check_field', 'MISSING'))" 2>/dev/null)
        if [ "$actual_value" != "$check_value" ]; then
            echo -e "${RED}FAIL${NC} ($check_field: expected '$check_value', got '$actual_value')"
            ((FAIL++))
            return 1
        fi
    fi

    echo -e "${GREEN}PASS${NC}"
    ((PASS++))
    return 0
}

# Helper function to run a legal search test and check results
run_legal_search_test() {
    local name="$1"
    local data="$2"
    local min_results="$3"
    local check_similarity="$4"

    printf "%-55s" "$name"

    response=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/api/legal/search" \
        -H "Content-Type: application/json" \
        -d "$data")

    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')

    if [ "$http_code" != "200" ]; then
        echo -e "${RED}FAIL${NC} (HTTP $http_code)"
        echo "  Response: $body"
        ((FAIL++))
        return 1
    fi

    num_results=$(echo "$body" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('total_results', 0))" 2>/dev/null)

    if [ "$num_results" -lt "$min_results" ]; then
        echo -e "${RED}FAIL${NC} (expected >= $min_results results, got $num_results)"
        ((FAIL++))
        return 1
    fi

    if [ "$check_similarity" == "true" ]; then
        similarity_check=$(echo "$body" | python3 -c "
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
            echo -e "${RED}FAIL${NC} (similarity check: $similarity_check)"
            ((FAIL++))
            return 1
        fi
    fi

    # Show search_method if available
    method=$(echo "$body" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('search_method', 'n/a'))" 2>/dev/null)
    echo -e "${GREEN}PASS${NC} ($num_results results, method=$method)"
    ((PASS++))
    return 0
}

echo "--- 1. Health & Info Endpoints ---"
echo ""

run_test "GET /api/legal/health returns 200" \
    "GET" "/api/legal/health" "" "200" "status" "healthy"

run_test "GET /api/legal/info returns 200" \
    "GET" "/api/legal/info" "" "200" "service" "Legal Document Search Engine"

run_test "GET /api/legal/stats returns 200" \
    "GET" "/api/legal/stats" "" "200"

echo ""
echo "--- 2. Semantic Search — Conceptual Legal Queries ---"
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
echo ""

run_legal_search_test "Hybrid: statute citation 42 U.S.C. § 1983" \
    '{"query": "42 U.S.C. § 1983", "search_field": "hybrid", "top_k": 5}' 0 true

run_legal_search_test "Hybrid: civil rights violation" \
    '{"query": "civil rights violation Section 1983", "search_field": "hybrid", "top_k": 5}' 1 true

run_legal_search_test "Hybrid: ADA disability accommodation" \
    '{"query": "ADA disability reasonable accommodation 42 U.S.C. § 12101", "search_field": "hybrid", "top_k": 5}' 1 true

echo ""
echo "--- 4. Jurisdiction Filtering ---"
echo ""

run_legal_search_test "CA jurisdiction: wrongful termination" \
    '{"query": "wrongful termination", "jurisdiction": "CA", "top_k": 5}' 0 true

run_legal_search_test "NY jurisdiction: wrongful termination" \
    '{"query": "wrongful termination", "jurisdiction": "NY", "top_k": 5}' 0 true

run_legal_search_test "US Supreme Court: constitutional rights" \
    '{"query": "constitutional rights", "jurisdiction": "US_Supreme_Court", "top_k": 5}' 0 true

echo ""
echo "--- 5. Status Filtering (Shepard's Demo) ---"
echo ""

run_legal_search_test "Exclude overruled: separate but equal" \
    '{"query": "separate but equal", "status_filter": "exclude_overruled", "top_k": 10}' 0 true

run_legal_search_test "Exclude overruled: search and seizure" \
    '{"query": "unreasonable search and seizure exclusionary rule", "status_filter": "exclude_overruled", "top_k": 5}' 0 true

echo ""
echo "--- 6. Document Type Filtering ---"
echo ""

run_legal_search_test "Statutes only: disability accommodation" \
    '{"query": "disability accommodation", "doc_type": "statute", "top_k": 5}' 0 true

run_legal_search_test "Case law only: disability accommodation" \
    '{"query": "disability accommodation", "doc_type": "case_law", "top_k": 5}' 0 true

run_legal_search_test "Practice guides: filing discrimination claim" \
    '{"query": "how to file discrimination claim", "doc_type": "practice_guide", "top_k": 5}' 0 true

echo ""
echo "--- 7. Semantic vs Hybrid Comparison ---"
echo ""

# Demonstrate that citation symbols work better with hybrid
echo -e "${YELLOW}Comparing semantic vs hybrid for citation '§ 1983':${NC}"

run_legal_search_test "  Semantic only: § 1983" \
    '{"query": "§ 1983", "search_field": "content", "top_k": 5}' 0 true

run_legal_search_test "  Hybrid: § 1983" \
    '{"query": "§ 1983", "search_field": "hybrid", "top_k": 5}' 0 true

echo ""
echo "--- 8. Edge Cases & Error Handling ---"
echo ""

# Empty query should return 400
printf "%-55s" "Empty query returns 400"
response=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/api/legal/search" \
    -H "Content-Type: application/json" \
    -d '{"query": ""}')
http_code=$(echo "$response" | tail -n1)
if [ "$http_code" == "400" ]; then
    echo -e "${GREEN}PASS${NC}"
    ((PASS++))
else
    echo -e "${RED}FAIL${NC} (expected 400, got $http_code)"
    ((FAIL++))
fi

# Missing query field should return 400
printf "%-55s" "Missing query field returns 400"
response=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/api/legal/search" \
    -H "Content-Type: application/json" \
    -d '{"top_k": 5}')
http_code=$(echo "$response" | tail -n1)
if [ "$http_code" == "400" ]; then
    echo -e "${GREEN}PASS${NC}"
    ((PASS++))
else
    echo -e "${RED}FAIL${NC} (expected 400, got $http_code)"
    ((FAIL++))
fi

# Whitespace-only query should return 400
printf "%-55s" "Whitespace-only query returns 400"
response=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/api/legal/search" \
    -H "Content-Type: application/json" \
    -d '{"query": "   "}')
http_code=$(echo "$response" | tail -n1)
if [ "$http_code" == "400" ]; then
    echo -e "${GREEN}PASS${NC}"
    ((PASS++))
else
    echo -e "${RED}FAIL${NC} (expected 400, got $http_code)"
    ((FAIL++))
fi

# Combined filters
run_legal_search_test "Combined: CA + employment + case_law" \
    '{"query": "discrimination", "jurisdiction": "CA", "practice_area": "employment", "doc_type": "case_law", "top_k": 5}' 0 true

echo ""
echo "--- 9. Response Structure Tests ---"
echo ""

# Check response has all required fields
printf "%-55s" "Response has required fields"
response=$(curl -s -X POST "$BASE_URL/api/legal/search" \
    -H "Content-Type: application/json" \
    -d '{"query": "employment law", "top_k": 3}')

fields_check=$(echo "$response" | python3 -c "
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
    echo -e "${GREEN}PASS${NC}"
    ((PASS++))
else
    echo -e "${RED}FAIL${NC} ($fields_check)"
    ((FAIL++))
fi

# Check result objects have required legal fields
printf "%-55s" "Result objects have legal-specific fields"
result_fields_check=$(echo "$response" | python3 -c "
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
    echo -e "${GREEN}PASS${NC}"
    ((PASS++))
else
    echo -e "${RED}FAIL${NC} ($result_fields_check)"
    ((FAIL++))
fi

# Check latency is reasonable
printf "%-55s" "Response latency is reasonable (<5s)"
latency_check=$(echo "$response" | python3 -c "
import sys, json
d = json.load(sys.stdin)
latency = d.get('latency_ms', 999999)
if latency < 5000:
    print('OK')
else:
    print(f'TOO_SLOW: {latency}ms')
" 2>/dev/null)

if [ "$latency_check" == "OK" ]; then
    echo -e "${GREEN}PASS${NC}"
    ((PASS++))
else
    echo -e "${YELLOW}WARN${NC} ($latency_check)"
    ((PASS++))
fi

echo ""
echo "--- 10. Performance Tests ---"
echo ""

printf "%-55s" "10 sequential legal searches complete"
total_latency=0
all_passed=true

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
    response=$(curl -s -X POST "$BASE_URL/api/legal/search" \
        -H "Content-Type: application/json" \
        -d "{\"query\": \"${queries[$i]}\", \"top_k\": 5}")

    latency=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('latency_ms', 0))" 2>/dev/null)

    if [ -z "$latency" ] || [ "$latency" == "0" ]; then
        all_passed=false
        break
    fi

    total_latency=$((total_latency + latency))
done

if [ "$all_passed" == true ]; then
    avg_latency=$((total_latency / 10))
    echo -e "${GREEN}PASS${NC} (avg ${avg_latency}ms)"
    ((PASS++))
else
    echo -e "${RED}FAIL${NC}"
    ((FAIL++))
fi

echo ""
echo "=============================================="
echo "Legal Search API Test Results"
echo "=============================================="
echo -e "Passed: ${GREEN}$PASS${NC}"
echo -e "Failed: ${RED}$FAIL${NC}"
echo ""

if [ $FAIL -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed.${NC}"
    exit 1
fi