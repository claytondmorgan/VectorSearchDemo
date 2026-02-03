#!/bin/bash
set -e

# Configuration
AWS_ACCOUNT=717914742237
AWS_REGION=us-east-1
ECR_REPO=llm-search-engine
IMAGE_TAG=latest

echo "=========================================="
echo "LLM Search Engine - Docker Build & Deploy"
echo "=========================================="

# Create ECR repository (ignore error if exists)
echo "Creating ECR repository..."
aws ecr create-repository --repository-name $ECR_REPO --region $AWS_REGION 2>/dev/null || true

# Create CloudWatch log group (ignore error if exists)
echo "Creating CloudWatch log group..."
aws logs create-log-group --log-group-name /ecs/llm-search-engine --region $AWS_REGION 2>/dev/null || true

# Authenticate Docker to ECR
echo "Authenticating Docker to ECR..."
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $AWS_ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com

# Build Docker image for AMD64
echo "Building Docker image for AMD64..."
docker build --platform linux/amd64 -t $ECR_REPO:$IMAGE_TAG .

# Tag image for ECR
echo "Tagging image for ECR..."
docker tag $ECR_REPO:$IMAGE_TAG $AWS_ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPO:$IMAGE_TAG

# Push to ECR
echo "Pushing image to ECR..."
docker push $AWS_ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPO:$IMAGE_TAG

# Register ECS task definition
echo "Registering ECS task definition..."
aws ecs register-task-definition --cli-input-json file://task-definition.json --region $AWS_REGION

echo ""
echo "=========================================="
echo "Deployment Complete!"
echo "=========================================="
echo ""
echo "Image pushed to: $AWS_ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPO:$IMAGE_TAG"
echo ""
echo "Next steps:"
echo "1. Run ./setup-ecs-service.sh to create the ALB target group and ECS service"
echo "2. Or manually update existing ECS service:"
echo "   aws ecs update-service --cluster llm-cluster --service llm-search-engine --force-new-deployment --region $AWS_REGION"
echo ""
