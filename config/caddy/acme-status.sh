#!/bin/sh
#
# Certificate status of the edge (`direct` mode). Caddy writes its TLS log
# (`tls.*` loggers) to /run/atlas-edge/tls.log; this script follows that file
# and keeps, per name, the outcome of the latest certificate attempt in
# acme.json on the edge-status volume, which the portal mounts read-only to
# show why a certificate is still missing.
#
# acme.json:
#   {"schema": 1, "updated_at": "...",
#    "names": {"<name or address>": {"state": "pending|ok|failed",
#              "issuer": "...", "error": "...", "at": "..."}}}
#
# "error" is the last refusal of the certificate authority, cut to 500
# characters. It survives a success by Caddy's own authority ("issuer":
# "local"), so the portal can explain why the public certificate was not
# issued; any other success clears it. The file is rewritten atomically.

set -u

log_file=${ATLAS_EDGE_TLS_LOG:-/run/atlas-edge/tls.log}
dir=${ATLAS_EDGE_STATUS_DIR:-/var/lib/atlas/edge-status}
status=$dir/acme.json

say() {
    printf '%s atlas-edge: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

# Without the volume (an older compose file) there is nowhere to write: the
# edge works as before and the portal shows no reasons.
if ! mkdir -p "$dir" 2>/dev/null || ! touch "$dir/.probe" 2>/dev/null; then
    say "certificate status not written: $dir is not writable"
    exit 0
fi
rm -f "$dir/.probe"

# update EVENT applies one JSON log entry of Caddy to acme.json.
update() {
    current=$(cat "$status" 2>/dev/null) || current=''
    # A missing or damaged file starts over: the next attempts refill it.
    printf '%s' "$current" | jq -e . >/dev/null 2>&1 || current='{}'
    next=$(printf '%s' "$current" | jq -c --argjson e "$1" '
        ($e.ts | floor | todate) as $at
        | ($e.identifier // "") as $id
        | ($e.msg // "") as $m
        | if $id == "" then empty
          elif $m == "obtaining certificate" or $m == "renewing certificate" then
            .names[$id] = ((.names[$id] // {}) + {state: "pending", at: $at})
          elif $m == "certificate obtained successfully" or $m == "certificate renewed successfully" then
            .names[$id] = ((.names[$id] // {}) + {state: "ok", issuer: ($e.issuer // ""), at: $at}
              | if .issuer == "local" then . else del(.error) end)
          elif $m == "could not get certificate from issuer" then
            .names[$id] = ((.names[$id] // {}) + {state: "failed", issuer: ($e.issuer // ""),
              error: (($e.error // "") | .[0:500]), at: $at})
          else empty end
        | .schema = 1 | .updated_at = $at' 2>/dev/null) || return 0
    [ -n "$next" ] || return 0
    printf '%s\n' "$next" >"$status.next" && chmod 0644 "$status.next" && mv "$status.next" "$status"
}

# Caddy creates the log on its first TLS entry; tail waits for it and follows
# it across Caddy's rotation.
tail -n +1 -F "$log_file" 2>/dev/null | while IFS= read -r line; do
    # Only the messages that change a name's state are parsed; lock and
    # storage housekeeping lines are skipped without starting jq.
    case $line in
        *'"msg":"obtaining certificate"'* | *'"msg":"renewing certificate"'* | \
            *'"msg":"certificate obtained successfully"'* | *'"msg":"certificate renewed successfully"'* | \
            *'"msg":"could not get certificate from issuer"'*)
            update "$line"
            ;;
    esac
done
