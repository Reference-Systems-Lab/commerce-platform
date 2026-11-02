# Mailpit, changed only so its data directory belongs to the non-root user compose.yaml runs it as.
FROM axllent/mailpit:v1.32.0@sha256:0790692be935ea4420d085694f7985b1f692ca6a8771ab0e0bd8ba75ac180498
USER 0
RUN mkdir -p /data && chown 65534:65534 /data
USER 65534:65534
