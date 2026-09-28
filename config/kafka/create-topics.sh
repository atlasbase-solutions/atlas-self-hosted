#!/bin/sh
# Creates the Kafka topics Atlas needs and brings existing ones up to the
# declared settings. Runs as the one-shot `kafka-init` service on every
# `docker compose up`; every step is idempotent.
set -eu

bootstrap_servers=${KAFKA_BOOTSTRAP_SERVERS:-kafka:19092}
topics=${KAFKA_TOPICS:-/opt/kafka/bin/kafka-topics.sh}
configs=${KAFKA_CONFIGS:-/opt/kafka/bin/kafka-configs.sh}
replication_factor=${KAFKA_REPLICATION_FACTOR:-1}

# ensure_partitions raises the partition count of an existing topic to the
# declared one. `--create --if-not-exists` never touches a live topic, so a
# topic the broker auto-created with a single partition (a service reached it
# before this script did) would otherwise keep one partition forever. That is
# not cosmetic: the partition count caps read parallelism, and a consumer that
# joined its group before the topic existed may hold no partitions at all.
# Only delete-policy topics are widened; a compacted topic is keyed, and
# widening it would move keys to other partitions.
ensure_partitions() {
    topic=$1
    want=$2
    have=$("$topics" --bootstrap-server "$bootstrap_servers" --describe --topic "$topic" |
        sed -n 's/.*PartitionCount: *\([0-9]*\).*/\1/p' | head -n 1)
    if [ -z "$have" ]; then
        printf 'WARNING: could not read the partition count of topic %s\n' "$topic" >&2
        return 0
    fi
    if [ "$have" -lt "$want" ]; then
        printf 'Topic %s has %s partitions, %s declared; adding partitions\n' "$topic" "$have" "$want"
        "$topics" --bootstrap-server "$bootstrap_servers" --alter --topic "$topic" --partitions "$want"
    elif [ "$have" -gt "$want" ]; then
        printf 'NOTE: topic %s has %s partitions, more than the %s declared; left as is\n' "$topic" "$have" "$want" >&2
    fi
}

create_delete_topic() {
    topic=$1
    partitions=$2
    retention_ms=$3
    "$topics" --bootstrap-server "$bootstrap_servers" --create --if-not-exists \
        --topic "$topic" --partitions "$partitions" \
        --replication-factor "$replication_factor" \
        --config cleanup.policy=delete --config retention.ms="$retention_ms"
    ensure_partitions "$topic" "$partitions"
}

create_delete_topic clicks "${KAFKA_CLICKS_PARTITIONS:-24}" 259200000
create_delete_topic lp-clicks "${KAFKA_LP_CLICKS_PARTITIONS:-12}" 259200000
create_delete_topic impressions "${KAFKA_IMPRESSIONS_PARTITIONS:-24}" 259200000
create_delete_topic conversions-raw "${KAFKA_CONVERSIONS_RAW_PARTITIONS:-24}" 604800000
create_delete_topic postbacks-outbound "${KAFKA_POSTBACKS_OUTBOUND_PARTITIONS:-12}" 604800000
# Trail of accepted and rejected postback attempts: what an integrator reads to
# find out why a conversion was refused. It is a ClickHouse-bound stream like
# the click one, so the gateway consumes it even when nothing rejects anything.
create_delete_topic postbacks-in "${KAFKA_POSTBACKS_IN_PARTITIONS:-12}" 259200000
create_delete_topic outbound-requests "${KAFKA_OUTBOUND_REQUESTS_PARTITIONS:-12}" 259200000
create_delete_topic postbacks-outbound-retry "${KAFKA_POSTBACKS_OUTBOUND_RETRY_PARTITIONS:-12}" 604800000
create_delete_topic postbacks-outbound-dlq "${KAFKA_POSTBACKS_OUTBOUND_DLQ_PARTITIONS:-6}" 2592000000

# Both quarantines must exist before the first message that needs them: a
# consumer that cannot publish to its quarantine stops, which is exactly the
# outage the quarantine prevents. Invalid configuration events must not stop
# updates for the rest of the installation. Retention matches the outbound DLQ
# (30 days) -- all three wait for an operator.
create_delete_topic config-quarantine "${KAFKA_CONFIG_QUARANTINE_PARTITIONS:-6}" 2592000000
create_delete_topic events-quarantine "${KAFKA_EVENTS_QUARANTINE_PARTITIONS:-6}" 2592000000

# The configuration topic is compacted: it keeps the latest state of every
# entity, and the Gateway rebuilds its configuration from it. Tombstones are
# kept for 7 days so that a consumer bootstrapping from the beginning still
# sees deletions.
"$topics" --bootstrap-server "$bootstrap_servers" --create --if-not-exists \
    --topic config-changes --partitions "${KAFKA_CONFIG_CHANGES_PARTITIONS:-6}" \
    --replication-factor "$replication_factor" \
    --config cleanup.policy=compact \
    --config delete.retention.ms=604800000 \
    --config min.cleanable.dirty.ratio=0.01 \
    --config segment.ms=3600000

# Reconcile an existing topic as well; --if-not-exists does not change its settings.
"$configs" --bootstrap-server "$bootstrap_servers" --alter \
    --entity-type topics --entity-name config-changes \
    --add-config cleanup.policy=compact,delete.retention.ms=604800000,min.cleanable.dirty.ratio=0.01,segment.ms=3600000

"$topics" --bootstrap-server "$bootstrap_servers" --list
