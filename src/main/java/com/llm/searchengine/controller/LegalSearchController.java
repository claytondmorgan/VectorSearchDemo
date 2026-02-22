package com.llm.searchengine.controller;

import com.llm.searchengine.dto.ErrorResponse;
import com.llm.searchengine.dto.LegalSearchRequest;
import com.llm.searchengine.dto.LegalSearchResponse;
import com.llm.searchengine.service.LegalSearchService;
import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.media.Content;
import io.swagger.v3.oas.annotations.media.ExampleObject;
import io.swagger.v3.oas.annotations.media.Schema;
import io.swagger.v3.oas.annotations.responses.ApiResponse;
import io.swagger.v3.oas.annotations.responses.ApiResponses;
import io.swagger.v3.oas.annotations.tags.Tag;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.Map;

@RestController
@RequestMapping("/api/legal")
@Tag(name = "Legal Document Search", description = "Semantic and hybrid search for legal documents with jurisdiction filtering")
public class LegalSearchController {

    private static final Logger logger = LoggerFactory.getLogger(LegalSearchController.class);

    private final LegalSearchService legalSearchService;

    public LegalSearchController(LegalSearchService legalSearchService) {
        this.legalSearchService = legalSearchService;
    }

    @Operation(
            summary = "Legal document search",
            description = """
                    Performs semantic or hybrid search over legal documents (cases, statutes, regulations, practice guides).

                    **Search modes:**
                    - `content` (default): Semantic search against document body text
                    - `title`: Semantic search against document titles
                    - `headnotes`: Semantic search against headnote summaries
                    - `hybrid`: Combines semantic (vector cosine similarity) with keyword (PostgreSQL full-text search)
                      using Reciprocal Rank Fusion (RRF). Best for queries mixing natural language with legal citations.

                    **Filters:**
                    - `jurisdiction`: Limit to a specific jurisdiction (e.g., CA, NY, US_Supreme_Court)
                    - `doc_type`: Limit to document type (case_law, statute, regulation, practice_guide)
                    - `practice_area`: Limit to practice area (employment, constitutional_law, criminal, tort)
                    - `status_filter`: Set to 'exclude_overruled' to omit overruled authorities
                    """
    )
    @ApiResponses(value = {
            @ApiResponse(
                    responseCode = "200",
                    description = "Search completed successfully",
                    content = @Content(
                            mediaType = "application/json",
                            schema = @Schema(implementation = LegalSearchResponse.class)
                    )
            ),
            @ApiResponse(
                    responseCode = "400",
                    description = "Invalid request - query is required",
                    content = @Content(
                            mediaType = "application/json",
                            schema = @Schema(implementation = ErrorResponse.class)
                    )
            ),
            @ApiResponse(
                    responseCode = "503",
                    description = "Service unavailable - model still loading",
                    content = @Content(
                            mediaType = "application/json",
                            schema = @Schema(implementation = ErrorResponse.class)
                    )
            )
    })
    @io.swagger.v3.oas.annotations.parameters.RequestBody(
            description = "Legal search request with query, optional filters, and search mode",
            required = true,
            content = @Content(
                    mediaType = "application/json",
                    schema = @Schema(implementation = LegalSearchRequest.class),
                    examples = {
                            @ExampleObject(
                                    name = "Semantic legal search",
                                    value = """
                                            {
                                              "query": "employment discrimination reasonable accommodation",
                                              "top_k": 10,
                                              "search_field": "content"
                                            }
                                            """
                            ),
                            @ExampleObject(
                                    name = "Hybrid search with jurisdiction filter",
                                    value = """
                                            {
                                              "query": "duty of care negligence standard",
                                              "top_k": 5,
                                              "search_field": "hybrid",
                                              "jurisdiction": "CA"
                                            }
                                            """
                            ),
                            @ExampleObject(
                                    name = "Search excluding overruled cases",
                                    value = """
                                            {
                                              "query": "Miranda rights custodial interrogation",
                                              "top_k": 10,
                                              "search_field": "hybrid",
                                              "status_filter": "exclude_overruled"
                                            }
                                            """
                            ),
                            @ExampleObject(
                                    name = "Citation-specific search",
                                    value = """
                                            {
                                              "query": "42 U.S.C. § 1983 civil rights",
                                              "top_k": 5,
                                              "search_field": "hybrid"
                                            }
                                            """
                            )
                    }
            )
    )
    @PostMapping("/search")
    public ResponseEntity<?> search(@RequestBody LegalSearchRequest request) {
        // Validate query
        if (request.getQuery() == null || request.getQuery().isBlank()) {
            ErrorResponse error = new ErrorResponse(
                    HttpStatus.BAD_REQUEST.value(),
                    "Bad Request",
                    "Query string is required and cannot be empty"
            );
            return ResponseEntity.badRequest().body(error);
        }

        try {
            LegalSearchResponse response = legalSearchService.search(request);
            return ResponseEntity.ok(response);
        } catch (Exception e) {
            logger.error("Legal search failed for query: {}", request.getQuery(), e);
            ErrorResponse error = new ErrorResponse(
                    HttpStatus.INTERNAL_SERVER_ERROR.value(),
                    "Internal Server Error",
                    e.getMessage()
            );
            return ResponseEntity.status(HttpStatus.INTERNAL_SERVER_ERROR).body(error);
        }
    }

