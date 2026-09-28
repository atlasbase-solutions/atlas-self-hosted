#!/bin/sh
#
# Edge entrypoint: renders the Caddyfile, runs Caddy, and every few seconds
# compares the SHA-256 of installation.json with the last one it saw. When the
# portal rewrites the file (the first-run wizard verified a domain, setup was
# completed, the owner's ACME consent changed), the configuration is rendered
# again and applied with `caddy reload`, without a restart and without dropping
# connections.
#
# A configuration that cannot be rendered or that Caddy refuses is never
# applied: the edge keeps serving the previous one and writes the reason to its
# log. SIGTERM stops Caddy gracefully and then this script.

set -eu

file=${ATLAS_INSTALLATION_FILE:-/var/lib/atlas/installation/installation.json}
interval=${ATLAS_EDGE_POLL_SECONDS:-5}
dir=/run/atlas-edge
conf=$dir/Caddyfile

log() {
    printf '%s atlas-edge: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

# fingerprint names the current state of the projection: its hash, "absent"
# before the portal wrote it, or "unreadable".
fingerprint() {
    if [ ! -e "$file" ]; then
        echo absent
        return
    fi
    sum=$(sha256sum "$file" 2>/dev/null | cut -d' ' -f1)
    echo "${sum:-unreadable}"
}

mkdir -p "$dir"
seen=$(fingerprint)

# Without a first configuration there is nothing to keep serving, so a render
# error at start stops the container and the reason is in its log.
if ! atlas-edge-render >"$conf.new" 2>"$dir/render.err"; then
    log "configuration not generated: $(cat "$dir/render.err")"
    exit 1
fi
mv "$conf.new" "$conf"
log "starting: mode=${ATLAS_EDGE_MODE:-direct} installation=$seen"

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

while :; do
    # Sleeping in the background keeps the shell able to run the trap at once.
    sleep "$interval" &
    wait $! || true

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
    [ "$now" != "$seen" ] || continue
    seen=$now

    if ! atlas-edge-render >"$conf.new" 2>"$dir/render.err"; then
        log "installation.json changed ($now) but the configuration was not generated; keeping the previous one: $(cat "$dir/render.err")"
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
