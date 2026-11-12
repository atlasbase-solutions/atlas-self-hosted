#!/bin/sh
#
# atlas-edge-render prints the edge Caddyfile for the current settings to
# stdout. It is run by the edge entrypoint at start and every time
# installation.json changes; it can also be run by hand inside the container to
# see what the edge would serve:
#
#   docker compose exec edge atlas-edge-render
#
# Inputs:
#   ATLAS_EDGE_MODE                direct (default), manual or proxy
#   ATLAS_INSTALLATION_FILE        the portal's projection, read-only here
#   ATLAS_PORTAL_HOST              wins over portal_domain from the file
#   ATLAS_TRACKING_HOST            wins over tracking_domains (comma/space list)
#   ATLAS_POSTBACK_HOST            wins over postback_domain
#   ATLAS_EDGE_TRUSTED_PROXY_CIDR  proxy mode: the balancer allowed to report
#                                  the client address and scheme
#   ATLAS_EDGE_ACME_CA             test stands only: "internal" (Caddy's own CA)
#                                  or the directory URL of another ACME CA;
#                                  refused in manual mode
#   ATLAS_EDGE_CERTS_DIR           the portal's own-certificate volume:
#                                  manifest.json and <fingerprint>.crt|.key,
#                                  read-only here (default /var/lib/atlas/edge-certs)
#   ATLAS_EDGE_OPERATOR_TLS_DIR    certificates set by the operator, mounted
#                                  from config/tls/ (default /etc/atlas/tls)
#
# Own certificates (direct and manual modes). A declared host is served with:
#   1. config/tls/<host>.crt and <host>.key when both files exist -- the
#      server configuration wins over the portal;
#   2. otherwise the certificate the network owner uploaded in the portal, when
#      the manifest lists the host and its serve_until has not passed yet --
#      the portal sets serve_until a day before expiry in direct mode and at
#      expiry in manual mode; the edge only honours it;
#   3. otherwise, in direct mode, a certificate the edge obtains itself; in
#      manual mode no certificate at all: HTTPS on that host fails the
#      handshake, plain HTTP still redirects to it.
# A manifest that is not schema 1, names a file that is not there, or lists a
# host twice is refused as a whole, never applied in part.
#
# manual mode: TLS is terminated here, but nothing obtains or renews a
# certificate -- no ACME, no Caddy's own CA, no OCSP requests. Only the
# certificates above are served; the server's own addresses are plain HTTP.
#
# public_ips from installation.json (direct mode): while no portal domain is
# declared, the server is also served over HTTPS on these addresses, with a
# short-lived Let's Encrypt certificate for the IP itself and Caddy's own CA as
# the fallback when that certificate cannot be issued. Once a portal domain is
# declared, plain HTTP on these addresses redirects to it.
#
# Any problem is reported on stderr with exit code 1 and nothing on stdout, so
# the caller keeps the configuration it already serves.

set -eu

mode=${ATLAS_EDGE_MODE:-direct}
file=${ATLAS_INSTALLATION_FILE:-/var/lib/atlas/installation/installation.json}
trusted=${ATLAS_EDGE_TRUSTED_PROXY_CIDR:-127.0.0.1/32}
acme_ca=${ATLAS_EDGE_ACME_CA:-}

fail() {
    printf 'atlas-edge-render: %s\n' "$*" >&2
    exit 1
}

case $mode in
    direct|manual|proxy) ;;
    *) fail "ATLAS_EDGE_MODE must be direct, manual or proxy, got '$mode'" ;;
esac
# tls is "edge" when this edge terminates TLS itself (direct and manual), and
# "balancer" when a proxy in front does.
tls=edge
[ "$mode" != proxy ] || tls=balancer
# manual mode promises that no certificate authority is ever asked: an ACME
# directory there is a contradiction, not a setting to ignore.
if [ "$mode" = manual ] && [ -n "$acme_ca" ]; then
    fail "ATLAS_EDGE_ACME_CA must be empty in manual mode: the edge obtains no certificates"
fi

# --- Hosts: environment first, then the portal's projection ------------------

