#!/usr/bin/env bash
# Matrix node installer/checker
# Synapse + PostgreSQL + Caddy + Coturn + LiveKit + lk-jwt-service
#
# Usage:
#   sudo bash ./matrix-node.sh install [--force] [--yes]
#   sudo bash ./matrix-node.sh check
#   sudo bash ./matrix-node.sh user USERNAME
#   sudo bash ./matrix-node.sh admin USERNAME
#   sudo bash ./matrix-node.sh backup
#   sudo bash ./matrix-node.sh restore [ARCHIVE]

set -Eeuo pipefail
umask 077

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
WORKDIR="$(dirname "$SCRIPT_PATH")"
STATE_DIR="${WORKDIR}/.matrix-node-state"
BACKUP_DIR="${WORKDIR}/.backups"
RUN_ID="$(date -u '+%Y%m%dT%H%M%SZ').$$"
RUN_DIR="${STATE_DIR}/runs/${RUN_ID}"
RUN_LOG="${RUN_DIR}/install.log"

FORCE=false
ASSUME_YES=false
SSH_PORT=""
DOMAIN="${DOMAIN:-}"
PUBLIC_IP="${PUBLIC_IP:-}"
SSH_PORT_CFG="${SSH_PORT_CFG:-}"
SKIP_DNS_CHECK="${SKIP_DNS_CHECK:-false}"
COTURN_SELF_SIGNED="${COTURN_SELF_SIGNED:-false}"
SWAP_SIZE_MB="${SWAP_SIZE_MB:-2048}"

# Pinned versions to avoid mutable latest
SYNAPSE_VERSION="${SYNAPSE_VERSION:-latest}"
POSTGRES_VERSION="${POSTGRES_VERSION:-16-alpine}"
COTURN_VERSION="${COTURN_VERSION:-4.6.3}"
LIVEKIT_VERSION="${LIVEKIT_VERSION:-latest}"
LK_JWT_VERSION="${LK_JWT_VERSION:-latest}"
CADDY_VERSION="${CADDY_VERSION:-2}"

if [[ -t 1 ]]; then
    C_INFO='\033[0;32m'
    C_WARN='\033[0;33m'
    C_ERROR='\033[0;31m'
    C_STEP='\033[0;34m'
    C_BOLD='\033[1m'
    C_RESET='\033[0m'
else
    C_INFO=''
    C_WARN=''
    C_ERROR=''
    C_STEP=''
    C_BOLD=''
    C_RESET=''
fi

log_line() {
    local color="$1" level="$2"
    shift 2
    printf '%b[%s] %-5s:%b %s\n' "$color" "$(date '+%H:%M:%S')" "$level" "$C_RESET" "$*"
}
log_info()  { log_line "$C_INFO" INFO "$@"; }
log_warn()  { log_line "$C_WARN" WARN "$@"; }
log_error() { log_line "$C_ERROR" ERROR "$@"; }
log_step()  { log_line "$C_STEP" STEP "$@"; }
die()       { log_error "$@"; exit 1; }

on_error() {
    local rc="$1" line="$2" command="$3"
    log_error "Command failed (exit=${rc}) at line ${line}: ${command}"
    return "$rc"
}
trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

confirm() {
    local prompt="${1:-Continue?}" reply
    if [[ "$ASSUME_YES" == true ]]; then
        return 0
    fi
    read -r -p "$(printf '%b%s [y/N]: %b' "$C_BOLD" "$prompt" "$C_RESET")" reply
    [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}

init_run() {
    mkdir -p "$RUN_DIR" "$BACKUP_DIR"
    chmod 700 "$STATE_DIR" "$RUN_DIR" "$BACKUP_DIR"
    touch "$RUN_LOG"
    chmod 600 "$RUN_LOG"
    printf '%s\n' "$RUN_ID" > "${STATE_DIR}/latest-run"
}

check_root() {
    [[ $EUID -eq 0 ]] || die "Run as root: sudo bash $SCRIPT_PATH"
}

check_os() {
    [[ -r /etc/os-release ]] || die "Cannot detect OS: /etc/os-release is missing."
    # shellcheck disable=SC1091
    source /etc/os-release
    case "${ID:-}" in
        debian|ubuntu) ;;
        *) die "Unsupported OS: ${ID:-unknown}. Supported: Debian and Ubuntu." ;;
    esac
    log_info "OS: ${PRETTY_NAME:-unknown}; architecture: $(uname -m)"
}

