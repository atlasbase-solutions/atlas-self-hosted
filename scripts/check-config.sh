#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)

missing=0
for example in "$repo_dir"/env/*.env.example; do
    target=${example%.example}
    if [ ! -f "$target" ]; then
        printf 'Missing %s; run ./scripts/prepare-env.sh\n' "${target#"$repo_dir"/}" >&2
        missing=1
    fi
done
[ "$missing" -eq 0 ] || exit 1

if grep -R -n 'CHANGE_ME\|example\.com' "$repo_dir"/env/*.env; then
    printf '%s\n' 'Replace every placeholder above before starting Atlas.' >&2
    exit 1
fi

# Encryption keys must be exactly 32 random bytes, written in hex or base64 --
# the same rule the services apply at startup, checked here so a passphrase is
# caught before the first `docker compose up` instead of in a restart loop.
check_key() {
    file=$1
    name=$2
    value=$(sed -n "s/^${name}=//p" "$file" | tail -n 1 | tr -d '"'"'"' \r')
    [ -n "$value" ] || return 0
    case $value in
        # 32 bytes in hex: 64 characters, hex alphabet only.
        *[!0-9A-Fa-f]*) ;;
        ????????????????????????????????????????????????????????????????) return 0 ;;
    esac
    # 32 bytes in base64: 44 characters with padding, 43 without.
    case $value in
        *[!0-9A-Za-z+/=_-]*) ;;
        ???????????????????????????????????????????|????????????????????????????????????????????) return 0 ;;
    esac
    printf '%s in %s is not 32 random bytes; generate one with `openssl rand -hex 32`\n' \
        "$name" "${file#"$repo_dir"/}" >&2
    return 1
}

# A trusted proxy network must be the balancer's own subnet. Trusting a whole
# private range makes every visitor look like one address and lets a client
# forge its own; the services refuse such a value at startup, and catching it
# here saves a restart loop.
check_proxy_cidrs() {
    file=$1
    name=$2
    value=$(sed -n "s/^${name}=//p" "$file" | tail -n 1 | tr -d '"'"'"' \r')
    [ -n "$value" ] || return 0
    problem=0
    for cidr in $(printf '%s' "$value" | tr ',' ' '); do
        bits=${cidr#*/}
        case $cidr in
            */*) ;;
            *)
                printf '%s in %s: %s has no network prefix\n' "$name" "${file#"$repo_dir"/}" "$cidr" >&2
                problem=1
                continue
                ;;
        esac
        case $cidr in
            # IPv6 entries are compared against their own limit below.
            *:*)
                [ "$bits" -ge 64 ] 2>/dev/null || {
                    printf '%s in %s: %s is wider than /64\n' "$name" "${file#"$repo_dir"/}" "$cidr" >&2
                    problem=1
                }
                ;;
            *)
                [ "$bits" -ge 16 ] 2>/dev/null || {
                    printf '%s in %s: %s is wider than /16 -- name the balancer subnet, not a whole private range\n' \
                        "$name" "${file#"$repo_dir"/}" "$cidr" >&2
                    problem=1
                }
                ;;
        esac
    done
    return $problem
}

# The edge replaces client forwarding headers unless it is told which proxy to
# believe, so "behind a proxy" without its subnet silently loses client
# addresses.
check_edge_proxy() {
    file="$repo_dir/env/edge.env"
    [ -f "$file" ] || return 0
    value=$(sed -n 's/^ATLAS_EDGE_TRUSTED_PROXY_CIDR=//p' "$file" | tail -n 1 | tr -d '"'"'"' \r')
    [ -n "$value" ] || {
        printf 'ATLAS_EDGE_TRUSTED_PROXY_CIDR in env/edge.env is empty; use 127.0.0.1/32 when no proxy sits in front of Atlas\n' >&2
        return 1
    }
    return 0
}

# The edge mode decides which ports are published and whether the edge
# obtains certificates itself; a typo would silently fall back to neither.
check_edge_mode() {
    file="$repo_dir/env/compose.env"
    value=$(sed -n 's/^ATLAS_EDGE_MODE=//p' "$file" | tail -n 1 | tr -d '"'"'"' \r')
    case ${value:-direct} in
        direct) return 0 ;;
        proxy)
            https_port=$(sed -n 's/^ATLAS_HTTPS_PORT=//p' "$file" | tail -n 1 | tr -d '"'"'"' \r')
            https_bind=$(sed -n 's/^ATLAS_HTTPS_BIND=//p' "$file" | tail -n 1 | tr -d '"'"'"' \r')
            # In proxy mode nothing listens on HTTPS; publishing 443 on every
            # address would only take the port from your own TLS proxy.
            if [ -n "$https_port" ] && [ "$https_bind" != 127.0.0.1 ]; then
                printf 'ATLAS_EDGE_MODE=proxy: set ATLAS_HTTPS_BIND=127.0.0.1 and leave ATLAS_HTTPS_PORT empty in env/compose.env\n' >&2
                return 1
            fi
            return 0
            ;;
    esac
    printf 'ATLAS_EDGE_MODE in env/compose.env must be direct or proxy, got %s\n' "$value" >&2
    return 1
}

key_problem=0
check_key "$repo_dir/env/portal.env" PORTAL_SECRET_KEY || key_problem=1
check_key "$repo_dir/env/portal.env" ATLAS_CONFIG_SECRET_KEY || key_problem=1
check_key "$repo_dir/env/gateway.env" ATLAS_CONFIG_SECRET_KEY || key_problem=1
check_proxy_cidrs "$repo_dir/env/portal.env" PORTAL_TRUSTED_PROXY_CIDRS || key_problem=1
check_proxy_cidrs "$repo_dir/env/portal.env" PORTAL_EXTERNAL_PROXY_CIDRS || key_problem=1
check_proxy_cidrs "$repo_dir/env/gateway.env" TRUSTED_PROXY_CIDRS || key_problem=1
check_proxy_cidrs "$repo_dir/env/gateway.env" EXTERNAL_PROXY_CIDRS || key_problem=1
check_edge_proxy || key_problem=1
check_edge_mode || key_problem=1
[ "$key_problem" -eq 0 ] || exit 1

docker compose --env-file "$repo_dir/env/compose.env" -f "$repo_dir/docker-compose.yml" config --quiet
printf '%s\n' 'Configuration is complete and the Compose model is valid.'

