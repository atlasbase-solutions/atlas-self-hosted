FROM alpine:3.24

RUN addgroup -g 10001 atlas \
    && adduser -D -H -u 10001 -G atlas atlas \
    && apk add --no-cache ca-certificates tzdata

COPY --chmod=0555 artifacts/linux-amd64/atlas-gateway /usr/local/bin/atlas-gateway
COPY --chmod=0555 artifacts/linux-amd64/atlas-migrate /usr/local/bin/atlas-migrate
# Operator tool for the outbound postback DLQ: it needs the gateway's own
# PostgreSQL and Kafka configuration, so it ships in this image rather than the
# portal one. Run it with
#   docker compose --env-file env/compose.env run --rm \
#     --entrypoint atlas-outbound-deliveries gateway
COPY --chmod=0555 artifacts/linux-amd64/atlas-outbound-deliveries /usr/local/bin/atlas-outbound-deliveries
COPY config/enrichment /usr/share/atlas-gateway/enrichment

USER atlas
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/atlas-gateway"]