setup_open=false
f_portal=
f_tracking=
f_postback=
acme_email=
f_ips=
if [ -f "$file" ]; then
    # The projection has a versioned format; a file of another version is not
    # read by guesswork.
    jq -e '.schema == 1' "$file" >/dev/null 2>&1 || fail "$file is unreadable or not schema 1"
    setup_open=$(jq -r 'if .setup_open == true then "true" else "false" end' "$file") || fail "cannot read setup_open from $file"
    f_portal=$(jq -r '.portal_domain // ""' "$file") || fail "cannot read portal_domain from $file"
    f_tracking=$(jq -r '(.tracking_domains // []) | join(" ")' "$file") || fail "cannot read tracking_domains from $file"
    f_postback=$(jq -r '.postback_domain // ""' "$file") || fail "cannot read postback_domain from $file"
    acme_email=$(jq -r '.acme_email // ""' "$file") || fail "cannot read acme_email from $file"
    f_ips=$(jq -r '(.public_ips // []) | join(" ")' "$file") || fail "cannot read public_ips from $file"
fi

lower() { printf '%s' "$1" | tr 'A-Z,' 'a-z '; }
portal=$(lower "${ATLAS_PORTAL_HOST:-$f_portal}")
tracking=$(lower "${ATLAS_TRACKING_HOST:-$f_tracking}")
postback=$(lower "${ATLAS_POSTBACK_HOST:-$f_postback}")
portal=$(printf '%s' "$portal" | tr -d ' ')
postback=$(printf '%s' "$postback" | tr -d ' ')

# A host goes into the configuration verbatim, so only a plain DNS name is
# accepted: anything else could change the meaning of the Caddyfile.
check_host() {
    case $1 in
        ''|.*|-*|*.|*..*|*[!a-z0-9.-]*) fail "'$1' is not a DNS host name" ;;
    esac
    case $1 in
        *[a-z]*) ;;
        *) fail "'$1' looks like an IP address; the edge serves DNS names only" ;;
    esac
}
all=
for h in $portal $tracking $postback; do
    check_host "$h"
    case " $all " in
        *" $h "*) fail "$h is declared for two roles; every role needs its own name" ;;
    esac
    all="$all $h"
done

# An address goes into the configuration verbatim as well: only digits, dots,
# hex digits and colons. The portal writes canonical public addresses; this
# check only keeps a hand-edited file from changing the Caddyfile's meaning.
ips=$(lower "$f_ips")
for ip in $ips; do
    case $ip in
        *[!0-9a-f.:]*|'') fail "'$ip' in public_ips is not an IP address" ;;
    esac
    case $ip in
        *:*) ;;
        *.*.*.*) ;;
        *) fail "'$ip' in public_ips is not an IP address" ;;
    esac
done

# --- Own certificates ---------------------------------------------------------

