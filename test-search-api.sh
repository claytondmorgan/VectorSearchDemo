#!/bin/bash
#
# Test script for the Java Search Service API
#
# Usage:
#   ./test-search-api.sh                    # Uses localhost:8080
#   ./test-search-api.sh http://my-alb.com  # Uses custom base URL
#
# Prerequisites:
#   - Java search service running
#   - Python inference service running (for /embed delegation)
#   - Database with ingested products
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
echo "Java Search Service API Tests"
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

    printf "%-50s" "$name"

    if [ "$method" == "GET" ]; then
        response=$(curl -s -w "\n%{http_code}" "$BASE_URL$endpoint")
    else
        response=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL$endpoint" \
            -H "Content-Type: application/json" \
            -d "$data")
    fi

    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')

    # Check HTTP status
    if [ "$http_code" != "$expected_status" ]; then
        echo -e "${RED}FAIL${NC} (expected HTTP $expected_status, got $http_code)"
        echo "  Response: $body"
        ((FAIL++))
        return 1
    fi

    # Check response field if specified
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

# Helper function to run a search test and check results
run_search_test() {
    local name="$1"
    local query="$2"
    local extra_params="$3"
    local min_results="$4"
    local check_similarity="$5"

    printf "%-50s" "$name"

    # Build the request body
    if [ -n "$extra_params" ]; then
        data="{\"query\": \"$query\", $extra_params}"
    else
        data="{\"query\": \"$query\"}"
    fi

    response=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/api/search" \
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

    # Check number of results
    num_results=$(echo "$body" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('total_results', 0))" 2>/dev/null)
    
    if [ "$num_results" -lt "$min_results" ]; then
        echo -e "${RED}FAIL${NC} (expected >= $min_results results, got $num_results)"
        ((FAIL++))
        return 1
    fi

    # Check similarity scores are valid (between 0 and 1, descending)
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
    elif scores != sorted(scores, reverse=True):
        print('NOT_SORTED')
    else:
        print('OK')
" 2>/dev/null)
        
        if [ "$similarity_check" != "OK" ] && [ "$similarity_check" != "NO_RESULTS" ]; then
            echo -e "${RED}FAIL${NC} (similarity check: $similarity_check)"
            ((FAIL++))
            return 1
        fi
    fi

    echo -e "${GREEN}PASS${NC} ($num_results results)"
    ((PASS++))
    return 0
}

echo "--- Health & Info Endpoints ---"
echo ""

run_test "GET /api/health returns 200" \
    "GET" "/api/health" "" "200" "status" "healthy"

run_test "GET /api/info returns 200" \
    "GET" "/api/info" "" "200" "service" "LLM Vector Search Engine"

echo ""
echo "--- Basic Search Tests ---"
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
echo ""

run_search_test "Search by content (default)" \
    "waterproof jacket for hiking" "\"search_field\": \"content\"" 1 true

run_search_test "Search by title" \
    "running shoes" "\"search_field\": \"title\"" 1 true

echo ""
echo "--- Similarity Threshold Tests ---"
echo ""

run_search_test "Search with low threshold (0.1)" \
    "kitchen appliances" "\"similarity_threshold\": 0.1" 1 true

run_search_test "Search with medium threshold (0.3)" \
    "kitchen appliances" "\"similarity_threshold\": 0.3" 0 true

run_search_test "Search with high threshold (0.5)" \
    "kitchen appliances" "\"similarity_threshold\": 0.5" 0 true

echo ""
echo "--- Semantic Search Tests ---"
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
echo ""

# Empty query should return 400
printf "%-50s" "Empty query returns 400"
response=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/api/search" \
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
printf "%-50s" "Missing query field returns 400"
response=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/api/search" \
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
printf "%-50s" "Whitespace-only query returns 400"
response=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/api/search" \
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

# Very long query should still work
run_search_test "Long query (100+ chars)" \
    "I am looking for a really good product that is high quality and affordable and will last a long time and is perfect for everyday use" "" 0 true

# Special characters in query
run_search_test "Query with special characters" \
    "laptop & computer (accessories)" "" 0 true

# Unicode characters
run_search_test "Query with unicode" \
    "café coffee maker électronique" "" 0 true

echo ""
echo "--- Response Structure Tests ---"
echo ""

# Check response has all required fields
printf "%-50s" "Response has required fields"
response=$(curl -s -X POST "$BASE_URL/api/search" \
    -H "Content-Type: application/json" \
    -d '{"query": "test product", "top_k": 3}')

fields_check=$(echo "$response" | python3 -c "
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
    echo -e "${GREEN}PASS${NC}"
    ((PASS++))
else
    echo -e "${RED}FAIL${NC} ($fields_check)"
    ((FAIL++))
fi

# Check result objects have required fields
printf "%-50s" "Result objects have required fields"
result_fields_check=$(echo "$response" | python3 -c "
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
    echo -e "${GREEN}PASS${NC}"
    ((PASS++))
else
    echo -e "${RED}FAIL${NC} ($result_fields_check)"
    ((FAIL++))
fi

# Check latency is reasonable (< 5 seconds)
printf "%-50s" "Response latency is reasonable (<5s)"
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
    ((PASS++))  # Don't fail on slow, just warn
fi

echo ""
echo "--- Performance Tests ---"
echo ""

# Run 10 sequential searches and measure average latency
printf "%-50s" "10 sequential searches complete"
total_latency=0
all_passed=true

for i in {1..10}; do
    response=$(curl -s -X POST "$BASE_URL/api/search" \
        -H "Content-Type: application/json" \
        -d "{\"query\": \"test query number $i\", \"top_k\": 5}")
    
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
echo "Test Results"
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
