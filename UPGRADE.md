# Upgrade notes

This file is the upgrade contract of the Atlas Self-Hosted distribution. Every release adds a section "Upgrading to X.Y.Z" at the top: the source versions it supports and the steps of every release in between, in the order they must be applied. The sections after them describe changes that take more than one step and are referred to from those lists.

A new installation needs none of this: follow "One-line installation" or "Quick start with Docker Compose" in `README.md`.

Since 1.0.0 every database schema change arrives as a new numbered migration, and each migration runner records the checksum of every file it applied. An installation of 1.0.0 or later is therefore upgraded in place, without recreating its databases. If the installed version is older than the oldest supported source version of the release you are installing, stop and contact Atlas support before changing binaries or images.

## Upgrading to 1.0.11

Supported source versions: 1.0.0 and later.

Release-specific steps, in order:

1. **manual** (1.0.11): 1. `atlas-update-check` from 1.0.10 and earlier cannot read the new answer from Atlas and reports that a signature does not verify. Download this release by hand instead: fetch `https://github.com/atlasbase-solutions/atlas-self-hosted/archive/refs/tags/v<version>.tar.gz`, unpack it into a new directory and run `./artifacts/linux-amd64/atlas-update-check -verify .` there before following the rest of this file.
   2. From this release on, `atlas-update-check -download <new directory>` does that for you.

## Upgrading to 1.0.10

Supported source versions: 1.0.0 and later.

Release-specific steps, in order:

1. **manual** (1.0.10): 1. Verify a freshly unpacked copy of the new distribution with its own tool: `./artifacts/linux-amd64/atlas-update-check -verify .`, and compare the printed key fingerprint with the one published by Atlas.
   2. If you keep your own files inside the distribution directory — for example a `docker-compose.override.yml` — the check lists them as not in the signed index. Move them out of the distribution directory, or verify the new distribution before copying them in.
   3. The new tool refuses distributions 1.0.9 and older: they were signed before this change, and only their binaries can be verified.

## Upgrading to 1.0.9

Supported source versions: 1.0.0 and later.

Release-specific steps, in order:

1. **manual** (1.0.2): 1. Before upgrading, check that `ATLAS_LICENSE_PORTAL_DOMAIN` and `ATLAS_LICENSE_TRACKING_DOMAINS` match the domains of your license.
   2. If a domain has changed, ask for the license to be reissued for the new domains before upgrading.
2. **migration** (1.0.2): 1. Apply the ClickHouse migrations before starting the new tracking gateway: the `clicks` and `lp_clicks` tables gain a column. The migration adds it with a default and is safe on a populated database.
   2. Move any end-to-end conversion test to a licensed tracking domain.
3. **env** (1.0.3): 1. Remove `PORTAL_ANTIFRAUD_FEED_URL` from `env/portal.env` (or from the Kubernetes config map) if you set it.
   2. If the installation has the reputation-data subscription, allow outbound HTTPS from Portal to `antifraud.getatlasbase.com`.
4. **migration** (1.0.4): 1. Apply the database migrations as part of the usual upgrade; Portal applies its own schema changes on start, no manual step is needed.
   2. Payout and revenue per landing variant are counted from conversions recorded after the upgrade; earlier conversions appear on the tab as a separate line with an unknown variant.
5. **migration** (1.0.6): 1. Apply the portal migration `0003_antifraud_ip_observations.sql` (the portal applies its chains at startup). It creates an empty table and changes no existing rows.
   2. Update the portal and the tracking gateway together. The signal counts only conversions attributed to clicks received after the update; earlier conversions have no value for it.
   3. The portal and the gateway must share the same `ATLAS_CONFIG_SECRET_KEY`, as they already do. After rotating it, keep the old value in `ATLAS_CONFIG_SECRET_KEY_PREVIOUS` so that deleting links by an address also finds observations made before the rotation.
6. **manual** (1.0.6): 1. Point Prometheus at the tracking service's metrics address (`METRICS_ADDR`, `:9108` by default) instead of its public port. In Kubernetes the gateway service now exposes a `metrics` port.
   2. If an external TLS proxy or load balancer runs in front of Atlas, set `ATLAS_EDGE_TRUSTED_PROXY_CIDR` in `env/edge.env` to its subnet and add the same subnet to `PORTAL_EXTERNAL_PROXY_CIDRS` and `EXTERNAL_PROXY_CIDRS`. Leave `PORTAL_TRUSTED_PROXY_CIDRS` and `TRUSTED_PROXY_CIDRS` at the installation's own subnet — the external proxy is now a separate variable, not a replacement.
   3. A trusted proxy network wider than /16 (IPv4) or /64 (IPv6) is refused at startup. The Kubernetes example no longer trusts the whole `10.0.0.0/8`: replace it with your ingress controller's own subnet.
   4. Run `./scripts/check-config.sh`: it now verifies both the proxy subnets and the edge proxy setting.
