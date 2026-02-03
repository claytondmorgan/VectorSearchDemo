package com.llm.searchengine.config;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.boot.jdbc.DataSourceBuilder;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Primary;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.secretsmanager.SecretsManagerClient;
import software.amazon.awssdk.services.secretsmanager.model.GetSecretValueRequest;
import software.amazon.awssdk.services.secretsmanager.model.GetSecretValueResponse;

import javax.sql.DataSource;

@Configuration
@ConditionalOnProperty(name = "aws.secrets.enabled", havingValue = "true")
public class DatabaseConfig {

    private static final Logger logger = LoggerFactory.getLogger(DatabaseConfig.class);

    @Value("${aws.secrets.name}")
    private String secretName;

    @Value("${aws.region}")
    private String region;

    @Bean
    @Primary
    public DataSource dataSource() {
        logger.info("Configuring DataSource from AWS Secrets Manager");
        logger.info("Secret name: {}, Region: {}", secretName, region);

        try (SecretsManagerClient client = SecretsManagerClient.builder()
                .region(Region.of(region))
                .build()) {

            GetSecretValueRequest request = GetSecretValueRequest.builder()
                    .secretId(secretName)
                    .build();

            GetSecretValueResponse response = client.getSecretValue(request);
            String secretString = response.secretString();

            ObjectMapper mapper = new ObjectMapper();
            JsonNode secret = mapper.readTree(secretString);

            String host = secret.get("host").asText();
            int port = secret.get("port").asInt();
            String database = secret.get("database").asText();
            String username = secret.get("username").asText();
            String password = secret.get("password").asText();

            String jdbcUrl = String.format("jdbc:postgresql://%s:%d/%s", host, port, database);

            logger.info("Creating DataSource with URL: {}, username: {}", jdbcUrl, username);

            return DataSourceBuilder.create()
                    .url(jdbcUrl)
                    .username(username)
                    .password(password)
                    .driverClassName("org.postgresql.Driver")
                    .build();

        } catch (Exception e) {
            logger.error("Failed to create DataSource from AWS Secrets Manager", e);
            throw new RuntimeException("Failed to create DataSource from AWS Secrets Manager", e);
        }
    }
}