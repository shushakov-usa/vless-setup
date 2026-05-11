#!/usr/bin/env bash
# vless-setup — fresh-server VLESS+Reality VPN setup via Marzban.
# One-liner:
#   bash <(curl -Ls https://raw.githubusercontent.com/shushakov-usa/vless-setup/main/setup.sh)
# Run as root on a fresh Debian 12+/Ubuntu 22+/24+ box.

set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────
# Constants & globals
# ──────────────────────────────────────────────────────────────────────────
SCRIPT_NAME="vless-setup"
MARZBAN_DIR="/opt/marzban"
MARZBAN_ENV="${MARZBAN_DIR}/.env"
MARZBAN_XRAY_JSON="${MARZBAN_DIR}/xray_config.json"
CERT_DIR="/etc/marzban-cert"
CERT_FILE="${CERT_DIR}/server.crt"
KEY_FILE="${CERT_DIR}/server.key"
OUTPUT_FILE="/root/${SCRIPT_NAME}-output.txt"
REALITLSCANNER_URL="https://github.com/XTLS/RealiTLScanner/releases/latest/download/RealiTLScanner-linux-64"
REALITLSCANNER_BIN="/usr/local/bin/RealiTLScanner"

# Allowed CDN cert issuers — sites with these issuers are de-facto allowlisted in RU.
CDN_ISSUERS_REGEX='cloudflare|microsoft|apple|amazon|akamai|google|fastly|digicert|sectigo'

# Fallback CDN-edge SNIs probed if neighbor scan finds nothing.
FALLBACK_SNIS=(
  "www.cloudflare.com"
  "www.microsoft.com"
  "swdlp.apple.com"
  "gateway.icloud.com"
  "update.microsoft.com"
  "www.bing.com"
)

# Filled by prompts / detection.
ADMIN_USER=""
ADMIN_PASS=""
PANEL_PORT=""
PANEL_PATH=""        # leading slash, no trailing slash, e.g. /a8f3c
SERVER_IP=""
SERVER_COUNTRY=""
REALITY_SNI=""
REALITY_PRIVATE_KEY=""
REALITY_PUBLIC_KEY=""
REALITY_SHORT_IDS=()
declare -a CLIENT_NAMES=()
declare -A CLIENT_UUIDS=()
declare -A CLIENT_SUB_URLS=()

# ──────────────────────────────────────────────────────────────────────────
# Logging helpers
# ──────────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YLW=$'\033[33m'; C_BLU=$'\033[34m'; C_DIM=$'\033[2m'
else
  C_RESET=""; C_BOLD=""; C_RED=""; C_GRN=""; C_YLW=""; C_BLU=""; C_DIM=""
fi

log()   { echo "${C_BLU}==>${C_RESET} ${C_BOLD}$*${C_RESET}"; }
ok()    { echo "${C_GRN}  ✓${C_RESET} $*"; }
warn()  { echo "${C_YLW}  ⚠${C_RESET} $*" >&2; }
err()   { echo "${C_RED}  ✗${C_RESET} $*" >&2; }
die()   { err "$*"; exit 1; }
ask()   { local prompt="$1" default="${2-}" reply
          if [[ -n "$default" ]]; then
            read -rp "  ${prompt} [${C_DIM}${default}${C_RESET}]: " reply </dev/tty
            echo "${reply:-$default}"
          else
            read -rp "  ${prompt}: " reply </dev/tty
            echo "$reply"
          fi
        }
ask_secret() { local prompt="$1" default="${2-}" reply
               if [[ -n "$default" ]]; then
                 read -rsp "  ${prompt} [random]: " reply </dev/tty; echo >&2
               else
                 read -rsp "  ${prompt}: " reply </dev/tty; echo >&2
               fi
               echo "${reply:-$default}"
             }
ask_yn() { local prompt="$1" default="${2:-Y}" reply
           local hint="[Y/n]"; [[ "$default" =~ ^[Nn]$ ]] && hint="[y/N]"
           read -rp "  ${prompt} ${hint} " reply
           reply="${reply:-$default}"
           [[ "$reply" =~ ^[Yy]$ ]]
         }
trap 'err "Failed at line $LINENO. See output above."' ERR

