#!/usr/bin/env bash
set -Eeuo pipefail

PROTO=""
IPS_CSV=""
SNI="video.yahoo.com"
XRAY_FLOW="xtls-rprx-vision"
OUT_DIR="/root/amz-multi/out"
STATE_DIR="/root/amz-multi/state"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_SERVICE="xray"
AWG_BRANCH="main"

usage() {
  cat <<'EOF'
Usage:
  bash install.sh --proto awg --ips 1.2.3.4,1.2.3.5
  bash install.sh --proto xray --ips 1.2.3.4,1.2.3.5 [--sni video.yahoo.com]

Args:
  --proto   awg | xray
  --ips     comma-separated public IPv4 list
  --sni     Xray Reality SNI/domain (default: video.yahoo.com)
EOF
}

log() { echo -e "\033[1;32m[+]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*" >&2; }
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
    openssl uuid-runtime unzip tar perl qrencode
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

persist_sysctl_basic() {
  cat >/etc/sysctl.d/99-amz-multi.conf <<'EOF'
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
EOF
  sysctl --system >/dev/null
}

save_iptables() {
  netfilter-persistent save >/dev/null 2>&1 || iptables-save >/etc/iptables/rules.v4
}

make_dirs() {
  mkdir -p "$OUT_DIR" "$STATE_DIR"
  chmod 700 /root/amz-multi "$OUT_DIR" "$STATE_DIR" || true
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --proto) PROTO="${2:-}"; shift 2 ;;
      --ips) IPS_CSV="${2:-}"; shift 2 ;;
      --sni) SNI="${2:-}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) err "Unknown arg: $1" ;;
    esac
  done

  [[ -n "$PROTO" ]] || err "--proto is required"
  [[ "$PROTO" == "awg" || "$PROTO" == "xray" ]] || err "--proto must be awg or xray"
  [[ -n "$IPS_CSV" ]] || err "--ips is required"
}

