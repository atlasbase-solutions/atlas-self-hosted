#!/bin/sh
set -eu

# Atlas Self-Hosted installation for a clean Debian or Ubuntu x86-64 server.
#
# The installer asks no questions and never reads the terminal, so the same
# command works in an SSH session, in cloud-init user data and in a provider's
# first-boot script:
#
#   curl -fsSL https://raw.githubusercontent.com/atlasbase-solutions/atlas-self-hosted/main/scripts/install.sh | sudo sh
#
# It installs Docker when missing, downloads and verifies the distribution,
# generates the internal secrets, starts the stack and registers a one-time
# setup code. The network, domains, owner account and license are then entered
# in the browser, in the first-run wizard, at the link it saves to
# /root/atlas-setup.txt.
#
# Optional settings (environment variables):
#   ATLAS_INSTALL_DIR      installation directory, default /opt/atlas
#   ATLAS_REPOSITORY       HTTPS mirror of the distribution repository
#   ATLAS_SOURCE_DIR       an already downloaded distribution directory (hosts
#                          without GitHub access); verified the same way
#   ATLAS_EDGE_MODE        direct (default: ports 80/443, certificates issued by
#                          Atlas) or proxy (plain HTTP behind your TLS proxy)
#   ATLAS_HTTP_PORT        edge HTTP port in proxy mode, default 8080
#   ATLAS_SETUP_CODE       setup code generated outside (a provider template)
#   ATLAS_PUBLIC_IPS       public addresses of this server, comma-separated;
#                          detected from the network interfaces when unset
# Configuration wins over the wizard (for automation):
#   ATLAS_PORTAL_DOMAIN + ATLAS_TRACKING_DOMAIN   domains set by configuration;
#                          the wizard shows them read-only
#   ATLAS_OWNER_EMAIL + ATLAS_OWNER_PASSWORD      the first Network Owner is
#                          created at startup and there is no wizard

atlas_repository=${ATLAS_REPOSITORY:-https://github.com/atlasbase-solutions/atlas-self-hosted}
install_dir=${ATLAS_INSTALL_DIR:-/opt/atlas}
source_override=${ATLAS_SOURCE_DIR:-}
edge_mode=${ATLAS_EDGE_MODE:-direct}
proxy_http_port=${ATLAS_HTTP_PORT:-8080}
setup_code=${ATLAS_SETUP_CODE:-}
public_ips=${ATLAS_PUBLIC_IPS:-}
portal_domain=$(printf '%s' "${ATLAS_PORTAL_DOMAIN:-}" | tr '[:upper:]' '[:lower:]')
tracking_domain=$(printf '%s' "${ATLAS_TRACKING_DOMAIN:-}" | tr '[:upper:]' '[:lower:]')
owner_email=${ATLAS_OWNER_EMAIL:-}
owner_password=${ATLAS_OWNER_PASSWORD:-}

setup_file=/root/atlas-setup.txt
motd_script=/etc/update-motd.d/99-atlas-setup
host_tool=/usr/local/bin/atlas-setup-code
sudo_cmd=
tmp_dir=
created_install_dir=0
started=0

# On failure before the stack started, remove the directory this run created,
# so that the next attempt is not refused as "already installed". Once the
# stack has been started the directory is kept: it holds data and logs.
cleanup() {
    status=$?
    # Remove only the temporary directory created by this process.
    if [ -n "$tmp_dir" ] && [ -d "$tmp_dir" ]; then
        rm -rf -- "$tmp_dir"
    fi
    # A partial installation that never started is not worth keeping.
    if [ "$status" -ne 0 ] && [ "$created_install_dir" -eq 1 ] && [ "$started" -eq 0 ]; then
        run_root rm -rf -- "$install_dir" 2>/dev/null || true
    fi
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

# Stop the installation with a clear operator-facing error.
fail() {
    printf 'Atlas installer: %s\n' "$*" >&2
    exit 1
}

# Print a warning that does not stop the installation.
warn() {
    printf 'Atlas installer: WARNING: %s\n' "$*" >&2
}

# Print the heading for the next installation stage.
info() {
    printf '\n==> %s\n' "$*"
}

# Run a command through sudo only for an unprivileged invocation.
run_root() {
    # Keep direct execution for root and use sudo for a regular user.
    if [ -n "$sudo_cmd" ]; then
        "$sudo_cmd" "$@"
    else
        "$@"
    fi
}

# Ensure the value is a DNS hostname rather than a URL or IP address.
valid_domain() {
    domain=$1
    # Schemes, paths, ports, underscores, and IP addresses are not valid here.
    printf '%s\n' "$domain" | grep -Eq '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$' || return 1
    [ "${#domain}" -le 253 ] || return 1
    printf '%s\n' "$domain" | grep -Eq '^[0-9.]+$' && return 1
    return 0
}

# Generate a cryptographically random hexadecimal secret.
random_hex() {
    openssl rand -hex "$1"
}

# Escape a value for safe substitution with sed.
escape_sed_replacement() {
    printf '%s' "$1" | sed 's/[&|\\]/\\&/g'
}

# Set KEY in an env file: replace the existing line, or append one.
set_value() {
    file=$1
    key=$2
    # Keys that the example does not carry yet are appended, not lost.
    if grep -q "^${key}=" "$file"; then
        value=$(escape_sed_replacement "$3")
        sed -i "s|^${key}=.*$|${key}=${value}|" "$file"
    else
        printf '%s=%s\n' "$key" "$3" >>"$file"
    fi
}

# Docker Compose for the installed stack.
compose() {
    run_root docker compose --env-file "$install_dir/env/compose.env" -f "$install_dir/docker-compose.yml" "$@"
}

# install_root_file puts content from stdin into a root-owned file with the given mode.
install_root_file() {
    mode=$1
    target=$2
    staged=$(mktemp)
    cat >"$staged"
    run_root install -m "$mode" "$staged" "$target"
    rm -f -- "$staged"
}

# is_public_ip tells a globally routable address from a private, shared or
# link-local one: only a public address belongs in a DNS record.
is_public_ip() {
    case $1 in
        10.*|127.*|169.254.*|192.168.*) return 1 ;;
        172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 1 ;;
        100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) return 1 ;;
        [Ff][CcDd]*|[Ff][Ee]80:*|::1) return 1 ;;
    esac
    return 0
}

