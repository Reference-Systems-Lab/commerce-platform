# Mailpit, changed only so its data directory belongs to the non-root user compose.yaml runs it as.
FROM axllent/mailpit:v1.33.1@sha256:aef2aacc11f075ec0fb6874275ee4a421e688e11a96ebb296134d1735c7761ce
USER 0
RUN mkdir -p /data && chown 65534:65534 /data
USER 65534:65534
