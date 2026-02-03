#!/bin/bash
set -e

AWS_REGION=us-east-1

echo "=========================================="
echo "LLM Search Engine - ECS Service Setup"
echo "=========================================="

# Get the default VPC ID
echo "Getting default VPC ID..."
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query 'Vpcs[0].VpcId' --output text --region $AWS_REGION)
echo "VPC ID: $VPC_ID"

# Create target group for port 8080
echo "Creating target group..."
aws elbv2 create-target-group \
    --name llm-search-engine-tg \
    --protocol HTTP \
    --port 8080 \
    --vpc-id $VPC_ID \
    --target-type ip \
    --health-check-path /api/health \
    --health-check-interval-seconds 30 \
    --health-check-timeout-seconds 10 \
    --healthy-threshold-count 2 \
    --unhealthy-threshold-count 3 \
    --region $AWS_REGION 2>/dev/null || echo "Target group may already exist"

# Get the target group ARN
echo "Getting target group ARN..."
SEARCH_TG_ARN=$(aws elbv2 describe-target-groups --names llm-search-engine-tg --query 'TargetGroups[0].TargetGroupArn' --output text --region $AWS_REGION)
echo "Target Group ARN: $SEARCH_TG_ARN"

# Get the ALB listener ARN
echo "Getting ALB listener ARN..."
ALB_ARN=$(aws elbv2 describe-load-balancers --names llm-alb --query 'LoadBalancers[0].LoadBalancerArn' --output text --region $AWS_REGION)
LISTENER_ARN=$(aws elbv2 describe-listeners --load-balancer-arn $ALB_ARN --query 'Listeners[0].ListenerArn' --output text --region $AWS_REGION)
echo "ALB ARN: $ALB_ARN"
echo "Listener ARN: $LISTENER_ARN"

# Create ALB listener rule for /api/* (priority 10)
echo "Creating ALB listener rule for /api/*..."
aws elbv2 create-rule \
    --listener-arn $LISTENER_ARN \
    --priority 10 \
    --conditions "Field=path-pattern,Values=/api/*" \
    --actions "Type=forward,TargetGroupArn=$SEARCH_TG_ARN" \
    --region $AWS_REGION 2>/dev/null || echo "Listener rule may already exist"

# Prompt for security group
echo ""
echo "=========================================="
echo "Security Group Required"
echo "=========================================="
echo "Please provide the security group ID for your application."
echo "This should allow inbound traffic on port 8080 from the ALB."
echo ""
read -p "Enter APP_SG_ID: " APP_SG_ID

if [ -z "$APP_SG_ID" ]; then
    echo "Error: Security group ID is required"
    exit 1
fi

# Create ECS service
echo ""
echo "Creating ECS service..."
aws ecs create-service \
    --cluster llm-cluster \
    --service-name llm-search-engine \
    --task-definition llm-search-engine-task \
    --desired-count 2 \
    --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[subnet-047dc9a7cff86f305,subnet-01c0dd594e3a9a223],securityGroups=[$APP_SG_ID],assignPublicIp=ENABLED}" \
    --load-balancers "targetGroupArn=$SEARCH_TG_ARN,containerName=search-engine,containerPort=8080" \
    --region $AWS_REGION

echo ""
echo "=========================================="
echo "ECS Service Created!"
echo "=========================================="
echo ""
echo "Verification commands:"
echo ""
echo "1. Check service status:"
echo "   aws ecs describe-services --cluster llm-cluster --services llm-search-engine --region $AWS_REGION"
echo ""
echo "2. Watch task status:"
echo "   aws ecs list-tasks --cluster llm-cluster --service-name llm-search-engine --region $AWS_REGION"
echo ""
echo "3. Tail logs:"
echo "   aws logs tail /ecs/llm-search-engine --follow --region $AWS_REGION"
echo ""
echo "4. Get ALB DNS name:"
echo "   aws elbv2 describe-load-balancers --names llm-alb --query 'LoadBalancers[0].DNSName' --output text --region $AWS_REGION"
echo ""
echo "5. Test endpoints (replace \$ALB_DNS with the DNS name above):"
echo "   curl http://\$ALB_DNS/api/health | jq"
echo "   curl http://\$ALB_DNS/api/info | jq"
echo "   curl -X POST http://\$ALB_DNS/api/search -H 'Content-Type: application/json' -d '{\"query\": \"running shoes\", \"top_k\": 5}' | jq"
echo ""