package com.llm.searchengine.repository;

import com.llm.searchengine.dto.LegalSearchResult;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

@Repository
public class LegalSearchRepository {

    private static final Logger logger = LoggerFactory.getLogger(LegalSearchRepository.class);

    private final JdbcTemplate jdbcTemplate;

    public LegalSearchRepository(JdbcTemplate jdbcTemplate) {
        this.jdbcTemplate = jdbcTemplate;
    }

    public List<LegalSearchResult> searchByContent(float[] queryEmbedding, int topK, double threshold,
                                                    String jurisdiction, String docType, String practiceArea, String statusFilter) {
        return semanticSearch(queryEmbedding, topK, threshold, "content_embedding",
                jurisdiction, docType, practiceArea, statusFilter);
    }

    public List<LegalSearchResult> searchByTitle(float[] queryEmbedding, int topK, double threshold,
                                                  String jurisdiction, String docType, String practiceArea, String statusFilter) {
        return semanticSearch(queryEmbedding, topK, threshold, "title_embedding",
                jurisdiction, docType, practiceArea, statusFilter);
    }

    public List<LegalSearchResult> searchByHeadnote(float[] queryEmbedding, int topK, double threshold,
                                                     String jurisdiction, String docType, String practiceArea, String statusFilter) {
        return semanticSearch(queryEmbedding, topK, threshold, "headnote_embedding",
                jurisdiction, docType, practiceArea, statusFilter);
    }

    /**
     * Hybrid search combining semantic (vector cosine similarity) with keyword (PostgreSQL full-text search)
     * using Reciprocal Rank Fusion (RRF) to merge the two ranked lists.
     */
    public List<LegalSearchResult> hybridSearch(float[] queryEmbedding, String queryText, int topK, double threshold,
                                                 String jurisdiction, String docType, String practiceArea, String statusFilter) {
        String vectorStr = toVectorString(queryEmbedding);

        // Build WHERE clauses for filtering
        StringBuilder filterClause = new StringBuilder();
        List<Object> params = new ArrayList<>();

        filterClause.append(" WHERE content_embedding IS NOT NULL");

        if (jurisdiction != null && !jurisdiction.isBlank()) {
            filterClause.append(" AND jurisdiction = ?");
            params.add(jurisdiction);
        }
        if (docType != null && !docType.isBlank()) {
            filterClause.append(" AND doc_type = ?");
            params.add(docType);
        }
        if (practiceArea != null && !practiceArea.isBlank()) {
            filterClause.append(" AND practice_area = ?");
            params.add(practiceArea);
        }
        if ("exclude_overruled".equals(statusFilter)) {
            filterClause.append(" AND status != 'overruled'");
        }

        String filter = filterClause.toString();

        // Build the hybrid query using RRF
        // Semantic search CTE
        String sql = """
            WITH semantic AS (
                SELECT id, doc_id, doc_type, title, citation, jurisdiction, court,
                       practice_area, status, LEFT(content, 300) as content_snippet,
                       1 - (content_embedding <=> ?::vector) AS similarity,
                       ROW_NUMBER() OVER (ORDER BY content_embedding <=> ?::vector) AS sem_rank
                FROM legal_documents
                %s
                  AND 1 - (content_embedding <=> ?::vector) >= ?
                LIMIT 20
            ),
            keyword AS (
                SELECT id, doc_id, doc_type, title, citation, jurisdiction, court,
                       practice_area, status, LEFT(content, 300) as content_snippet,
                       ts_rank(content_tsv, plainto_tsquery('english', ?)) AS kw_score,
                       ROW_NUMBER() OVER (ORDER BY ts_rank(content_tsv, plainto_tsquery('english', ?)) DESC) AS kw_rank
                FROM legal_documents
                %s
                  AND content_tsv @@ plainto_tsquery('english', ?)
                LIMIT 20
            )
            SELECT COALESCE(s.id, k.id) as id,
                   COALESCE(s.doc_id, k.doc_id) as doc_id,
                   COALESCE(s.doc_type, k.doc_type) as doc_type,
                   COALESCE(s.title, k.title) as title,
                   COALESCE(s.citation, k.citation) as citation,
                   COALESCE(s.jurisdiction, k.jurisdiction) as jurisdiction,
                   COALESCE(s.court, k.court) as court,
                   COALESCE(s.practice_area, k.practice_area) as practice_area,
                   COALESCE(s.status, k.status) as status,
                   COALESCE(s.content_snippet, k.content_snippet) as content_snippet,
                   COALESCE(s.similarity, 0) as similarity,
                   COALESCE(1.0/(60 + s.sem_rank), 0) + COALESCE(1.0/(60 + k.kw_rank), 0) AS rrf_score,
                   CASE
                       WHEN s.id IS NOT NULL AND k.id IS NOT NULL THEN 'hybrid'
                       WHEN s.id IS NOT NULL THEN 'semantic'
                       ELSE 'keyword'
                   END as search_method
            FROM semantic s
            FULL OUTER JOIN keyword k ON s.id = k.id
            ORDER BY rrf_score DESC
            LIMIT ?
            """.formatted(filter, filter);

        // Build parameter list:
        // Semantic CTE params: vectorStr, vectorStr, [filter params], vectorStr, threshold
        // Keyword CTE params: queryText, queryText, [filter params], queryText
        // Final: topK
        List<Object> allParams = new ArrayList<>();

        // Semantic CTE
        allParams.add(vectorStr);
        allParams.add(vectorStr);
        allParams.addAll(params); // filter params for semantic
        allParams.add(vectorStr);
        allParams.add(threshold);

        // Keyword CTE
        allParams.add(queryText);
        allParams.add(queryText);
        allParams.addAll(params); // filter params for keyword
        allParams.add(queryText);

        // Final LIMIT
        allParams.add(topK);

        logger.debug("Executing hybrid search: query='{}', topK={}, filters=[jurisdiction={}, docType={}, practiceArea={}, status={}]",
                queryText, topK, jurisdiction, docType, practiceArea, statusFilter);

        return jdbcTemplate.query(
                sql,
                (rs, rowNum) -> mapHybridRow(rs),
                allParams.toArray()
        );
    }

