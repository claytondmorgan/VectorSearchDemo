package com.llm.searchengine.dto;

import com.fasterxml.jackson.annotation.JsonInclude;
import com.fasterxml.jackson.annotation.JsonProperty;

import java.util.List;

@JsonInclude(JsonInclude.Include.NON_NULL)
public class LegalSearchResponse {

    private String query;

    @JsonProperty("search_field")
    private String searchField;

    @JsonProperty("total_results")
    private int totalResults;

    private List<LegalSearchResult> results;

    @JsonProperty("latency_ms")
    private long latencyMs;

    @JsonProperty("search_method")
    private String searchMethod;

    public LegalSearchResponse() {
    }

    public String getQuery() {
        return query;
    }

    public void setQuery(String query) {
        this.query = query;
    }

    public String getSearchField() {
        return searchField;
    }

    public void setSearchField(String searchField) {
        this.searchField = searchField;
    }

    public int getTotalResults() {
        return totalResults;
    }

    public void setTotalResults(int totalResults) {
        this.totalResults = totalResults;
    }

    public List<LegalSearchResult> getResults() {
        return results;
    }

    public void setResults(List<LegalSearchResult> results) {
        this.results = results;
    }

    public long getLatencyMs() {
        return latencyMs;
    }

    public void setLatencyMs(long latencyMs) {
        this.latencyMs = latencyMs;
    }

    public String getSearchMethod() {
        return searchMethod;
    }

    public void setSearchMethod(String searchMethod) {
        this.searchMethod = searchMethod;
    }
}