# ──────────────────────────────────────────────────────────────────────────
# Pre-flight
# ──────────────────────────────────────────────────────────────────────────
preflight() {
  log "Pre-flight checks"
  [[ "$EUID" -eq 0 ]] || die "Run as root."
  [[ -f /etc/os-release ]] || die "Cannot detect OS."
  . /etc/os-release
  case "$ID" in
    debian|ubuntu) ok "Detected $PRETTY_NAME" ;;
    *) die "Unsupported distro: $ID. Only Debian/Ubuntu supported." ;;
  esac
  command -v apt-get >/dev/null || die "apt-get not found."
  ok "apt-get present"

  SERVER_IP="$(curl -sf --max-time 5 https://ifconfig.co 2>/dev/null || curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  [[ -n "$SERVER_IP" ]] || die "Could not detect public IP."
  ok "Public IP: $SERVER_IP"

  SERVER_COUNTRY="$(curl -sf --max-time 5 "https://ifconfig.co/country-iso" 2>/dev/null || true)"
  [[ -n "$SERVER_COUNTRY" ]] && ok "Server country: $SERVER_COUNTRY" || warn "Could not detect country (continuing)."
}

apt_install() {
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" >/dev/null
}

ensure_base_pkgs() {
  log "Installing base packages"
  apt-get update -qq >/dev/null
  apt_install curl ca-certificates openssl jq iproute2 lsof
  ok "Base packages installed"
}

# ──────────────────────────────────────────────────────────────────────────
# Idempotency
# ──────────────────────────────────────────────────────────────────────────
detect_existing() {
  [[ -f "$MARZBAN_ENV" ]]
}

handle_existing_install() {
  warn "Existing Marzban detected at ${MARZBAN_DIR}"
  echo
  echo "  ${C_BOLD}1)${C_RESET} Skip & exit (no changes)"
  echo "  ${C_BOLD}2)${C_RESET} Add more clients only (keep existing setup)"
  echo "  ${C_BOLD}3)${C_RESET} Wipe everything and reinstall (regenerates ALL keys, breaks existing clients)"
  echo
  local choice
  read -rp "  Choice [1]: " choice
  choice="${choice:-1}"
  case "$choice" in
    1) log "Skipping. No changes made."; exit 0 ;;
    2) MODE="add-clients" ;;
    3) local conf
       read -rp "  Type ${C_RED}WIPE${C_RESET} to confirm full reinstall: " conf
       [[ "$conf" == "WIPE" ]] || die "Confirmation failed; aborting."
       MODE="reinstall"
       wipe_existing
       ;;
    *) die "Invalid choice." ;;
  esac
}

wipe_existing() {
  log "Wiping existing Marzban installation"
  # marzban uninstall is interactive (asks twice: confirm, then remove data files).
  # The upstream CLI has no -y flag — feed it answers via stdin.
  if command -v marzban >/dev/null; then
    marzban down >/dev/null 2>&1 || true
    printf 'y\ny\n' | marzban uninstall >/dev/null 2>&1 || true
  fi
  # Belt-and-braces: remove everything ourselves in case the CLI bailed early.
  rm -rf "$MARZBAN_DIR" "$CERT_DIR" "$OUTPUT_FILE" /var/lib/marzban /usr/local/bin/marzban
  ok "Wipe complete"
}

# ──────────────────────────────────────────────────────────────────────────
# Prompts
# ──────────────────────────────────────────────────────────────────────────
gen_random() { tr -dc 'a-zA-Z0-9' </dev/urandom | head -c "${1:-16}"; }

prompt_panel_settings() {
  log "Panel configuration"
  local default_user="admin_$(gen_random 4 | tr 'A-Z' 'a-z')"
  local default_pass="$(gen_random 24)"
  local default_path="/$(gen_random 8 | tr 'A-Z' 'a-z')"
  local default_port=8000

  ADMIN_USER="$(ask "Admin username" "$default_user")"
  ADMIN_PASS="$(ask_secret "Admin password" "$default_pass")"
  PANEL_PATH="$(ask "Panel base path (leading slash)" "$default_path")"
  PANEL_PORT="$(ask "Panel port" "$default_port")"

  # Normalise PANEL_PATH: ensure leading slash, no trailing slash
  PANEL_PATH="/${PANEL_PATH#/}"; PANEL_PATH="${PANEL_PATH%/}"
  [[ "$PANEL_PORT" =~ ^[0-9]+$ ]] || die "Panel port must be numeric."
}