certs_dir=${ATLAS_EDGE_CERTS_DIR:-/var/lib/atlas/edge-certs}
operator_dir=${ATLAS_EDGE_OPERATOR_TLS_DIR:-/etc/atlas/tls}
# Both directories go into the configuration verbatim.
for d in "$certs_dir" "$operator_dir"; do
    case $d in
        /*) ;;
        *) fail "'$d' is not an absolute directory" ;;
    esac
    case $d in
        *[!A-Za-z0-9/._-]*) fail "'$d' contains characters a Caddyfile path cannot hold" ;;
    esac
done

# own lists "<host> <certificate file> <key file>", one host per line.
own=
own_has() {
    printf '%s' "$own" | awk -v h="$1" '$1 == h { found = 1 } END { exit !found }'
}
# A balancer in front holds its own certificates; this edge reads none.
if [ "$tls" = edge ]; then
    for h in $all; do
        if [ -f "$operator_dir/$h.crt" ] && [ -f "$operator_dir/$h.key" ]; then
            # The files keep their names when the operator renews them, so
            # their hash goes into the configuration: new contents are a new
            # configuration, and the edge reloads it.
            sum=$(cat "$operator_dir/$h.crt" "$operator_dir/$h.key" | sha256sum | cut -c1-16)
            own="$own$h $operator_dir/$h.crt $operator_dir/$h.key operator:$sum
"
        fi
    done
    manifest=$certs_dir/manifest.json
    if [ -e "$manifest" ]; then
        jq -e '.schema == 1 and (.certificates | type == "array")' "$manifest" >/dev/null 2>&1 \
            || fail "$manifest is unreadable or not schema 1"
        # Fractions of a second are cut: fromdateiso8601 does not read them.
        entries=$(jq -r '.certificates[]
            | select((.serve_until | sub("\\.[0-9]+"; "") | fromdateiso8601) > now)
            | [.fingerprint, .cert_file, .key_file, (.hosts | join(" "))] | @tsv' "$manifest") \
            || fail "cannot read certificates from $manifest"
        tab=$(printf '\t')
        listed=" "
        while IFS="$tab" read -r fp crt key hosts; do
            [ -n "$fp" ] || continue
            printf '%s' "$fp" | grep -Eq '^[0-9a-f]{64}$' || fail "'$fp' in $manifest is not a certificate fingerprint"
            [ "$crt" = "$fp.crt" ] && [ "$key" = "$fp.key" ] || fail "files of $fp in $manifest are not named after its fingerprint"
            [ -r "$certs_dir/$crt" ] && [ -r "$certs_dir/$key" ] || fail "files of $fp are missing in $certs_dir"
            for h in $hosts; do
                case $h in
                    ''|.*|-*|*.|*..*|*[!a-z0-9.-]*) fail "'$h' in $manifest is not a DNS host name" ;;
                esac
                case $listed in
                    *" $h "*) fail "$h is listed by two certificates in $manifest" ;;
                esac
                listed="$listed$h "
                # Only declared hosts have sites; another name is not served.
                case " $all " in
                    *" $h "*) ;;
                    *) continue ;;
                esac
                # The operator's files win over the portal.
                own_has "$h" && continue
                own="$own$h $certs_dir/$crt $certs_dir/$key portal:$fp
"
            done
        done <<EOF_ENTRIES
$entries
EOF_ENTRIES
    fi
fi

# own_tls prints the tls directive of a host that has its own certificate.
own_tls() {
    printf '%s' "$own" | awk -v h="$1" '$1 == h { printf "\t# own certificate, %s\n\ttls %s %s\n", $4, $2, $3 }'
}

# site_addr prints an address as a Caddyfile host: IPv6 goes in brackets.
site_addr() {
    case $1 in
        *:*) printf '[%s]' "$1" ;;
        *) printf '%s' "$1" ;;
    esac
}

# The wizard is served while the portal says setup is open, and also while the
# edge knows neither a host nor an address of its own: a fresh server has
# nothing else to show. With its addresses known, a setup finished without
# domains leaves the portal on HTTPS at those addresses instead.
setup=false
if [ "$setup_open" = true ] || [ -z "$portal$tracking$postback$ips" ]; then
    setup=true
fi

# manual mode asks no certificate authority, so an ACME account email has no
# use there and is not written into the configuration.
[ "$mode" != manual ] || acme_email=
if [ -n "$acme_email" ]; then
    printf '%s' "$acme_email" | grep -Eq '^[^][:space:]{}"\\@]+@[^][:space:]{}"\\@]+$' \
        || fail "acme_email in $file is not a plain email address"
fi
case $acme_ca in
    ''|internal) ;;
    https://*)
        printf '%s' "$acme_ca" | grep -Eq '^https://[^][:space:]{}"\\]+$' || fail "ATLAS_EDGE_ACME_CA is not a URL"
        ;;
    *) fail "ATLAS_EDGE_ACME_CA must be empty, 'internal' or an https:// directory URL" ;;
esac
# HTTPS on the server's own address: direct mode, addresses known, no portal
# domain yet. With a portal domain the addresses only redirect to it, and the
# IP certificate is no longer renewed. Never in manual mode: a certificate for
# an address can be neither uploaded (an own certificate names DNS names) nor
# issued (nothing issues), so the address stays plain HTTP.
ip_site=false
if [ "$mode" = direct ] && [ -z "$portal" ] && [ -n "$ips" ]; then
    ip_site=true
fi

if [ "$mode" = proxy ]; then
    printf '%s' "$trusted" | grep -Eq '^[0-9A-Fa-f.:]+/[0-9]{1,3}$' \
        || fail "ATLAS_EDGE_TRUSTED_PROXY_CIDR must be one network such as 10.0.5.0/24"
fi

# --- Caddyfile ---------------------------------------------------------------

site_list() {
    # "http://" prefix for every host, comma-separated, for one site block.
    prefix=$1
    shift
    out=
    for h in "$@"; do
        out="${out:+$out, }$prefix$h"
    done
    printf '%s' "$out"
}

printf '# Generated by atlas-edge-render: mode=%s setup=%s ip_site=%s. Do not edit; the\n' "$mode" "$setup" "$ip_site"
printf '# edge regenerates it from installation.json and its environment.\n'
printf '{\n'
printf '\tadmin localhost:2019\n'
printf '\tpersist_config off\n'
printf '\thttp_port 80\n'
printf '\thttps_port 443\n'
# Global TLS options follow the mode: direct obtains certificates itself,
# manual only serves the ones it is given, proxy leaves TLS to the balancer.
if [ "$mode" = direct ]; then
    # Redirects are written explicitly below: during setup the wizard's
    # reachability check must get an answer over plain HTTP, not a redirect.
    printf '\tauto_https disable_redirects\n'
    # The TLS log goes twice: to the container log for the operator, and to a
    # file that atlas-edge-acme-status turns into acme.json for the portal.
    # A named logger takes its namespaces out of the default one, hence both.
    printf '\tlog tls_console {\n\t\toutput stderr\n\t\tformat json\n\t\tinclude tls\n\t}\n'
    printf '\tlog tls_status {\n\t\toutput file /run/atlas-edge/tls.log {\n\t\t\troll_size 1MiB\n\t\t\troll_keep 1\n\t\t}\n\t\tformat json\n\t\tinclude tls\n\t}\n'
    [ -z "$acme_email" ] || printf '\temail %s\n' "$acme_email"
    case $acme_ca in
        internal) printf '\tlocal_certs\n\tskip_install_trust\n' ;;
        '') ;;
        *) printf '\tacme_ca %s\n' "$acme_ca" ;;
    esac
    # A browser that opens https://<IP> sends no SNI, and behind Docker's port
    # mapping the edge does not see the public address either: the name of
    # the certificate to present has to be given.
    if [ "$ip_site" = true ]; then
        set -- $ips
        printf '\tdefault_sni %s\n' "$1"
    fi
elif [ "$mode" = manual ]; then
    # No certificate management at all: no ACME, no Caddy's own CA, and no
    # automatic HTTP->HTTPS redirects (they are written explicitly below).
    # Sites with a DNS name are still HTTPS sites -- auto_https off does not
    # turn them into HTTP -- so a site without a tls directive has no
    # certificate and its handshake fails; Caddy 2.11 keeps :443 a TLS
    # listener even when no site has a certificate at all (plain HTTP sent to
    # it gets a 400). OCSP stapling is off as well: it would make the edge
    # contact the certificate authority's responder.
    printf '\tauto_https off\n'
    printf '\tocsp_stapling off\n'
else
    printf '\tauto_https off\n'
    # Only the named balancer may report the client address and scheme; the
    # rightmost untrusted address is the client, as in the services.
    printf '\tservers {\n\t\ttrusted_proxies static %s\n\t\ttrusted_proxies_strict\n\t}\n' "$trusted"
fi
printf '}\n\n'

cat <<'EOF'
# Access log. Postback URLs carry the receiver's token in the query string, so
# their lines are written without it; every other route keeps the full line.
(common) {
	log {
		format filter {
			fields {
				request>uri regexp `^(/postback[^?]*)[?].*$` `${1}`
			}
			wrap json
		}
	}
	header -Server
}

# Upstreams. X-Forwarded-For and X-Forwarded-Proto are set by Caddy itself:
# without trusted proxies it replaces whatever the client sent with what it
# observed; X-Real-IP is set here for the same reason.
(to_portal) {
	reverse_proxy portal:11082 {
		header_up X-Real-IP {client_ip}
		transport http {
			response_header_timeout 60s
		}
	}
}

(to_gateway) {
	reverse_proxy gateway:8080 {
		header_up X-Real-IP {client_ip}
		transport http {
			response_header_timeout 15s
		}
	}
}

# Reachability label of the first-run wizard and of the portal's domain
# settings: the portal checks that a name leads to this installation by
# fetching it over plain HTTP. Unknown labels are 404 in the portal itself.
(setup_label) {
	handle /.well-known/atlas-setup/* {
		import to_portal
	}
}

# Portal host: the Application API, health and version, and the SPA.
(portal_routes) {
	@portal_api path_regexp portal_api ^/(api|internal|health|version)(/|$)
	handle @portal_api {
		import to_portal
	}
	handle {
		root * /srv/spa
		try_files {path} /index.html
		file_server
	}
}

# Tracking host: intake only. Anything not listed answers 404 here and never
# reaches the tracking service; its metrics live on an internal listener.
(tracking_routes) {
	@intake path_regexp intake ^/(c/|lp$|impression$|impression[.]gif$|_atlas/refusal-preview$)
	handle @intake {
		import to_gateway
	}
	handle /postback* {
		import to_gateway
	}
	@gateway_health path_regexp gateway_health ^/(health(/|$)|version$|healthz$|readyz$)
	handle @gateway_health {
		import to_gateway
	}
	handle {
		respond 404
	}
}

# Separate postback host: conversion postbacks, health and version.
(postback_routes) {
	handle /postback* {
		import to_gateway
	}
	@gateway_health path_regexp gateway_health ^/(health(/|$)|version$|healthz$|readyz$)
	handle @gateway_health {
		import to_gateway
	}
	handle {
		respond 404
	}
}

EOF

# Site blocks for the known hosts. In direct mode the name gets a certificate
# and HTTPS; plain HTTP only redirects (the ACME HTTP-01 challenge is answered
# by Caddy before any route). In manual mode the same HTTPS site carries the
# own certificate when there is one, and has none otherwise. In proxy mode the
# balancer terminates TLS and the routes are served over HTTP.
emit_site() {
    role=$1
    host=$2
    # Whoever terminates TLS decides between an HTTPS site and a plain one.
    if [ "$tls" = edge ]; then
        printf '%s {\n\timport common\n' "$host"
        own_tls "$host"
        # The portal lives on HTTPS only; HSTS removes the first plain request
        # that could carry the session cookie.
        [ "$role" != portal ] || printf '\theader Strict-Transport-Security "max-age=31536000"\n'
    else
        printf 'http://%s {\n\timport common\n\timport setup_label\n' "$host"
    fi
    printf '\timport %s_routes\n}\n\n' "$role"
}

[ -z "$portal" ] || emit_site portal "$portal"
for h in $tracking; do
    emit_site tracking "$h"
done
[ -z "$postback" ] || emit_site postback "$postback"

# Plain HTTP of the known names redirects to HTTPS -- in manual mode too, with
# or without a certificate, so that HTTP behaves the same whatever the state of
# the certificate. Nothing answers ACME challenges there in manual mode.
if [ "$tls" = edge ] && [ -n "$all" ]; then
    # shellcheck disable=SC2086
    printf '%s {\n\timport common\n\timport setup_label\n' "$(site_list http:// $all)"
    [ "$mode" != manual ] || printf '\thandle /.well-known/acme-challenge/* {\n\t\trespond 404\n\t}\n'
    printf '\thandle {\n\t\tredir https://{host}{uri} 308\n\t}\n}\n\n'
fi

# HTTPS on the server's own address while no portal domain is declared. Let's
# Encrypt issues IP certificates only under its short-lived profile; if that
# fails -- ports closed at the provider, the CA unreachable -- the next issuer,
# Caddy's own CA, still gives the wizard and the portal an encrypted
# connection, at the price of a browser warning that the wizard explains.
# During setup it is the wizard; afterwards the portal host.
if [ "$ip_site" = true ]; then
    list=
    for ip in $ips; do
        list="${list:+$list, }https://$(site_addr "$ip")"
    done
    printf '%s {\n\timport common\n\ttls {\n' "$list"
    case $acme_ca in
        internal)
            printf '\t\tissuer internal\n'
            ;;
        *)
            printf '\t\tissuer acme%s {\n' "${acme_ca:+ $acme_ca}"
            [ -z "$acme_email" ] || printf '\t\t\temail %s\n' "$acme_email"
            printf '\t\t\tprofile shortlived\n\t\t}\n\t\tissuer internal\n'
            ;;
    esac
    printf '\t}\n'
    if [ "$setup" = true ]; then
        printf '\thandle /api/setup/* {\n\t\timport to_portal\n\t}\n'
        printf '\t@not_published path /api/* /internal/*\n\thandle @not_published {\n\t\trespond 404\n\t}\n'
        printf '\thandle {\n\t\troot * /srv/spa\n\t\ttry_files {path} /index.html\n\t\tfile_server\n\t}\n'
    else
        printf '\timport portal_routes\n'
    fi
    printf '}\n\n'
fi

# Plain HTTP on the server's own address once setup is over: the portal lives
# on HTTPS only. Without a portal domain that is HTTPS on the same address;
# with one, the portal domain. During setup plain HTTP stays the wizard below:
# its first steps run before any certificate exists. In manual mode only the
# redirect to the portal domain exists: the address has no HTTPS of its own,
# and without a portal domain it falls to the catch-all below (404).
if [ "$setup" = false ] && [ -n "$ips" ] && { [ "$mode" = direct ] || { [ "$mode" = manual ] && [ -n "$portal" ]; }; }; then
    for ip in $ips; do
        if [ -n "$portal" ]; then
            target="https://$portal"
        else
            target="https://$(site_addr "$ip")"
        fi
        printf 'http://%s {\n\timport common\n\thandle {\n\t\tredir %s{uri} 308\n\t}\n}\n\n' "$(site_addr "$ip")" "$target"
    done
fi

# HTTPS for a name this edge does not serve. Without a certificate for it the
# handshake fails anyway; this block answers the one remaining case, a known
# name in SNI with a different Host header, which Caddy would otherwise answer
# with an empty 200. Needed whenever this edge terminates TLS.
if [ "$tls" = edge ]; then
    printf 'https:// {\n\timport common\n\trespond 404\n}\n\n'
fi

# Everything else on plain HTTP: IP addresses and unknown names. During setup
# it is the wizard; afterwards only the reachability label, the rest is 404.
printf 'http:// {\n\timport common\n'
# Without a balancer the health check is internal; behind one the
# orchestrator probes it from outside.
if [ "$tls" = edge ]; then
    # The container health check asks from inside; nobody else needs it.
    printf '\t@edge_health {\n\t\tpath /edge-health\n\t\tremote_ip 127.0.0.1/8 ::1\n\t}\n'
else
    printf '\t@edge_health path /edge-health\n'
fi
printf '\thandle @edge_health {\n\t\trespond "ok" 200\n\t}\n'
# manual mode answers no ACME challenge, on any name: a clean 404 instead of
# the wizard's index.html.
[ "$mode" != manual ] || printf '\thandle /.well-known/acme-challenge/* {\n\t\trespond 404\n\t}\n'
if [ "$setup" = true ]; then
    printf '\timport setup_label\n'
    printf '\thandle /api/setup/* {\n\t\timport to_portal\n\t}\n'
    # The rest of the API is not published before setup: the wizard's SPA
    # must get a clean 404 there, not index.html.
    printf '\t@not_published path /api/* /internal/* /edge-health\n\thandle @not_published {\n\t\trespond 404\n\t}\n'
    printf '\thandle {\n\t\troot * /srv/spa\n\t\ttry_files {path} /index.html\n\t\tfile_server\n\t}\n'
else
    # Names the owner is adding in the portal settings are not sites yet:
    # their reachability label is answered here, everything else is 404.
    printf '\timport setup_label\n'
    printf '\thandle {\n\t\trespond 404\n\t}\n'
fi
printf '}\n'