split_ips() {
  IFS=',' read -r -a IPS <<<"$IPS_CSV"
  [[ ${#IPS[@]} -gt 0 ]] || err "No IPs parsed from --ips"
  for ip in "${IPS[@]}"; do
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || err "Bad IPv4: $ip"
  done
}

ensure_xray_installed() {
  if command -v xray >/dev/null 2>&1; then
    log "xray already installed"
    return
  fi
  log "Installing Xray"
  bash <(curl -Ls https://github.com/XTLS/Xray-install/raw/main/install-release.sh) install
}

build_xray_config() {
  local nic="$1"
  local public_key private_key
  local x25519_out

  mkdir -p /usr/local/etc/xray
  x25519_out="$(xray x25519)"
  private_key="$(awk '/Private key:/ {print $3}' <<<"$x25519_out")"
  public_key="$(awk '/Public key:/ {print $3}' <<<"$x25519_out")"

  local config_tmp
  config_tmp="$(mktemp)"

  cat >"$config_tmp" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
EOF

  local i=0
  : >"${OUT_DIR}/xray-clients.txt"

  for ip in "${IPS[@]}"; do
    local port uuid sid tag_in tag_out link
    port="$(rand_port)"
    uuid="$(rand_uuid)"
    sid="$(rand_hex 4)"
    tag_in="in_$((i+1))"
    tag_out="out_$((i+1))"

    cat >>"$config_tmp" <<EOF
    {
      "tag": "$tag_in",
      "listen": "$ip",
      "port": $port,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$uuid",
            "flow": "$XRAY_FLOW"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${SNI}:443",
          "xver": 0,
          "serverNames": ["${SNI}"],
          "privateKey": "$private_key",
          "shortIds": ["$sid"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }$( [[ $i -lt $((${#IPS[@]}-1)) ]] && echo "," )
EOF

    link="vless://${uuid}@${ip}:${port}?type=tcp&security=reality&pbk=${public_key}&fp=chrome&sni=${SNI}&sid=${sid}&spx=%2F&flow=${XRAY_FLOW}#xray-${ip//./-}"
    {
      echo "NAME=xray-${ip//./-}"
      echo "PUBLIC_IP=$ip"
      echo "PORT=$port"
      echo "UUID=$uuid"
      echo "PUBLIC_KEY=$public_key"
      echo "SHORT_ID=$sid"
      echo "SNI=$SNI"
      echo "URL=$link"
      echo
    } >> "${OUT_DIR}/xray-clients.txt"
    echo "$link" > "${OUT_DIR}/xray-${ip//./-}.vless.txt"
    ((i+=1))
  done

  cat >>"$config_tmp" <<'EOF'
  ],
  "outbounds": [
EOF

  i=0
  for ip in "${IPS[@]}"; do
    cat >>"$config_tmp" <<EOF
    {
      "tag": "out_$((i+1))",
      "protocol": "freedom",
      "settings": {},
      "sendThrough": "$ip"
    }$( [[ $i -lt $((${#IPS[@]}-1)) ]] && echo "," )
EOF
    ((i+=1))
  done

  cat >>"$config_tmp" <<'EOF'
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
EOF

  i=0
  for ip in "${IPS[@]}"; do
    cat >>"$config_tmp" <<EOF
      {
        "type": "field",
        "inboundTag": ["in_$((i+1))"],
        "outboundTag": "out_$((i+1))"
      }$( [[ $i -lt $((${#IPS[@]}-1)) ]] && echo "," )
EOF
    ((i+=1))
  done

  cat >>"$config_tmp" <<'EOF'
    ]
  }
}
EOF

  mv "$config_tmp" "$XRAY_CONFIG"
  chmod 600 "$XRAY_CONFIG"
}

enable_xray() {
  systemctl daemon-reload
  systemctl enable --now "$XRAY_SERVICE"
  systemctl restart "$XRAY_SERVICE"
  systemctl --no-pager --full status "$XRAY_SERVICE" | sed -n '1,15p' || true
}

open_xray_ports() {
  local ip line port
  while IFS= read -r line; do
    [[ "$line" == PORT=* ]] || continue
    port="${line#PORT=}"
    iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport "$port" -j ACCEPT
  done < "${OUT_DIR}/xray-clients.txt"
  save_iptables
}

install_awg_base() {
  if [[ -x /root/awg/manage_amneziawg.sh ]]; then
    log "AWG installer already present"
    return
  fi

  log "Installing AWG 2.0 base via bivlked installer"
  cd /root
  rm -f install_amneziawg_en.sh
  wget -O /root/install_amneziawg_en.sh "https://raw.githubusercontent.com/bivlked/amneziawg-installer/${AWG_BRANCH}/install_amneziawg_en.sh"
  chmod +x /root/install_amneziawg_en.sh

  # One-shot best effort. Upstream installer may reboot/resume.
  bash /root/install_amneziawg_en.sh --yes --route-all || true

  [[ -x /root/awg/manage_amneziawg.sh ]] || err "AWG base install did not finish. If the server rebooted during upstream install, run the same curl command once more."
}

get_awg_port() {
  awk -F= '/^export AWG_PORT=/{gsub(/'\''|"/,"",$2); print $2}' /root/awg/awgsetup_cfg.init | tail -n1
}

add_awg_clients() {
  local i=1
  for ip in "${IPS[@]}"; do
    local name="awg-${ip//./-}"
    log "Creating AWG client $name"
    bash /root/awg/manage_amneziawg.sh add "$name"
    ((i+=1))
  done
}

set_awg_endpoints() {
  local port="$1"
  for ip in "${IPS[@]}"; do
    local name="awg-${ip//./-}"
    bash /root/awg/manage_amneziawg.sh modify "$name" Endpoint "${ip}:${port}"
  done
}

collect_awg_client_ips() {
  bash /root/awg/manage_amneziawg.sh stats --json > "${STATE_DIR}/awg-stats.json"
}

apply_awg_snat() {
  local nic="$1"
  jq -r '.[] | [.name,.ip] | @tsv' "${STATE_DIR}/awg-stats.json" | while IFS=$'\t' read -r name vpn_ip; do
    [[ -n "$name" && -n "$vpn_ip" && "$vpn_ip" != "null" ]] || continue
    local public_ip="${name#awg-}"
    public_ip="${public_ip//-/.}"

    iptables -t nat -C POSTROUTING -s "${vpn_ip}/32" -o "$nic" -j SNAT --to-source "$public_ip" 2>/dev/null \
      || iptables -t nat -A POSTROUTING -s "${vpn_ip}/32" -o "$nic" -j SNAT --to-source "$public_ip"
  done
  save_iptables
}

collect_awg_outputs() {
  : > "${OUT_DIR}/awg-clients.txt"
  for ip in "${IPS[@]}"; do
    local name="awg-${ip//./-}"
    local conf vpnuri
    conf="$(find /root/awg -maxdepth 3 -type f -name "${name}.conf" | head -n1 || true)"
    vpnuri="/root/awg/${name}.vpnuri"

    {
      echo "NAME=${name}"
      echo "PUBLIC_IP=${ip}"
      [[ -n "$conf" ]] && echo "CONF_PATH=${conf}"
      [[ -f "$vpnuri" ]] && echo "VPNURI_PATH=${vpnuri}"
      if [[ -f "$vpnuri" ]]; then
        echo "VPNURI=$(cat "$vpnuri")"
      fi
      echo
    } >> "${OUT_DIR}/awg-clients.txt"
  done
}

run_xray() {
  local nic="$1"
  ensure_xray_installed
  build_xray_config "$nic"
  enable_xray
  open_xray_ports

  log "Done. Files:"
  log "  ${OUT_DIR}/xray-clients.txt"
  for ip in "${IPS[@]}"; do
    log "  ${OUT_DIR}/xray-${ip//./-}.vless.txt"
  done

  echo
  echo "===== Xray import keys ====="
  cat "${OUT_DIR}/xray-clients.txt"
}

run_awg() {
  local nic="$1"
  install_awg_base

  local awg_port
  awg_port="$(get_awg_port)"
  [[ -n "$awg_port" ]] || err "Could not detect AWG port"

  add_awg_clients
  set_awg_endpoints "$awg_port"
  collect_awg_client_ips
  apply_awg_snat "$nic"
  collect_awg_outputs

  log "Done. Files:"
  log "  ${OUT_DIR}/awg-clients.txt"

  echo
  echo "===== AWG import info ====="
  cat "${OUT_DIR}/awg-clients.txt"
}

main() {
  require_root
  parse_args "$@"
  split_ips
  make_dirs
  ensure_pkgs

  local nic
  nic="$(detect_nic)"
  [[ -n "$nic" ]] || err "Could not detect WAN interface"

  persist_sysctl_basic
  ensure_ip_aliases "$nic" "${IPS[@]}"

  if [[ "$PROTO" == "xray" ]]; then
    run_xray "$nic"
  else
    run_awg "$nic"
  fi
}

main "$@"