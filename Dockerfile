# --- Stage 1: Build with Maven ---
FROM --platform=linux/amd64 maven:3.9-eclipse-temurin-17 AS build
WORKDIR /app
COPY pom.xml .
RUN mvn dependency:go-offline -B
COPY src ./src
RUN mvn package -DskipTests -B

# --- Stage 2: Runtime ---
FROM --platform=linux/amd64 eclipse-temurin:17-jre
WORKDIR /app
COPY --from=build /app/target/search-engine-1.0.0.jar app.jar
EXPOSE 8080
ENV JAVA_OPTS="-Xms256m -Xmx512m -XX:+UseG1GC -XX:MaxGCPauseMillis=200"
ENTRYPOINT ["sh", "-c", "java $JAVA_OPTS -jar app.jar"]