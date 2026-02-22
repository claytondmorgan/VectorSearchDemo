# LLM Vector Search Engine

A Spring Boot service that provides semantic and hybrid vector search for both product data and legal documents, using pgvector and delegated embeddings from a Python inference service.

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
# Product search health
curl http://llm-alb-1402483560.us-east-1.elb.amazonaws.com/api/health

# Legal search health
curl http://llm-alb-1402483560.us-east-1.elb.amazonaws.com/api/legal/health
```

### Service Info

```bash
curl http://llm-alb-1402483560.us-east-1.elb.amazonaws.com/api/info
curl http://llm-alb-1402483560.us-east-1.elb.amazonaws.com/api/legal/info
```

### Product Search Example

```bash
curl -X POST http://llm-alb-1402483560.us-east-1.elb.amazonaws.com/api/search \
  -H "Content-Type: application/json" \
  -d '{"query": "comfortable running shoes", "top_k": 5}'
```

### Legal Document Search Examples

```bash
# Semantic search
curl -X POST http://llm-alb-1402483560.us-east-1.elb.amazonaws.com/api/legal/search \
  -H "Content-Type: application/json" \
  -d '{"query": "employment discrimination reasonable accommodation", "top_k": 5}'

# Hybrid search (semantic + keyword with Reciprocal Rank Fusion)
curl -X POST http://llm-alb-1402483560.us-east-1.elb.amazonaws.com/api/legal/search \
  -H "Content-Type: application/json" \
  -d '{"query": "42 U.S.C. § 1983 civil rights", "top_k": 5, "search_field": "hybrid"}'

# Jurisdiction filtering
curl -X POST http://llm-alb-1402483560.us-east-1.elb.amazonaws.com/api/legal/search \
  -H "Content-Type: application/json" \
  -d '{"query": "wrongful termination", "top_k": 5, "jurisdiction": "CA"}'

# Exclude overruled cases (Shepard's-style filtering)
curl -X POST http://llm-alb-1402483560.us-east-1.elb.amazonaws.com/api/legal/search \
  -H "Content-Type: application/json" \
  -d '{"query": "separate but equal", "top_k": 10, "status_filter": "exclude_overruled"}'
```

### Legal Document Statistics

```bash
curl http://llm-alb-1402483560.us-east-1.elb.amazonaws.com/api/legal/stats
```

## API Endpoints

### Product Search

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/health` | Health check |
| GET | `/api/info` | Service information |
| POST | `/api/search` | Vector similarity search |

### Legal Document Search

| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/api/legal/search` | Semantic/hybrid search with metadata filters |
| GET | `/api/legal/health` | Legal search health check |
| GET | `/api/legal/info` | Legal service info and capabilities |
| GET | `/api/legal/stats` | Document counts by type, jurisdiction, practice area, status |

### Product Search Request

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

### Legal Search Request

```json
{
  "query": "employment discrimination reasonable accommodation",
  "top_k": 10,
  "search_field": "content",
  "jurisdiction": "CA",
  "doc_type": "case_law",
  "practice_area": "employment",
  "status_filter": "exclude_overruled"
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| query | string | required | Search query text |
| top_k | integer | 10 | Number of results (1-100) |
| search_field | string | "content" | `content`, `title`, `headnotes`, or `hybrid` |
| jurisdiction | string | null | Filter: `US_Supreme_Court`, `CA`, `NY`, `Federal_9th_Circuit`, etc. |
| doc_type | string | null | Filter: `case_law`, `statute`, `regulation`, `practice_guide` |
| practice_area | string | null | Filter: `employment`, `constitutional_law`, `criminal`, `tort`, etc. |
| status_filter | string | null | `exclude_overruled` to omit overruled authorities |
| similarity_threshold | float | 0.0 | Minimum similarity score (0.0-1.0) |

## Architecture

```
                    Client (curl / Swagger UI)
                         |
                         v
              ┌─────────────────────┐
              │   ALB (port 80)     │
              │   /api/*  -> :8080  │
              │   /*      -> :8000  │
              └────────┬────────────┘
                       |
          ┌────────────┴────────────┐
          |                         |
    ┌─────▼──────────┐     ┌───────▼─────────────┐
    │  Java Service   │     │  Python Service      │
    │  Spring Boot    │     │  FastAPI              │
    │  port 8080      │     │  port 8000            │
    │                 │     │                       │
    │ /api/search     │────>│ POST /embed (384-dim) │
    │ (product)       │     │ all-MiniLM-L6-v2      │
    │                 │     │                       │
    │ /api/legal/*    │────>│ POST /legal/search    │
    │ (legal search)  │     │ ModernBERT (768-dim)  │
    │                 │     │                       │
    │ /api/legal/stats│     │ POST /legal/rag       │
    │ (direct DB)     │     │ Phi-3.5 Mini          │
    └────────┬────────┘     └───────┬───────────────┘
             |                      |
             └──────────┬───────────┘
                        |
               ┌────────▼────────┐
               │  PostgreSQL RDS │
               │  + pgvector     │
               │                 │
               │ ingested_records│  384-dim (products)
               │ legal_documents │  768-dim (legal)
               │ HNSW indexes   │
               └─────────────────┘
```

### Key Design Decisions

- **Product search**: Java generates 384-dim embeddings via Python `/embed`, then queries `ingested_records` directly
- **Legal search**: Java delegates to Python `/legal/search` because legal documents use a different 768-dim embedding model (ModernBERT Legal). The embedding model is only loaded in Python, so search execution stays there.
- **Stats/counts**: Java queries `legal_documents` table directly (no embeddings needed)
- **Hybrid search**: Combines semantic (vector cosine similarity via HNSW) with keyword (PostgreSQL tsvector/GIN) using Reciprocal Rank Fusion

## Running the Test Suites

### Product Search Tests (26 tests)

```bash
# Against AWS
./test-search-api.sh http://llm-alb-1402483560.us-east-1.elb.amazonaws.com

# Against local
./test-search-api.sh
```

### Legal Search Tests (29 tests)

```bash
# Against AWS
./test-legal-api.sh http://llm-alb-1402483560.us-east-1.elb.amazonaws.com

# Against local
./test-legal-api.sh
```

### Verbose Mode

Both test scripts support a `-v` / `--verbose` flag. By default tests print a compact pass/fail line per test. With verbose enabled, each test shows:

- **Curl command** — the exact request being issued (method, URL, payload)
- **Response metrics** — HTTP status, response size, and timing breakdown (DNS lookup, TCP connect, time-to-first-byte, total)
- **Search details** — result count, search method, API latency, and the top-ranked hit with similarity score
- **Performance stats** — per-query latency during the 10-query benchmark, plus min/max/avg/P95 summary
- **AWS cost estimate** — incremental ALB and data transfer costs for the test run, with LCU breakdown

```bash
# Verbose product tests
./test-search-api.sh -v http://llm-alb-1402483560.us-east-1.elb.amazonaws.com

# Verbose legal tests
./test-legal-api.sh --verbose http://llm-alb-1402483560.us-east-1.elb.amazonaws.com
```

The flag can appear before or after the base URL.

### Test Coverage

**Product tests** (`test-search-api.sh`):
- Health and info endpoints
- Basic search with various top_k
- Search field options (title vs content)
- Similarity threshold filtering
- Semantic search quality
- Edge cases and error handling
- Response structure validation
- Performance benchmarks (10 sequential searches)

**Legal tests** (`test-legal-api.sh`):
- Health, info, and stats endpoints
- Semantic search (employment discrimination, negligence, Miranda rights, etc.)
- Hybrid search (statute citations, civil rights, ADA)
- Jurisdiction filtering (CA vs NY vs US Supreme Court)
- Shepard's status filtering (exclude overruled)
- Document type filtering (statutes vs case law vs practice guides)
- Semantic vs hybrid comparison (citation symbol handling)
- Edge cases (empty query, missing fields, combined filters)
- Response structure validation (legal-specific fields)
- Performance benchmarks (10 sequential legal searches)

## Deployment

### Full Legal Deployment (DB + build + deploy + verify)

```bash
./deploy-legal.sh
```

### Java-Only Redeploy (skip DB setup)

```bash
./deploy-legal.sh --skip-db
```

### Product-Only Redeploy

```bash
./redeploy.sh
```

### Database Schema Setup

```bash
./setup-legal-db.sh
```

### Deployment Steps

`deploy-legal.sh` performs:
1. Creates `legal_documents` table in RDS (if not exists)
2. Builds the project with Maven
3. Creates a Docker image (linux/amd64)
4. Pushes to ECR
5. Updates the ECS task definition
6. Forces a new ECS deployment
7. Waits for rollout to stabilize
8. Verifies both product and legal search endpoints