    /**
     * Semantic-only search on a specified embedding column with metadata filters.
     */
    private List<LegalSearchResult> semanticSearch(float[] queryEmbedding, int topK, double threshold,
                                                    String embeddingColumn,
                                                    String jurisdiction, String docType, String practiceArea, String statusFilter) {
        String vectorStr = toVectorString(queryEmbedding);

        StringBuilder filterClause = new StringBuilder();
        List<Object> params = new ArrayList<>();

        // Vector string used 3 times in the query
        params.add(vectorStr);
        params.add(vectorStr);

        filterClause.append(" WHERE ").append(embeddingColumn).append(" IS NOT NULL");

        if (jurisdiction != null && !jurisdiction.isBlank()) {
            filterClause.append(" AND jurisdiction = ?");
            params.add(jurisdiction);
        }
        if (docType != null && !docType.isBlank()) {
            filterClause.append(" AND doc_type = ?");
            params.add(docType);
        }
        if (practiceArea != null && !practiceArea.isBlank()) {
            filterClause.append(" AND practice_area = ?");
            params.add(practiceArea);
        }
        if ("exclude_overruled".equals(statusFilter)) {
            filterClause.append(" AND status != 'overruled'");
        }

        params.add(threshold);
        params.add(vectorStr);
        params.add(topK);

        String sql = """
            SELECT id, doc_id, doc_type, title, citation, jurisdiction, court,
                   practice_area, status, LEFT(content, 300) as content_snippet,
                   1 - (%s <=> ?::vector) AS similarity
            FROM legal_documents
            %s
              AND 1 - (%s <=> ?::vector) >= ?
            ORDER BY %s <=> ?::vector
            LIMIT ?
            """.formatted(embeddingColumn, filterClause.toString(), embeddingColumn, embeddingColumn);

        logger.debug("Executing semantic search on column: {}, topK: {}, threshold: {}", embeddingColumn, topK, threshold);

        return jdbcTemplate.query(
                sql,
                (rs, rowNum) -> mapSemanticRow(rs),
                params.toArray()
        );
    }

