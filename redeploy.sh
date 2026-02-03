#!/bin/bash
set -e

AWS_ACCOUNT=717914742237
AWS_REGION=us-east-1
ECR_REPO=llm-search-engine

echo "=== Step 1: Build ==="
mvn clean package -DskipTests -B
echo "Build successful"

echo ""
echo "=== Step 2: Docker build ==="
docker build --platform linux/amd64 -t $ECR_REPO:latest .
echo "Docker image built"

echo ""
echo "=== Step 3: Push to ECR ==="
aws ecr get-login-password --region $AWS_REGION | \
  docker login --username AWS --password-stdin $AWS_ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com
docker tag $ECR_REPO:latest $AWS_ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPO:latest
docker push $AWS_ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPO:latest
echo "Image pushed"

echo ""
echo "=== Step 4: Update task definition ==="
aws ecs register-task-definition \
  --cli-input-json file://task-definition.json \
  --region $AWS_REGION
echo "Task definition updated"

echo ""
echo "=== Step 5: Force new deployment ==="
aws ecs update-service \
  --cluster llm-cluster \
  --service llm-search-engine \
  --task-definition llm-search-engine-task \
  --force-new-deployment \
  --region $AWS_REGION
echo "Deployment initiated"

echo ""
echo "=== Waiting for deployment (30s) ==="
sleep 30

echo ""
echo "=== Step 6: Verify ==="
ALB_DNS="llm-alb-1402483560.us-east-1.elb.amazonaws.com"

echo "Health check:"
curl -s http://$ALB_DNS/api/health | python3 -m json.tool

echo ""
echo "Service info:"
curl -s http://$ALB_DNS/api/info | python3 -m json.tool

echo ""
echo "Test search:"
curl -s -X POST http://$ALB_DNS/api/search \
  -H "Content-Type: application/json" \
  -d '{"query": "comfortable running shoes for men", "top_k": 3}' | python3 -m json.tool

echo ""
echo "=== Deployment complete ==="
echo "The Java service now delegates embeddings to the Python service."
echo "Model shown in /api/info should reflect whatever the Python service is running."