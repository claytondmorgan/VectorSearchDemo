# LLM Vector Search Engine

A Spring Boot service that provides semantic vector search capabilities using pgvector and delegated embeddings from a Python inference service.

## AWS Deployment

The service is deployed to AWS ECS and accessible via Application Load Balancer.

**Base URL:** `http://llm-alb-1402483560.us-east-1.elb.amazonaws.com`


## API Documentation

### Swagger UI

Interactive API documentation with the ability to test endpoints directly:

http://llm-alb-1402483560.us-east-1.elb.amazonaws.com/swagger-ui/index.html

### OpenAPI Spec

Raw OpenAPI 3.0 specification (JSON):

http://llm-alb-1402483560.us-east-1.elb.amazonaws.com/v3/api-docs

## Quick Start

### Health Check

```bash
curl http://llm-alb-1402483560.us-east-1.elb.amazonaws.com/api/health
```

### Service Info

```bash
curl http://llm-alb-1402483560.us-east-1.elb.amazonaws.com/api/info
```

### Search Example

```bash
curl -X POST http://llm-alb-1402483560.us-east-1.elb.amazonaws.com/api/search \
  -H "Content-Type: application/json" \
  -d '{"query": "comfortable running shoes", "top_k": 5}'
```

## Running the Test Suite

The `test-search-api.sh` script runs a comprehensive test suite against the API.

### Test Against AWS (Production)

```bash
./test-search-api.sh http://llm-alb-1402483560.us-east-1.elb.amazonaws.com
```

### Test Against Local

```bash
./test-search-api.sh
# or explicitly:
./test-search-api.sh http://localhost:8080
```

### Test Output

The script tests:
- Health and info endpoints
- Basic search functionality
- Search field options (title vs content)
- Similarity threshold filtering
- Semantic search quality
- Edge cases and error handling
- Response structure validation
- Performance benchmarks

## API Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/health` | Health check |
| GET | `/api/info` | Service information |
| POST | `/api/search` | Vector similarity search |

### Search Request Body

```json
{
  "query": "search text",
  "top_k": 10,
  "search_field": "content",
  "similarity_threshold": 0.0
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| query | string | required | Search query text |
| top_k | integer | 10 | Number of results (1-100) |
| search_field | string | "content" | Field to search ("content" or "title") |
| similarity_threshold | float | 0.0 | Minimum similarity score (0.0-1.0) |

## Deployment

To deploy changes to AWS:

```bash
./redeploy.sh
```

This script:
1. Builds the project with Maven
2. Creates a Docker image
3. Pushes to ECR
4. Updates the ECS task definition
5. Forces a new deployment
6. Verifies the deployment with health checks