bootstrap_dependencies() {
    local packages=(curl jq openssl ca-certificates gnupg lsb-release iproute2 tar)
    local commands=(curl jq openssl update-ca-certificates gpg lsb_release ss tar)
    local missing=()
    local index
    for index in "${!commands[@]}"; do
        command -v "${commands[$index]}" >/dev/null 2>&1 || missing+=("${packages[$index]}")
    done
    if (( ${#missing[@]} > 0 )); then
        log_step "Installing bootstrap dependencies: ${missing[*]}"
        apt-get update -qq
        apt-get install -y -qq "${missing[@]}"
    fi
}

load_config() {
    if [[ -z "$DOMAIN" ]]; then
        read -r -p "$(printf '%bEnter Matrix domain: %b' "$C_BOLD" "$C_RESET")" DOMAIN
    fi
    DOMAIN="${DOMAIN,,}"
    [[ -n "$DOMAIN" ]] || die "DOMAIN is required."
    if [[ -z "$PUBLIC_IP" && -t 0 ]]; then
        read -r -p "$(printf '%bPublic IPv4 (blank for automatic detection): %b' "$C_BOLD" "$C_RESET")" PUBLIC_IP
    fi
}

validate_domain() {
    [[ ${#DOMAIN} -le 253 ]] || die "DOMAIN is longer than 253 characters."
    [[ "$DOMAIN" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || die "Invalid DOMAIN: $DOMAIN"
    local label
    local IFS='.'
    read -r -a labels <<< "$DOMAIN"
    (( ${#labels[@]} >= 2 )) || die "DOMAIN must be a fully-qualified domain name."
    for label in "${labels[@]}"; do
        [[ -n "$label" && ${#label} -le 63 ]] || die "Invalid DNS label in DOMAIN: $DOMAIN"
        [[ "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || die "Invalid DNS label: $label"
    done
}

validate_ipv4() {
    local ip="$1" octet
    local -a octets
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS='.' read -r -a octets <<< "$ip"
    (( ${#octets[@]} == 4 )) || return 1
    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^[0-9]+$ ]] || return 1
        (( 10#$octet >= 0 && 10#$octet <= 255 )) || return 1
    done
}

detect_public_ip() {
    if [[ -z "$PUBLIC_IP" ]]; then
        log_step "Detecting public IPv4..."
        PUBLIC_IP=$(curl -4fsS --max-time 10 https://api.ipify.org 2>/dev/null) ||
            PUBLIC_IP=$(curl -4fsS --max-time 10 https://ifconfig.me 2>/dev/null) ||
            PUBLIC_IP=$(curl -4fsS --max-time 10 https://icanhazip.com 2>/dev/null) ||
            die "Cannot detect public IPv4. Set PUBLIC_IP explicitly."
    fi
    PUBLIC_IP="${PUBLIC_IP//$'\r'/}"
    PUBLIC_IP="${PUBLIC_IP//$'\n'/}"
    validate_ipv4 "$PUBLIC_IP" || die "Invalid PUBLIC_IP: $PUBLIC_IP"
    log_info "Public IPv4: $PUBLIC_IP"
}

detect_ssh_port() {
    local port="" client_ip client_port server_ip
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        read -r client_ip client_port server_ip port <<< "$SSH_CONNECTION"
        : "$client_ip" "$client_port" "$server_ip"
    elif [[ -n "$SSH_PORT_CFG" ]]; then
        port="$SSH_PORT_CFG"
    else
        local -a ports=()
        mapfile -t ports < <(ss -H -ltnp 2>/dev/null | awk '/sshd/ {sub(/^.*:/,"",$4); print $4}' | sort -nu)
        if (( ${#ports[@]} == 1 )); then
            port="${ports[0]}"
        else
            die "Cannot unambiguously detect SSH port. Use an active SSH session or set SSH_PORT_CFG."
        fi
    fi
    if [[ ! "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        die "Invalid SSH port: $port"
    fi
    ss -H -ltnp 2>/dev/null | awk -v port=":${port}" '$4 ~ port "$" && $0 ~ /sshd/ {found=1} END {exit !found}' ||
        die "SSH port ${port} is not confirmed as an sshd listening socket."
    SSH_PORT="$port"
    log_info "Protected SSH port: $SSH_PORT"
}

check_dns() {
    if [[ "$SKIP_DNS_CHECK" == true ]]; then
        log_warn "DNS check explicitly skipped."
        return 0
    fi
    local -a dns_ips=()
    mapfile -t dns_ips < <(getent ahostsv4 "$DOMAIN" | awk '$2 == "STREAM" {print $1}' | sort -u)
    (( ${#dns_ips[@]} > 0 )) || die "No DNS A record found for $DOMAIN."
    local ip
    for ip in "${dns_ips[@]}"; do
        if [[ "$ip" == "$PUBLIC_IP" ]]; then
            log_info "DNS A record matches $PUBLIC_IP"
            return 0
        fi
    done
    die "DNS A records (${dns_ips[*]}) do not contain PUBLIC_IP=$PUBLIC_IP. Set SKIP_DNS_CHECK=true only for an intentional proxy/CDN setup."
}

existing_stack_running() {
    [[ -f "${WORKDIR}/docker-compose.yml" ]] || return 1
    command -v docker >/dev/null 2>&1 || return 1
    docker compose -f "${WORKDIR}/docker-compose.yml" ps -q 2>/dev/null |
        awk 'NF {found=1} END {exit !found}'
}

socket_in_use() {
    local port="$1" protocol="$2"
    if [[ "$protocol" == tcp ]]; then
        ss -H -ltn "sport = :${port}" 2>/dev/null | awk 'NF {found=1} END {exit !found}'
    else
        ss -H -lun "sport = :${port}" 2>/dev/null | awk 'NF {found=1} END {exit !found}'
    fi
}

check_required_ports() {
    if existing_stack_running; then
        log_info "Existing compose stack is running; preserving its listeners during idempotent update."
        return 0
    fi
    log_step "Checking required ports..."
    local conflicts=0 port
    for port in 80 443 3478 5349 7881; do
        if socket_in_use "$port" tcp; then
            log_error "Port ${port}/tcp is occupied."
            conflicts=$((conflicts + 1))
        fi
    done
    if socket_in_use 3478 udp; then
        log_error "Port 3478/udp is occupied."
        conflicts=$((conflicts + 1))
    fi
    for port in $(seq 49160 49200) $(seq 50000 50100); do
        if socket_in_use "$port" udp; then
            log_error "Port ${port}/udp is occupied."
            conflicts=$((conflicts + 1))
        fi
    done
    (( conflicts == 0 )) || die "$conflicts required port(s) are occupied."
    log_info "Required ports are available."
}

configure_docker_repository() {
    # shellcheck disable=SC1091
    source /etc/os-release
    local repo_os="$ID" codename="${VERSION_CODENAME:-}"
    [[ "$repo_os" == debian || "$repo_os" == ubuntu ]] || die "Unsupported Docker repository OS: $repo_os"
    [[ -n "$codename" ]] || die "Cannot determine OS codename for Docker repository."
    local key_tmp
    key_tmp=$(mktemp)
    curl -fsSL "https://download.docker.com/linux/${repo_os}/gpg" -o "$key_tmp"
    install -m 0755 -d /etc/apt/keyrings
    gpg --dearmor --batch --yes -o /etc/apt/keyrings/docker.gpg "$key_tmp"
    rm -f "$key_tmp"
    chmod a+r /etc/apt/keyrings/docker.gpg
    local arch
    arch=$(dpkg --print-architecture)
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/%s %s stable\n' \
        "$arch" "$repo_os" "$codename" > /etc/apt/sources.list.d/docker.list
}

install_docker() {
    if command -v docker >/dev/null 2>&1; then
        docker info >/dev/null 2>&1 || die "Docker CLI exists but daemon is unavailable; refusing automatic reinstall."
        if docker compose version >/dev/null 2>&1; then
            log_info "Docker Engine and Compose are operational."
            return 0
        fi
        log_step "Installing missing Docker Compose plugin..."
        configure_docker_repository
        apt-get update -qq
        apt-get install -y -qq docker-compose-plugin
    else
        log_step "Installing Docker Engine and Compose plugin..."
        configure_docker_repository
        apt-get update -qq
        apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
    fi
    docker info >/dev/null 2>&1 || die "Docker daemon is unavailable after installation."
    docker compose version >/dev/null 2>&1 || die "Docker Compose plugin is unavailable after installation."
    log_info "Docker: $(docker --version); $(docker compose version)"
}

backup_external_file() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    local destination
    destination="${RUN_DIR}/system$(dirname "$file")"
    mkdir -p "$destination"
    cp -a "$file" "${destination}/$(basename "$file")"
}

setup_swap() {
    log_step "Checking swap and swappiness..."
    local active=false
    if swapon --noheadings --show=NAME 2>/dev/null | awk 'NF {found=1} END {exit !found}'; then
        active=true
    elif [[ -f /swapfile ]]; then
        swapon /swapfile || die "Existing /swapfile cannot be activated."
        active=true
    fi
    local ram_mb
    ram_mb=$(awk '/MemTotal/ {printf "%d",$2/1024}' /proc/meminfo)
    if [[ "$active" == false && "$ram_mb" -lt 2048 ]]; then
        if [[ ! "$SWAP_SIZE_MB" =~ ^[0-9]+$ ]] || (( SWAP_SIZE_MB < 512 )); then
            die "Invalid SWAP_SIZE_MB=$SWAP_SIZE_MB"
        fi
        log_step "Creating ${SWAP_SIZE_MB} MB /swapfile..."
        fallocate -l "${SWAP_SIZE_MB}M" /swapfile 2>/dev/null ||
            dd if=/dev/zero of=/swapfile bs=1M count="$SWAP_SIZE_MB" status=progress
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null
        swapon /swapfile
        backup_external_file /etc/fstab
        if ! awk '$0 !~ /^[[:space:]]*#/ && $1 == "/swapfile" {found=1} END {exit !found}' /etc/fstab; then
            printf '/swapfile none swap sw 0 0\n' >> /etc/fstab
        fi
    fi
    backup_external_file /etc/sysctl.d/99-matrix.conf
    local sysctl_tmp
    sysctl_tmp=$(mktemp)
    printf 'vm.swappiness=10\n' > "$sysctl_tmp"
    install -m 0644 "$sysctl_tmp" /etc/sysctl.d/99-matrix.conf
    rm -f "$sysctl_tmp"
    sysctl -w vm.swappiness=10 >/dev/null
}

ufw_rule_exists() {
    local rule="$1"
    ufw status 2>/dev/null | awk -v rule="$rule" '$1 == rule && $2 == "ALLOW" {found=1} END {exit !found}'
}

ensure_ufw_rule() {
    local rule="$1" comment="$2"
    if ufw_rule_exists "$rule"; then
        log_info "UFW rule already present: $rule"
        return 0
    fi
    ufw allow "$rule" comment "$comment" >/dev/null
    printf '%s\n' "$rule" >> "${RUN_DIR}/ufw-added.rules"
    log_info "Added UFW rule: $rule"
}

setup_ufw() {
    command -v ufw >/dev/null 2>&1 || { apt-get update -qq; apt-get install -y -qq ufw; }
    cat <<RULES
Planned UFW additions:
  ${SSH_PORT}/tcp       SSH
  80/tcp, 443/tcp      Caddy
  3478/tcp, 3478/udp   Coturn
  5349/tcp             Coturn TLS
  49160:49200/udp      Coturn relay
  7881/tcp             LiveKit TCP
  50000:50100/udp      LiveKit RTC
RULES
    confirm "Apply these UFW rules?" || die "UFW changes declined."
    ensure_ufw_rule "${SSH_PORT}/tcp" "SSH"
    if ! ufw status 2>/dev/null | awk '$0 == "Status: active" {found=1} END {exit !found}'; then
        ufw --force enable
        log_info "UFW enabled after confirming SSH rule."
    fi
    ensure_ufw_rule 80/tcp HTTP
    ensure_ufw_rule 443/tcp HTTPS
    ensure_ufw_rule 3478/tcp "Coturn TCP"
    ensure_ufw_rule 3478/udp "Coturn UDP"
    ensure_ufw_rule 5349/tcp "Coturn TLS"
    ensure_ufw_rule 49160:49200/udp "Coturn relay"
    ensure_ufw_rule 7881/tcp "LiveKit TCP"
    ensure_ufw_rule 50000:50100/udp "LiveKit RTC"
}

load_saved_secrets() {
    local file="${WORKDIR}/.secrets.env" key value
    [[ -f "$file" ]] || return 0
    while IFS='=' read -r key value; do
        [[ -n "$key" ]] || continue
        case "$key" in
            POSTGRES_PASSWORD|TURN_SECRET|LIVEKIT_SECRET|REGISTRATION_SHARED_SECRET|MACAROON_SECRET_KEY|FORM_SECRET)
                if [[ -n "${!key:-}" && "${!key}" != "$value" ]]; then
                    die "$key differs from the saved value; implicit secret rotation is forbidden."
                fi
                printf -v "$key" '%s' "$value"
                ;;
            *) die "Unexpected key in .secrets.env: $key" ;;
        esac
    done < "$file"
    log_info "Existing secrets loaded."
}

gen_secret() {
    openssl rand -hex "${1:-16}"
}

prepare_secrets() {
    local existing_hs="${WORKDIR}/synapse/data/homeserver.yaml"
    if [[ -f "$existing_hs" && ! -f "${WORKDIR}/.secrets.env" ]]; then
        die "Existing Synapse configuration found without .secrets.env; refusing to regenerate secrets."
    fi
    load_saved_secrets
    : "${POSTGRES_PASSWORD:=$(gen_secret 16)}"
    : "${TURN_SECRET:=$(gen_secret 16)}"
    : "${LIVEKIT_SECRET:=$(gen_secret 16)}"
    : "${REGISTRATION_SHARED_SECRET:=$(gen_secret 32)}"
    : "${MACAROON_SECRET_KEY:=$(gen_secret 32)}"
    : "${FORM_SECRET:=$(gen_secret 32)}"
}

check_server_name() {
    local file="${WORKDIR}/synapse/data/homeserver.yaml" existing
    [[ -f "$file" ]] || return 0
    existing=$(awk '$1 == "server_name:" {print $2; exit}' "$file")
    existing="${existing#\"}"
    existing="${existing%\"}"
    existing="${existing#\'}"
    existing="${existing%\'}"
    [[ -n "$existing" ]] || die "Cannot read existing Synapse server_name."
    [[ "$existing" == "$DOMAIN" ]] || die "Refusing to change server_name from $existing to $DOMAIN."
}

backup_config_file() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    local relative="${file#"${WORKDIR}"/}"
    local destination="${RUN_DIR}/config-backups/${relative}"
    mkdir -p "$(dirname "$destination")"
    cp -a "$file" "$destination"
}

commit_file() {
    local temporary="$1" destination="$2" mode="$3"
    if [[ -f "$destination" ]] && cmp -s "$temporary" "$destination"; then
        rm -f "$temporary"
        log_info "Unchanged: ${destination#"${WORKDIR}"/}"
        return 0
    fi
    backup_config_file "$destination"
    chmod "$mode" "$temporary"
    mv -f "$temporary" "$destination"
    log_info "Updated: ${destination#"${WORKDIR}"/}"
}

render_configs() {
    log_step "Rendering configuration atomically..."
    mkdir -p "${WORKDIR}"/{postgres,synapse/data,caddy/data,caddy/config,livekit,coturn/certs}
    chmod 755 \
        "${WORKDIR}/caddy" \
        "${WORKDIR}/caddy/data" \
        "${WORKDIR}/caddy/config" \
        "${WORKDIR}/coturn" \
        "${WORKDIR}/coturn/certs"
    local tmp

    tmp=$(mktemp "${WORKDIR}/docker-compose.yml.tmp.XXXXXX")
    cat > "$tmp" <<COMPOSE
services:
  postgres:
    image: postgres:${POSTGRES_VERSION}
    container_name: postgres
    restart: unless-stopped
    environment:
      POSTGRES_DB: synapse
      POSTGRES_USER: synapse
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_INITDB_ARGS: "--encoding=UTF8 --locale=C"
    volumes:
      - ./postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U synapse -d synapse"]
      interval: 5s
      timeout: 3s
      retries: 20

  synapse:
    image: ghcr.io/element-hq/synapse:${SYNAPSE_VERSION}
    container_name: synapse
    restart: unless-stopped
    environment:
      UID: "0"
      GID: "0"
    depends_on:
      postgres:
        condition: service_healthy
    volumes:
      - ./synapse/data:/data
    expose:
      - "8008"

  coturn:
    image: coturn/coturn:${COTURN_VERSION}
    container_name: coturn
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./coturn/certs:/certs:ro
    command:
      - -l
      - stdout
      - --use-auth-secret
      - --static-auth-secret=${TURN_SECRET}
      - --realm=${DOMAIN}
      - --server-name=${DOMAIN}
      - --listening-ip=${PUBLIC_IP}
      - --relay-ip=${PUBLIC_IP}
      - --external-ip=${PUBLIC_IP}
      - --listening-port=3478
      - --tls-listening-port=5349
      - --cert=/certs/${DOMAIN}.crt
      - --pkey=/certs/${DOMAIN}.key
      - --min-port=49160
      - --max-port=49200
      - --fingerprint
      - --no-tlsv1

  livekit:
    image: livekit/livekit-server:${LIVEKIT_VERSION}
    container_name: livekit
    restart: unless-stopped
    command: ["--config", "/livekit.yaml"]
    volumes:
      - ./livekit/livekit.yaml:/livekit.yaml:ro
    expose:
      - "7880"
    ports:
      - "7881:7881/tcp"
      - "50000-50100:50000-50100/udp"

  lk-jwt-service:
    image: ghcr.io/element-hq/lk-jwt-service:${LK_JWT_VERSION}
    container_name: lk-jwt-service
    restart: unless-stopped
    env_file:
      - ./livekit/.env
    expose:
      - "8080"

  caddy:
    image: caddy:${CADDY_VERSION}
    container_name: caddy
    restart: unless-stopped
    depends_on:
      - synapse
      - livekit
      - lk-jwt-service
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - ./caddy/data:/data
      - ./caddy/config:/config
COMPOSE
    commit_file "$tmp" "${WORKDIR}/docker-compose.yml" 0600

    tmp=$(mktemp "${WORKDIR}/synapse/data/homeserver.yaml.tmp.XXXXXX")
    cat > "$tmp" <<HOMESERVER
server_name: "${DOMAIN}"
public_baseurl: "https://${DOMAIN}/"
pid_file: /data/homeserver.pid
listeners:
  - port: 8008
    type: http
    tls: false
    x_forwarded: true
    resources:
      - names: [client, federation]
        compress: false
database:
  name: psycopg2
  args:
    user: synapse
    password: "${POSTGRES_PASSWORD}"
    database: synapse
    host: postgres
    port: 5432
    cp_min: 5
    cp_max: 10
media_store_path: /data/media_store
registration_shared_secret: "${REGISTRATION_SHARED_SECRET}"
report_stats: false
macaroon_secret_key: "${MACAROON_SECRET_KEY}"
form_secret: "${FORM_SECRET}"
signing_key_path: "/data/${DOMAIN}.signing.key"
trusted_key_servers:
  - server_name: "matrix.org"
turn_uris:
  - "turn:${DOMAIN}:3478?transport=udp"
  - "turn:${DOMAIN}:3478?transport=tcp"
  - "turns:${DOMAIN}:5349?transport=tcp"
turn_shared_secret: "${TURN_SECRET}"
turn_user_lifetime: 86400000
turn_allow_guests: false
experimental_features:
  msc3266_enabled: true
  msc4222_enabled: true
max_event_delay_duration: 24h
rc_message:
  per_second: 0.5
  burst_count: 30
rc_delayed_event_mgmt:
  per_second: 1
  burst_count: 20
HOMESERVER
    commit_file "$tmp" "${WORKDIR}/synapse/data/homeserver.yaml" 0600

    tmp=$(mktemp "${WORKDIR}/caddy/Caddyfile.tmp.XXXXXX")
    cat > "$tmp" <<CADDY
${DOMAIN} {
    handle /.well-known/matrix/server {
        header Content-Type application/json
        respond \`{"m.server":"${DOMAIN}:443"}\` 200
    }
    handle /.well-known/matrix/client {
        header Content-Type application/json
        header Access-Control-Allow-Origin "*"
        header Access-Control-Allow-Methods "GET, POST, PUT, DELETE, OPTIONS"
        header Access-Control-Allow-Headers "X-Requested-With, Content-Type, Authorization"
        respond \`{"m.homeserver":{"base_url":"https://${DOMAIN}"},"org.matrix.msc4143.rtc_foci":[{"type":"livekit","livekit_service_url":"https://${DOMAIN}/livekit/jwt"}]}\` 200
    }
    handle /livekit/jwt/* {
        uri strip_prefix /livekit/jwt
        reverse_proxy lk-jwt-service:8080
    }
    handle /livekit/sfu/* {
        uri strip_prefix /livekit/sfu
        reverse_proxy livekit:7880
    }
    encode gzip
    reverse_proxy synapse:8008
}
CADDY
    commit_file "$tmp" "${WORKDIR}/caddy/Caddyfile" 0644

    tmp=$(mktemp "${WORKDIR}/livekit/livekit.yaml.tmp.XXXXXX")
    cat > "$tmp" <<LIVEKIT
port: 7880
bind_addresses: ["0.0.0.0"]
rtc:
  tcp_port: 7881
  port_range_start: 50000
  port_range_end: 50100
  use_external_ip: true
room:
  auto_create: false
keys:
  matrixrtc: ${LIVEKIT_SECRET}
webhook:
  api_key: matrixrtc
  urls:
    - https://${DOMAIN}/livekit/jwt/sfu_webhook
LIVEKIT
    commit_file "$tmp" "${WORKDIR}/livekit/livekit.yaml" 0600

    tmp=$(mktemp "${WORKDIR}/livekit/.env.tmp.XXXXXX")
    cat > "$tmp" <<LIVEKITENV
LIVEKIT_KEY=matrixrtc
LIVEKIT_SECRET=${LIVEKIT_SECRET}
LIVEKIT_URL=wss://${DOMAIN}/livekit/sfu
LIVEKIT_FULL_ACCESS_HOMESERVERS=${DOMAIN}
LIVEKITENV
    commit_file "$tmp" "${WORKDIR}/livekit/.env" 0600

    tmp=$(mktemp "${WORKDIR}/.secrets.env.tmp.XXXXXX")
    cat > "$tmp" <<SECRETS
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
TURN_SECRET=${TURN_SECRET}
LIVEKIT_SECRET=${LIVEKIT_SECRET}
REGISTRATION_SHARED_SECRET=${REGISTRATION_SHARED_SECRET}
MACAROON_SECRET_KEY=${MACAROON_SECRET_KEY}
FORM_SECRET=${FORM_SECRET}
SECRETS
    commit_file "$tmp" "${WORKDIR}/.secrets.env" 0600

    docker compose -f "${WORKDIR}/docker-compose.yml" config --quiet || die "Rendered docker-compose.yml is invalid."
}

wait_for_postgres() {
    local waited=0
    until docker compose -f "${WORKDIR}/docker-compose.yml" exec -T postgres pg_isready -U synapse -d synapse >/dev/null 2>&1; do
        (( waited >= 60 )) && die "PostgreSQL did not become ready within 60 seconds."
        sleep 2
        waited=$((waited + 2))
    done
}

wait_for_synapse() {
    local waited=0
    while true; do
        if docker compose -f "${WORKDIR}/docker-compose.yml" exec -T synapse \
            python - <<'PY' >/dev/null 2>&1
import urllib.request
urllib.request.urlopen("http://127.0.0.1:8008/_matrix/client/versions", timeout=5)
PY
        then
            log_info "Synapse is ready."
            return 0
        fi
        (( waited >= 180 )) && die "Synapse did not become ready within 180 seconds."
        sleep 3
        waited=$((waited + 3))
    done
}

find_caddy_certificate() {
    find "${WORKDIR}/caddy/data" -type f -name "${DOMAIN}.crt" -path "*/${DOMAIN}/*" -print -quit 2>/dev/null
}

copy_coturn_certificate() {
    local cert_src key_src cert_dst key_dst
    cert_src=$(find_caddy_certificate)
    key_src="${cert_src%.crt}.key"
    cert_dst="${WORKDIR}/coturn/certs/${DOMAIN}.crt"
    key_dst="${WORKDIR}/coturn/certs/${DOMAIN}.key"
    if [[ -f "$cert_src" && -f "$key_src" ]]; then
        backup_config_file "$cert_dst"
        backup_config_file "$key_dst"
        install -m 0644 "$cert_src" "$cert_dst"
        install -m 0600 "$key_src" "$key_dst"
    elif [[ "$COTURN_SELF_SIGNED" == true ]]; then
        log_warn "Generating explicitly requested self-signed Coturn certificate."
        backup_config_file "$cert_dst"
        backup_config_file "$key_dst"
        openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
            -days 30 -keyout "$key_dst" -out "$cert_dst" \
            -subj "/CN=${DOMAIN}" -addext "subjectAltName=DNS:${DOMAIN},IP:${PUBLIC_IP}" >/dev/null 2>&1
        chmod 0600 "$key_dst"
        chmod 0644 "$cert_dst"
    else
        die "Caddy certificate not found; refusing implicit self-signed fallback."
    fi
    openssl x509 -in "$cert_dst" -noout -checkend 86400 >/dev/null || die "Coturn certificate is invalid or expires within 24 hours."
    openssl pkey -in "$key_dst" -noout >/dev/null || die "Coturn private key is invalid."
    local cert_public key_public
    cert_public=$(openssl x509 -in "$cert_dst" -pubkey -noout | openssl pkey -pubin -outform DER | openssl sha256)
    key_public=$(openssl pkey -in "$key_dst" -pubout -outform DER | openssl sha256)
    [[ "$cert_public" == "$key_public" ]] || die "Coturn certificate and private key do not match."
    fix_coturn_cert_permissions
}

# Coturn (inside its container) needs to be able to read the private key.
# copy_coturn_certificate() can be followed by other steps before the
# container actually starts, so this is also re-run immediately before
# `docker compose up -d coturn` in start_stack() to guarantee the key is
# readable at the moment the process actually starts.
fix_coturn_cert_permissions() {
    chmod 755 "${WORKDIR}/coturn" "${WORKDIR}/coturn/certs"
    chmod 644 "${WORKDIR}/coturn/certs/${DOMAIN}.crt"
    chmod 644 "${WORKDIR}/coturn/certs/${DOMAIN}.key"
}

generate_signing_key() {
    local key_path="${WORKDIR}/synapse/data/${DOMAIN}.signing.key"
    if [[ -f "$key_path" ]]; then
        return 0
    fi
    log_step "Generating Synapse signing key..."
    local tmp
    tmp=$(mktemp "${WORKDIR}/synapse/data/.signing.key.tmp.XXXXXX")
    if ! docker run --rm --entrypoint="" \
        -v "${WORKDIR}/synapse/data:/data" \
        "ghcr.io/element-hq/synapse:${SYNAPSE_VERSION}" \
        python -m synapse._scripts.generate_signing_key -o "/data/$(basename "$tmp")" \
        >/dev/null 2>&1; then
        rm -f "$tmp"
        die "Failed to generate Synapse signing key."
    fi
    chmod 0600 "$tmp"
    mv -f "$tmp" "$key_path"
    log_info "Signing key created: ${key_path#"${WORKDIR}"/}"
}

start_stack() {
    cd "$WORKDIR"
    generate_signing_key
    docker compose up -d postgres synapse livekit lk-jwt-service caddy
    wait_for_postgres
    wait_for_synapse
    local waited=0
    while [[ -z "$(find_caddy_certificate)" ]]; do
        (( waited >= 125 )) && break
        [[ "$(docker inspect --format='{{.State.Running}}' caddy 2>/dev/null)" == true ]] || die "Caddy stopped before obtaining a certificate."
        sleep 2
        waited=$((waited + 2))
    done
    copy_coturn_certificate
    fix_coturn_cert_permissions
    docker compose up -d coturn
    log_info "Stack started."
}

create_backup() {
    [[ -f "${WORKDIR}/docker-compose.yml" ]] || die "docker-compose.yml not found; nothing to back up."
    local archive stage
    archive="${BACKUP_DIR}/matrix_backup_$(date -u '+%Y%m%dT%H%M%SZ_%N').tar.gz"
    stage=$(mktemp -d)
    chmod 700 "$stage"
    local -a items=()
    local item
    for item in docker-compose.yml caddy synapse livekit coturn .secrets.env; do
        [[ -e "${WORKDIR}/${item}" ]] && items+=("$item")
    done
    (( ${#items[@]} > 0 )) || die "No Matrix configuration/data found to back up."
    tar -C "$WORKDIR" -cf - "${items[@]}" | tar -C "$stage" -xf -
    if [[ -d "${WORKDIR}/postgres" ]]; then
        existing_stack_running || die "PostgreSQL data exists but stack is not running; cannot create a consistent database backup."
        docker compose -f "${WORKDIR}/docker-compose.yml" exec -T postgres \
            pg_dump -U synapse -d synapse -Fc > "${stage}/postgres.dump"
    fi
    cat > "${stage}/BACKUP_MANIFEST" <<MANIFEST
format=matrix-node-v1
created_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
domain=${DOMAIN:-unknown}
database_dump=$([[ -f "${stage}/postgres.dump" ]] && printf yes || printf no)
MANIFEST
    tar -C "$stage" -czf "$archive" .
    chmod 600 "$archive"
    rm -rf "$stage"
    printf '%s\n' "$archive"
}

latest_backup() {
    find "$BACKUP_DIR" -maxdepth 1 -type f -name 'matrix_backup_*.tar.gz' -printf '%T@ %p\n' 2>/dev/null |
        sort -nr | awk 'NR == 1 {sub(/^[^ ]+ /, ""); print}'
}

restore_backup() {
    local archive="${1:-}" stage
    [[ -n "$archive" ]] || archive=$(latest_backup)
    [[ -n "$archive" ]] || die "No backup archive found."
    archive=$(readlink -f -- "$archive")
    case "$archive" in
        "${BACKUP_DIR}"/matrix_backup_*.tar.gz) ;;
        *) die "Restore accepts only archives created in $BACKUP_DIR" ;;
    esac
    [[ -f "$archive" ]] || die "Backup archive not found: ${archive:-<none>}"
    local listing
    listing=$(tar -tzf "$archive") || die "Backup archive is corrupt."
    if grep -E '(^/|(^|/)\.\.(/|$))' <<< "$listing" >/dev/null; then
        die "Backup archive contains unsafe paths."
    fi
    stage=$(mktemp -d)
    chmod 700 "$stage"
    tar -xzf "$archive" -C "$stage"
    grep -q '^format=matrix-node-v1$' "${stage}/BACKUP_MANIFEST" || die "Unsupported backup format."
    confirm "Restore $(basename "$archive")? Current services will restart." || die "Restore cancelled."
    if [[ -f "${WORKDIR}/docker-compose.yml" ]] && existing_stack_running; then
        local pre_restore_bak
        pre_restore_bak=$(create_backup)
        log_info "Pre-restore safety backup created: $pre_restore_bak"
        docker compose -f "${WORKDIR}/docker-compose.yml" down
    fi
    local -a items=()
    local item
    for item in docker-compose.yml caddy synapse livekit coturn .secrets.env; do
        [[ -e "${stage}/${item}" ]] && items+=("$item")
    done
    tar -C "$stage" -cf - "${items[@]}" | tar -C "$WORKDIR" -xf -
    chmod 600 "${WORKDIR}/.secrets.env" "${WORKDIR}/livekit/.env" 2>/dev/null || true
    if [[ -f "${stage}/postgres.dump" ]]; then
        docker compose -f "${WORKDIR}/docker-compose.yml" up -d postgres
        wait_for_postgres
        docker compose -f "${WORKDIR}/docker-compose.yml" exec -T postgres \
            pg_restore -U synapse -d synapse --clean --if-exists < "${stage}/postgres.dump" 2>&1 | tee "${RUN_DIR}/pg_restore.log" || \
            log_warn "pg_restore completed with non-fatal errors (check ${RUN_DIR}/pg_restore.log if data is missing)."
    fi
    docker compose -f "${WORKDIR}/docker-compose.yml" up -d
    rm -rf "$stage"
    log_info "Restore completed from $archive"
}

container_ok() {
    local name="$1" state health
    state=$(docker inspect --format='{{.State.Status}}' "$name" 2>/dev/null || printf missing)
    [[ "$state" == running ]] || { log_error "$name: $state"; return 1; }
    health=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$name" 2>/dev/null || printf unknown)
    [[ "$health" != unhealthy ]] || { log_error "$name: unhealthy"; return 1; }
    log_info "$name: running (health=$health)"
}

http_code() {
    curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "$1" 2>/dev/null || true
}

check_ufw() {
    ufw status 2>/dev/null | awk '$0 == "Status: active" {found=1} END {exit !found}' || return 1
    local rule
    for rule in "${SSH_PORT}/tcp" 80/tcp 443/tcp 3478/tcp 3478/udp 5349/tcp 49160:49200/udp 7881/tcp 50000:50100/udp; do
        ufw_rule_exists "$rule" || { log_error "Missing UFW rule: $rule"; return 1; }
    done
}

healthcheck() {
    local domain="$DOMAIN" errors=0 code body
    if [[ -z "$domain" && -f "${WORKDIR}/synapse/data/homeserver.yaml" ]]; then
        domain=$(awk '$1 == "server_name:" {gsub(/"/, "", $2); print $2; exit}' "${WORKDIR}/synapse/data/homeserver.yaml")
    fi
    [[ -n "$domain" ]] || die "Cannot determine Matrix domain for healthcheck."
    if [[ -z "$SSH_PORT" ]]; then
        detect_ssh_port
    fi
    cd "$WORKDIR"
    docker compose ps || errors=$((errors + 1))
    local container
    for container in postgres synapse coturn livekit lk-jwt-service caddy; do
        container_ok "$container" || errors=$((errors + 1))
    done
    code=$(http_code "https://${domain}/_matrix/client/versions")
    [[ "$code" == 200 ]] || { log_error "Synapse HTTP status: $code"; errors=$((errors + 1)); }
    body=$(curl -fsS --max-time 15 "https://${domain}/.well-known/matrix/server" 2>/dev/null || true)
    jq -e --arg server "${domain}:443" '."m.server" == $server' <<< "$body" >/dev/null || { log_error "Invalid .well-known/matrix/server"; errors=$((errors + 1)); }
    body=$(curl -fsS --max-time 15 "https://${domain}/.well-known/matrix/client" 2>/dev/null || true)
    jq -e --arg url "https://${domain}" '."m.homeserver".base_url == $url and ."org.matrix.msc4143.rtc_foci"[0].type == "livekit"' \
        <<< "$body" >/dev/null || { log_error "Invalid .well-known/matrix/client"; errors=$((errors + 1)); }
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "https://${domain}/livekit/jwt/get_token" 2>/dev/null || printf 000)
    [[ "$code" == 405 ]] || { log_error "JWT GET status: $code (expected 405)"; errors=$((errors + 1)); }
    body=$(curl -sS -w $'\n%{http_code}' --max-time 15 -X POST -H 'Content-Type: application/json' \
        -d '{}' "https://${domain}/livekit/jwt/get_token" 2>/dev/null || true)
    code=$(tail -n 1 <<< "$body")
    if [[ "$code" != 400 ]] || ! grep -q 'M_BAD_JSON' <<< "$body"; then
        log_error "Unexpected JWT POST response."
        errors=$((errors + 1))
    fi
    code=$(http_code "https://${domain}/livekit/sfu/")
    [[ "$code" == 200 ]] || { log_error "LiveKit SFU status: $code"; errors=$((errors + 1)); }
    ss -H -ltn "sport = :7881" | awk 'NF {found=1} END {exit !found}' || { log_error "7881/tcp is not listening."; errors=$((errors + 1)); }
    ss -H -lun "sport = :50000" | awk 'NF {found=1} END {exit !found}' || { log_error "50000/udp is not listening."; errors=$((errors + 1)); }
    ss -H -lun "sport = :50100" | awk 'NF {found=1} END {exit !found}' || { log_error "50100/udp is not listening."; errors=$((errors + 1)); }
    ss -H -ltn | awk -v address="${PUBLIC_IP}:3478" '$4 == address {found=1} END {exit !found}' || { log_error "Coturn TCP is not bound to PUBLIC_IP:3478."; errors=$((errors + 1)); }
    ss -H -lun | awk -v address="${PUBLIC_IP}:3478" '$5 == address || $4 == address {found=1} END {exit !found}' || { log_error "Coturn UDP is not bound to PUBLIC_IP:3478."; errors=$((errors + 1)); }
    ss -H -ltn | awk -v address="${PUBLIC_IP}:5349" '$4 == address {found=1} END {exit !found}' || { log_error "Coturn TLS is not bound to PUBLIC_IP:5349."; errors=$((errors + 1)); }
    check_ufw || errors=$((errors + 1))
    (( errors == 0 )) || die "Healthcheck failed with $errors issue(s)."
    log_info "Healthcheck passed."
}

validate_matrix_localpart() {
    local username="$1"

    [[ -n "$username" ]] || die "USERNAME is required."

    # Практичный безопасный subset для локальных пользователей:
    # lowercase letters, digits, dot, underscore, equals, hyphen, slash.
    # Не разрешаем ':' и '@', потому что нужен именно localpart, а не полный MXID.
    [[ "$username" =~ ^[a-z0-9._=/-]+$ ]] || die "Invalid USERNAME: use Matrix localpart only, e.g. admin or user.name"

    [[ "$username" != *:* ]] || die "USERNAME must be localpart only, not full Matrix ID."
    [[ "$username" != @* ]] || die "USERNAME must be localpart only, not full Matrix ID."
}

read_password_twice() {
    local pass1 pass2

    read -r -s -p "Password: " pass1
    printf '\n'
    read -r -s -p "Confirm password: " pass2
    printf '\n'

    [[ -n "$pass1" ]] || die "Password must not be empty."
    [[ "$pass1" == "$pass2" ]] || die "Passwords do not match."

    MATRIX_USER_PASSWORD="$pass1"
}

create_matrix_user() {
    local username="$1"
    local admin="${2:-false}"

    check_root
    init_run
    exec > >(tee -a "$RUN_LOG") 2>&1

    validate_matrix_localpart "$username"

    [[ -f "${WORKDIR}/docker-compose.yml" ]] || die "docker-compose.yml not found. Run install first."

    cd "$WORKDIR"

    docker compose ps -q synapse >/dev/null 2>&1 || die "Synapse service is not available."
    [[ "$(docker inspect --format='{{.State.Running}}' synapse 2>/dev/null || printf false)" == true ]] || die "Synapse container is not running."

    read_password_twice

    local -a cmd=(
        docker compose exec -T synapse
        register_new_matrix_user
        -c /data/homeserver.yaml
        -u "$username"
        -p "$MATRIX_USER_PASSWORD"
    )

    if [[ "$admin" == true ]]; then
        cmd+=(-a)
    fi

    cmd+=(http://localhost:8008)

    "${cmd[@]}"

    if [[ -z "$DOMAIN" && -f "${WORKDIR}/synapse/data/homeserver.yaml" ]]; then
        DOMAIN=$(awk '$1 == "server_name:" {gsub(/"/, "", $2); print $2; exit}' "${WORKDIR}/synapse/data/homeserver.yaml")
    fi

    if [[ "$admin" == true ]]; then
        log_info "Admin created: @${username}:${DOMAIN:-<server_name>}"
    else
        log_info "User created: @${username}:${DOMAIN:-<server_name>}"
    fi
}

mode_install() {
    check_root
    check_os
    init_run
    exec > >(tee -a "$RUN_LOG") 2>&1
    bootstrap_dependencies
    load_config
    validate_domain
    detect_public_ip
    detect_ssh_port
    check_dns
    check_required_ports
    local existing=false
    [[ -f "${WORKDIR}/docker-compose.yml" || -f "${WORKDIR}/.secrets.env" ]] && existing=true
    if [[ "$existing" == true && "$FORCE" != true ]]; then
        die "Existing installation detected. Re-run with --force for an idempotent, backed-up update."
    fi
    prepare_secrets
    check_server_name
    if [[ "$existing" == true ]]; then
        local pre_update_bak
        pre_update_bak=$(create_backup)
        log_info "Pre-update backup saved to: $pre_update_bak"
    fi
    install_docker
    setup_swap
    setup_ufw
    render_configs
    start_stack
    healthcheck
    log_info "Installation completed: https://${DOMAIN}"
    cat <<EOF
Homeserver: https://${DOMAIN}

Create admin:
  sudo bash $SCRIPT_PATH admin admin

Create user:
  sudo bash $SCRIPT_PATH user username

Login ID format:
  @username:${DOMAIN}
EOF
}

mode_check() {
    check_root
    local command
    for command in curl jq openssl ss docker ufw; do
        command -v "$command" >/dev/null 2>&1 || die "Required checker command is missing: $command"
    done
    prepare_secrets
    if [[ -z "$DOMAIN" && -f "${WORKDIR}/synapse/data/homeserver.yaml" ]]; then
        DOMAIN=$(awk '$1 == "server_name:" {gsub(/"/, "", $2); print $2; exit}' "${WORKDIR}/synapse/data/homeserver.yaml")
    fi
    if [[ -z "$PUBLIC_IP" && -f "${WORKDIR}/docker-compose.yml" ]]; then
        PUBLIC_IP=$(awk -F= '/--listening-ip=/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' "${WORKDIR}/docker-compose.yml")
    fi
    healthcheck
}

parse_install_options() {
    while (( $# > 0 )); do
        case "$1" in
            --force) FORCE=true ;;
            --yes|-y) ASSUME_YES=true ;;
            *) die "Unknown install option: $1" ;;
        esac
        shift
    done
}

main() {
    local mode="${1:-}"
    (( $# > 0 )) && shift || true
    case "$mode" in
        install) parse_install_options "$@"; mode_install ;;
        check) mode_check ;;
        user) create_matrix_user "${1:-}" false ;;
        admin) create_matrix_user "${1:-}" true ;;
        backup) check_root; init_run; create_backup ;;
        restore) check_root; init_run; restore_backup "${1:-}" ;;
        *)
            printf 'Usage: sudo bash %s {install [--force] [--yes]|check|user USERNAME|admin USERNAME|backup|restore [ARCHIVE]}\n' "$SCRIPT_PATH"
            exit 2
            ;;
    esac
}

main "$@"