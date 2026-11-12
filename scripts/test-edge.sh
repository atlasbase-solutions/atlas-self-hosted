#!/usr/bin/env bash
#
# Route contract test of the edge (`make test-edge`).
#
# Builds the edge image from this directory and runs it in each mode -- `direct`,
# `manual` and `proxy` -- next to two stubs that answer as "portal" and "gateway".
# The test writes installation.json itself, the way the portal would, and walks
# through the life of an installation: setup without domains, setup with
# verified domains, and a completed setup with portal, tracking and postback
# hosts; in `direct` mode also a server known by its public address only:
# HTTPS on the address during and after setup, the redirect to the portal
# domain once one is declared, and the fallback to Caddy's own CA when the
# ACME CA cannot be reached; and own certificates: the one the owner uploaded
# in the portal (the manifest on the edge-certs volume), the operator's files
# in config/tls/, and the return to the edge's own certificate at serve_until
# without anything being rewritten. Every phase sends the SAME requests in every
# mode and expects the same upstream for each: which host publishes which path
# must not depend on how the edge faces the internet.
#
# In `direct` mode certificates come from Caddy's internal certificate
# authority (ATLAS_EDGE_ACME_CA=internal): nothing is asked of a real ACME CA.
# In `manual` mode the edge obtains nothing at all: the known hosts are served
# with certificates of a throwaway test CA, given to the edge the way the
# portal and the operator give them. On top of the shared requests it checks
# that the generated configuration has no issuance directive, that a host
# without a certificate fails the handshake while HTTP still redirects, that a
# certificate is served until its serve_until (the certificate's expiry) and
# dropped afterwards with nothing rewritten, that the server's address has no
# HTTPS, and that the edge starts on a container without any network.
# Requires Docker, curl and openssl; touches no running Atlas installation and removes
# everything it created, also on failure.
#
# Usage: scripts/test-edge.sh [direct|manual|proxy]...   (default: all three)

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(cd -- "$script_dir/.." && pwd)
modes=("$@")
[ ${#modes[@]} -gt 0 ] || modes=(direct manual proxy)

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
    docker rm -f "$run_id-edge" "$run_id-offline" "$run_id-portal" "$run_id-gateway" >/dev/null 2>&1 || true
    docker network rm "$net" >/dev/null 2>&1 || true
    docker image rm "$image" >/dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT

say() { printf '%s\n' "$*"; }

# --- Stubs and installation.json ----------------------------------------------

mkdir -p "$work/stub" "$work/installation" "$work/edge-certs" "$work/tls"
chmod 755 "$work/installation" "$work/edge-certs" "$work/tls"
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

# --- Own certificates ----------------------------------------------------------

# iso_in SECONDS prints the UTC time SECONDS from now, as the portal writes it.
iso_in() {
    local at=$(( $(date +%s) + $1 ))
    date -u -d "@$at" +%Y-%m-%dT%H:%M:%S.000000000Z 2>/dev/null || date -u -r "$at" +%Y-%m-%dT%H:%M:%S.000000000Z
}

# make_cert PATH SAN...: a self-signed certificate and its key at PATH.crt and
# PATH.key; prints the SHA-256 of the certificate, the name the portal gives
# its files.
make_cert() {
    local path=$1 san
    shift
    san=$(printf 'DNS:%s,' "$@")
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 30 \
        -subj "/CN=$1" -addext "subjectAltName=${san%,}" \
        -keyout "$path.key" -out "$path.crt" >/dev/null 2>&1
    chmod 644 "$path.key" "$path.crt"
    openssl x509 -in "$path.crt" -outform der | sha256sum | cut -d' ' -f1
}

# make_ca_cert PATH SAN...: like make_cert, but signed by the test CA
# ($work/ca.crt), which manual mode gives curl as its trust root.
make_ca_cert() {
    local path=$1 san
    shift
    san=$(printf 'DNS:%s,' "$@")
    openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
        -subj "/CN=$1" -keyout "$path.key" -out "$path.csr" >/dev/null 2>&1
    printf 'subjectAltName=%s\nbasicConstraints=CA:FALSE\n' "${san%,}" >"$path.ext"
    openssl x509 -req -in "$path.csr" -CA "$work/ca.crt" -CAkey "$work/ca.key" -CAcreateserial \
        -days 30 -extfile "$path.ext" -out "$path.crt" >/dev/null 2>&1
    chmod 644 "$path.key" "$path.crt"
    openssl x509 -in "$path.crt" -outform der | sha256sum | cut -d' ' -f1
}

# install_portal_cert PATH: puts a certificate made by make_cert or
# make_ca_cert on the edge-certs volume under its fingerprint, as the portal
# does, and prints the fingerprint.
install_portal_cert() {
    local fp
    fp=$(openssl x509 -in "$1.crt" -outform der | sha256sum | cut -d' ' -f1)
    cp "$1.crt" "$work/edge-certs/$fp.crt"
    cp "$1.key" "$work/edge-certs/$fp.key"
    printf '%s' "$fp"
}

# handshake HOST prints the HTTP code of an HTTPS request to HOST trusted by
# the test roots; 000 means the TLS handshake did not complete.
handshake() {
    curl -s -o /dev/null -w '%{http_code}' --max-time 5 --cacert "$work/root.crt" \
        --resolve "$1:$https_port:127.0.0.1" "https://$1:$https_port/version" || true
}

# write_manifest FP HOSTS-JSON SERVE-UNTIL replaces manifest.json atomically,
# as the portal does.
write_manifest() {
    printf '{"schema":1,"generated_at":"%s","certificates":[{"fingerprint":"%s","cert_file":"%s.crt","key_file":"%s.key","hosts":[%s],"serve_until":"%s"}]}\n' \
        "$(iso_in 0)" "$1" "$1" "$1" "$2" "$3" >"$work/edge-certs/.next"
    chmod 644 "$work/edge-certs/.next"
    mv "$work/edge-certs/.next" "$work/edge-certs/manifest.json"
}

# served_fp HOST prints the SHA-256 of the certificate the edge presents for HOST.
served_fp() {
    echo | openssl s_client -connect "127.0.0.1:$https_port" -servername "$1" 2>/dev/null \
        | openssl x509 -outform der 2>/dev/null | sha256sum | cut -d' ' -f1
}

# own_fetch HOST PATH prints the body served over HTTPS, the certificate not
# being verified: the test only checks where the request went.
own_fetch() {
    curl -sk --max-time 10 --resolve "$1:$https_port:127.0.0.1" "https://$1:$https_port$2" || true
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
    elif [ "$mode" != proxy ] && [ "${scheme:-https}" = https ] && [[ $host != other.* ]]; then
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
    local trusted=$1 acme_ca=${2:-}
    # Only direct mode issues certificates, from Caddy's own CA unless told
    # otherwise; manual mode must refuse any CA, and proxy ignores it.
    [ "$mode" != direct ] || acme_ca=${acme_ca:-internal}
    docker rm -f "$run_id-edge" >/dev/null 2>&1 || true
    local ports=(-p 127.0.0.1::80)
    [ "$mode" = proxy ] || ports+=(-p 127.0.0.1::443)
    edge=$(docker run -d --name "$run_id-edge" --network "$net" \
        --network-alias portal.edge.test --network-alias track.edge.test --network-alias pb.edge.test \
        "${ports[@]}" \
        -e ATLAS_EDGE_MODE="$mode" -e ATLAS_EDGE_ACME_CA="$acme_ca" \
        -e ATLAS_EDGE_TRUSTED_PROXY_CIDR="$trusted" -e ATLAS_EDGE_FULL_RENDER_SECONDS=10 \
        -v "$work/installation:/var/lib/atlas/installation:ro" \
        -v "$work/edge-certs:/var/lib/atlas/edge-certs:ro" \
        -v "$work/tls:/etc/atlas/tls:ro" \
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

# yesno CONDITION... prints "yes" when the command succeeds, "no" otherwise.
yesno() {
    if "$@"; then echo yes; else echo no; fi
}

# no_issuance prints "yes" when nothing in the running edge obtains a
# certificate: no issuance directive in the configuration, no ACME account,
# no certificate or CA in Caddy's storage and no attempt in the log (manual
# mode only).
no_issuance() {
    local conf data logs
    # The 404 for ACME challenge paths is the only "acme" allowed in the file.
    conf=$(docker exec "$edge" sh -c "grep -v 'acme-challenge' /run/atlas-edge/Caddyfile | grep -Ec 'acme|issuer|cert_issuer|local_certs|on_demand|email|tls internal|default_sni'" || true)
    data=$(docker exec "$edge" sh -c 'ls -d /data/caddy/certificates /data/caddy/acme /data/caddy/pki 2>/dev/null' || true)
    logs=$(docker logs "$edge" 2>&1 | grep -Eci 'obtain|acme_client|issuing|renew|solving challenge' || true)
    [ "$conf" = 0 ] && [ -z "$data" ] && [ "$logs" = 0 ] \
        && docker exec "$edge" grep -q 'auto_https off' /run/atlas-edge/Caddyfile \
        && ! docker exec "$edge" test -e /var/lib/atlas/edge-status/acme.json
}

run_mode() {
    say ""
    say "== $mode"
    # The source address the edge sees for requests from this host.
    local gateway_ip
    gateway_ip=$(docker network inspect -f '{{(index .IPAM.Config 0).Gateway}}' "$net")
    rm -f "$work/edge-certs/manifest.json" "$work/edge-certs/"*.crt "$work/edge-certs/"*.key "$work/tls/"*

    # Manual mode trusts the test CA only; its certificate for the three known
    # hosts goes to the edge the way the portal gives one, and stays valid for
    # the whole run unless a phase replaces it.
    local base_fp=
    if [ "$mode" = manual ]; then
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 30 \
            -subj "/CN=Atlas edge test CA" -keyout "$work/ca.key" -out "$work/ca.crt" >/dev/null 2>&1
        cp "$work/ca.crt" "$work/root.crt"
        make_ca_cert "$work/base" portal.edge.test track.edge.test pb.edge.test >/dev/null
        base_fp=$(install_portal_cert "$work/base")
    fi

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
    # The container health check: an edge facing the internet answers it only
    # from inside the container; proxy keeps it open for orchestrator probes.
    if [ "$mode" != proxy ]; then
        expect ip /edge-health 404
    else
        expect ip /edge-health 200
    fi
    expect other.edge.test /setup spa
    # Manual mode answers no ACME challenge, not even with the wizard.
    [ "$mode" != manual ] || expect ip /.well-known/acme-challenge/token 404

    # Phase 1b: the same fresh server, its public address known. In direct
    # mode the wizard is also served over HTTPS on that address, with plain
    # HTTP still serving the first steps; manual mode serves the address over
    # plain HTTP only; proxy mode ignores the address.
    write_installation true "" "" "" "$pub_ip"
    local rendered
    case $mode in
        direct)
            wait_for_config 'ip_site=true' "default_sni $pub_ip"
            wait_for_ip_certificate
            say "-- setup, no domains, HTTPS on the public address"
            expect pubip /setup spa
            expect pubip /api/setup/status portal
            expect pubip /api/me 404
            expect pubip /internal/settings 404
            scheme=http expect pubip /setup spa
            scheme=http expect pubip /api/setup/status portal
            ;;
        manual)
            wait_for_config 'ip_site=false' 'http:// {'
            say "-- setup, no domains, plain HTTP on the public address"
            rendered=$(docker exec "$edge" grep -c "$pub_ip" /run/atlas-edge/Caddyfile || true)
            check "manual mode gives the public address no site of its own" "$(yesno [ "$rendered" = 0 ])"
            scheme=http expect pubip /setup spa
            scheme=http expect pubip /api/setup/status portal
            rendered=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -k \
                --connect-to "$pub_ip:$https_port:127.0.0.1:$https_port" "https://$pub_ip:$https_port/" || true)
            check "no HTTPS on the public address ($rendered)" "$(yesno [ "$rendered" = 000 ])"
            ;;
        *)
            wait_for_config 'ip_site=false' 'http:// {'
            rendered=$(docker exec "$edge" grep -c "$pub_ip" /run/atlas-edge/Caddyfile || true)
            check "proxy mode ignores public_ips" "$(yesno [ "$rendered" = 0 ])"
            expect ip /setup spa
            ;;
    esac

    # Phase 2: the wizard verified the domains, setup still open. The names
    # already serve their roles, and their plain-HTTP side still answers the
    # reachability label -- no redirect, the portal does not follow one.
    [ "$mode" != manual ] || write_manifest "$base_fp" '"portal.edge.test","track.edge.test","pb.edge.test"' "$(iso_in 3600)"
    write_installation true portal.edge.test track.edge.test ""
    wait_for_config 'setup=true' 'track.edge.test'
    say "-- setup, domains verified"
    scheme=http expect portal.edge.test /.well-known/atlas-setup/label portal
    scheme=http expect track.edge.test /.well-known/atlas-setup/label portal
    expect ip /setup spa
    if [ "$mode" = manual ]; then
        # A portal domain with a certificate already carries the wizard's
        # owner step over HTTPS while setup is open.
        wait_for_config 'setup=true' "portal:$base_fp"
        expect portal.edge.test /api/setup/status portal
        expect portal.edge.test /setup spa
    fi

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
    [ "$mode" = proxy ] || expect track.edge.test /.well-known/atlas-setup/label 404
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

    if [ "$mode" = manual ]; then
        # Nothing in the edge obtains a certificate, and no challenge is
        # answered on plain HTTP of a known name.
        check "no issuance directive, ACME account, CA or attempt in the edge" "$(yesno no_issuance)"
        scheme=http expect track.edge.test /.well-known/acme-challenge/token 404
    fi

    local fp op_fp fake kept
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
    elif [ "$mode" = manual ]; then
        # Phase 3b: setup completed without domains. Manual mode has no
        # HTTPS on an address and never serves the portal over plain HTTP.
        write_installation false "" "" "" "$pub_ip"
        # The marker of this configuration is an absence: no host is left.
        for _ in $(seq 1 30); do
            [ "$(docker exec "$edge" grep -c 'portal.edge.test' /run/atlas-edge/Caddyfile 2>/dev/null || true)" = 0 ] && break
            sleep 1
        done
        say "-- setup completed without domains"
        body=$(docker exec "$edge" grep -c "$pub_ip" /run/atlas-edge/Caddyfile || true)
        check "no site on the address without a portal domain" "$(yesno [ "$body" = 0 ])"
        scheme=http expect pubip / 404
        scheme=http expect pubip /api/me 404
    fi

    if [ "$mode" != proxy ]; then
        # Phase 3c: a portal domain is declared. The address stops being a
        # site of its own and redirects to the portal domain.
        write_installation false portal.edge.test track.edge.test pb.edge.test "$pub_ip"
        wait_for_config 'ip_site=false' "redir https://portal.edge.test"
        say "-- portal domain declared"
        body=$(redirect_of "http://$pub_ip:$http_port/offers?x=1" --connect-to "$pub_ip:$http_port:127.0.0.1:$http_port")
        check "HTTP on the address redirects to the portal domain ($body)" "$([ "$body" = "308 https://portal.edge.test/offers?x=1" ] && echo yes || echo no)"
        body=$(docker exec "$edge" grep -c "https://$pub_ip" /run/atlas-edge/Caddyfile || true)
        check "no HTTPS site on the address once a portal domain is declared" "$([ "$body" = 0 ] && echo yes || echo no)"
        if [ "$mode" = manual ]; then
            body=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -k \
                --connect-to "$pub_ip:$https_port:127.0.0.1:$https_port" "https://$pub_ip:$https_port/" || true)
            check "no HTTPS on the public address with a portal domain ($body)" "$(yesno [ "$body" = 000 ])"
        fi
        expect portal.edge.test /api/me portal
        expect track.edge.test /c/abc gateway

        # Phase 3d: own certificates. The owner uploaded a wildcard in the
        # portal; the manifest names the declared hosts it covers, plus a
        # name the installation does not declare.
        say "-- own certificates"
        if [ "$mode" = manual ]; then
            make_ca_cert "$work/own" '*.edge.test' >/dev/null
        else
            make_cert "$work/own" '*.edge.test' >/dev/null
        fi
        fp=$(install_portal_cert "$work/own")
        write_manifest "$fp" '"track.edge.test","pb.edge.test","undeclared.edge.test"' "$(iso_in 40)"
        wait_for_config 'setup=false' "portal:$fp"
        check "tracking host presents the uploaded certificate" "$([ "$(served_fp track.edge.test)" = "$fp" ] && echo yes || echo no)"
        check "one wildcard serves two declared hosts" "$([ "$(served_fp pb.edge.test)" = "$fp" ] && echo yes || echo no)"
        # Caddy keeps a loaded certificate in one shared cache and presents
        # it for every name it covers, listed or not -- which is why the
        # portal asks for a confirmation when an upload covers the portal host.
        check "a covered host the manifest does not list is served the same certificate" "$([ "$(served_fp portal.edge.test)" = "$fp" ] && echo yes || echo no)"
        body=$(docker exec "$edge" grep -c undeclared.edge.test /run/atlas-edge/Caddyfile || true)
        check "a manifest host the installation does not declare gets no site" "$([ "$body" = 0 ] && echo yes || echo no)"
        body=$(own_fetch track.edge.test /c/abc)
        check "the uploaded certificate keeps the tracking routes" "$([[ $body == upstream=gateway* ]] && echo yes || echo no)"

        # The operator's files win over the portal and are reported to it.
        op_fp=$(make_cert "$work/tls/track.edge.test" track.edge.test)
        wait_for_config 'setup=false' "operator:"
        check "config/tls/ wins over the uploaded certificate" "$([ "$(served_fp track.edge.test)" = "$op_fp" ] && echo yes || echo no)"
        body=$(docker exec "$edge" jq -r '.hosts | join(",")' /var/lib/atlas/edge-status/tls-config.json 2>/dev/null || true)
        check "tls-config.json names the operator's host ($body)" "$([ "$body" = track.edge.test ] && echo yes || echo no)"
        rm -f "$work/tls/track.edge.test.crt" "$work/tls/track.edge.test.key"
        wait_for_config 'setup=false' "portal:$fp"
        for _ in $(seq 1 15); do
            [ "$(docker exec "$edge" jq -r '.hosts | length' /var/lib/atlas/edge-status/tls-config.json 2>/dev/null)" = 0 ] && break
            sleep 1
        done
        check "removed operator files return the host to the portal's certificate" "$([ "$(served_fp track.edge.test)" = "$fp" ] && echo yes || echo no)"

        # A manifest naming files that are not there is not applied.
        fake=$(printf 'c%.0s' $(seq 64))
        kept=$(docker logs "$edge" 2>&1 | grep -c 'keeping the previous one' || true)
        write_manifest "$fake" '"track.edge.test"' "$(iso_in 3600)"
        sleep 7
        body=$(docker logs "$edge" 2>&1 | grep -c 'keeping the previous one' || true)
        check "a manifest with a missing file is logged and not applied" "$([ "$body" -gt "$kept" ] && [ "$(served_fp track.edge.test)" = "$fp" ] && echo yes || echo no)"

        # serve_until passes with nothing rewritten: the edge withdraws the
        # certificate on its own. Direct mode falls back to a certificate of
        # its own; manual mode has none, and the handshake fails from then on.
        write_manifest "$fp" '"track.edge.test","pb.edge.test"' "$(iso_in 12)"
        wait_for_config 'setup=false' "portal:$fp"
        body=no
        for _ in $(seq 1 40); do
            if [ "$mode" = direct ]; then
                if [ "$(served_fp track.edge.test)" != "$fp" ] && [ "$(handshake track.edge.test)" = 200 ]; then
                    body=yes
                    break
                fi
            elif [ "$(handshake track.edge.test)" = 000 ] && [ "$(handshake pb.edge.test)" = 000 ]; then
                body=yes
                break
            fi
            sleep 1
        done
        if [ "$mode" = direct ]; then
            check "at serve_until the host returns to the edge's own certificate" "$body"
        else
            check "at serve_until the certificate is dropped and the handshake fails" "$body"
            body=$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' -H 'Host: track.edge.test' "http://127.0.0.1:$http_port/c/abc?x=1")
            check "HTTP of a host without a certificate still redirects ($body)" "$(yesno [ "$body" = "308 https://track.edge.test/c/abc?x=1" ])"
            check "still nothing obtained after the certificate expired" "$(yesno no_issuance)"
        fi
        rm -f "$work/edge-certs/manifest.json"

        if [ "$mode" = manual ]; then
            # A certificate for the portal host only: the other hosts have no
            # certificate and fail the handshake, the portal host is served.
            say "-- manual: one host without a certificate"
            make_ca_cert "$work/portal-only" portal.edge.test >/dev/null
            fp=$(install_portal_cert "$work/portal-only")
            write_manifest "$fp" '"portal.edge.test"' "$(iso_in 3600)"
            wait_for_config 'setup=false' "portal:$fp"
            check "the host with a certificate is served" "$(yesno [ "$(served_fp portal.edge.test)" = "$fp" ])"
            expect portal.edge.test /api/me portal
            body=$(handshake pb.edge.test)
            check "a host without a certificate fails the TLS handshake ($body)" "$(yesno [ "$body" = 000 ])"
            body=$(docker exec "$edge" grep -c '^pb.edge.test {' /run/atlas-edge/Caddyfile || true)
            check "the host without a certificate is still declared as a site" "$(yesno [ "$body" = 1 ])"
            # The operator's file serves a host the portal has no certificate for.
            op_fp=$(make_ca_cert "$work/tls/pb.edge.test" pb.edge.test)
            rm -f "$work/tls/pb.edge.test.csr" "$work/tls/pb.edge.test.ext"
            wait_for_config 'setup=false' "operator:"
            check "an operator certificate is served in manual mode" "$(yesno [ "$(served_fp pb.edge.test)" = "$op_fp" ])"
            expect pb.edge.test '/postback?token=secret' gateway
            rm -f "$work/tls/"*

            # Back to the certificate for all three hosts for the checks below.
            write_manifest "$base_fp" '"portal.edge.test","track.edge.test","pb.edge.test"' "$(iso_in 3600)"
            wait_for_config 'setup=false' "portal:$base_fp"
            for _ in $(seq 1 15); do
                [ "$(handshake pb.edge.test)" = 200 ] && break
                sleep 1
            done
        fi
    fi

    # Postback query strings never reach the access log.
    local logged
    logged=$(docker logs "$edge" 2>&1 | grep -c 'token=secret' || true)
    check "postback token absent from the edge log" "$([ "$logged" = 0 ] && echo yes || echo no)"

    local body
    if [ "$mode" != proxy ]; then
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

    if [ "$mode" = manual ]; then
        say "-- manual: isolation from certificate authorities"
        # An ACME directory in manual mode is a configuration error.
        write_installation false portal.edge.test track.edge.test pb.edge.test "$pub_ip"
        body=$(docker run --rm --entrypoint atlas-edge-render -e ATLAS_EDGE_MODE=manual \
            -e ATLAS_EDGE_ACME_CA=internal -v "$work/installation:/var/lib/atlas/installation:ro" \
            "$image" 2>&1 >/dev/null || true)
        check "ATLAS_EDGE_ACME_CA is refused in manual mode" "$([[ $body == *"must be empty in manual mode"* ]] && echo yes || echo no)"
        # The edge starts and serves on a container without any network: it
        # needs nobody outside to come up.
        write_manifest "$base_fp" '"portal.edge.test","track.edge.test","pb.edge.test"' "$(iso_in 3600)"
        docker rm -f "$run_id-offline" >/dev/null 2>&1 || true
        docker run -d --name "$run_id-offline" --network none -e ATLAS_EDGE_MODE=manual \
            -v "$work/installation:/var/lib/atlas/installation:ro" \
            -v "$work/edge-certs:/var/lib/atlas/edge-certs:ro" \
            -v "$work/tls:/etc/atlas/tls:ro" \
            "$image" >/dev/null
        body=no
        for _ in $(seq 1 30); do
            if docker exec "$run_id-offline" wget -qO- http://127.0.0.1:80/edge-health >/dev/null 2>&1; then
                body=yes
                break
            fi
            sleep 1
        done
        check "the edge comes up without any network" "$body"
        body=$(docker logs "$run_id-offline" 2>&1 | grep -Eci 'obtain|acme_client|issuing|solving challenge' || true)
        check "no certificate attempt without a network" "$(yesno [ "$body" = 0 ])"
        docker stop -t 20 "$run_id-offline" >/dev/null
        rm -f "$work/edge-certs/manifest.json"
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
        direct|manual|proxy) run_mode ;;
        *) say "unknown mode: $mode"; exit 2 ;;
    esac
done

say ""
if [ "$failures" -gt 0 ]; then
    say "edge route contract: $failures of $checks checks FAILED"
    exit 1
fi
say "edge route contract: all $checks checks passed"
