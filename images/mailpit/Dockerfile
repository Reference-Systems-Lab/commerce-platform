# Mailpit, changed only so its data directory belongs to the non-root user compose.yaml runs it as.
FROM axllent/mailpit:v1.31.5@sha256:94f6b70c1436defae6799d9ac7ff0eeff9540465b842026d5cdb018f1c0234ea
USER 0
RUN mkdir -p /data && chown 65534:65534 /data
USER 65534:65534
