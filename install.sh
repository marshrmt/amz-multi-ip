#!/usr/bin/env bash
set -Eeuo pipefail

PROTO="xray"
IPS_CSV=""
SNI="video.yahoo.com"
PRUNE="0"

BASE_DIR="/root/amz-multi"
OUT_DIR="${BASE_DIR}/out"
STATE_DIR="${BASE_DIR}/state"
STATE_FILE="${STATE_DIR}/installed.json"

XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_DIR="/usr/local/etc/xray"
XRAY_SERVICE="xray"

usage() {
  cat <<'EOF'
Usage:
  bash install.sh --ips 1.2.3.4,1.2.3.5
  bash install.sh --proto xray --ips 1.2.3.4,1.2.3.5 [--sni video.yahoo.com] [--prune]

Args:
  --proto   only xray is supported in this script
  --ips     comma-separated public IPv4 list
  --sni     Xray Reality SNI/domain (default: video.yahoo.com)
  --prune   remove configs for IPs missing from current list
EOF
}

log() { echo -e "\033[1;32m[+]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
err() { echo -e "\033[1;31m[-]\033[0m $*" >&2; exit 1; }

require_root() {
  [[ $EUID -eq 0 ]] || err "Run as root."
}

rand_port() {
  shuf -i 47000-49000 -n 1
}

rand_hex() {
  local n="${1:-8}"
  openssl rand -hex "$n"
}

rand_uuid() {
  cat /proc/sys/kernel/random/uuid
}

detect_nic() {
  ip route get 1.1.1.1 2>/dev/null | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

ensure_pkgs() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y \
    curl wget jq iptables iptables-persistent ca-certificates \
    openssl uuid-runtime unzip tar perl qrencode netcat-openbsd
}

make_dirs() {
  mkdir -p "$BASE_DIR" "$OUT_DIR" "$STATE_DIR"
  chmod 700 "$BASE_DIR" "$OUT_DIR" "$STATE_DIR" || true
}

init_state() {
  if [[ ! -f "$STATE_FILE" ]]; then
    cat >"$STATE_FILE" <<'EOF'
{
  "xray": {
    "private_key": "",
    "public_key": "",
    "clients": {}
  }
}
EOF
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --proto) PROTO="${2:-}"; shift 2 ;;
      --ips) IPS_CSV="${2:-}"; shift 2 ;;
      --sni) SNI="${2:-}"; shift 2 ;;
      --prune) PRUNE="1"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) err "Unknown arg: $1" ;;
    esac
  done

  [[ "$PROTO" == "xray" ]] || err "This script supports only --proto xray"
  [[ -n "$IPS_CSV" ]] || err "--ips is required"
}

