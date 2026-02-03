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
                                Vector similarity search API powered by pgvector and ONNX Runtime.

                                ## Features
                                - **Semantic Search**: Search products by meaning, not just keywords
                                - **384-dimensional embeddings**: Using sentence-transformers/all-MiniLM-L6-v2
                                - **HNSW Index**: Fast approximate nearest neighbor search via pgvector
                                - **Cosine Similarity**: Results ranked by semantic similarity (0.0 - 1.0)

                                ## Search Fields
                                - `content`: Search against product descriptions (default)
                                - `title`: Search against product titles only
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
