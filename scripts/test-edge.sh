#!/usr/bin/env bash
#
# Route contract test of the edge (`make test-edge`).
#
# Builds the edge image from this directory and runs it twice, in `direct` and
# in `proxy` mode, next to two stubs that answer as "portal" and "gateway".
# The test writes installation.json itself, the way the portal would, and walks
# through the life of an installation: setup without domains, setup with
# verified domains, and a completed setup with portal, tracking and postback
# hosts; in `direct` mode also a server known by its public address only:
# HTTPS on the address during and after setup, the redirect to the portal
# domain once one is declared, and the fallback to Caddy's own CA when the
# ACME CA cannot be reached. Every phase sends the SAME requests in both modes and expects the same
# upstream for each: which host publishes which path must not depend on how
# the edge faces the internet.
#
# In `direct` mode certificates come from Caddy's internal certificate
# authority (ATLAS_EDGE_ACME_CA=internal): nothing is asked of a real ACME CA.
# Requires Docker and curl; touches no running Atlas installation and removes
# everything it created, also on failure.
#
# Usage: scripts/test-edge.sh [direct|proxy]...   (default: both modes)

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(cd -- "$script_dir/.." && pwd)
modes=("$@")
[ ${#modes[@]} -gt 0 ] || modes=(direct proxy)

run_id="atlas-edge-test-$$"
image="$run_id:image"
net="$run_id"
work=$(mktemp -d)
failures=0
checks=0
edge=
http_port=
https_port=
# The server's public address in the test: a documentation address the edge
# is told about through installation.json; curl connects it to 127.0.0.1.
pub_ip=203.0.113.10

cleanup() {
    docker rm -f "$run_id-edge" "$run_id-portal" "$run_id-gateway" >/dev/null 2>&1 || true
    docker network rm "$net" >/dev/null 2>&1 || true
    docker image rm "$image" >/dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT

say() { printf '%s\n' "$*"; }

# --- Stubs and installation.json ----------------------------------------------

mkdir -p "$work/stub" "$work/installation"
chmod 755 "$work/installation"
cat >"$work/stub/Caddyfile" <<'EOF'
:11082 {
	respond "upstream=portal uri={uri} xff={header.X-Forwarded-For} proto={header.X-Forwarded-Proto} realip={header.X-Real-IP}" 200
}
:8080 {
	respond "upstream=gateway uri={uri} xff={header.X-Forwarded-For} proto={header.X-Forwarded-Proto} realip={header.X-Real-IP}" 200
}
EOF

# write_installation replaces installation.json atomically, as the portal does.
write_installation() {
    local setup_open=$1 portal=$2 tracking=$3 postback=$4 ips=${5:-}
    local tracking_json='[]' postback_json=null ips_json='[]'
    [ -z "$tracking" ] || tracking_json="[\"$tracking\"]"
    [ -z "$postback" ] || postback_json="\"$postback\""
    [ -z "$ips" ] || ips_json="[\"$ips\"]"
    printf '{"schema":1,"generated_at":"%s","setup_open":%s,"portal_domain":"%s","tracking_domains":%s,"postback_domain":%s,"acme_email":null,"public_ips":%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)" "$setup_open" "$portal" "$tracking_json" "$postback_json" "$ips_json" \
        >"$work/installation/.next"
    chmod 644 "$work/installation/.next"
    mv "$work/installation/.next" "$work/installation/installation.json"
}

# wait_for_config waits until the edge serves a configuration rendered for the
# expected setup state and host set -- the reload is asynchronous.
wait_for_config() {
    local marker=$1 i
    for _ in $(seq 1 30); do
        if docker exec "$edge" head -n 1 /run/atlas-edge/Caddyfile 2>/dev/null | grep -q "$marker" \
            && docker exec "$edge" grep -q "$2" /run/atlas-edge/Caddyfile 2>/dev/null; then
            return 0
        fi
        sleep 1
    done
    say "edge did not apply the configuration ($marker, $2)"
    docker logs "$edge" 2>&1 | grep atlas-edge | tail -n 5
    return 1
}

# --- Requests ------------------------------------------------------------------

# fetch HOST PATH [curl args...]: HOST "ip" means the server's address, "pubip"
# the public address of the server (HTTPS unless scheme=http), any
# other value is a host name; other.* is a name the edge does not serve, asked
# over plain HTTP (its HTTPS side is checked apart: no certificate, no
# handshake). In direct mode known names go over HTTPS, in proxy
# mode everything is plain HTTP with a Host header -- as the balancer sends it.
# Prints "<code> <body>".
fetch() {
    local host=$1 path=$2
    shift 2
    local url args=(-s -o "$work/body" -w '%{http_code}' --max-time 10)
    if [ "$host" = pubip ] && [ "${scheme:-https}" = https ]; then
        # No SNI goes out for an address: the edge has to pick the
        # certificate itself.
        url="https://$pub_ip:$https_port$path"
        args+=(--cacert "$work/root.crt" --connect-to "$pub_ip:$https_port:127.0.0.1:$https_port")
    elif [ "$host" = pubip ]; then
        url="http://$pub_ip:$http_port$path"
        args+=(--connect-to "$pub_ip:$http_port:127.0.0.1:$http_port")
    elif [ "$host" = ip ]; then
        url="http://127.0.0.1:$http_port$path"
    elif [ "$mode" = direct ] && [ "${scheme:-https}" = https ] && [[ $host != other.* ]]; then
        url="https://$host:$https_port$path"
        args+=(--cacert "$work/root.crt" --resolve "$host:$https_port:127.0.0.1")
    else
        url="http://127.0.0.1:$http_port$path"
        args+=(-H "Host: $host")
    fi
    local code
    code=$(curl "${args[@]}" "$@" "$url" || true)
    printf '%s %s' "$code" "$(head -c 300 "$work/body" 2>/dev/null | tr '\n' ' ')"
}

# expect HOST PATH WANT: WANT is portal, gateway, spa (the portal SPA's
# index.html from the edge itself) or a bare HTTP code answered by the edge.
expect() {
    local host=$1 path=$2 want=$3 got code body ok=0
    got=$(fetch "$host" "$path")
    code=${got%% *}
    body=${got#* }
    case $want in
        portal|gateway) [ "$code" = 200 ] && [[ $body == upstream=$want* ]] && ok=1 ;;
        spa) [ "$code" = 200 ] && [[ $body == *"<!doctype html"* || $body == *"<!DOCTYPE html"* ]] && ok=1 ;;
        *) [ "$code" = "$want" ] && [[ $body != upstream=* ]] && ok=1 ;;
    esac
    checks=$((checks + 1))
    if [ "$ok" -eq 1 ]; then
        printf '  ok    %-7s %-18s %-32s -> %s\n' "$mode" "$host" "$path" "$want"
    else
        failures=$((failures + 1))
        printf '  FAIL  %-7s %-18s %-32s -> want %s, got %s %.80s\n' "$mode" "$host" "$path" "$want" "$code" "$body"
    fi
}

# check NAME CONDITION-RESULT: a free-form assertion with its own name.
check() {
    checks=$((checks + 1))
    if [ "$2" = yes ]; then
        printf '  ok    %-7s %s\n' "$mode" "$1"
    else
        failures=$((failures + 1))
        printf '  FAIL  %-7s %s\n' "$mode" "$1"
    fi
}

# --- One mode --------------------------------------------------------------------

start_edge() {
    local trusted=$1 acme_ca=${2:-internal}
    docker rm -f "$run_id-edge" >/dev/null 2>&1 || true
    local ports=(-p 127.0.0.1::80)
    [ "$mode" = proxy ] || ports+=(-p 127.0.0.1::443)
    edge=$(docker run -d --name "$run_id-edge" --network "$net" \
        --network-alias portal.edge.test --network-alias track.edge.test --network-alias pb.edge.test \
        "${ports[@]}" \
        -e ATLAS_EDGE_MODE="$mode" -e ATLAS_EDGE_ACME_CA="$acme_ca" \
        -e ATLAS_EDGE_TRUSTED_PROXY_CIDR="$trusted" \
        -v "$work/installation:/var/lib/atlas/installation:ro" \
        "$image")
    http_port=$(docker port "$edge" 80/tcp | head -n 1 | sed 's/.*://')
    https_port=
    [ "$mode" = proxy ] || https_port=$(docker port "$edge" 443/tcp | head -n 1 | sed 's/.*://')
    local i
    for _ in $(seq 1 30); do
        docker exec "$edge" wget -qO- http://127.0.0.1:80/edge-health >/dev/null 2>&1 && return 0
        sleep 1
    done
    say "edge did not become healthy"
    docker logs "$edge" 2>&1 | tail -n 20
    exit 1
}

# wait_for_certificates waits until the internal CA issued certificates for the
# known names (direct mode only) and keeps its root for curl.
wait_for_certificates() {
    [ "$mode" = direct ] || return 0
    local i
    docker cp "$edge:/data/caddy/pki/authorities/local/root.crt" "$work/root.crt" >/dev/null
    for _ in $(seq 1 30); do
        if curl -s -o /dev/null --max-time 5 --cacert "$work/root.crt" \
            --resolve "pb.edge.test:$https_port:127.0.0.1" "https://pb.edge.test:$https_port/version"; then
            return 0
        fi
        sleep 1
    done
    say "certificates were not issued"
    return 1
}

# wait_for_ip_certificate waits until HTTPS on the public address completes a
# handshake trusted by the edge's own CA (direct mode only) and keeps its root.
wait_for_ip_certificate() {
    local i
    for _ in $(seq 1 30); do
        if docker cp "$edge:/data/caddy/pki/authorities/local/root.crt" "$work/root.crt" >/dev/null 2>&1 \
            && curl -s -o /dev/null --max-time 5 --cacert "$work/root.crt" \
                --connect-to "$pub_ip:$https_port:127.0.0.1:$https_port" "https://$pub_ip:$https_port/"; then
            return 0
        fi
        sleep 1
    done
    say "no certificate for $pub_ip"
    docker logs "$edge" 2>&1 | tail -n 10
    return 1
}

# acme_state NAME: waits until acme.json names NAME with a final outcome and
# prints "<state> <issuer> <error>" (direct mode only).
acme_state() {
    local out=
    for _ in $(seq 1 15); do
        out=$(docker exec "$edge" jq -r --arg n "$1" \
            '.names[$n] // empty | select(.state != "pending") | "\(.state) \(.issuer) \(.error // "")"' \
            /var/lib/atlas/edge-status/acme.json 2>/dev/null || true)
        [ -z "$out" ] || break
        sleep 1
    done
    printf '%s' "$out"
}

# redirect_of HOST-URL [curl args...]: prints "<code> <Location>".
redirect_of() {
    local url=$1
    shift
    curl -s -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 10 "$@" "$url" || true
}

run_mode() {
    say ""
    say "== $mode"
    # The source address the edge sees for requests from this host.
    local gateway_ip
    gateway_ip=$(docker network inspect -f '{{(index .IPAM.Config 0).Gateway}}' "$net")

    # Phase 1: a fresh server. No domains, setup open: the wizard by IP.
    write_installation true "" "" ""
    start_edge 127.0.0.1/32
    wait_for_config 'setup=true' 'http:// {'
    say "-- setup, no domains"
    expect ip /setup spa
    expect ip /assets/ spa
    expect ip /api/setup/status portal
    expect ip /.well-known/atlas-setup/label portal
    expect ip /api/me 404
    expect ip /internal/settings 404
    # The container health check: direct answers it only from inside the
    # container; proxy keeps it open for orchestrator probes.
    if [ "$mode" = direct ]; then
        expect ip /edge-health 404
    else
        expect ip /edge-health 200
    fi
    expect other.edge.test /setup spa

    # Phase 1b: the same fresh server, its public address known. In direct
    # mode the wizard is also served over HTTPS on that address, with plain
    # HTTP still serving the first steps; proxy mode ignores the address.
    write_installation true "" "" "" "$pub_ip"
    if [ "$mode" = direct ]; then
        wait_for_config 'ip_site=true' "default_sni $pub_ip"
        wait_for_ip_certificate
        say "-- setup, no domains, HTTPS on the public address"
        expect pubip /setup spa
        expect pubip /api/setup/status portal
        expect pubip /api/me 404
        expect pubip /internal/settings 404
        scheme=http expect pubip /setup spa
        scheme=http expect pubip /api/setup/status portal
    else
        wait_for_config 'ip_site=false' 'http:// {'
        local rendered
        rendered=$(docker exec "$edge" grep -c "$pub_ip" /run/atlas-edge/Caddyfile || true)
        check "proxy mode ignores public_ips" "$([ "$rendered" = 0 ] && echo yes || echo no)"
        expect ip /setup spa
    fi

    # Phase 2: the wizard verified the domains, setup still open. The names
    # already serve their roles, and their plain-HTTP side still answers the
    # reachability label -- no redirect, the portal does not follow one.
    write_installation true portal.edge.test track.edge.test ""
    wait_for_config 'setup=true' 'track.edge.test'
    say "-- setup, domains verified"
    scheme=http expect portal.edge.test /.well-known/atlas-setup/label portal
    scheme=http expect track.edge.test /.well-known/atlas-setup/label portal
    expect ip /setup spa

    # Phase 3: setup completed, portal + tracking + postback hosts.
    write_installation false portal.edge.test track.edge.test pb.edge.test
    wait_for_config 'setup=false' 'pb.edge.test'
    wait_for_certificates
    say "-- setup completed"
    if [ "$mode" = direct ]; then
        # The edge records each certificate it obtained for the portal.
        body=$(acme_state portal.edge.test)
        check "certificate status: portal host obtained ($body)" "$([[ $body == "ok local"* ]] && echo yes || echo no)"
    fi
    # Portal host: API, health, version and the SPA; tracking paths and the
    # vendor-only /s2s never reach a service from here.
    expect portal.edge.test /api/me portal
    expect portal.edge.test /api/setup/status portal
    expect portal.edge.test /internal/settings portal
    expect portal.edge.test /health/ready portal
    expect portal.edge.test /version portal
    expect portal.edge.test / spa
    expect portal.edge.test /setup spa
    expect portal.edge.test /c/abc spa
    expect portal.edge.test /postback spa
    expect portal.edge.test /s2s/tenants spa
    expect portal.edge.test /metrics spa
    # Tracking host: intake only.
    expect track.edge.test /c/abc gateway
    expect track.edge.test /lp gateway
    expect track.edge.test /impression gateway
    expect track.edge.test /impression.gif gateway
    expect track.edge.test /_atlas/refusal-preview gateway
    expect track.edge.test '/postback?token=secret' gateway
    expect track.edge.test /health/ready gateway
    expect track.edge.test /version gateway
    expect track.edge.test /healthz gateway
    expect track.edge.test /readyz gateway
    expect track.edge.test /api/me 404
    expect track.edge.test /internal/settings 404
    expect track.edge.test /api/setup/status 404
    expect track.edge.test / 404
    expect track.edge.test /setup 404
    expect track.edge.test /metrics 404
    expect track.edge.test /lpx 404
    # The reachability label stays open on plain HTTP after setup: the owner
    # declares and changes domains in the portal settings, including names
    # that are not sites yet. HTTPS sites never carry it.
    scheme=http expect track.edge.test /.well-known/atlas-setup/label portal
    scheme=http expect other.edge.test /.well-known/atlas-setup/label portal
    [ "$mode" != direct ] || expect track.edge.test /.well-known/atlas-setup/label 404
    # Postback host: postbacks, health and version.
    expect pb.edge.test '/postback?token=secret' gateway
    expect pb.edge.test /health/ready gateway
    expect pb.edge.test /version gateway
    expect pb.edge.test /c/abc 404
    expect pb.edge.test /api/me 404
    expect pb.edge.test / 404
    # The wizard is closed: IP addresses and unknown names get nothing.
    expect ip / 404
    expect ip /setup 404
    expect ip /api/setup/status 404
    expect other.edge.test / 404
    expect other.edge.test /api/me 404

    if [ "$mode" = direct ]; then
        # Phase 3b: setup completed without domains. The public address is
        # the portal host on HTTPS; its plain HTTP redirects there.
        write_installation false "" "" "" "$pub_ip"
        wait_for_config 'ip_site=true' "redir https://$pub_ip"
        wait_for_ip_certificate
        say "-- setup completed without domains"
        expect pubip /api/me portal
        expect pubip /api/setup/status portal
        expect pubip /internal/settings portal
        expect pubip /version portal
        expect pubip / spa
        expect pubip /c/abc spa
        body=$(redirect_of "http://$pub_ip:$http_port/settings/domains?x=1" --connect-to "$pub_ip:$http_port:127.0.0.1:$http_port")
        check "HTTP on the address redirects to HTTPS on it ($body)" "$([ "$body" = "308 https://$pub_ip/settings/domains?x=1" ] && echo yes || echo no)"
        expect ip / 404

        # Phase 3c: a portal domain is declared. The address stops being a
        # site of its own and redirects to the portal domain.
        write_installation false portal.edge.test track.edge.test pb.edge.test "$pub_ip"
        wait_for_config 'ip_site=false' "redir https://portal.edge.test"
        say "-- portal domain declared"
        body=$(redirect_of "http://$pub_ip:$http_port/offers?x=1" --connect-to "$pub_ip:$http_port:127.0.0.1:$http_port")
        check "HTTP on the address redirects to the portal domain ($body)" "$([ "$body" = "308 https://portal.edge.test/offers?x=1" ] && echo yes || echo no)"
        body=$(docker exec "$edge" grep -c "https://$pub_ip" /run/atlas-edge/Caddyfile || true)
        check "no HTTPS site on the address once a portal domain is declared" "$([ "$body" = 0 ] && echo yes || echo no)"
        expect portal.edge.test /api/me portal
        expect track.edge.test /c/abc gateway
    fi

    # Postback query strings never reach the access log.
    local logged
    logged=$(docker logs "$edge" 2>&1 | grep -c 'token=secret' || true)
    check "postback token absent from the edge log" "$([ "$logged" = 0 ] && echo yes || echo no)"

    local body
    if [ "$mode" = direct ]; then
        # Plain HTTP of a known name redirects to HTTPS; HSTS on the portal only.
        body=$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' -H 'Host: track.edge.test' "http://127.0.0.1:$http_port/c/abc?x=1")
        check "HTTP of a known name redirects to HTTPS ($body)" "$([ "$body" = "308 https://track.edge.test/c/abc?x=1" ] && echo yes || echo no)"
        body=$(curl -s -D - -o /dev/null --cacert "$work/root.crt" --resolve "portal.edge.test:$https_port:127.0.0.1" "https://portal.edge.test:$https_port/" | tr -d '\r' | grep -ci '^strict-transport-security:' || true)
        check "HSTS on the portal host" "$([ "$body" = 1 ] && echo yes || echo no)"
        body=$(curl -s -D - -o /dev/null --cacert "$work/root.crt" --resolve "track.edge.test:$https_port:127.0.0.1" "https://track.edge.test:$https_port/c/abc" | tr -d '\r' | grep -ci '^strict-transport-security:' || true)
        check "no HSTS on the tracking host" "$([ "$body" = 0 ] && echo yes || echo no)"
        # A known name in SNI with a foreign Host header is not routed.
        body=$(curl -s -o /dev/null -w '%{http_code}' --cacert "$work/root.crt" --resolve "track.edge.test:$https_port:127.0.0.1" -H 'Host: other.edge.test' "https://track.edge.test:$https_port/c/abc")
        check "known SNI with a foreign Host answers 404 ($body)" "$([ "$body" = 404 ] && echo yes || echo no)"
        # An unknown name gets no certificate at all.
        body=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --cacert "$work/root.crt" --resolve "other.edge.test:$https_port:127.0.0.1" "https://other.edge.test:$https_port/" || true)
        check "unknown SNI fails the TLS handshake ($body)" "$([ "$body" = 000 ] && echo yes || echo no)"
        # No proxy in front: forged forwarding headers are replaced.
        body=$(fetch track.edge.test /c/abc -H 'X-Forwarded-For: 1.2.3.4' -H 'X-Real-IP: 1.2.3.4' -H 'X-Forwarded-Proto: http')
        check "forged X-Forwarded-*/X-Real-IP replaced" "$([[ $body != *1.2.3.4* && $body == *proto=https* ]] && echo yes || echo no)"
    else
        # Untrusted peer (the default loopback CIDR): forged headers replaced.
        body=$(fetch track.edge.test /c/abc -H 'X-Forwarded-For: 1.2.3.4' -H 'X-Real-IP: 1.2.3.4' -H 'X-Forwarded-Proto: https')
        check "untrusted peer: forged X-Forwarded-*/X-Real-IP replaced" "$([[ $body != *1.2.3.4* && $body == *proto=http\ * ]] && echo yes || echo no)"
        body=$(curl -s -D - -o /dev/null -H 'Host: portal.edge.test' "http://127.0.0.1:$http_port/" | tr -d '\r' | grep -ci '^strict-transport-security:' || true)
        check "no HSTS in proxy mode" "$([ "$body" = 0 ] && echo yes || echo no)"
        # The same edge trusting this host as the balancer keeps its headers.
        start_edge "$gateway_ip/32"
        wait_for_config 'setup=false' 'pb.edge.test'
        body=$(fetch track.edge.test /c/abc -H 'X-Forwarded-For: 1.2.3.4' -H 'X-Forwarded-Proto: https')
        check "trusted balancer: client address and scheme passed on" "$([[ $body == *xff=1.2.3.4,* && $body == *proto=https* && $body == *realip=1.2.3.4* ]] && echo yes || echo no)"
    fi

    # A broken projection is not applied; the edge keeps serving.
    printf '{broken' >"$work/installation/.next"
    chmod 644 "$work/installation/.next"
    mv "$work/installation/.next" "$work/installation/installation.json"
    sleep 7
    expect track.edge.test /c/abc gateway
    body=$(docker logs "$edge" 2>&1 | grep -c 'keeping the previous one' || true)
    check "broken installation.json logged and not applied" "$([ "$body" -ge 1 ] && echo yes || echo no)"

    # SIGTERM stops the edge cleanly.
    docker stop -t 20 "$edge" >/dev/null
    body=$(docker inspect -f '{{.State.ExitCode}}' "$edge")
    check "SIGTERM stops the edge with exit code 0 (got $body)" "$([ "$body" = 0 ] && echo yes || echo no)"

    if [ "$mode" = direct ]; then
        # The ACME CA cannot be reached (a closed port at the provider looks
        # the same to the edge): HTTPS on the address still works, on a
        # certificate of Caddy's own CA.
        write_installation true "" "" "" "$pub_ip"
        start_edge 127.0.0.1/32 https://127.0.0.1:9/directory
        wait_for_config 'ip_site=true' 'profile shortlived'
        say "-- ACME CA unreachable: Caddy's own CA on the address"
        wait_for_ip_certificate
        # The fallback certificate keeps the refusal of the public CA, so the
        # portal can say why the browser warns.
        body=$(acme_state "$pub_ip")
        check "certificate status: own CA with the ACME refusal kept ($body)" "$([[ $body == "ok local "*"connection refused"* ]] && echo yes || echo no)"
        expect pubip /setup spa
        docker stop -t 20 "$edge" >/dev/null
    fi
}

# --- Main ----------------------------------------------------------------------

say "building the edge image from $repo_dir"
docker build -q -f "$repo_dir/images/frontend/Dockerfile" -t "$image" "$repo_dir" >/dev/null
docker network create "$net" >/dev/null
for name in portal gateway; do
    docker run -d --name "$run_id-$name" --network "$net" --network-alias "$name" \
        -v "$work/stub:/stub:ro" --entrypoint caddy "$image" \
        run --config /stub/Caddyfile --adapter caddyfile >/dev/null
done

for mode in "${modes[@]}"; do
    case $mode in
        direct|proxy) run_mode ;;
        *) say "unknown mode: $mode"; exit 2 ;;
    esac
done

say ""
if [ "$failures" -gt 0 ]; then
    say "edge route contract: $failures of $checks checks FAILED"
    exit 1
fi
say "edge route contract: all $checks checks passed"
