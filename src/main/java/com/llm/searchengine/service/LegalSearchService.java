package com.llm.searchengine.service;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.llm.searchengine.dto.LegalSearchRequest;
import com.llm.searchengine.dto.LegalSearchResponse;
import com.llm.searchengine.dto.LegalSearchResult;
import com.llm.searchengine.repository.LegalSearchRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Delegates legal document search to the Python inference service.
 *
 * The Python service uses a 768-dim ModernBERT legal embedding model
 * (freelawproject/modernbert-embed-base_finetune_512) which is different
 * from the 384-dim all-MiniLM-L6-v2 used for product search.
 * Since the legal embedding model is only available in Python,
 * search requests are proxied to POST /legal/search on the Python service.
 *
 * Stats/count queries go directly to the database via LegalSearchRepository
 * since they don't require embeddings.
 */
@Service
public class LegalSearchService {

    private static final Logger logger = LoggerFactory.getLogger(LegalSearchService.class);

    private final LegalSearchRepository legalSearchRepository;
    private final HttpClient httpClient;
    private final ObjectMapper objectMapper;

    @Value("${embedding.service.url}")
    private String pythonServiceUrl;

    @Value("${embedding.service.timeout-ms:5000}")
    private int timeoutMs;

    @Value("${search.default-top-k}")
    private int defaultTopK;

    @Value("${search.max-top-k}")
    private int maxTopK;

    @Value("${search.default-search-field}")
    private String defaultSearchField;

    public LegalSearchService(LegalSearchRepository legalSearchRepository) {
        this.legalSearchRepository = legalSearchRepository;
        this.httpClient = HttpClient.newBuilder()
                .connectTimeout(Duration.ofSeconds(10))
                .build();
        this.objectMapper = new ObjectMapper();
    }

    /**
     * Delegates legal search to the Python service's POST /legal/search endpoint.
     * The Python service generates 768-dim legal embeddings and queries the
     * legal_documents table, then returns ranked results.
     */
    public LegalSearchResponse search(LegalSearchRequest request) {
        long startTime = System.currentTimeMillis();

        // Apply defaults
        int topK = request.getTopK() != null ? request.getTopK() : defaultTopK;
        topK = Math.min(topK, maxTopK);
        String searchField = request.getSearchField() != null ? request.getSearchField() : defaultSearchField;

        logger.info("Legal search (delegated): query='{}', topK={}, field={}, jurisdiction={}, docType={}, practiceArea={}, statusFilter={}",
                request.getQuery(), topK, searchField,
                request.getJurisdiction(), request.getDocType(), request.getPracticeArea(), request.getStatusFilter());

        try {
            // Build request body matching Python's LegalSearchRequest model
            Map<String, Object> requestBody = new LinkedHashMap<>();
            requestBody.put("query", request.getQuery());
            requestBody.put("top_k", topK);
            requestBody.put("search_field", searchField);

            if (request.getJurisdiction() != null && !request.getJurisdiction().isBlank()) {
                requestBody.put("jurisdiction", request.getJurisdiction());
            }
            if (request.getDocType() != null && !request.getDocType().isBlank()) {
                requestBody.put("doc_type", request.getDocType());
            }
            if (request.getPracticeArea() != null && !request.getPracticeArea().isBlank()) {
                requestBody.put("practice_area", request.getPracticeArea());
            }
            if (request.getStatusFilter() != null && !request.getStatusFilter().isBlank()) {
                requestBody.put("status_filter", request.getStatusFilter());
            }

            String jsonBody = objectMapper.writeValueAsString(requestBody);

            HttpRequest httpRequest = HttpRequest.newBuilder()
                    .uri(URI.create(pythonServiceUrl + "/legal/search"))
                    .header("Content-Type", "application/json")
                    .timeout(Duration.ofMillis(timeoutMs))
                    .POST(HttpRequest.BodyPublishers.ofString(jsonBody))
                    .build();

            logger.debug("Calling Python legal search: {}/legal/search", pythonServiceUrl);

            HttpResponse<String> httpResponse = httpClient.send(httpRequest, HttpResponse.BodyHandlers.ofString());

            if (httpResponse.statusCode() != 200) {
                throw new RuntimeException("Python legal search returned HTTP " + httpResponse.statusCode() + ": " + httpResponse.body());
            }

            // Python returns List[LegalSearchResult] directly
            List<LegalSearchResult> results = objectMapper.readValue(
                    httpResponse.body(),
                    new TypeReference<List<LegalSearchResult>>() {}
            );

            long totalTime = System.currentTimeMillis() - startTime;

            // Determine search method from results
            String searchMethod = searchField.equals("hybrid") ? "hybrid" : "semantic";
            if (!results.isEmpty() && results.get(0).getSearchMethod() != null) {
                // If results have mixed methods (hybrid), keep "hybrid"
                boolean hasKeyword = results.stream().anyMatch(r -> "keyword".equals(r.getSearchMethod()));
                boolean hasSemantic = results.stream().anyMatch(r -> "semantic".equals(r.getSearchMethod()));
                if (hasKeyword && hasSemantic) {
                    searchMethod = "hybrid";
                } else if (hasKeyword) {
                    searchMethod = "keyword";
                }
            }

            LegalSearchResponse response = new LegalSearchResponse();
            response.setQuery(request.getQuery());
            response.setSearchField(searchField);
            response.setTotalResults(results.size());
            response.setResults(results);
            response.setLatencyMs(totalTime);
            response.setSearchMethod(searchMethod);

            logger.info("Legal search completed: {} results in {}ms (delegated to Python)",
                    results.size(), totalTime);

            return response;

        } catch (Exception e) {
            logger.error("Legal search delegation failed for query: '{}'", request.getQuery(), e);
            throw new RuntimeException("Legal search failed: " + e.getMessage(), e);
        }
    }

    public int getIndexedCount() {
        return legalSearchRepository.getIndexedCount();
    }

    public Map<String, Integer> getCountByType() {
        return legalSearchRepository.getCountByType();
    }

    public Map<String, Integer> getCountByJurisdiction() {
        return legalSearchRepository.getCountByJurisdiction();
    }

    public Map<String, Integer> getCountByPracticeArea() {
        return legalSearchRepository.getCountByPracticeArea();
    }

    public Map<String, Integer> getCountByStatus() {
        return legalSearchRepository.getCountByStatus();
    }
}