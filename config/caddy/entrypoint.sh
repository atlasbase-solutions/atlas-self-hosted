#!/bin/sh
#
# Edge entrypoint: renders the Caddyfile, runs Caddy, and every few seconds
# compares the state of its inputs with the last one it saw: installation.json,
# the own-certificate manifest the portal writes to the edge-certs volume, and
# the operator's certificate files in config/tls/. When an input changes (the
# first-run wizard verified a domain, setup was completed, the owner uploaded a
# certificate), the configuration is rendered again and applied with
# `caddy reload`, without a restart and without dropping connections. Once a
# minute it is rendered regardless, so an own certificate stops being presented
# at its serve_until even when nothing was rewritten.
#
# A configuration that cannot be rendered or that Caddy refuses is never
# applied: the edge keeps serving the previous one and writes the reason to its
# log. SIGTERM stops Caddy gracefully and then this script.

set -eu

file=${ATLAS_INSTALLATION_FILE:-/var/lib/atlas/installation/installation.json}
interval=${ATLAS_EDGE_POLL_SECONDS:-5}
full_every=${ATLAS_EDGE_FULL_RENDER_SECONDS:-60}
certs_dir=${ATLAS_EDGE_CERTS_DIR:-/var/lib/atlas/edge-certs}
operator_dir=${ATLAS_EDGE_OPERATOR_TLS_DIR:-/etc/atlas/tls}
status_dir=${ATLAS_EDGE_STATUS_DIR:-/var/lib/atlas/edge-status}
dir=/run/atlas-edge
conf=$dir/Caddyfile

log() {
    printf '%s atlas-edge: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

# file_state names the state of one input file: its hash, "absent" or
# "unreadable".
file_state() {
    if [ ! -e "$1" ]; then
        echo absent
        return
    fi
    sum=$(sha256sum "$1" 2>/dev/null | cut -d' ' -f1)
    echo "${sum:-unreadable}"
}

# operator_hosts lists the hosts the operator set a certificate for: both
# config/tls/<host>.crt and <host>.key exist.
operator_hosts() {
    for crt in "$operator_dir"/*.crt; do
        [ -f "$crt" ] || continue
        h=$(basename "$crt" .crt)
        [ -f "$operator_dir/$h.key" ] && printf '%s\n' "$h"
    done
}

# fingerprint names the state of every input: the projection, the manifest and
# the operator's files (their names, sizes and modification times).
fingerprint() {
    ops=$(find "$operator_dir" -maxdepth 1 -type f -exec stat -c '%n %s %Y' {} + 2>/dev/null | sort | sha256sum | cut -d' ' -f1)
    echo "$(file_state "$file")/$(file_state "$certs_dir/manifest.json")/$ops"
}

# write_tls_config tells the portal which hosts take their certificate from
# config/tls/: Settings -> Domains shows them as set by the server
# configuration and refuses an upload over them. Without the edge-status
# volume there is nowhere to write, and the portal simply does not know.
write_tls_config() {
    # Behind a balancer (proxy mode) this edge serves no certificate, so there
    # is nothing to report; direct and manual modes both read config/tls/.
    [ "${ATLAS_EDGE_MODE:-direct}" != proxy ] || return 0
    hosts=$(operator_hosts | jq -R . | jq -sc .) || return 0
    # The directory is normally the mounted volume; in manual mode no other
    # writer creates it, so it is made here when missing.
    mkdir -p "$status_dir" 2>/dev/null || return 0
    printf '{"schema":1,"hosts":%s}\n' "$hosts" >"$status_dir/tls-config.json.next" 2>/dev/null || return 0
    chmod 0644 "$status_dir/tls-config.json.next"
    mv "$status_dir/tls-config.json.next" "$status_dir/tls-config.json"
}

mkdir -p "$dir"
seen=$(fingerprint)

write_tls_config
# Without a first configuration there is nothing to keep serving, so a render
# error at start stops the container and the reason is in its log. A rejected
# own-certificate manifest is the one exception: the edge starts without the
# portal's certificates -- in direct mode the domains get certificates of
# their own, in manual mode they stay without HTTPS until the manifest is
# fixed -- rather than not at all.
if ! atlas-edge-render >"$conf.new" 2>"$dir/render.err"; then
    if ATLAS_EDGE_CERTS_DIR=/nonexistent atlas-edge-render >"$conf.new" 2>/dev/null; then
        log "own certificates not applied at start: $(cat "$dir/render.err")"
    else
        log "configuration not generated: $(cat "$dir/render.err")"
        exit 1
    fi
fi
mv "$conf.new" "$conf"
log "starting: mode=${ATLAS_EDGE_MODE:-direct} installation=$seen"

# In `direct` mode the edge obtains certificates itself, and the outcome of
# every attempt is kept for the portal (see atlas-edge-acme-status). The
# follower dies with the container; nothing else depends on it. In `manual`
# mode nothing is obtained, so there is no outcome to keep and no acme.json.
if [ "${ATLAS_EDGE_MODE:-direct}" = direct ]; then
    atlas-edge-acme-status &
fi

caddy run --config "$conf" --adapter caddyfile &
caddy_pid=$!

stop() {
    log "stopping"
    kill -TERM "$caddy_pid" 2>/dev/null || true
    code=0
    wait "$caddy_pid" || code=$?
    exit "$code"
}
trap stop TERM INT

since_full=0
while :; do
    # Sleeping in the background keeps the shell able to run the trap at once.
    sleep "$interval" &
    wait $! || true
    since_full=$((since_full + interval))

    # Caddy is the service; if it is gone the container must say so.
    if ! kill -0 "$caddy_pid" 2>/dev/null; then
        code=0
        wait "$caddy_pid" || code=$?
        log "caddy exited with code $code"
        # An unexpected exit is a failure even when Caddy reported success.
        [ "$code" -ne 0 ] || code=1
        exit "$code"
    fi

    now=$(fingerprint)
    # Nothing changed and the minute is not up yet: nothing to render.
    if [ "$now" = "$seen" ] && [ "$since_full" -lt "$full_every" ]; then
        continue
    fi
    # The portal learns the operator's hosts from tls-config.json; rewriting it
    # on every pass also repairs a file removed by hand.
    write_tls_config
    seen=$now
    since_full=0

    if ! atlas-edge-render >"$conf.new" 2>"$dir/render.err"; then
        log "inputs changed ($now) but the configuration was not generated; keeping the previous one: $(cat "$dir/render.err")"
        continue
    fi
    # Only the timestamp changed: nothing to apply.
    if cmp -s "$conf.new" "$conf"; then
        continue
    fi
    if caddy reload --config "$conf.new" --adapter caddyfile >"$dir/reload.out" 2>&1; then
        mv "$conf.new" "$conf"
        log "configuration reloaded ($now)"
    else
        log "caddy refused the new configuration; keeping the previous one: $(tail -n 5 "$dir/reload.out")"
    fi
done