# detect_public_ips lists the host's global addresses that are publicly
# routable. A server behind the provider's NAT has none on its interfaces.
detect_public_ips() {
    command -v ip >/dev/null 2>&1 || return 0
    ip -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | while read -r addr; do
        # Private and shared ranges are not what a DNS record should point to.
        if is_public_ip "$addr"; then
            printf '%s\n' "$addr"
        fi
    done | paste -sd, -
}

# first_global_ip is the fallback link host when no public address is known.
first_global_ip() {
    command -v ip >/dev/null 2>&1 || return 0
    ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n 1
}

# port_in_use reports whether a TCP port on this host already has a listener.
port_in_use() {
    command -v ss >/dev/null 2>&1 || return 1
    ss -Hltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)$1\$"
}

# check_resources warns, never refuses: a smaller server can run an evaluation.
# The figures are the README's minimum.
check_resources() {
    cpus=$(nproc 2>/dev/null || echo 0)
    mem_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
    probe=$install_dir
    while [ ! -d "$probe" ]; do probe=$(dirname "$probe"); done
    disk_kb=$(df -Pk "$probe" 2>/dev/null | awk 'NR==2 {print $4}')
    disk_kb=${disk_kb:-0}
    # 3.5 GB and 95 GB leave room for what the kernel and the filesystem keep.
    if [ "$cpus" -lt 2 ] || [ "$mem_kb" -lt 3500000 ] || [ "$disk_kb" -lt 95000000 ]; then
        warn "this server has ${cpus} vCPU, $((mem_kb / 1024 / 1024)) GB of memory and $((disk_kb / 1024 / 1024)) GB of free disk;"
        warn 'Atlas needs at least 2 vCPU, 4 GB and 100 GB. Continuing, but expect the stack to run short of resources.'
    fi
}

# normalize_code turns a setup code as typed (any case, dashes, spaces) into
# the 24-character form; the portal applies the same rule.
normalize_code() {
    printf '%s' "$1" | tr -d ' -' | tr '[:lower:]' '[:upper:]'
}

