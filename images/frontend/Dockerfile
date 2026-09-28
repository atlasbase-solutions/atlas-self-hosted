# The edge: Caddy serving the portal SPA and routing the portal, tracking and
# postback hosts. In `direct` mode it obtains and renews TLS certificates
# itself; in `proxy` mode it serves plain HTTP behind your TLS balancer. See the
# "Edge" section of README.md.
FROM caddy:2.11.4-alpine

# jq reads installation.json, the portal's projection of the installation's
# domains, when the Caddyfile is rendered.
RUN apk add --no-cache jq

COPY --chmod=0555 config/caddy/render.sh /usr/local/bin/atlas-edge-render
COPY --chmod=0555 config/caddy/entrypoint.sh /usr/local/bin/atlas-edge
COPY artifacts/frontend /srv/spa

# Certificates and ACME account state live in /data (the edge-data volume):
# losing them means issuing every certificate again, and certificate
# authorities limit how often that may happen.
VOLUME ["/data"]

# 80 serves plain HTTP in both modes; 443 serves HTTPS in `direct` mode.
EXPOSE 80 443

ENTRYPOINT ["/usr/local/bin/atlas-edge"]
