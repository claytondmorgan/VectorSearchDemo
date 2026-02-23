package com.llm.searchengine.dto;

import com.fasterxml.jackson.annotation.JsonProperty;
import io.swagger.v3.oas.annotations.media.Schema;

@Schema(description = "Legal document search request parameters")
public class LegalSearchRequest {

    @Schema(
            description = "The search query text to find relevant legal documents",
            example = "employment discrimination reasonable accommodation",
            requiredMode = Schema.RequiredMode.REQUIRED
    )
    private String query;

    @Schema(
            description = "Maximum number of results to return (default: 10, max: 100)",
            example = "10",
            minimum = "1",
            maximum = "100"
    )
    @JsonProperty("top_k")
    private Integer topK;

    @Schema(
            description = "Field to search against: 'content' (default), 'title', 'headnotes', or 'hybrid'",
            example = "content",
            allowableValues = {"content", "title", "headnotes", "hybrid"}
    )
    @JsonProperty("search_field")
    private String searchField;

    @Schema(
            description = "Filter by jurisdiction (e.g., 'US_Supreme_Court', 'CA', 'NY', 'Federal_9th_Circuit')",
            example = "CA"
    )
    private String jurisdiction;

    @Schema(
            description = "Filter by document type (e.g., 'case_law', 'statute', 'regulation', 'practice_guide')",
            example = "case_law"
    )
    @JsonProperty("doc_type")
    private String docType;

    @Schema(
            description = "Filter by legal practice area (e.g., 'employment', 'constitutional_law', 'criminal')",
            example = "employment"
    )
    @JsonProperty("practice_area")
    private String practiceArea;

    @Schema(
            description = "Filter by Shepard's status: 'exclude_overruled' to omit overruled cases",
            example = "exclude_overruled"
    )
    @JsonProperty("status_filter")
    private String statusFilter;

    @Schema(
            description = "Minimum similarity threshold (0.0-1.0). Results below this are filtered out.",
            example = "0.0",
            minimum = "0.0",
            maximum = "1.0"
    )
    @JsonProperty("similarity_threshold")
    private Double similarityThreshold;

    public LegalSearchRequest() {
    }

    public LegalSearchRequest(String query) {
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

    public String getJurisdiction() {
        return jurisdiction;
    }

    public void setJurisdiction(String jurisdiction) {
        this.jurisdiction = jurisdiction;
    }

    public String getDocType() {
        return docType;
    }

    public void setDocType(String docType) {
        this.docType = docType;
    }

    public String getPracticeArea() {
        return practiceArea;
    }

    public void setPracticeArea(String practiceArea) {
        this.practiceArea = practiceArea;
    }

    public String getStatusFilter() {
        return statusFilter;
    }

    public void setStatusFilter(String statusFilter) {
        this.statusFilter = statusFilter;
    }

    public Double getSimilarityThreshold() {
        return similarityThreshold;
    }

    public void setSimilarityThreshold(Double similarityThreshold) {
        this.similarityThreshold = similarityThreshold;
    }
}