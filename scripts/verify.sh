#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)

compose="docker compose --env-file $repo_dir/env/compose.env -f $repo_dir/docker-compose.yml"
setting() { sed -n "s/^$1=//p" "$2" | tail -n 1 | tr -d '"'"'"' \r'; }

mode=$(setting ATLAS_EDGE_MODE "$repo_dir/env/compose.env")
mode=${mode:-direct}
http_bind=$(setting ATLAS_HTTP_BIND "$repo_dir/env/compose.env")
http_port=$(setting ATLAS_HTTP_PORT "$repo_dir/env/compose.env")
https_bind=$(setting ATLAS_HTTPS_BIND "$repo_dir/env/compose.env")
https_port=$(setting ATLAS_HTTPS_PORT "$repo_dir/env/compose.env")

cd "$repo_dir"
sha256sum -c SHA256SUMS
# SHA256SUMS travels inside the distribution, so it proves only that the files
# are intact; the signed release index proves who built them.
./artifacts/linux-amd64/atlas-update-check -verify .
$compose ps

# The edge answers its own health check only from inside the container.
$compose exec -T edge wget -qO- http://127.0.0.1:80/edge-health >/dev/null

# Host names: env/edge.env wins; otherwise the domains the first-run wizard
# stored, as the edge sees them.
portal_host=$(setting ATLAS_PORTAL_HOST "$repo_dir/env/edge.env")
tracking_host=$(setting ATLAS_TRACKING_HOST "$repo_dir/env/edge.env" | cut -d, -f1)
[ -n "$portal_host" ] || portal_host=$($compose exec -T edge jq -r '.portal_domain // ""' /var/lib/atlas/installation/installation.json)
[ -n "$tracking_host" ] || tracking_host=$($compose exec -T edge jq -r '.tracking_domains[0] // ""' /var/lib/atlas/installation/installation.json)
if [ -z "$portal_host" ] || [ -z "$tracking_host" ]; then
    printf '%s\n' 'No portal or tracking domain yet: finish the first-run wizard, then run this again.' >&2
    exit 1
fi

loopback() {
    case $1 in
        ''|0.0.0.0|::) echo 127.0.0.1 ;;
        *) echo "$1" ;;
    esac
}

# In direct mode the edge serves HTTPS with its own certificates, so the
# check goes over TLS to this host and fails on a missing or untrusted one.
if [ "$mode" = direct ]; then
    addr=$(loopback "$https_bind")
    port=${https_port:-443}
    for host in "$portal_host" "$tracking_host"; do
        curl -fsS --resolve "$host:$port:$addr" "https://$host:$port/health/ready"
        curl -fsS --resolve "$host:$port:$addr" "https://$host:$port/version"
    done
else
    addr=$(loopback "$http_bind")
    for host in "$portal_host" "$tracking_host"; do
        curl -fsS -H "Host: $host" "http://$addr:$http_port/health/ready"
        curl -fsS -H "Host: $host" "http://$addr:$http_port/version"
    done
fi

printf '%s\n' 'Atlas application artifacts and runtime endpoints verified.'