7. **manual** (1.0.6): 1. If `PORTAL_SECRET_KEY` or `ATLAS_CONFIG_SECRET_KEY` is not 32 random bytes in hex or base64, generate a new one with `openssl rand -hex 32`, move the old value to `PORTAL_SECRET_KEY_PREVIOUS` / `ATLAS_CONFIG_SECRET_KEY_PREVIOUS`, and run the re-encryption command described under operator recovery tools. Keep `ATLAS_CONFIG_SECRET_KEY` identical in the portal and the tracking gateway.
   2. A key that already has this format keeps working and needs no change: values sealed with it stay readable, and the re-encryption command re-seals them at your convenience.
   3. Remove `PORTAL_SESSION_SECRET` from your env files; it is ignored now.
   4. `PORTAL_OWNER_PASSWORD` is used only on a database with no Network Owner. On a fresh installation choose at least 10 characters; the owner replaces the password at the first sign-in.
   5. `./scripts/check-config.sh` now verifies the key format too — run it before starting.
8. **env** (1.0.6): 1. If a conversion receiver, a traffic-source postback receiver or the SMTP relay of your installation lives in an internal network (including a carrier-grade NAT or Tailscale network), add that network to `OUTBOUND_ALLOWED_TARGET_CIDRS` — otherwise those deliveries and mails stop after the update.
   2. Set the same value for the portal and the tracking gateway. The portal now reads the variable too and refuses to start when an entry is not a valid CIDR.
   3. Never use `0.0.0.0/0`: it turns the filter off and hands a user-entered address access to your internal services.
9. **migration** (1.0.6): - The gateway reads a new optional variable `POSTBACK_IP_RATE_LIMIT_RPS`: the number of `/postback` requests per second allowed from one client address before the request is parsed. The default is 300, and `0` turns the limit off. Raise it if one advertiser server sends more postbacks than that across all its offers. The existing per-offer `POSTBACK_RATE_LIMIT_RPS` is unchanged.
   - The portal applies a database migration on startup. Existing offers keep their postback mode.
10. **manual** (1.0.7): 1. Update `atlas-update-check` together with the rest of the distribution: the previous version cannot read the update channel's new answer.
   2. Before installing a distribution, run `./artifacts/linux-amd64/atlas-update-check -verify .` and compare the printed key fingerprint with the one published by Atlas.
