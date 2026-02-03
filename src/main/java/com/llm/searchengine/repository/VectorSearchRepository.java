package com.llm.searchengine.repository;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.llm.searchengine.dto.SearchResult;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

import java.sql.Array;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

@Repository
public class VectorSearchRepository {

    private static final Logger logger = LoggerFactory.getLogger(VectorSearchRepository.class);

    private final JdbcTemplate jdbcTemplate;
    private final ObjectMapper objectMapper;

    public VectorSearchRepository(JdbcTemplate jdbcTemplate) {
        this.jdbcTemplate = jdbcTemplate;
        this.objectMapper = new ObjectMapper();
    }

    public List<SearchResult> searchByContent(float[] queryEmbedding, int topK, double threshold) {
        return search(queryEmbedding, topK, threshold, "content_embedding");
    }

    public List<SearchResult> searchByTitle(float[] queryEmbedding, int topK, double threshold) {
        return search(queryEmbedding, topK, threshold, "title_embedding");
    }

    private List<SearchResult> search(float[] queryEmbedding, int topK, double threshold, String column) {
        String vectorStr = toVectorString(queryEmbedding);

        String sql = """
            SELECT id, title, description, category, tags, raw_data,
                   1 - (%s <=> ?::vector) AS similarity
            FROM ingested_records
            WHERE status = 'active'
              AND %s IS NOT NULL
              AND 1 - (%s <=> ?::vector) >= ?
            ORDER BY %s <=> ?::vector
            LIMIT ?
            """.formatted(column, column, column, column);

        logger.debug("Executing vector search on column: {}, topK: {}, threshold: {}", column, topK, threshold);

        return jdbcTemplate.query(
                sql,
                (rs, rowNum) -> mapRow(rs),
                vectorStr, vectorStr, threshold, vectorStr, topK
        );
    }

    private SearchResult mapRow(ResultSet rs) throws SQLException {
        SearchResult result = new SearchResult();
        result.setId(rs.getLong("id"));
        result.setTitle(rs.getString("title"));
        result.setDescription(rs.getString("description"));
        result.setCategory(rs.getString("category"));

        // Parse PostgreSQL text[] array
        Array tagsArray = rs.getArray("tags");
        if (tagsArray != null) {
            result.setTags((String[]) tagsArray.getArray());
        }

        // Parse JSONB raw_data
        String rawDataJson = rs.getString("raw_data");
        if (rawDataJson != null) {
            try {
                Map<String, Object> rawData = objectMapper.readValue(
                        rawDataJson,
                        new TypeReference<Map<String, Object>>() {}
                );
                result.setRawData(rawData);
            } catch (Exception e) {
                logger.warn("Failed to parse raw_data JSON for record {}", result.getId(), e);
            }
        }

        result.setSimilarity(rs.getDouble("similarity"));

        return result;
    }

    public int getIndexedCount() {
        String sql = "SELECT COUNT(*) FROM ingested_records WHERE status = 'active' AND content_embedding IS NOT NULL";
        Integer count = jdbcTemplate.queryForObject(sql, Integer.class);
        return count != null ? count : 0;
    }

    private String toVectorString(float[] embedding) {
        StringBuilder sb = new StringBuilder("[");
        for (int i = 0; i < embedding.length; i++) {
            if (i > 0) {
                sb.append(",");
            }
            sb.append(embedding[i]);
        }
        sb.append("]");
        return sb.toString();
    }
}