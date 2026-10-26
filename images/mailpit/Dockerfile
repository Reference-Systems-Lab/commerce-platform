# Mailpit, changed only so its data directory belongs to the non-root user compose.yaml runs it as.
FROM axllent/mailpit:v1.31.6@sha256:23fe39e81bde596a918000b3135c0f85dc8bb4c9ea6be274b051143f3e300387
USER 0
RUN mkdir -p /data && chown 65534:65534 /data
USER 65534:65534
