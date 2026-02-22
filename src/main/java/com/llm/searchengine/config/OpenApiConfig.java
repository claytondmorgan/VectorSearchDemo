package com.llm.searchengine.config;

import io.swagger.v3.oas.models.OpenAPI;
import io.swagger.v3.oas.models.info.Contact;
import io.swagger.v3.oas.models.info.Info;
import io.swagger.v3.oas.models.info.License;
import io.swagger.v3.oas.models.servers.Server;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

import java.util.List;

@Configuration
public class OpenApiConfig {

    @Value("${server.port:8080}")
    private int serverPort;

    @Bean
    public OpenAPI customOpenAPI() {
        return new OpenAPI()
                .info(new Info()
                        .title("LLM Vector Search API")
                        .version("1.0.0")
                        .description("""
                                Vector similarity search API powered by pgvector and huggingface.

                                ## Features
                                - **Semantic Search**: Search products and legal documents by meaning, not just keywords
                                - **Hybrid Search**: Combine semantic + keyword search with Reciprocal Rank Fusion (legal)
                                - **384-dimensional embeddings**: Using sentence-transformers/all-MiniLM-L6-v2
                                - **HNSW Index**: Fast approximate nearest neighbor search via pgvector
                                - **Cosine Similarity**: Results ranked by semantic similarity (0.0 - 1.0)

                                ## Product Search (/api/search)
                                - `content`: Search against product descriptions (default)
                                - `title`: Search against product titles only

                                ## Legal Document Search (/api/legal/search)
                                - `content`: Semantic search against document body text (default)
                                - `title`: Semantic search against document titles
                                - `headnotes`: Semantic search against headnote summaries
                                - `hybrid`: Combined semantic + keyword search (best for legal citations)
                                - Filters: jurisdiction, doc_type, practice_area, status
                                """)
                        .contact(new Contact()
                                .name("LLM Team")
                                .email("llm-team@example.com"))
                        .license(new License()
                                .name("Apache 2.0")
                                .url("https://www.apache.org/licenses/LICENSE-2.0")))
                .servers(List.of(
                        new Server().url("/").description("Current server")
                ));
    }
}