# Install the official Docker Engine or preserve a complete provider-managed installation.
install_docker() {
    # Do not change provider-managed packages when Engine and Compose are already available.
    if command -v docker >/dev/null 2>&1 && run_root docker compose version >/dev/null 2>&1; then
        info 'Using the existing Docker Engine and Docker Compose plugin'
        return
    fi

    [ "${ID:-}" = ubuntu ] || [ "${ID:-}" = debian ] || fail 'automatic Docker installation supports Debian and Ubuntu only'
    codename=${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}
    [ -n "$codename" ] || fail 'the operating-system codename is missing from /etc/os-release'

    info "Installing Docker Engine from Docker's official ${ID} repository"
    run_root env DEBIAN_FRONTEND=noninteractive apt-get update
    run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl openssl tar
    run_root install -m 0755 -d /etc/apt/keyrings
    run_root curl -fsSL "https://download.docker.com/linux/$ID/gpg" -o /etc/apt/keyrings/docker.asc
    run_root chmod a+r /etc/apt/keyrings/docker.asc

    printf '%s\n' \
        'Types: deb' \
        "URIs: https://download.docker.com/linux/$ID" \
        "Suites: $codename" \
        'Components: stable' \
        'Architectures: amd64' \
        'Signed-By: /etc/apt/keyrings/docker.asc' | install_root_file 0644 /etc/apt/sources.list.d/docker.sources

    run_root env DEBIAN_FRONTEND=noninteractive apt-get update
    run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    run_root systemctl enable --now docker
    run_root docker version >/dev/null
    run_root docker compose version >/dev/null
}

# --- 1. Checks -----------------------------------------------------------------