split_ips() {
  IFS=',' read -r -a IPS_RAW <<<"$IPS_CSV"
  [[ ${#IPS_RAW[@]} -gt 0 ]] || err "No IPs parsed from --ips"

  IPS=()
  declare -A seen=()
  local ip
  for ip in "${IPS_RAW[@]}"; do
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || err "Bad IPv4: $ip"
    if [[ -z "${seen[$ip]+x}" ]]; then
      IPS+=("$ip")
      seen["$ip"]=1
    fi
  done
}

persist_sysctl_basic() {
  cat >/etc/sysctl.d/99-amz-multi.conf <<'EOF'
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
EOF
  sysctl --system >/dev/null
}

ensure_ip_aliases() {
  local nic="$1"; shift
  local ip
  for ip in "$@"; do
    if ! ip -4 addr show dev "$nic" | grep -qw "$ip"; then
      log "Adding $ip to $nic"
      ip addr add "${ip}/32" dev "$nic" || true
    fi
  done
}

remove_ip_alias() {
  local nic="$1"
  local ip="$2"
  if ip -4 addr show dev "$nic" | grep -qw "$ip"; then
    ip addr del "${ip}/32" dev "$nic" || true
  fi
}

save_iptables() {
  netfilter-persistent save >/dev/null 2>&1 || iptables-save >/etc/iptables/rules.v4
}

port_is_in_use_anywhere() {
  local port="$1"
  ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)$port$"
}

port_is_in_state() {
  local port="$1"
  jq -e --argjson p "$port" '.xray.clients | to_entries[]? | select(.value.port == $p)' "$STATE_FILE" >/dev/null
}

ensure_xray_installed() {
  if command -v xray >/dev/null 2>&1; then
    log "xray already installed"
    return
  fi
  log "Installing Xray"
  bash <(curl -Ls https://github.com/XTLS/Xray-install/raw/main/install-release.sh) install
}

ensure_xray_keys() {
  local priv pub out tmp

  priv="$(jq -r '.xray.private_key // ""' "$STATE_FILE")"
  pub="$(jq -r '.xray.public_key // ""' "$STATE_FILE")"

  if [[ -n "$priv" && -n "$pub" ]]; then
    return
  fi

  out="$(xray x25519 2>/dev/null || true)"

  priv="$(printf '%s\n' "$out" | sed -n 's/^PrivateKey: *//p' | head -n1 | tr -d '\r')"
  pub="$(printf '%s\n' "$out" | sed -n 's/^Password (PublicKey): *//p' | head -n1 | tr -d '\r')"

  [[ -n "$priv" && -n "$pub" ]] || err "Failed to parse xray x25519 output. Raw output was: $out"

  tmp="$(mktemp)"
  jq --arg priv "$priv" --arg pub "$pub" \
     '.xray.private_key=$priv | .xray.public_key=$pub' \
     "$STATE_FILE" > "$tmp"
  mv "$tmp" "$STATE_FILE"
}

xray_has_ip() {
  local ip="$1"
  jq -e --arg ip "$ip" '.xray.clients[$ip] != null' "$STATE_FILE" >/dev/null
}

write_vless_file() {
  local ip="$1"
  local name url
  name="$(jq -r --arg ip "$ip" '.xray.clients[$ip].name' "$STATE_FILE")"
  url="$(jq -r --arg ip "$ip" '.xray.clients[$ip].url' "$STATE_FILE")"
  printf '%s\n' "$url" > "${OUT_DIR}/${name}.vless.txt"
}

choose_random_port() {
  local port tries=0
  while :; do
    port="$(rand_port)"
    if ! port_is_in_use_anywhere "$port" && ! port_is_in_state "$port"; then
      printf '%s\n' "$port"
      return
    fi
    tries=$((tries + 1))
    [[ "$tries" -lt 5000 ]] || err "Could not find a free port in 47000-49000"
  done
}

xray_add_ip() {
  local ip="$1"
  local port uuid sid name url pub tmp

  port="$(choose_random_port)"
  uuid="$(rand_uuid)"
  sid="$(rand_hex 4)"
  name="xray-${ip//./-}"
  pub="$(jq -r '.xray.public_key' "$STATE_FILE")"

  url="vless://${uuid}@${ip}:${port}?encryption=none&type=tcp&security=reality&pbk=${pub}&fp=chrome&sni=${SNI}&sid=${sid}&flow=xtls-rprx-vision#${name}"

  tmp="$(mktemp)"
  jq --arg ip "$ip" \
     --arg name "$name" \
     --arg uuid "$uuid" \
     --arg sid "$sid" \
     --arg sni "$SNI" \
     --arg url "$url" \
     --argjson port "$port" \
     '
     .xray.clients[$ip] = {
       "name": $name,
       "port": $port,
       "uuid": $uuid,
       "short_id": $sid,
       "sni": $sni,
       "url": $url
     }' \
     "$STATE_FILE" > "$tmp"
  mv "$tmp" "$STATE_FILE"

  write_vless_file "$ip"
  log "Added Xray client for ${ip}"
}

xray_remove_ip() {
  local ip="$1"
  local name port tmp

  name="$(jq -r --arg ip "$ip" '.xray.clients[$ip].name // ""' "$STATE_FILE")"
  port="$(jq -r --arg ip "$ip" '.xray.clients[$ip].port // empty' "$STATE_FILE")"

  [[ -n "$name" ]] && rm -f "${OUT_DIR}/${name}.vless.txt"

  if [[ -n "${port:-}" ]]; then
    iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null && iptables -D INPUT -p tcp --dport "$port" -j ACCEPT || true
  fi

  tmp="$(mktemp)"
  jq --arg ip "$ip" 'del(.xray.clients[$ip])' "$STATE_FILE" > "$tmp"
  mv "$tmp" "$STATE_FILE"

  log "Removed Xray client for ${ip}"
}

build_xray_config() {
  local tmp priv

  priv="$(jq -r '.xray.private_key // ""' "$STATE_FILE")"
  [[ -n "$priv" ]] || err "xray.private_key is empty in $STATE_FILE"

  tmp="$(mktemp)"

  jq -n --arg priv "$priv" --slurpfile st "$STATE_FILE" '
    ($st[0].xray.clients // {}) as $clients
    | {
        log: {
          loglevel: "warning"
        },
        inbounds: (
          $clients
          | to_entries
          | sort_by(.key)
          | map({
              tag: ("in_" + (.key | gsub("\\."; "_"))),
              listen: .key,
              port: .value.port,
              protocol: "vless",
              settings: {
                clients: [
                  {
                    id: .value.uuid,
                    flow: "xtls-rprx-vision"
                  }
                ],
                decryption: "none"
              },
              streamSettings: {
                network: "tcp",
                security: "reality",
                realitySettings: {
                  show: false,
                  dest: (.value.sni + ":443"),
                  xver: 0,
                  serverNames: [ .value.sni ],
                  privateKey: $priv,
                  shortIds: [ .value.short_id ]
                }
              },
              sniffing: {
                enabled: true,
                destOverride: ["http", "tls", "quic"]
              }
            })
        ),
        outbounds: (
          $clients
          | to_entries
          | sort_by(.key)
          | map({
              tag: ("out_" + (.key | gsub("\\."; "_"))),
              protocol: "freedom",
              settings: {},
              sendThrough: .key
            })
        ),
        routing: {
          domainStrategy: "AsIs",
          rules: (
            $clients
            | to_entries
            | sort_by(.key)
            | map({
                type: "field",
                inboundTag: [("in_" + (.key | gsub("\\."; "_")))],
                outboundTag: ("out_" + (.key | gsub("\\."; "_")))
              })
          )
        }
      }
  ' > "$tmp"

  mv "$tmp" "$XRAY_CONFIG"
  chown root:root "$XRAY_CONFIG"
  chmod 755 "$XRAY_DIR"
  chmod 644 "$XRAY_CONFIG"
}

enable_xray() {
  systemctl daemon-reload
  systemctl enable --now "$XRAY_SERVICE" >/dev/null 2>&1 || true
}

xray_sync_firewall() {
  local port
  while IFS= read -r port; do
    [[ -z "$port" ]] && continue
    iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport "$port" -j ACCEPT
  done < <(jq -r '.xray.clients | to_entries[]? | .value.port' "$STATE_FILE" | sort -n)

  save_iptables
}

list_missing_ports() {
  local missing=()
  local port
  while IFS= read -r port; do
    [[ -z "$port" ]] && continue
    if ! ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)$port$"; then
      missing+=("$port")
    fi
  done < <(jq -r '.xray.clients | to_entries[]? | .value.port' "$STATE_FILE" | sort -n)

  (IFS=,; printf '%s' "${missing[*]-}")
}

ensure_ports_listening() {
  local attempt missing
  for attempt in 1 2 3; do
    enable_xray
    systemctl restart "$XRAY_SERVICE" >/dev/null 2>&1 || true
    sleep 1

    if ! systemctl is-active --quiet "$XRAY_SERVICE"; then
      warn "Xray restart attempt ${attempt} failed, trying remediation"
      chmod 755 "$XRAY_DIR" || true
      chmod 644 "$XRAY_CONFIG" || true
      build_xray_config
      continue
    fi

    missing="$(list_missing_ports)"
    if [[ -z "$missing" ]]; then
      return 0
    fi

    warn "After restart attempt ${attempt}, ports not listening: $missing"
    chmod 755 "$XRAY_DIR" || true
    chmod 644 "$XRAY_CONFIG" || true
    build_xray_config
    xray_sync_firewall
  done

  systemctl status "$XRAY_SERVICE" --no-pager -l || true
  journalctl -u "$XRAY_SERVICE" -n 100 --no-pager || true
  err "Xray did not start correctly or ports are not listening. Missing ports: $(list_missing_ports)"
}

write_xray_summary() {
  : > "${OUT_DIR}/xray-clients.txt"
  jq -r '
    .xray.clients
    | to_entries
    | sort_by(.key)
    | .[]
    | .key, .value.url, "==="
  ' "$STATE_FILE" >> "${OUT_DIR}/xray-clients.txt"

  perl -0pi -e 's/\n===\n?\z/\n/s' "${OUT_DIR}/xray-clients.txt"
}

print_console_configs() {
  jq -r '
    .xray.clients
    | to_entries
    | sort_by(.key)
    | .[]
    | .key, .value.url, "==="
  ' "$STATE_FILE"
}

sync_xray() {
  local ip wanted keep

  ensure_xray_installed
  ensure_xray_keys

  for ip in "${IPS[@]}"; do
    if xray_has_ip "$ip"; then
      log "Xray already exists for ${ip}, skipping"
      write_vless_file "$ip"
    else
      xray_add_ip "$ip"
    fi
  done

  if [[ "$PRUNE" == "1" ]]; then
    while IFS= read -r ip; do
      [[ -z "$ip" ]] && continue
      keep=0
      for wanted in "${IPS[@]}"; do
        if [[ "$wanted" == "$ip" ]]; then
          keep=1
          break
        fi
      done

      if [[ "$keep" -eq 0 ]]; then
        xray_remove_ip "$ip"
      fi
    done < <(jq -r '.xray.clients | keys[]?' "$STATE_FILE")
  fi

  build_xray_config
  xray_sync_firewall
  ensure_ports_listening
  write_xray_summary

  log "Done."
}

main() {
  require_root
  parse_args "$@"
  split_ips
  make_dirs
  init_state
  ensure_pkgs

  local nic
  nic="$(detect_nic)"
  [[ -n "$nic" ]] || err "Could not detect WAN interface"

  persist_sysctl_basic
  ensure_ip_aliases "$nic" "${IPS[@]}"
  sync_xray

  echo
  print_console_configs
}

main "$@"