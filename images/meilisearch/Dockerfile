# Meilisearch (the MIT-licensed community build), changed only so its data directory belongs to the
# non-root user compose.yaml runs it as.
FROM getmeili/meilisearch:v1.57.0@sha256:91bf09897482c17205c8faeca8daa8d57999fb9de20d862763cdfa92ba4ec790
RUN mkdir -p /meili_data && chown 65534:65534 /meili_data
USER 65534:65534
