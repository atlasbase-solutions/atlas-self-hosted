FROM alpine:3.24

RUN addgroup -g 10001 atlas \
    && adduser -D -H -u 10001 -G atlas atlas \
    && apk add --no-cache ca-certificates tzdata \
    && mkdir -p /var/lib/atlas/portal-files \
    && chown -R atlas:atlas /var/lib/atlas

# A named volume inherits this directory ownership on its first mount.
RUN mkdir -p /var/lib/atlas/antifraud && chown atlas:atlas /var/lib/atlas/antifraud

COPY --chmod=0555 artifacts/linux-amd64/atlas-portal /usr/local/bin/atlas-portal
# Operator recovery tools. They live in this image because they need the portal's
# database and Kafka configuration, and the README's procedures call for them:
# config-backfill bootstraps the config topic after a loss, payouts-quarantine
# inspects and replays a stuck payout ledger message, rotate-secrets re-encrypts
# secrets at rest, reset-owner-password restores access to the network owner.
# The image starts the portal by default, so run a tool with --entrypoint:
#   docker compose --env-file env/compose.env run --rm \
#     --entrypoint atlas-config-backfill portal
# reset-owner-password reads the new password from stdin: pipe it in and add -T.
COPY --chmod=0555 artifacts/linux-amd64/atlas-config-backfill /usr/local/bin/atlas-config-backfill
COPY --chmod=0555 artifacts/linux-amd64/atlas-payouts-quarantine /usr/local/bin/atlas-payouts-quarantine
# atlas-rotate-secrets re-encrypts the stored secrets after PORTAL_SECRET_KEY is
# replaced, and atlas-reset-owner-password gives the installation's operator the
# only way back into a network whose owner lost access and has no working email.
COPY --chmod=0555 artifacts/linux-amd64/atlas-rotate-secrets /usr/local/bin/atlas-rotate-secrets
COPY --chmod=0555 artifacts/linux-amd64/atlas-reset-owner-password /usr/local/bin/atlas-reset-owner-password

# Issues the one-time code that opens the first-run wizard while the
# installation has no users: `docker compose exec portal atlas-setup-code`.
COPY --chmod=0555 artifacts/linux-amd64/atlas-setup-code /usr/local/bin/atlas-setup-code

# Check the signed release manifest using the installation license.
COPY --chmod=0555 artifacts/linux-amd64/atlas-update-check /usr/local/bin/atlas-update-check

USER atlas
EXPOSE 11082
ENTRYPOINT ["/usr/local/bin/atlas-portal"]