prompt_clients() {
  log "Initial client setup"
  local count
  count="$(ask "How many clients to create?" "1")"
  [[ "$count" =~ ^[0-9]+$ ]] && (( count >= 1 )) || die "Client count must be a positive integer."
  CLIENT_NAMES=()
  for ((i=1; i<=count; i++)); do
    local default_name="user${i}"
    local name
    name="$(ask "Client $i name" "$default_name")"
    [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || die "Client name '$name' invalid (alphanumeric/_/- only)."
    CLIENT_NAMES+=("$name")
  done
}

prompt_ssh_keys() {
  log "SSH key bootstrap"
  echo "  Paste your SSH public key(s), one per line. Press Ctrl-D when done."
  echo "  (Leave empty + Ctrl-D to skip; SSH hardening will then be skipped too.)"
  local pasted
  pasted="$(cat)"
  mkdir -p /root/.ssh && chmod 700 /root/.ssh
  touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
  local added=0
  while IFS= read -r line; do
    [[ -z "${line// }" ]] && continue
    if ! grep -qxF "$line" /root/.ssh/authorized_keys; then
      echo "$line" >> /root/.ssh/authorized_keys
      added=$((added+1))
    fi
  done <<<"$pasted"
  if (( added > 0 )); then
    ok "Added $added new SSH key(s)"
  elif [[ -s /root/.ssh/authorized_keys ]]; then
    ok "authorized_keys already populated; no new keys added"
  else
    warn "No SSH keys provided and authorized_keys is empty."
  fi
}

# ──────────────────────────────────────────────────────────────────────────
# Port checks
# ──────────────────────────────────────────────────────────────────────────
port_in_use() {
  ss -lnt "sport = :$1" 2>/dev/null | tail -n +2 | grep -q .
}

check_ports() {
  log "Checking required ports"
  local taken=()
  port_in_use 443 && taken+=(443)
  port_in_use "$PANEL_PORT" && taken+=("$PANEL_PORT")
  if (( ${#taken[@]} > 0 )); then
    die "Port(s) already in use: ${taken[*]}. Free them or pick a different panel port and re-run."
  fi
  ok "Ports 443 and $PANEL_PORT are free"
}

# ──────────────────────────────────────────────────────────────────────────
# SNI selection
# ──────────────────────────────────────────────────────────────────────────
download_realitlscanner() {
  if [[ ! -x "$REALITLSCANNER_BIN" ]]; then
    log "Downloading RealiTLScanner"
    curl -sfL "$REALITLSCANNER_URL" -o "$REALITLSCANNER_BIN.tmp" \
      || die "Failed to download RealiTLScanner from $REALITLSCANNER_URL"
    chmod +x "$REALITLSCANNER_BIN.tmp"
    mv "$REALITLSCANNER_BIN.tmp" "$REALITLSCANNER_BIN"
    ok "RealiTLScanner installed"
  else
    ok "RealiTLScanner already present"
  fi
}

probe_sni_latency() {
  # Returns RTT in ms (integer) for a TLS 1.3 + h2 handshake to $1:443, or empty on failure.
  local sni="$1"
  local start_ns end_ns
  start_ns=$(date +%s%N)
  if echo | timeout 5 openssl s_client -tls1_3 -alpn h2 -servername "$sni" \
       -connect "${sni}:443" 2>/dev/null | grep -q "Verify return code: 0"; then
    end_ns=$(date +%s%N)
    echo $(( (end_ns - start_ns) / 1000000 ))
  fi
}

select_reality_sni() {
  log "Selecting Reality SNI (this may take ~60s)"
  download_realitlscanner

  local cidr_base
  cidr_base="$(echo "$SERVER_IP" | awk -F. '{printf "%s.%s.%s.0/24", $1,$2,$3}')"
  local scan_out="/tmp/realitlscan-$$.csv"
  log "Scanning neighbor /24: $cidr_base"
  "$REALITLSCANNER_BIN" -addr "$cidr_base" -port 443 -thread 32 -timeout 5 -out "$scan_out" >/dev/null 2>&1 || true

  local -a candidates=()
  if [[ -f "$scan_out" && -s "$scan_out" ]]; then
    # CSV columns: IP,ORIGIN,CERT_DOMAIN,CERT_ISSUER,GEO_CODE
    while IFS=, read -r ip origin cert_domain cert_issuer geo; do
      [[ "$ip" == "IP" ]] && continue   # skip header
      [[ -z "$cert_domain" || "$cert_domain" == "*" ]] && continue
      # Strip wildcard prefix
      local sni="${cert_domain#\*.}"
      # Filter: GEO matches server's country (if known)
      if [[ -n "$SERVER_COUNTRY" && -n "$geo" && "$geo" != "$SERVER_COUNTRY" ]]; then
        continue
      fi
      # Filter: cert issuer must be a major CDN/big-tech
      if ! echo "$cert_issuer" | grep -qiE "$CDN_ISSUERS_REGEX"; then
        continue
      fi
      candidates+=("$sni")
    done < "$scan_out"
    rm -f "$scan_out"
  fi

  if (( ${#candidates[@]} == 0 )); then
    warn "No suitable SNIs found via neighbor scan; falling back to curated CDN list."
    candidates=("${FALLBACK_SNIS[@]}")
  fi

  # Probe each candidate, pick top 5 by latency
  log "Probing candidates for TLS 1.3 + h2 latency"
  local probed=""
  local seen=" "
  for sni in "${candidates[@]}"; do
    [[ "$seen" == *" $sni "* ]] && continue
    seen+=" $sni "
    local rtt
    rtt="$(probe_sni_latency "$sni")"
    [[ -n "$rtt" ]] && probed+="$rtt $sni"$'\n'
  done

  [[ -n "$probed" ]] || die "No candidate SNI handshakes succeeded; check server connectivity."

  local sorted
  sorted="$(echo "$probed" | sort -n | head -n 5)"
  echo
  echo "  Top SNI candidates (latency  domain):"
  local idx=1
  declare -a top_snis=()
  while read -r rtt sni; do
    [[ -z "$sni" ]] && continue
    printf "  ${C_BOLD}%d)${C_RESET} %4d ms  %s\n" "$idx" "$rtt" "$sni"
    top_snis+=("$sni")
    idx=$((idx+1))
  done <<<"$sorted"
  echo

  local choice
  read -rp "  Pick number, or type a custom SNI [1]: " choice
  choice="${choice:-1}"
  if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#top_snis[@]} )); then
    REALITY_SNI="${top_snis[$((choice-1))]}"
  else
    REALITY_SNI="$choice"
  fi
  ok "Selected SNI: $REALITY_SNI"
}

# ──────────────────────────────────────────────────────────────────────────
# Self-signed cert
# ──────────────────────────────────────────────────────────────────────────
generate_self_signed_cert() {
  log "Generating self-signed panel certificate"
  mkdir -p "$CERT_DIR"
  local out
  if ! out="$(openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
        -subj "/CN=${SERVER_IP}" \
        -addext "subjectAltName=IP:${SERVER_IP}" \
        -keyout "$KEY_FILE" -out "$CERT_FILE" 2>&1)"; then
    err "openssl req failed. Output:"
    echo "$out" >&2
    die "Could not generate self-signed certificate at $CERT_FILE"
  fi
  [[ -s "$CERT_FILE" && -s "$KEY_FILE" ]] \
    || die "openssl reported success but cert/key file is empty: $CERT_FILE / $KEY_FILE"
  chmod 600 "$KEY_FILE"
  ok "Cert at $CERT_FILE"
}

# ──────────────────────────────────────────────────────────────────────────
# Marzban install + config
# ──────────────────────────────────────────────────────────────────────────
install_marzban() {
  log "Installing Marzban (this can take a few minutes)"
  # The upstream installer ends with `docker compose logs -f`, which never returns.
  # Stream its output to a file, watch for the startup-complete line, then kill
  # the entire process group (installer + child docker-compose-logs).
  local log_file="/root/${SCRIPT_NAME}-marzban-install.log"
  local installer_src
  installer_src="$(curl -sL https://github.com/Gozargah/Marzban-scripts/raw/master/marzban.sh)"
  [[ -n "$installer_src" ]] || die "Could not fetch Marzban installer."

  : >"$log_file"
  setsid bash -c "$installer_src" @ install >>"$log_file" 2>&1 &
  local pid=$!
  local pgid
  pgid="$(ps -o pgid= "$pid" 2>/dev/null | tr -d ' ')"
  pgid="${pgid:-$pid}"

  local waited=0
  local deadline=600   # 10 minutes; covers slow apt/docker pulls
  while (( waited < deadline )); do
    if grep -q "Application startup complete" "$log_file" 2>/dev/null; then
      ok "Marzban application startup complete"
      kill -TERM "-$pgid" 2>/dev/null || true
      sleep 2
      kill -KILL "-$pgid" 2>/dev/null || true
      break
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      err "Marzban installer exited before startup. Last 30 lines of $log_file:"
      tail -n 30 "$log_file" >&2
      die "See full log at $log_file"
    fi
    sleep 2
    waited=$((waited + 2))
  done

  if (( waited >= deadline )); then
    kill -KILL "-$pgid" 2>/dev/null || true
    err "Timed out waiting for Marzban startup. Last 30 lines of $log_file:"
    tail -n 30 "$log_file" >&2
    die "See full log at $log_file"
  fi

  command -v marzban >/dev/null || die "Marzban CLI not found after install. See $log_file"
  docker ps --format '{{.Names}}' | grep -q '^marzban-marzban-1$' \
    || die "marzban container is not running. See $log_file"
  ok "Marzban installed (full log: $log_file)"
}

write_env() {
  log "Writing /opt/marzban/.env"
  local sub_prefix="https://${SERVER_IP}:${PANEL_PORT}${PANEL_PATH}"
  cat >"$MARZBAN_ENV" <<EOF
# Generated by ${SCRIPT_NAME} on $(date -Iseconds)
SUDO_USERNAME = "${ADMIN_USER}"
SUDO_PASSWORD = "${ADMIN_PASS}"

UVICORN_HOST = "0.0.0.0"
UVICORN_PORT = ${PANEL_PORT}
UVICORN_SSL_CERTFILE = "${CERT_FILE}"
UVICORN_SSL_KEYFILE = "${KEY_FILE}"
UVICORN_SSL_CA_TYPE = "private"

DASHBOARD_PATH = "${PANEL_PATH}/dashboard/"
XRAY_JSON = "${MARZBAN_XRAY_JSON}"
XRAY_SUBSCRIPTION_URL_PREFIX = "${sub_prefix}"

SQLALCHEMY_DATABASE_URL = "sqlite:////var/lib/marzban/db.sqlite3"

# Reality client defaults so subscription generator emits correct vless:// links
EOF
  chmod 600 "$MARZBAN_ENV"
  ok ".env written"
}

generate_reality_keys() {
  log "Generating Reality x25519 keys + short IDs"
  # Xray output format (v24.x):
  #   Private key: <base64>
  #   Public key:  <base64>
  # (older versions emitted "PrivateKey:" / "Password:" — both are tried below.)
  local kp kp_err
  kp_err="$(mktemp)"
  if ! kp="$(docker exec marzban-marzban-1 xray x25519 2>"$kp_err")"; then
    err "docker exec xray x25519 failed. stderr:"
    cat "$kp_err" >&2
    rm -f "$kp_err"
    die "Could not exec xray inside Marzban container (is container running? docker ps)"
  fi
  rm -f "$kp_err"

  REALITY_PRIVATE_KEY="$(echo "$kp" | awk -F': *' '/^(Private key|PrivateKey)/{print $2; exit}')"
  REALITY_PUBLIC_KEY="$(echo "$kp"  | awk -F': *' '/^(Public key|Password)/{print $2; exit}')"
  if [[ -z "$REALITY_PRIVATE_KEY" || -z "$REALITY_PUBLIC_KEY" ]]; then
    err "Could not parse 'xray x25519' output. Raw output was:"
    echo "----- xray x25519 stdout -----" >&2
    echo "$kp" >&2
    echo "------------------------------" >&2
    die "Expected lines starting with 'Private key:' and 'Public key:' (or legacy 'PrivateKey:'/'Password:')"
  fi
  REALITY_SHORT_IDS=()
  for n in 2 4 6 8 10 12 14 16; do
    REALITY_SHORT_IDS+=("$(openssl rand -hex $((n/2)))")
  done
  ok "x25519 keypair generated; 8 short IDs"
}

write_xray_config() {
  log "Writing $MARZBAN_XRAY_JSON"
  local short_ids_json
  short_ids_json="$(printf '"%s",' "${REALITY_SHORT_IDS[@]}")"
  short_ids_json="[${short_ids_json%,}]"

  cat >"$MARZBAN_XRAY_JSON" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "VLESS TCP REALITY",
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${REALITY_SNI}:443",
          "xver": 0,
          "serverNames": ["${REALITY_SNI}"],
          "privateKey": "${REALITY_PRIVATE_KEY}",
          "shortIds": ${short_ids_json}
        }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    }
  ],
  "outbounds": [
    { "tag": "direct",  "protocol": "freedom",   "settings": {} },
    { "tag": "blocked", "protocol": "blackhole", "settings": {} }
  ],
  "routing": {
    "rules": [
      { "type": "field", "outboundTag": "blocked", "ip": ["geoip:private"] },
      { "type": "field", "outboundTag": "blocked", "protocol": ["bittorrent"] }
    ]
  }
}
EOF
  ok "xray_config.json written"
}

restart_marzban_and_wait() {
  log "Restarting Marzban + waiting for API"
  local restart_log="/root/${SCRIPT_NAME}-marzban-restart.log"
  if ! marzban restart >"$restart_log" 2>&1; then
    err "'marzban restart' returned non-zero. Output:"
    tail -n 40 "$restart_log" >&2
    die "Restart failed. Full log: $restart_log"
  fi
  local i last_curl=""
  for i in $(seq 1 30); do
    last_curl="$(curl -sk --max-time 2 -w $'\nHTTP_CODE:%{http_code}\n' \
                  "https://127.0.0.1:${PANEL_PORT}${PANEL_PATH}/api/admin/token" \
                  -d "username=${ADMIN_USER}&password=${ADMIN_PASS}" 2>&1)" || true
    if echo "$last_curl" | grep -q access_token; then
      ok "Marzban API responsive (attempt $i)"
      return 0
    fi
    sleep 2
  done
  err "Marzban API did not respond on https://127.0.0.1:${PANEL_PORT}${PANEL_PATH}/api/admin/token within 60s."
  err "Last curl output:"
  echo "$last_curl" >&2
  err "Tail of 'marzban logs' (last 30 lines):"
  marzban logs 2>&1 | tail -n 30 >&2 || true
  die "API never came up. See above; also check: marzban logs, /opt/marzban/.env, container status (docker ps)"
}

# ──────────────────────────────────────────────────────────────────────────
# Client creation via Marzban HTTP API
# ──────────────────────────────────────────────────────────────────────────
api_token() {
  # Returns the raw JSON response on stdout (caller parses); stderr passes through.
  curl -sk -X POST "https://127.0.0.1:${PANEL_PORT}${PANEL_PATH}/api/admin/token" \
    -d "username=${ADMIN_USER}&password=${ADMIN_PASS}"
}

create_clients() {
  log "Creating ${#CLIENT_NAMES[@]} client(s) via Marzban API"
  local token_resp token
  token_resp="$(api_token)"
  token="$(echo "$token_resp" | jq -r '.access_token // empty' 2>/dev/null)"
  if [[ -z "$token" || "$token" == "null" ]]; then
    err "Could not obtain admin token from https://127.0.0.1:${PANEL_PORT}${PANEL_PATH}/api/admin/token"
    err "Username used: ${ADMIN_USER}"
    err "Raw response from Marzban:"
    echo "$token_resp" >&2
    die "Auth to Marzban API failed. Check ADMIN_USER/ADMIN_PASS in /opt/marzban/.env match what was prompted; check that the panel path '${PANEL_PATH}' matches DASHBOARD_PATH in .env."
  fi

  for name in "${CLIENT_NAMES[@]}"; do
    local body
    body=$(jq -n --arg u "$name" '{
      username: $u,
      proxies: { vless: { flow: "xtls-rprx-vision" } },
      inbounds: { vless: ["VLESS TCP REALITY"] },
      data_limit: 0,
      expire: 0,
      status: "active"
    }')
    local resp
    resp="$(curl -sk -X POST "https://127.0.0.1:${PANEL_PORT}${PANEL_PATH}/api/user" \
              -H "Authorization: Bearer ${token}" \
              -H "Content-Type: application/json" \
              -d "$body")"
    local uuid sub_url
    uuid="$(echo "$resp" | jq -r '.proxies.vless.id // empty')"
    sub_url="$(echo "$resp" | jq -r '.subscription_url // empty')"
    if [[ -z "$uuid" ]]; then
      err "Failed to create '$name'. API response: $resp"; continue
    fi
    CLIENT_UUIDS["$name"]="$uuid"
    # Marzban returns subscription_url as a relative path; prefix with the sub URL host
    if [[ "$sub_url" == /* ]]; then
      sub_url="https://${SERVER_IP}:${PANEL_PORT}${sub_url}"
    fi
    CLIENT_SUB_URLS["$name"]="$sub_url"
    ok "Created client '$name' (uuid=${uuid:0:8}…)"
  done
}

build_vless_url() {
  local name="$1" uuid="$2"
  printf 'vless://%s@%s:443?type=tcp&security=reality&encryption=none&flow=xtls-rprx-vision&sni=%s&fp=chrome&pbk=%s&sid=%s#%s\n' \
    "$uuid" "$SERVER_IP" "$REALITY_SNI" "$REALITY_PUBLIC_KEY" "${REALITY_SHORT_IDS[0]}" "$name"
}

# ──────────────────────────────────────────────────────────────────────────
# Firewall
# ──────────────────────────────────────────────────────────────────────────
detect_ssh_port() {
  local p
  p="$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/{print $2; exit}' /etc/ssh/sshd_config 2>/dev/null)"
  echo "${p:-22}"
}

configure_firewall() {
  log "Configuring firewall"
  local ssh_port; ssh_port="$(detect_ssh_port)"
  if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
    ufw allow "${ssh_port}/tcp" >/dev/null
    ufw allow 443/tcp >/dev/null
    ufw allow "${PANEL_PORT}/tcp" >/dev/null
    ok "UFW already active; allowed ${ssh_port}/443/${PANEL_PORT}"
  elif command -v firewall-cmd >/dev/null && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port="${ssh_port}/tcp" >/dev/null
    firewall-cmd --permanent --add-port=443/tcp >/dev/null
    firewall-cmd --permanent --add-port="${PANEL_PORT}/tcp" >/dev/null
    firewall-cmd --reload >/dev/null
    ok "firewalld: allowed ${ssh_port}/443/${PANEL_PORT}"
  elif command -v nft >/dev/null && nft list ruleset 2>/dev/null | grep -q 'hook input'; then
    warn "nftables rules detected but not modified; please open ${ssh_port}/443/${PANEL_PORT}/tcp manually."
  else
    log "Installing + enabling UFW (no active firewall detected)"
    apt_install ufw
    ufw --force reset >/dev/null
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    ufw allow "${ssh_port}/tcp" >/dev/null
    ufw allow 443/tcp >/dev/null
    ufw allow "${PANEL_PORT}/tcp" >/dev/null
    ufw --force enable >/dev/null
    ok "UFW enabled; allowed ${ssh_port}/443/${PANEL_PORT}"
  fi
}

# ──────────────────────────────────────────────────────────────────────────
# SSH hardening + fail2ban
# ──────────────────────────────────────────────────────────────────────────
harden_ssh() {
  if [[ ! -s /root/.ssh/authorized_keys ]]; then
    warn "authorized_keys is empty — skipping SSH hardening (would lock you out)."
    return 0
  fi
  log "Hardening SSH (disabling password auth)"
  local cfg=/etc/ssh/sshd_config
  cp -a "$cfg" "${cfg}.${SCRIPT_NAME}.bak"
  sed -i \
    -e 's/^[#[:space:]]*PasswordAuthentication.*/PasswordAuthentication no/' \
    -e 's/^[#[:space:]]*PermitRootLogin.*/PermitRootLogin prohibit-password/' \
    -e 's/^[#[:space:]]*ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' \
    "$cfg"
  grep -q '^PasswordAuthentication no' "$cfg" || echo 'PasswordAuthentication no' >> "$cfg"
  systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
  ok "SSH password auth disabled"

  log "Installing fail2ban"
  apt_install fail2ban
  cat >/etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
port    = $(detect_ssh_port)
maxretry = 5
findtime = 600
bantime  = 3600
EOF
  systemctl enable --now fail2ban >/dev/null
  ok "fail2ban active"
}

# ──────────────────────────────────────────────────────────────────────────
# Optional extras (zsh + dotfile niceties + AI CLIs)
# ──────────────────────────────────────────────────────────────────────────
install_extras() {
  log "Installing extras (shell + CLI utilities + AI CLIs)"

  apt_install zsh git tmux vim htop ca-certificates
  # Modern CLI replacements (eza isn't in older repos; skip silently if missing)
  apt_install ripgrep fd-find bat fzf 2>/dev/null || warn "Some modern CLI packages unavailable in this release."
  # Symlink fd → fdfind, bat → batcat (Debian/Ubuntu naming)
  command -v fdfind >/dev/null && ln -sf "$(command -v fdfind)" /usr/local/bin/fd
  command -v batcat >/dev/null && ln -sf "$(command -v batcat)" /usr/local/bin/bat
  ok "Shell + CLI utilities installed"

  if [[ ! -d /root/.oh-my-zsh ]]; then
    RUNZSH=no CHSH=no \
      sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" >/dev/null
    ok "oh-my-zsh installed"
  fi
  chsh -s "$(command -v zsh)" root || true

  # Node via nvm
  if [[ ! -d /root/.nvm ]]; then
    curl -sL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash >/dev/null 2>&1 || true
  fi
  # shellcheck disable=SC1091
  export NVM_DIR="/root/.nvm"; [[ -s "$NVM_DIR/nvm.sh" ]] && . "$NVM_DIR/nvm.sh"
  if command -v nvm >/dev/null; then
    nvm install --lts >/dev/null 2>&1 && nvm use --lts >/dev/null 2>&1
    ok "Node LTS installed via nvm"
  fi

  # AI CLIs
  if command -v npm >/dev/null; then
    npm i -g @openai/codex >/dev/null 2>&1 && ok "Codex CLI installed" || warn "Codex CLI install failed."
  fi
  curl -fsSL https://claude.ai/install.sh | bash >/dev/null 2>&1 \
    && ok "Claude Code installed" || warn "Claude Code install failed."
  curl -fsSL https://gh.io/copilot-install | bash >/dev/null 2>&1 \
    && ok "Copilot CLI installed" || warn "Copilot CLI install failed."
}

# ──────────────────────────────────────────────────────────────────────────
# Output summary
# ──────────────────────────────────────────────────────────────────────────
write_summary() {
  log "Writing summary to ${OUTPUT_FILE}"
  {
    echo "==================================================================="
    echo " ${SCRIPT_NAME} — generated $(date -Iseconds)"
    echo "==================================================================="
    echo
    echo "PANEL"
    echo "  URL:        https://${SERVER_IP}:${PANEL_PORT}${PANEL_PATH}/dashboard/"
    echo "  Username:   ${ADMIN_USER}"
    echo "  Password:   ${ADMIN_PASS}"
    echo "  TLS:        self-signed (browser will warn once)"
    echo
    echo "REALITY"
    echo "  Server IP:  ${SERVER_IP}"
    echo "  Port:       443"
    echo "  SNI / dest: ${REALITY_SNI}"
    echo "  Public key: ${REALITY_PUBLIC_KEY}"
    echo "  Short IDs:  ${REALITY_SHORT_IDS[*]}"
    echo
    echo "CLIENTS"
    for name in "${CLIENT_NAMES[@]}"; do
      local uuid="${CLIENT_UUIDS[$name]:-}"
      local sub="${CLIENT_SUB_URLS[$name]:-}"
      echo "  ── ${name} ──"
      echo "    UUID:   ${uuid}"
      echo "    sub:    ${sub}"
      echo "    vless:  $(build_vless_url "$name" "$uuid")"
      echo
    done
  } | tee "$OUTPUT_FILE"
  chmod 600 "$OUTPUT_FILE"
}

# ──────────────────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────────────────
main() {
  MODE="install"   # default
  preflight
  ensure_base_pkgs

  if detect_existing; then
    handle_existing_install
  fi

  if [[ "$MODE" == "add-clients" ]]; then
    # Read existing settings from .env
    ADMIN_USER="$(grep -E '^SUDO_USERNAME' "$MARZBAN_ENV" | sed -E 's/.*"([^"]+)".*/\1/')"
    ADMIN_PASS="$(grep -E '^SUDO_PASSWORD' "$MARZBAN_ENV" | sed -E 's/.*"([^"]+)".*/\1/')"
    PANEL_PORT="$(grep -E '^UVICORN_PORT' "$MARZBAN_ENV" | sed -E 's/.*=\s*([0-9]+).*/\1/')"
    PANEL_PATH="$(grep -E '^DASHBOARD_PATH' "$MARZBAN_ENV" | sed -E 's|.*"(.*)/dashboard/".*|\1|')"
    SERVER_IP="${SERVER_IP:-$(curl -sf https://ifconfig.co)}"
    # Recover Reality params from xray_config.json for vless:// link printing
    REALITY_SNI="$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$MARZBAN_XRAY_JSON")"
    REALITY_PRIVATE_KEY="$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' "$MARZBAN_XRAY_JSON")"
    REALITY_PUBLIC_KEY="$(docker exec marzban-marzban-1 xray x25519 -i "$REALITY_PRIVATE_KEY" 2>/dev/null \
                            | awk -F': *' '/^(Public key|Password)/{print $2; exit}')"
    [[ -n "$REALITY_PUBLIC_KEY" ]] || die "Failed to derive public key from existing private key (xray x25519 -i produced no parseable output)."
    mapfile -t REALITY_SHORT_IDS < <(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[]' "$MARZBAN_XRAY_JSON")
    prompt_clients
    create_clients
    write_summary
    log "Done. New client info added to ${OUTPUT_FILE}"
    exit 0
  fi

  prompt_panel_settings
  prompt_clients
  prompt_ssh_keys
  check_ports
  select_reality_sni
  generate_self_signed_cert
  install_marzban
  write_env
  generate_reality_keys
  write_xray_config
  restart_marzban_and_wait
  create_clients
  configure_firewall
  harden_ssh
  if ask_yn "Install extras (zsh+omz, vim, tmux, htop, ripgrep/fd/bat/fzf, Node LTS, Codex/Claude/Copilot CLIs)?" "Y"; then
    install_extras
  fi
  write_summary

  log "All done."
  echo
  echo "  ${C_GRN}${C_BOLD}Panel:${C_RESET}    https://${SERVER_IP}:${PANEL_PORT}${PANEL_PATH}/dashboard/"
  echo "  ${C_GRN}${C_BOLD}Output:${C_RESET}   ${OUTPUT_FILE}"
  echo "  ${C_DIM}First panel visit will show a self-signed-cert warning. Click through.${C_RESET}"
}

main "$@"