    @Operation(
            summary = "Legal search health check",
            description = "Returns health status for the legal document search index including document counts."
    )
    @ApiResponse(responseCode = "200", description = "Health status retrieved")
    @GetMapping("/health")
    public ResponseEntity<Map<String, Object>> health() {
        Map<String, Object> health = new LinkedHashMap<>();

        health.put("service", "Legal Document Search");
        health.put("legal_embedding_model", "freelawproject/modernbert-embed-base_finetune_512");
        health.put("legal_embedding_dimensions", 768);
        health.put("search_delegation", "Python inference service");
        health.put("timestamp", Instant.now().toString());

        try {
            int indexedDocs = legalSearchService.getIndexedCount();
            health.put("status", "healthy");
            health.put("indexed_legal_documents", indexedDocs);
            health.put("database", "connected");
        } catch (Exception e) {
            logger.warn("Failed to get legal document count", e);
            health.put("status", "degraded");
            health.put("database", "error: " + e.getMessage());
        }

        return ResponseEntity.ok(health);
    }

    @Operation(
            summary = "Legal search service information",
            description = "Returns metadata about the legal search service including document counts by type, available endpoints, and search capabilities."
    )
    @ApiResponse(responseCode = "200", description = "Service information retrieved")
    @GetMapping("/info")
    public ResponseEntity<Map<String, Object>> info() {
        Map<String, Object> info = new LinkedHashMap<>();

        info.put("service", "Legal Document Search Engine");
        info.put("version", "1.0.0");
        info.put("framework", "Spring Boot 3.3");
        info.put("language", "Java 17");
        info.put("legal_embedding_model", "freelawproject/modernbert-embed-base_finetune_512");
        info.put("legal_embedding_dimensions", 768);
        info.put("search_delegation", "Python inference service (768-dim ModernBERT legal embeddings)");
        info.put("vector_index", "HNSW (pgvector)");
        info.put("distance_metric", "cosine");
        info.put("search_modes", new String[]{"semantic", "hybrid"});
        info.put("filterable_fields", new String[]{"jurisdiction", "doc_type", "practice_area", "status"});

        Map<String, String> endpoints = new LinkedHashMap<>();
        endpoints.put("POST /api/legal/search", "Legal document search with filters");
        endpoints.put("GET /api/legal/health", "Health check");
        endpoints.put("GET /api/legal/info", "Service information");
        endpoints.put("GET /api/legal/stats", "Document statistics");
        info.put("endpoints", endpoints);

        try {
            info.put("indexed_legal_documents", legalSearchService.getIndexedCount());
            info.put("documents_by_type", legalSearchService.getCountByType());
        } catch (Exception e) {
            info.put("indexed_legal_documents", "unavailable");
        }

        return ResponseEntity.ok(info);
    }

    @Operation(
            summary = "Legal document statistics",
            description = "Returns document counts grouped by jurisdiction, practice area, document type, and Shepard's status."
    )
    @ApiResponse(responseCode = "200", description = "Statistics retrieved")
    @GetMapping("/stats")
    public ResponseEntity<Map<String, Object>> stats() {
        Map<String, Object> stats = new LinkedHashMap<>();

        try {
            stats.put("total_documents", legalSearchService.getIndexedCount());
            stats.put("by_doc_type", legalSearchService.getCountByType());
            stats.put("by_jurisdiction", legalSearchService.getCountByJurisdiction());
            stats.put("by_practice_area", legalSearchService.getCountByPracticeArea());
            stats.put("by_status", legalSearchService.getCountByStatus());
        } catch (Exception e) {
            logger.error("Failed to retrieve legal document stats", e);
            stats.put("error", e.getMessage());
        }

        return ResponseEntity.ok(stats);
    }
}