11. **env** (1.0.8): 1. Take the new `docker-compose.yml`, or add to your copy the `atlas-license` volume, its mounts (read-write in `portal`, read-only in `gateway`, both at `/var/lib/atlas/license`) and the one-shot `license-volume-init` service that both depend on.
   2. Add `ATLAS_LICENSE_TOKEN_FILE=/var/lib/atlas/license/license.token` to `env/portal.env` and `env/gateway.env`, and `PORTAL_GATEWAY_INTERNAL_URL=http://gateway:9108` to `env/portal.env` (point it at the gateway's `METRICS_ADDR` port if you changed it).
   3. Start the release as usual. With `ATLAS_LICENSE_TOKEN` set nothing else is needed; to manage the license from the portal instead, follow "License volume and the license installed from the portal" in `UPGRADE.md`.
   4. Add the `atlas-license` volume to your backups.
12. **migration** (1.0.8): 1. Nothing to do by hand: the portal applies its new database migration (the `installation_acme_consent` table) automatically at startup.
13. **migration** (1.0.8): 1. Nothing to do by hand: the portal applies its new database migration (the `installation_setup_code` table) automatically at startup.
   2. Existing installations keep `PORTAL_OWNER_EMAIL`/`PORTAL_OWNER_PASSWORD` as they are; an installation that already has users never enters setup mode, even if you later remove these variables.
   3. Setting only one of the two variables now stops the portal at startup with an error naming the missing one — set both or neither.
14. **migration** (1.0.8): 1. Nothing to do by hand: the portal applies its new database migration automatically at startup.
15. **manual** (1.0.8): 1. Installations behind their own TLS proxy or load balancer (every installation made from an earlier distribution): in `env/compose.env` add `ATLAS_EDGE_MODE=proxy`, `ATLAS_HTTPS_BIND=127.0.0.1` and an empty `ATLAS_HTTPS_PORT=`, and keep your `ATLAS_HTTP_PORT` (the earlier default was `8080`). Without `ATLAS_EDGE_MODE=proxy` the edge starts in `direct` mode and redirects your proxy's plain-HTTP requests to HTTPS.
   2. Keep `ATLAS_PORTAL_HOST`, `ATLAS_TRACKING_HOST` and `ATLAS_EDGE_TRUSTED_PROXY_CIDR` in `env/edge.env`; delete `NGINX_ENVSUBST_FILTER`, which is no longer used.
   3. Add `ATLAS_INSTALLATION_FILE=/var/lib/atlas/installation/installation.json` to `env/portal.env` and `env/gateway.env`.
   4. Take the new `docker-compose.yml`. If you keep a modified copy, add the `ATLAS_EDGE_MODE` environment entries of `edge` and `portal`, the HTTPS port, the `edge-data` and `atlas-installation` volumes with their mounts and the `installation-volume-init` service exactly as in the distribution file.
   5. If you edited `config/nginx/default.conf.template`, that file is no longer read: reproduce your additions on your own proxy in front of Atlas.
   6. Start the release (`make up`), run `make verify`, and add the `edge-data` volume to your backups.

## Before every upgrade

1. Read the "Upgrading to" sections of every release between the installed version and the new one, and `CHANGELOG.md` for the same range.
2. Record the running version: `GET /version` on the portal and tracking domains.
3. Make sure every health check is green and that Kafka consumer lag, the configuration quarantine and the outbound dead-letter queue are understood.
4. Take a backup you have verified can be restored (see `docs/backup-restore.md`).
5. Verify the new distribution before building anything: `make verify-release` checks every binary against `SHA256SUMS` and the release index against the Atlas release key; compare the fingerprint it prints with the one in `README.md` and on the Atlas website.

Then, for Docker Compose:

1. Keep your working files (`env/*.env`, any license file you mount) and replace everything else with the new distribution. If you keep a modified `docker-compose.yml`, carry every change listed in the upgrade steps into your copy.
2. Apply the release-specific steps in the order listed.
3. Run `make up`. The Gateway migrator runs once before Portal and Gateway start, and the portal applies its own migrations at startup.
4. Run `make verify` and confirm that `/version` reports the new version on both hosts.
5. Check sign-in, an offer, a test click and conversion, the reports and the payout ledger.

For Kubernetes, build and push the three images with the new tag, update `k8s/kustomization.yaml`, run the `gateway-migrate` Job to completion, and only then roll Portal, Gateway and the edge together (`k8s/README.md`).

Portal, Gateway, the migrator, the SPA and the edge are one release unit. Do not run two versions side by side for longer than a rolling update takes.

## License volume and the license installed from the portal

Applies to installations upgrading from a release before 1.0.8. The upgrade steps above list the same changes; this section explains the choice they leave you.

What is new:

- a named volume `atlas-license`, mounted read-write into Portal and read-only into Gateway at `/var/lib/atlas/license`, and a one-shot service `license-volume-init` that gives the directory to uid 10001 on every start;
- `ATLAS_LICENSE_TOKEN_FILE=/var/lib/atlas/license/license.token` in both `env/portal.env` and `env/gateway.env` — the file the portal writes when a license is activated on the screen before sign-in or replaced in Settings → License;
- `PORTAL_GATEWAY_INTERNAL_URL=http://gateway:9108` in `env/portal.env` — where the portal reads the Gateway's license state (the Gateway's internal metrics listener, `METRICS_ADDR`).

Steps:

1. Take the new `docker-compose.yml` from the distribution. If you keep a modified copy, add the `atlas-license` volume, both mounts and the `license-volume-init` service (with `depends_on` from `portal` and `gateway`) exactly as in the distribution file.
2. Add `ATLAS_LICENSE_TOKEN_FILE` to `env/portal.env` and `env/gateway.env` with the same path, and `PORTAL_GATEWAY_INTERNAL_URL` to `env/portal.env`. Copy them, with their comments, from the `.env.example` files. If you changed the Gateway's `METRICS_ADDR`, point `PORTAL_GATEWAY_INTERNAL_URL` at that port.
3. Start the release as usual (`make up`). Docker Compose creates the volume and runs `license-volume-init` before Portal and Gateway.

**If your license is set in `ATLAS_LICENSE_TOKEN`, nothing else changes.** The variable takes precedence over the file; Settings → License shows the license as set in the server configuration and offers no replacement or removal there.

**To manage the license from the portal instead:**

