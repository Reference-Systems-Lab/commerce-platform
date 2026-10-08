# Meilisearch (the MIT-licensed community build), changed only so its data directory belongs to the
# non-root user compose.yaml runs it as.
FROM getmeili/meilisearch:v1.54.3@sha256:e68913ab7d6f5b159529e472cfd362ce3c741fafd3c127961b2142abbe41b3c9
RUN mkdir -p /meili_data && chown 65534:65534 /meili_data
USER 65534:65534
