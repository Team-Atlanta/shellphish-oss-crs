# OSS-CRS run module: Neo4j graph database service
# Used by coverage-guy, grammar-guy, grammaroomba for coverage/grammar data
FROM neo4j:latest

ENV NEO4J_AUTH=neo4j/helloworldpdt
ENV NEO4J_PLUGINS=["apoc"]

# Disable telemetry
ENV NEO4J_dbms_usage__report_enabled=false

EXPOSE 7687 7474
