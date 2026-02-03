package com.llm.searchengine.controller;

import com.llm.searchengine.dto.ErrorResponse;
import com.llm.searchengine.dto.SearchRequest;
import com.llm.searchengine.dto.SearchResponse;
import com.llm.searchengine.service.EmbeddingService;
import com.llm.searchengine.service.SearchService;
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
@RequestMapping("/api")
@Tag(name = "Vector Search", description = "Semantic vector search operations")
public class SearchController {

    private static final Logger logger = LoggerFactory.getLogger(SearchController.class);

    private final SearchService searchService;
    private final EmbeddingService embeddingService;

    public SearchController(SearchService searchService, EmbeddingService embeddingService) {
        this.searchService = searchService;
        this.embeddingService = embeddingService;
    }

    @Operation(
            summary = "Semantic vector search api",
            description = """
                    Performs semantic similarity search using vector embeddings.

                    The query text is converted to a 384-dimensional embedding using the all-MiniLM-L6-v2 model,
                    then compared against indexed product embeddings using cosine similarity via pgvector's HNSW index.

                    Results are sorted by similarity score (higher = more relevant).
                    """
    )
    @ApiResponses(value = {
            @ApiResponse(
                    responseCode = "200",
                    description = "Search completed successfully",
                    content = @Content(
                            mediaType = "application/json",
                            schema = @Schema(implementation = SearchResponse.class)
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
            description = "Search request with query and optional parameters",
            required = true,
            content = @Content(
                    mediaType = "application/json",
                    schema = @Schema(implementation = SearchRequest.class),
                    examples = {
                            @ExampleObject(
                                    name = "Basic search",
                                    value = """
                                            {
                                              "query": "comfortable running shoes for men",
                                              "top_k": 5
                                            }
                                            """
                            ),
                            @ExampleObject(
                                    name = "Search by title",
                                    value = """
                                            {
                                              "query": "wireless headphones",
                                              "top_k": 10,
                                              "search_field": "title"
                                            }
                                            """
                            ),
                            @ExampleObject(
                                    name = "Search with threshold",
                                    value = """
                                            {
                                              "query": "waterproof hiking jacket",
                                              "top_k": 5,
                                              "similarity_threshold": 0.3
                                            }
                                            """
                            )
                    }
            )
    )
    @PostMapping("/search")
    public ResponseEntity<?> search(@RequestBody SearchRequest request) {
        // Validate query
        if (request.getQuery() == null || request.getQuery().isBlank()) {
            ErrorResponse error = new ErrorResponse(
                    HttpStatus.BAD_REQUEST.value(),
                    "Bad Request",
                    "Query string is required and cannot be empty"
            );
            return ResponseEntity.badRequest().body(error);
        }

        // Check if model is ready
        if (!embeddingService.isReady()) {
            ErrorResponse error = new ErrorResponse(
                    HttpStatus.SERVICE_UNAVAILABLE.value(),
                    "Service Unavailable",
                    "Embedding model is still loading"
            );
            return ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE).body(error);
        }

        try {
            SearchResponse response = searchService.search(request);
            return ResponseEntity.ok(response);
        } catch (Exception e) {
            logger.error("Search failed for query: {}", request.getQuery(), e);
            ErrorResponse error = new ErrorResponse(
                    HttpStatus.INTERNAL_SERVER_ERROR.value(),
                    "Internal Server Error",
                    e.getMessage()
            );
            return ResponseEntity.status(HttpStatus.INTERNAL_SERVER_ERROR).body(error);
        }
    }

    @Operation(
            summary = "Health check",
            description = "Returns service health status including embedding model state and database connectivity."
    )
    @ApiResponses(value = {
            @ApiResponse(
                    responseCode = "200",
                    description = "Service is healthy",
                    content = @Content(mediaType = "application/json")
            ),
            @ApiResponse(
                    responseCode = "503",
                    description = "Service is initializing",
                    content = @Content(mediaType = "application/json")
            )
    })
    @GetMapping("/health")
    public ResponseEntity<Map<String, Object>> health() {
        Map<String, Object> health = new LinkedHashMap<>();

        boolean modelReady = embeddingService.isReady();
        health.put("status", modelReady ? "healthy" : "initializing");
        health.put("embedding_model", embeddingService.getModelName());
        health.put("embedding_dimensions", embeddingService.getDimensions());
        health.put("model_ready", modelReady);
        health.put("timestamp", Instant.now().toString());

        if (modelReady) {
            try {
                int indexedRecords = searchService.getIndexedCount();
                health.put("indexed_records", indexedRecords);
                health.put("database", "connected");
            } catch (Exception e) {
                logger.warn("Failed to get indexed count", e);
                health.put("database", "error: " + e.getMessage());
            }
        }

        HttpStatus status = modelReady ? HttpStatus.OK : HttpStatus.SERVICE_UNAVAILABLE;
        return ResponseEntity.status(status).body(health);
    }

    @Operation(
            summary = "Service information",
            description = "Returns metadata about the service including version, embedding model, and available endpoints."
    )
    @ApiResponse(
            responseCode = "200",
            description = "Service information retrieved",
            content = @Content(mediaType = "application/json")
    )
    @GetMapping("/info")
    public ResponseEntity<Map<String, Object>> info() {
        Map<String, Object> info = new LinkedHashMap<>();

        info.put("service", "LLM Vector Search Engine");
        info.put("version", "1.0.0");
        info.put("framework", "Spring Boot 3.3");
        info.put("language", "Java 17");
        info.put("embedding_model", embeddingService.getModelName());
        info.put("embedding_dimensions", embeddingService.getDimensions());
        info.put("vector_index", "HNSW (pgvector)");
        info.put("distance_metric", "cosine");

        Map<String, String> endpoints = new LinkedHashMap<>();
        endpoints.put("POST /api/search", "Vector similarity search");
        endpoints.put("GET /api/health", "Health check");
        endpoints.put("GET /api/info", "Service information");
        endpoints.put("GET /swagger-ui.html", "Swagger UI");
        info.put("endpoints", endpoints);

        try {
            info.put("indexed_records", searchService.getIndexedCount());
        } catch (Exception e) {
            info.put("indexed_records", "unavailable");
        }

        return ResponseEntity.ok(info);
    }
}
