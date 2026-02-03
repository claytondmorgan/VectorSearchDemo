package com.llm.searchengine.service;

import com.llm.searchengine.dto.SearchRequest;
import com.llm.searchengine.dto.SearchResponse;
import com.llm.searchengine.dto.SearchResult;
import com.llm.searchengine.repository.VectorSearchRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;

import java.util.List;

@Service
public class SearchService {

    private static final Logger logger = LoggerFactory.getLogger(SearchService.class);

    private final EmbeddingService embeddingService;
    private final VectorSearchRepository vectorSearchRepository;

    @Value("${search.default-top-k}")
    private int defaultTopK;

    @Value("${search.max-top-k}")
    private int maxTopK;

    @Value("${search.default-search-field}")
    private String defaultSearchField;

    @Value("${search.similarity-threshold}")
    private double defaultThreshold;

    public SearchService(EmbeddingService embeddingService, VectorSearchRepository vectorSearchRepository) {
        this.embeddingService = embeddingService;
        this.vectorSearchRepository = vectorSearchRepository;
    }

    public SearchResponse search(SearchRequest request) {
        long startTime = System.currentTimeMillis();

        // Apply defaults
        int topK = request.getTopK() != null ? request.getTopK() : defaultTopK;
        topK = Math.min(topK, maxTopK);

        String searchField = request.getSearchField() != null ? request.getSearchField() : defaultSearchField;
        double threshold = request.getSimilarityThreshold() != null ? request.getSimilarityThreshold() : defaultThreshold;

        logger.info("Search: query='{}', topK={}, field={}, threshold={}",
                request.getQuery(), topK, searchField, threshold);

        // Generate embedding
        long embedStart = System.currentTimeMillis();
        float[] embedding = embeddingService.generateEmbedding(request.getQuery());
        long embedTime = System.currentTimeMillis() - embedStart;
        logger.debug("Embedding generated in {}ms", embedTime);

        // Execute vector search
        long searchStart = System.currentTimeMillis();
        List<SearchResult> results;

        if ("title".equals(searchField)) {
            results = vectorSearchRepository.searchByTitle(embedding, topK, threshold);
        } else {
            results = vectorSearchRepository.searchByContent(embedding, topK, threshold);
        }

        long searchTime = System.currentTimeMillis() - searchStart;
        logger.debug("Vector search completed in {}ms, found {} results", searchTime, results.size());

        // Build response
        long totalTime = System.currentTimeMillis() - startTime;

        SearchResponse response = new SearchResponse();
        response.setQuery(request.getQuery());
        response.setSearchField(searchField);
        response.setTotalResults(results.size());
        response.setResults(results);
        response.setLatencyMs(totalTime);

        logger.info("Search completed: {} results in {}ms (embed={}ms, search={}ms)",
                results.size(), totalTime, embedTime, searchTime);

        return response;
    }

    public int getIndexedCount() {
        return vectorSearchRepository.getIndexedCount();
    }
}