    private LegalSearchResult mapSemanticRow(ResultSet rs) throws SQLException {
        LegalSearchResult result = new LegalSearchResult();
        result.setId(rs.getInt("id"));
        result.setDocId(rs.getString("doc_id"));
        result.setDocType(rs.getString("doc_type"));
        result.setTitle(rs.getString("title"));
        result.setCitation(rs.getString("citation"));
        result.setJurisdiction(rs.getString("jurisdiction"));
        result.setCourt(rs.getString("court"));
        result.setPracticeArea(rs.getString("practice_area"));
        result.setStatus(rs.getString("status"));
        result.setContentSnippet(rs.getString("content_snippet"));
        result.setSimilarity(rs.getDouble("similarity"));
        result.setSearchMethod("semantic");
        return result;
    }

    private LegalSearchResult mapHybridRow(ResultSet rs) throws SQLException {
        LegalSearchResult result = new LegalSearchResult();
        result.setId(rs.getInt("id"));
        result.setDocId(rs.getString("doc_id"));
        result.setDocType(rs.getString("doc_type"));
        result.setTitle(rs.getString("title"));
        result.setCitation(rs.getString("citation"));
        result.setJurisdiction(rs.getString("jurisdiction"));
        result.setCourt(rs.getString("court"));
        result.setPracticeArea(rs.getString("practice_area"));
        result.setStatus(rs.getString("status"));
        result.setContentSnippet(rs.getString("content_snippet"));
        result.setSimilarity(rs.getDouble("similarity"));
        result.setSearchMethod(rs.getString("search_method"));
        return result;
    }

    public int getIndexedCount() {
        String sql = "SELECT COUNT(*) FROM legal_documents WHERE content_embedding IS NOT NULL";
        Integer count = jdbcTemplate.queryForObject(sql, Integer.class);
        return count != null ? count : 0;
    }

    public Map<String, Integer> getCountByType() {
        String sql = "SELECT doc_type, COUNT(*) as cnt FROM legal_documents GROUP BY doc_type ORDER BY cnt DESC";
        Map<String, Integer> counts = new LinkedHashMap<>();
        jdbcTemplate.query(sql, (rs) -> {
            counts.put(rs.getString("doc_type"), rs.getInt("cnt"));
        });
        return counts;
    }

    public Map<String, Integer> getCountByJurisdiction() {
        String sql = "SELECT jurisdiction, COUNT(*) as cnt FROM legal_documents GROUP BY jurisdiction ORDER BY cnt DESC";
        Map<String, Integer> counts = new LinkedHashMap<>();
        jdbcTemplate.query(sql, (rs) -> {
            counts.put(rs.getString("jurisdiction"), rs.getInt("cnt"));
        });
        return counts;
    }

    public Map<String, Integer> getCountByPracticeArea() {
        String sql = "SELECT practice_area, COUNT(*) as cnt FROM legal_documents GROUP BY practice_area ORDER BY cnt DESC";
        Map<String, Integer> counts = new LinkedHashMap<>();
        jdbcTemplate.query(sql, (rs) -> {
            counts.put(rs.getString("practice_area"), rs.getInt("cnt"));
        });
        return counts;
    }

    public Map<String, Integer> getCountByStatus() {
        String sql = "SELECT status, COUNT(*) as cnt FROM legal_documents GROUP BY status ORDER BY cnt DESC";
        Map<String, Integer> counts = new LinkedHashMap<>();
        jdbcTemplate.query(sql, (rs) -> {
            counts.put(rs.getString("status"), rs.getInt("cnt"));
        });
        return counts;
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