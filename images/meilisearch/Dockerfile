# Meilisearch (the MIT-licensed community build), changed only so its data directory belongs to the
# non-root user compose.yaml runs it as.
FROM getmeili/meilisearch:v1.56.2@sha256:9600db22be3fcbf3d506176d3a73dd70a65c5719d9aa1d2837355b75afb8f4fb
RUN mkdir -p /meili_data && chown 65534:65534 /meili_data
USER 65534:65534
