package com.llm.searchengine.service;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import jakarta.annotation.PostConstruct;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;

/**
 * Delegates embedding generation to the Python inference service.
 *
 * Instead of running the model locally via ONNX Runtime, this service
 * calls the Python service's /embed endpoint. This ensures a single
 * source of truth for the embedding model — when the model is fine-tuned
 * or swapped, only the Python service needs to be updated.
 */
@Service
public class EmbeddingService {

    private static final Logger log = LoggerFactory.getLogger(EmbeddingService.class);

    @Value("${embedding.service.url}")
    private String embeddingServiceUrl;

    @Value("${embedding.service.timeout-ms:5000}")
    private int timeoutMs;

    @Value("${embedding.model.name:delegated-to-python}")
    private String modelName;

    @Value("${embedding.model.dimensions:384}")
    private int dimensions;

    private HttpClient httpClient;
    private ObjectMapper objectMapper;
    private boolean ready = false;

    @PostConstruct
    public void init() {
        log.info("Initializing embedding service (delegated to Python at {})", embeddingServiceUrl);

        httpClient = HttpClient.newBuilder()
                .connectTimeout(Duration.ofMillis(timeoutMs))
                .build();
        objectMapper = new ObjectMapper();

        // Verify the Python service is reachable
        try {
            float[] testEmbedding = generateEmbedding("test");
            if (testEmbedding.length == dimensions) {
                ready = true;
                log.info("Embedding service ready (Python responded with {}-dim vector)", testEmbedding.length);
            } else {
                log.warn("Unexpected embedding dimensions: expected {}, got {}", dimensions, testEmbedding.length);
                ready = true; // still usable, just log the warning
                dimensions = testEmbedding.length;
            }
        } catch (Exception e) {
            log.warn("Python embedding service not reachable at startup: {}. Will retry on first request.", e.getMessage());
            ready = true; // allow startup even if Python isn't ready yet — it may start later
        }
    }

    /**
     * Generate an embedding by calling the Python service's /embed endpoint.
     *
     * POST {embeddingServiceUrl}/embed
     * Body: {"text": "query text"}
     * Response: {"embedding": [0.1, 0.2, ...], "dimensions": 384, "model": "..."}
     */
    public float[] generateEmbedding(String text) {
        try {
            String requestBody = objectMapper.writeValueAsString(
                    java.util.Map.of("text", text)
            );

            HttpRequest request = HttpRequest.newBuilder()
                    .uri(URI.create(embeddingServiceUrl + "/embed"))
                    .header("Content-Type", "application/json")
                    .timeout(Duration.ofMillis(timeoutMs))
                    .POST(HttpRequest.BodyPublishers.ofString(requestBody))
                    .build();

            HttpResponse<String> response = httpClient.send(request, HttpResponse.BodyHandlers.ofString());

            if (response.statusCode() != 200) {
                throw new RuntimeException("Python embedding service returned HTTP " + response.statusCode() + ": " + response.body());
            }

            JsonNode json = objectMapper.readTree(response.body());
            JsonNode embeddingNode = json.get("embedding");

            if (embeddingNode == null || !embeddingNode.isArray()) {
                throw new RuntimeException("Invalid response from Python embedding service: missing 'embedding' array");
            }

            float[] embedding = new float[embeddingNode.size()];
            for (int i = 0; i < embeddingNode.size(); i++) {
                embedding[i] = (float) embeddingNode.get(i).asDouble();
            }

            // Update model name from Python response if available
            JsonNode modelNode = json.get("model");
            if (modelNode != null) {
                modelName = modelNode.asText();
            }

            return embedding;

        } catch (Exception e) {
            log.error("Failed to get embedding from Python service for text: '{}'",
                    text.substring(0, Math.min(50, text.length())), e);
            throw new RuntimeException("Embedding generation failed: " + e.getMessage(), e);
        }
    }

    public boolean isReady() {
        return ready;
    }

    public int getDimensions() {
        return dimensions;
    }

    public String getModelName() {
        return modelName;
    }
}