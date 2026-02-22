#!/bin/bash
set -e

#
# Full deployment script for the Legal Document Search feature.
# Combines database setup + Java build/push/deploy + verification.
#
# Usage:
#   ./deploy-legal.sh          # Full deploy (DB setup + build + deploy + verify)
#   ./deploy-legal.sh --skip-db  # Skip DB setup (just rebuild and redeploy Java)
#
# What this does:
#   1. Creates legal_documents table in RDS (if not exists)
#   2. Builds the Java project with Maven
#   3. Builds Docker image and pushes to ECR
#   4. Updates ECS task definition and forces new deployment
#   5. Waits for deployment to stabilize
#   6. Verifies both product search AND legal search endpoints
#

AWS_ACCOUNT=717914742237
AWS_REGION=us-east-1
ECR_REPO=llm-search-engine
SECRET_NAME=llm-db-credentials
ALB_DNS="llm-alb-1402483560.us-east-1.elb.amazonaws.com"
SCHEMA_FILE="$(dirname "$0")/schema_legal.sql"

SKIP_DB=false
if [ "$1" == "--skip-db" ]; then
    SKIP_DB=true
fi

echo "=============================================="
echo "Legal Document Search — Full Deployment"
echo "=============================================="
echo ""

# ==========================================
# Step 1: Database Schema
# ==========================================
if [ "$SKIP_DB" == false ]; then
    echo "=== Step 1: Database Schema Setup ==="

    if ! command -v psql &> /dev/null; then
        echo "WARNING: psql not installed. Skipping DB setup."
        echo "  Run ./setup-legal-db.sh manually after installing: brew install postgresql"
        echo ""
    else
        SECRET_JSON=$(aws secretsmanager get-secret-value \
            --secret-id "$SECRET_NAME" \
            --region "$AWS_REGION" \
            --query 'SecretString' \
            --output text)

        DB_HOST=$(echo "$SECRET_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['host'])")
        DB_PORT=$(echo "$SECRET_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['port'])")
        DB_NAME=$(echo "$SECRET_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['database'])")
        DB_USER=$(echo "$SECRET_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['username'])")
        DB_PASS=$(echo "$SECRET_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['password'])")

        echo "Running schema_legal.sql against $DB_HOST/$DB_NAME..."
        PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -f "$SCHEMA_FILE"
        echo "Database schema applied."
    fi
    echo ""
else
    echo "=== Step 1: Database Schema Setup (SKIPPED) ==="
    echo ""
fi

# ==========================================
# Step 2: Maven Build
# ==========================================
echo "=== Step 2: Maven Build ==="
mvn clean package -DskipTests -B
echo "Build successful."
echo ""

# ==========================================
# Step 3: Docker Build & Push to ECR
# ==========================================
echo "=== Step 3: Docker Build & Push to ECR ==="
aws ecr get-login-password --region $AWS_REGION | \
    docker login --username AWS --password-stdin $AWS_ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com

docker build --platform linux/amd64 -t $ECR_REPO:latest .
docker tag $ECR_REPO:latest $AWS_ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPO:latest
docker push $AWS_ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPO:latest
echo "Image pushed to ECR."
echo ""

# ==========================================
# Step 4: Update ECS Task Definition
# ==========================================
echo "=== Step 4: Update ECS Task Definition ==="
aws ecs register-task-definition \
    --cli-input-json file://task-definition.json \
    --region $AWS_REGION > /dev/null
echo "Task definition updated."
echo ""

# ==========================================
# Step 5: Force New Deployment
# ==========================================
echo "=== Step 5: Force New Deployment ==="
aws ecs update-service \
    --cluster llm-cluster \
    --service llm-search-engine \
    --task-definition llm-search-engine-task \
    --force-new-deployment \
    --region $AWS_REGION > /dev/null
echo "Deployment initiated."
echo ""

# ==========================================
# Step 6: Wait for Deployment
# ==========================================
echo "=== Step 6: Waiting for Deployment ==="
echo "Waiting 45 seconds for ECS to roll out new tasks..."
for i in $(seq 1 9); do
    sleep 5
    printf "  %ds...\n" $((i * 5))
done
echo ""

# ==========================================
# Step 7: Verify Product Search (existing)
# ==========================================
echo "=== Step 7: Verify Product Search (existing) ==="

echo "Health check:"
curl -s http://$ALB_DNS/api/health | python3 -m json.tool
echo ""

echo "Product search test:"
curl -s -X POST http://$ALB_DNS/api/search \
    -H "Content-Type: application/json" \
    -d '{"query": "comfortable running shoes for men", "top_k": 3}' | python3 -m json.tool
echo ""

# ==========================================
# Step 8: Verify Legal Search (new)
# ==========================================
echo "=== Step 8: Verify Legal Search (new) ==="

echo "Legal health check:"
curl -s http://$ALB_DNS/api/legal/health | python3 -m json.tool
echo ""

echo "Legal info:"
curl -s http://$ALB_DNS/api/legal/info | python3 -m json.tool
echo ""

echo "Legal stats:"
curl -s http://$ALB_DNS/api/legal/stats | python3 -m json.tool
echo ""

echo "Legal semantic search test:"
curl -s -X POST http://$ALB_DNS/api/legal/search \
    -H "Content-Type: application/json" \
    -d '{"query": "employment discrimination reasonable accommodation", "top_k": 5}' | python3 -m json.tool
echo ""

echo "Legal hybrid search test:"
curl -s -X POST http://$ALB_DNS/api/legal/search \
    -H "Content-Type: application/json" \
    -d '{"query": "42 U.S.C. § 1983 civil rights", "top_k": 5, "search_field": "hybrid"}' | python3 -m json.tool
echo ""

echo "Legal jurisdiction filter test (CA):"
curl -s -X POST http://$ALB_DNS/api/legal/search \
    -H "Content-Type: application/json" \
    -d '{"query": "wrongful termination", "top_k": 5, "jurisdiction": "CA"}' | python3 -m json.tool
echo ""

# ==========================================
# Done
# ==========================================
echo "=============================================="
echo "Deployment Complete!"
echo "=============================================="
echo ""
echo "Endpoints available at:"
echo "  Product search:  http://$ALB_DNS/api/search"
echo "  Legal search:    http://$ALB_DNS/api/legal/search"
echo "  Legal health:    http://$ALB_DNS/api/legal/health"
echo "  Legal info:      http://$ALB_DNS/api/legal/info"
echo "  Legal stats:     http://$ALB_DNS/api/legal/stats"
echo "  Swagger UI:      http://$ALB_DNS/swagger-ui/index.html"
echo ""
echo "Run the full test suite:"
echo "  ./test-legal-api.sh http://$ALB_DNS"
echo ""
echo "NOTE: Legal search results require ingested legal documents."
echo "  If you haven't ingested yet, run via the Python service:"
echo "  curl -X POST http://$ALB_DNS/legal/ingest"