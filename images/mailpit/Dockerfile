# Mailpit, changed only so its data directory belongs to the non-root user compose.yaml runs it as.
FROM axllent/mailpit:v1.31.4@sha256:b68349e3a014b90c5610bfb26b2ae36f3892d7b8cf25ee140c6c71c98d2fcf48
USER root
RUN mkdir -p /data && chown 65534:65534 /data
USER 65534:65534