1. Keep the license string at hand (the value of `ATLAS_LICENSE_TOKEN`).
2. Clear `ATLAS_LICENSE_TOKEN` in both `env/portal.env` and `env/gateway.env` and recreate the two services: `docker compose --env-file env/compose.env up -d portal gateway`.
3. Open the portal: it shows the activation screen. Paste the license and click **Activate**, wait until traffic intake is confirmed, then sign in. From now on, replace, restore or remove the license in Settings → License.

Between steps 2 and 3 Atlas does not serve traffic, so do this in a maintenance window. To go back, set `ATLAS_LICENSE_TOKEN` again and recreate the services; the file in the volume is then ignored.

Include the `atlas-license` volume in your backups. Losing it only means activating the installation again with the same license string.

## Edge on Caddy: certificates on the server itself, or behind your proxy

Applies to installations upgrading from a release before 1.0.8, whose edge was nginx.

What is new:

- the edge image is Caddy. `config/nginx/` is gone; its routes are unchanged (the tracking host still publishes intake, `/health/*` and `/version` only; the portal host the API, `/health/*`, `/version` and the SPA);
- `ATLAS_EDGE_MODE` in `env/compose.env`: `direct` (the default) listens on ports 80 and 443 and obtains TLS certificates itself; `proxy` serves plain HTTP behind your TLS proxy or load balancer, as the nginx edge did;
- new ports in `env/compose.env`: `ATLAS_HTTP_PORT` now defaults to `80`, and `ATLAS_HTTPS_BIND`/`ATLAS_HTTPS_PORT` publish HTTPS;
- two volumes: `edge-data` (certificates and ACME state) and `atlas-installation` (`installation.json`, written by the portal, read by the edge and Gateway), with a one-shot `installation-volume-init` service;
- `ATLAS_INSTALLATION_FILE` in `env/portal.env` and `env/gateway.env`;
- `NGINX_ENVSUBST_FILTER` in `env/edge.env` is no longer used.

**If Atlas sits behind your own TLS proxy or load balancer (every installation made from an earlier distribution):**

1. In `env/compose.env` add `ATLAS_EDGE_MODE=proxy`, `ATLAS_HTTPS_BIND=127.0.0.1` and an empty `ATLAS_HTTPS_PORT=`; keep your `ATLAS_HTTP_PORT` (the earlier default was `8080`). Without `ATLAS_EDGE_MODE=proxy` the edge would start in `direct` mode, redirect your proxy's plain-HTTP requests to HTTPS and try to publish port 443.
2. Keep `ATLAS_PORTAL_HOST`, `ATLAS_TRACKING_HOST` and `ATLAS_EDGE_TRUSTED_PROXY_CIDR` in `env/edge.env` as they are; delete `NGINX_ENVSUBST_FILTER`.
3. Add `ATLAS_INSTALLATION_FILE` to `env/portal.env` and `env/gateway.env`, copied with its comment from the `.env.example` files.
4. Take the new `docker-compose.yml`. If you keep a modified copy, add the `ATLAS_EDGE_MODE` environment entries of `edge` and `portal`, the new ports, both volumes and their mounts, and the `installation-volume-init` service exactly as in the distribution file.
5. Start the release as usual (`make up`) and run `make verify`.

**If you edited `config/nginx/default.conf.template`:** the file is no longer read. Extra routes, headers or hosts you added there have to be reproduced on your own proxy in front of Atlas; the edge's route list is fixed on purpose, so that the tracking host never publishes more than intake. Tell Atlas support what you needed the change for if your proxy cannot do it.

**To let the edge obtain certificates itself instead (`direct`):** point the portal and tracking DNS records at this server, make ports 80 and 443 reachable from the internet, remove your proxy from the path, and set `ATLAS_EDGE_MODE=direct`, `ATLAS_HTTP_PORT=80`, `ATLAS_HTTPS_BIND=0.0.0.0` and `ATLAS_HTTPS_PORT=443`. Certificates appear within about a minute; `docker compose logs edge` shows each one obtained, or the reason it was not (DNS pointing elsewhere, a closed port 80, a CAA record that does not allow Let's Encrypt).

Add `edge-data` to your backups. The `atlas-installation` volume needs no backup.

## What every release states

Every release's section states:

- the supported source versions;
- whether a database migration is required, and its order relative to the Portal and Gateway rollout;
- incompatible environment changes;
- required Kafka topic or retention changes;
- manual steps, backup and rollback requirements;
- post-upgrade verification beyond the standard checks above.

If a release does not document an in-place path from the installed version, stop and contact Atlas support before changing binaries or images.
