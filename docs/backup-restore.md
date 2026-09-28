# Backup and restore runbook

This runbook defines the minimum recoverable state of Atlas Self-Hosted. Adapt commands to the customer's database tooling, storage class, encryption, and retention policy.

## Recovery set

A complete recovery point contains:

1. Portal PostgreSQL dump or physical backup.
2. Gateway PostgreSQL dump or physical backup.
3. ClickHouse backup.
4. Redis AOF/RDB state.
5. Kafka recovery data or a documented rebuild/replay strategy that meets retention requirements.
6. Portal file storage snapshot.
7. The working env files (or Kubernetes Secrets), encrypted and stored separately: they hold the database passwords and both encryption keys, and without `PORTAL_SECRET_KEY` and `ATLAS_CONFIG_SECRET_KEY` the secrets stored in the database cannot be decrypted.
8. The `atlas-license` volume (the license installed from the portal). Treat it as a secret: it holds the license string. Without it, the installation starts unactivated and is activated again on the portal screen with the same license.
9. The `edge-data` volume (the edge's TLS certificates and ACME account) in `direct` mode. It can be rebuilt by issuing the certificates again, but certificate authorities limit how often that may happen for one name, so a restore without it can leave the portal without HTTPS for hours. The `atlas-installation` volume needs no backup: the portal rebuilds `installation.json` from its database at every start.
10. Distribution version (`release.json`), `SHA256SUMS`, and the digests of the deployed images.

## Consistency rule for Portal files

Portal PostgreSQL and `portal-files` must be captured and restored as one logical point-in-time set. The database stores authorization and metadata; the volume stores the bytes.

- A newer database can reference files absent from an older volume.
- A newer volume can contain files with no database row and no authorized retrieval path.

Use storage snapshots coordinated with the PostgreSQL recovery point, or place the Portal in a documented maintenance window while both are captured.

## Backup sequence

1. Record `/version` from Portal and Gateway.
2. Record health and Kafka consumer state.
3. Quiesce administrative file mutations if the backup mechanism cannot coordinate database and volume snapshots.
4. Back up Portal PostgreSQL and `portal-files` as one recovery point.
5. Back up Gateway PostgreSQL.
6. Back up ClickHouse.
7. Capture Redis and Kafka according to their platform-specific procedures.
8. Export encrypted configuration from the customer's secret manager.
9. Verify checksums, encryption, off-host copy, retention, and restore readability.
10. Resume normal operations and record the recovery point identifier.

## Restore sequence

1. Restore into an isolated network first.
2. Install the exact Atlas distribution version recorded with the backup.
3. Restore both PostgreSQL databases.
4. Restore Portal PostgreSQL and `portal-files` from the same recovery point.
5. Restore ClickHouse, Redis, and Kafka.
6. Restore env/Secrets without exposing them in shell history or Git.
7. Start data services.
8. Run only migration steps explicitly permitted by the release's `UPGRADE.md`.
9. Start Portal, Gateway and the edge.
10. Verify health, version, owner login, offer reads, file download, click intake, conversion attribution, reporting, and payout-ledger completeness.
11. Keep external traffic disabled until the recovery test is accepted.

## Restore acceptance

A restore is not complete until an operator verifies:

- the expected tenant is `tenant_id=1`;
- user authentication and permissions work;
- offers, partners, advertisers, settings, and API keys have the expected metadata;
- promo files can be downloaded by an authorized user;
- a test click and conversion reach reports;
- Kafka consumers have no unexplained offset gap;
- payout closing is not blocked by an unexplained incomplete ledger;
- `/version` matches the intended release.


## Reputation packages

Include the `antifraud-feed` volume (Kubernetes: the claim of the same name) in the backup when preserving the current signed reputation package is required. Restore the parent directory with ownership `10001:10001`; Portal needs write access and Gateway read-only access. Alternatively, let Portal fetch a fresh package after restoring settings and license connectivity. Until a valid package is available, reputation signals are unknown. Local rules and investigation records are part of the Portal database backup.
