package com.llm.searchengine.dto;

import com.fasterxml.jackson.annotation.JsonProperty;
import io.swagger.v3.oas.annotations.media.Schema;

@Schema(description = "Search request parameters")
public class SearchRequest {

    @Schema(
            description = "The search query text to find similar products",
            example = "comfortable running shoes for men",
            requiredMode = Schema.RequiredMode.REQUIRED
    )
    private String query;

    @Schema(
            description = "Maximum number of results to return (default: 10, max: 100)",
            example = "5",
            minimum = "1",
            maximum = "100"
    )
    @JsonProperty("top_k")
    private Integer topK;

    @Schema(
            description = "Field to search against: 'content' (default) or 'title'",
            example = "content",
            allowableValues = {"content", "title"}
    )
    @JsonProperty("search_field")
    private String searchField;

    @Schema(
            description = "Minimum similarity threshold (0.0-1.0). Results below this are filtered out.",
            example = "0.3",
            minimum = "0.0",
            maximum = "1.0"
    )
    @JsonProperty("similarity_threshold")
    private Double similarityThreshold;

    public SearchRequest() {
    }

    public SearchRequest(String query) {
        this.query = query;
    }

    public String getQuery() {
        return query;
    }

    public void setQuery(String query) {
        this.query = query;
    }

    public Integer getTopK() {
        return topK;
    }

    public void setTopK(Integer topK) {
        this.topK = topK;
    }

    public String getSearchField() {
        return searchField;
    }

    public void setSearchField(String searchField) {
        this.searchField = searchField;
    }

    public Double getSimilarityThreshold() {
        return similarityThreshold;
    }

    public void setSimilarityThreshold(Double similarityThreshold) {
        this.similarityThreshold = similarityThreshold;
    }
}
