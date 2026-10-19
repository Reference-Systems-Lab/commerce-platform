# Meilisearch (the MIT-licensed community build), changed only so its data directory belongs to the
# non-root user compose.yaml runs it as.
FROM getmeili/meilisearch:v1.55.0@sha256:ff546679970126f8822e15d1b6a06bfbff1f2ce2e43f810cfb5258012f92de5c
RUN mkdir -p /meili_data && chown 65534:65534 /meili_data
USER 65534:65534