[ "$(uname -s)" = Linux ] || fail 'Linux is required'
[ "$(uname -m)" = x86_64 ] || fail 'this release supports x86-64 servers only'
[ -r /etc/os-release ] || fail '/etc/os-release is required'
# Require an unambiguous absolute installation path that is not the filesystem root.
case "$install_dir" in
    /) fail 'ATLAS_INSTALL_DIR cannot be the filesystem root' ;;
    /*) ;;
    *) fail 'ATLAS_INSTALL_DIR must be an absolute path' ;;
esac
# Allow the release archive to be fetched only from an HTTPS repository.
case "$atlas_repository" in
    https://*) ;;
    *) fail 'ATLAS_REPOSITORY must use HTTPS' ;;
esac
# The edge mode decides the published ports; anything else is a typo.
case "$edge_mode" in
    direct|proxy) ;;
    *) fail "ATLAS_EDGE_MODE must be direct or proxy, got '$edge_mode'" ;;
esac
# A proxy-mode port is a plain TCP port number.
case "$proxy_http_port" in
    ''|*[!0-9]*) fail 'ATLAS_HTTP_PORT must be a port number' ;;
esac
# Domains come in a pair: an installation needs both roles, or the wizard asks for both.
if [ -n "$portal_domain$tracking_domain" ]; then
    valid_domain "$portal_domain" || fail 'ATLAS_PORTAL_DOMAIN must be a DNS host name, for example portal.example.com'
    valid_domain "$tracking_domain" || fail 'ATLAS_TRACKING_DOMAIN must be a DNS host name, for example track.example.com'
    [ "$portal_domain" != "$tracking_domain" ] || fail 'the portal and tracking domains must be different'
fi
# The owner comes in a pair too; half of it would neither create an owner nor open the wizard.
if [ -n "$owner_email$owner_password" ]; then
    [ -n "$owner_email" ] && [ -n "$owner_password" ] || fail 'set both ATLAS_OWNER_EMAIL and ATLAS_OWNER_PASSWORD, or neither'
    printf '%s\n' "$owner_email" | grep -Eq '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' || fail 'ATLAS_OWNER_EMAIL is not an email address'
    [ "${#owner_password}" -ge 10 ] || fail 'ATLAS_OWNER_PASSWORD must be at least 10 characters'
    [ -z "$setup_code" ] || fail 'ATLAS_SETUP_CODE has no use when the owner is set by ATLAS_OWNER_EMAIL: there is no wizard'
    [ -n "$portal_domain" ] || fail 'ATLAS_OWNER_EMAIL needs ATLAS_PORTAL_DOMAIN and ATLAS_TRACKING_DOMAIN: without the wizard nothing else declares the domains'
fi
# A setup code from outside must have the shape the portal accepts.
if [ -n "$setup_code" ]; then
    setup_code=$(normalize_code "$setup_code")
    printf '%s\n' "$setup_code" | grep -Eq '^[0-9A-Z]{24}$' || fail 'ATLAS_SETUP_CODE must be 24 letters and digits (dashes and spaces are ignored)'
fi
# shellcheck disable=SC1091
. /etc/os-release

# Check privilege escalation before an unprivileged installation begins.
if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || fail 'run as root or install sudo'
    sudo_cmd=sudo
fi

# Never place a new installation over an existing directory.
if run_root test -e "$install_dir"; then
    fail "$install_dir already exists; the installer never overwrites an installation"
fi

check_resources

# In direct mode the edge needs the host's ports 80 and 443 for itself.
if [ "$edge_mode" = direct ]; then
    for port in 80 443; do
        # A listener already there would make the edge fail to start.
        if port_in_use "$port"; then
            fail "port $port is already in use on this server; stop that service, or install with ATLAS_EDGE_MODE=proxy behind it"
        fi
    done
elif port_in_use "$proxy_http_port"; then
    fail "port $proxy_http_port is already in use on this server; choose another with ATLAS_HTTP_PORT"
fi

printf '%s\n' 'Atlas Self-Hosted installation' "Directory: $install_dir; edge mode: $edge_mode"

# --- 2. Docker -----------------------------------------------------------------

install_docker

# The Compose project name is fixed by the distribution, so a second
# installation in another directory would take over the first one's containers
# and volumes -- "never overwrite an installation" covers that too.
if run_root docker ps -aq --filter label=com.docker.compose.project=atlas-self-hosted | grep -q . ||
    run_root docker volume ls -q --filter label=com.docker.compose.project=atlas-self-hosted | grep -q .; then
    fail 'an Atlas installation (Docker Compose project atlas-self-hosted) already exists on this server; the installer never overwrites an installation'
fi

# curl, OpenSSL and tar are also required on a minimal host with Docker already installed.
command -v curl >/dev/null 2>&1 || fail 'curl is required'
command -v openssl >/dev/null 2>&1 || fail 'openssl is required'
command -v tar >/dev/null 2>&1 || fail 'tar is required'

# --- 3. Download and verify ------------------------------------------------------

tmp_dir=$(mktemp -d)
# A local copy serves hosts without access to GitHub; it is verified like a download.
if [ -n "$source_override" ]; then
    [ -f "$source_override/docker-compose.yml" ] || fail "ATLAS_SOURCE_DIR ($source_override) is not an Atlas distribution"
    info "Using the distribution in $source_override"
    source_dir="$tmp_dir/atlas-self-hosted-local"
    mkdir -p "$source_dir"
    cp -a "$source_override/." "$source_dir/"
else
    archive_url="$atlas_repository/archive/refs/heads/main.tar.gz"
    archive_path="$tmp_dir/atlas.tar.gz"
    info 'Downloading Atlas Self-Hosted'
    curl -fL --proto '=https' --tlsv1.2 "$archive_url" -o "$archive_path"
    tar -xzf "$archive_path" -C "$tmp_dir"
    source_dir=$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d -name 'atlas-self-hosted-*' | head -n 1)
    [ -n "$source_dir" ] && [ -f "$source_dir/docker-compose.yml" ] || fail 'the release archive has an unexpected layout'
fi

info 'Verifying Atlas application artifacts'
# SHA256SUMS lives inside the archive, so on its own it proves only that the
# archive is intact -- not who built it. The release index carries the same
# sums signed with Atlas's release key, whose fingerprint is printed in the
# README and on the website, so this check answers a different question: did
# this distribution come from the vendor.
(cd "$source_dir" && sha256sum -c --quiet SHA256SUMS) || fail 'the distribution files do not match SHA256SUMS'
# The signature check needs the tool shipped with the distribution itself.
if [ -x "$source_dir/artifacts/linux-amd64/atlas-update-check" ]; then
    (cd "$source_dir" && ./artifacts/linux-amd64/atlas-update-check -verify .) ||
        fail 'the distribution is not signed by the Atlas release key: do not install it, and ask support for a fresh download link'
else
    fail 'atlas-update-check is missing from the distribution; cannot verify its signature'
fi

# --- 4-5. Secrets and configuration -----------------------------------------------

info 'Generating secrets and configuration'
portal_db_password=$(random_hex 24)
gateway_db_password=$(random_hex 24)
clickhouse_password=$(random_hex 24)
portal_secret=$(random_hex 32)
config_secret=$(random_hex 32)
[ -n "$public_ips" ] || public_ips=$(detect_public_ips)

"$source_dir/scripts/prepare-env.sh" >/dev/null
env_dir="$source_dir/env"
set_value "$env_dir/portal-postgres.env" POSTGRES_PASSWORD "$portal_db_password"
set_value "$env_dir/gateway-postgres.env" POSTGRES_PASSWORD "$gateway_db_password"
set_value "$env_dir/clickhouse.env" CLICKHOUSE_PASSWORD "$clickhouse_password"

set_value "$env_dir/portal.env" PORTAL_DATABASE_URL "postgres://atlas_portal:${portal_db_password}@portal-postgres:5432/atlas_portal?sslmode=disable"
set_value "$env_dir/portal.env" PORTAL_SECRET_KEY "$portal_secret"
set_value "$env_dir/portal.env" ATLAS_CONFIG_SECRET_KEY "$config_secret"
set_value "$env_dir/portal.env" PORTAL_CLICKHOUSE_URL "http://atlas_gateway:${clickhouse_password}@clickhouse:8123/atlas_gateway"
set_value "$env_dir/portal.env" ATLAS_PUBLIC_IPS "$public_ips"

set_value "$env_dir/gateway.env" PG_DSN "postgres://atlas_gateway:${gateway_db_password}@gateway-postgres:5432/atlas_gateway?sslmode=disable"
set_value "$env_dir/gateway.env" CLICKHOUSE_DSN "http://atlas_gateway:${clickhouse_password}@clickhouse:8123/atlas_gateway"
set_value "$env_dir/gateway.env" ATLAS_CONFIG_SECRET_KEY "$config_secret"

set_value "$env_dir/compose.env" ATLAS_EDGE_MODE "$edge_mode"
# Proxy mode: plain HTTP on the chosen port, and no HTTPS port taken from the host.
if [ "$edge_mode" = proxy ]; then
    set_value "$env_dir/compose.env" ATLAS_HTTP_PORT "$proxy_http_port"
    set_value "$env_dir/compose.env" ATLAS_HTTPS_BIND 127.0.0.1
    set_value "$env_dir/compose.env" ATLAS_HTTPS_PORT ''
fi

# Domains given by configuration win over the wizard (it shows them read-only).
if [ -n "$portal_domain" ]; then
    set_value "$env_dir/edge.env" ATLAS_PORTAL_HOST "$portal_domain"
    set_value "$env_dir/edge.env" ATLAS_TRACKING_HOST "$tracking_domain"
    for file in "$env_dir/portal.env" "$env_dir/gateway.env"; do
        set_value "$file" ATLAS_LICENSE_PORTAL_DOMAIN "$portal_domain"
        set_value "$file" ATLAS_LICENSE_TRACKING_DOMAIN "$tracking_domain"
    done
fi
# An owner given by configuration is created at startup; there is no wizard.
if [ -n "$owner_email" ]; then
    set_value "$env_dir/portal.env" PORTAL_OWNER_EMAIL "$owner_email"
    set_value "$env_dir/portal.env" PORTAL_OWNER_PASSWORD "$owner_password"
fi

"$source_dir/scripts/check-config.sh" >/dev/null

run_root install -d -m 0750 "$install_dir"
created_install_dir=1
run_root cp -a "$source_dir/." "$install_dir/"
# Restrict access to working env files because they contain generated secrets.
run_root chown -R root:root "$install_dir"
run_root chmod 0750 "$install_dir" "$install_dir/env"
run_root chmod 0600 "$install_dir"/env/*.env

# --- 6. Start ------------------------------------------------------------------

info 'Building images and starting Atlas (this takes a few minutes)'
started=1
compose up -d --build --wait ||
    fail "the stack did not become healthy; see: sudo docker compose --env-file $install_dir/env/compose.env -f $install_dir/docker-compose.yml logs"

http_port=80
[ "$edge_mode" = direct ] || http_port=$proxy_http_port

# --- 7. Setup code ---------------------------------------------------------------

display_code=
# Only an installation without a configured owner has a wizard to open.
if [ -z "$owner_email" ]; then
    info 'Registering the setup code'
    # A code from the provider is registered as is; otherwise the portal issues one.
    if [ -n "$setup_code" ]; then
        printf '%s' "$setup_code" | compose exec -T portal atlas-setup-code set >/dev/null 2>&1 ||
            fail 'the portal did not accept ATLAS_SETUP_CODE'
        display_code=$setup_code
    else
        display_code=$(compose exec -T portal atlas-setup-code 2>/dev/null | tr -d '\r' | tail -n 1)
        [ -n "$display_code" ] || fail 'the portal did not issue a setup code'
    fi
fi

# --- 8. Health from inside the host --------------------------------------------------

info 'Checking Atlas from inside this server'
compose exec -T edge wget -qO- http://127.0.0.1:80/edge-health >/dev/null || fail 'the edge does not answer its health check'
compose exec -T gateway wget -qO- http://127.0.0.1:8080/health/ready >/dev/null || fail 'the tracking service is not ready'
# While setup is open the edge serves the wizard on this server's own address:
# asking it proves the whole path edge -> portal, not just the containers.
if [ -z "$owner_email" ]; then
    status=$(curl -fsS -m 10 "http://127.0.0.1:$http_port/api/setup/status" || true)
    case $status in
        *'"setup_open":true'*) ;;
        *) fail "the first-run wizard does not answer on http://127.0.0.1:$http_port/ (got: ${status:-no answer})" ;;
    esac
else
    compose exec -T portal wget -qO- http://127.0.0.1:11082/health/ready >/dev/null || fail 'the portal is not ready'
fi

# --- 9. Result -----------------------------------------------------------------------

link_host=$(printf '%s' "$public_ips" | cut -d, -f1)
behind_nat=0
# Without a public address on the interfaces the link shows the private one.
if [ -z "$link_host" ]; then
    link_host=$(first_global_ip)
    behind_nat=1
fi
[ -n "$link_host" ] || link_host='SERVER-IP'
case $link_host in
    *:*) link_host="[$link_host]" ;;
esac
port_suffix=
[ "$http_port" = 80 ] || port_suffix=":$http_port"

# The host tool issues a new code later (a lost link, or a locked code) and
# rewrites the saved link; it lives outside the containers because the link
# needs this server's address, which the portal does not know.
install_root_file 0750 "$host_tool" <<EOF
#!/bin/sh
# Issues a new one-time setup code for the Atlas first-run wizard, replacing the
# previous one, and prints the wizard link. Written by the Atlas installer.
set -eu
code=\$(docker compose --env-file '$install_dir/env/compose.env' -f '$install_dir/docker-compose.yml' exec -T portal atlas-setup-code | tr -d '\\r' | tail -n 1)
[ -n "\$code" ] || exit 1
link="http://$link_host$port_suffix/setup#code=\$code"
umask 077
printf 'Atlas first-run wizard: %s\n' "\$link" >'$setup_file'
printf '%s\n' "\$link"
EOF

if [ -z "$owner_email" ]; then
    link="http://$link_host$port_suffix/setup#code=$display_code"
    printf 'Atlas first-run wizard: %s\n' "$link" | install_root_file 0600 "$setup_file"

    # The login message says that setup is waiting and where the link is, but
    # never carries the code itself: every account that logs in sees it.
    if [ -d /etc/update-motd.d ]; then
        install_root_file 0755 "$motd_script" <<EOF
#!/bin/sh
# Atlas: a reminder while the first-run wizard is not completed. Written by the
# Atlas installer; prints nothing once setup is complete.
curl -fsS -m 2 http://127.0.0.1:$http_port/api/setup/status 2>/dev/null | grep -q '"setup_open":true' || exit 0
printf '\nAtlas is waiting for its first-run wizard.\n  Link with the setup code: sudo cat $setup_file\n  New code (the old one stops working): sudo atlas-setup-code\n\n'
EOF
    fi

    printf '\nAtlas Self-Hosted is running and waiting for the first-run wizard.\n\n'
    # The link carries the code: print it to a person at a terminal, not into a
    # provider's boot log.
    if [ -t 1 ]; then
        printf 'Open in a browser:\n\n  %s\n\n' "$link"
    fi
    printf 'The link with the setup code is saved in %s (readable by root only).\nLost it, or the code is locked? Run: sudo atlas-setup-code\n' "$setup_file"
    # A server behind the provider's NAT only knows its private address.
    if [ "$behind_nat" -eq 1 ]; then
        printf 'No public address was found on this server: replace %s in the link with the address you connect to.\n' "$link_host"
    fi
    # What the network has to allow depends on who terminates TLS.
    if [ "$edge_mode" = direct ]; then
        printf 'Keep ports 80 and 443 open: the wizard checks your domains on port 80, and certificates are issued automatically.\n'
    else
        printf 'Proxy mode: point your TLS proxy at port %s of this server.\n' "$proxy_http_port"
    fi
else
    printf '\nAtlas Self-Hosted is running. The Network Owner %s signs in at https://%s\n' "$owner_email" "${portal_domain:-<portal domain>}"
fi
printf 'Configuration: %s/env/\nLogs: sudo docker compose --env-file %s/env/compose.env -f %s/docker-compose.yml logs -f\n' \
    "$install_dir" "$install_dir" "$install_dir"
