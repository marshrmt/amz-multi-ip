#!/usr/bin/env bash
set -Eeuo pipefail

PROTO=""
IPS_CSV=""
SNI="video.yahoo.com"
PRUNE="0"

BASE_DIR="/root/amz-multi"
OUT_DIR="${BASE_DIR}/out"
STATE_DIR="${BASE_DIR}/state"
STATE_FILE="${STATE_DIR}/installed.json"

XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_SERVICE="xray"

AWG_BRANCH="main"

usage() {
  cat <<'EOF'
Usage:
  bash install.sh --proto xray --ips 1.2.3.4,1.2.3.5
  bash install.sh --proto awg --ips 1.2.3.4,1.2.3.5 [--prune]

Args:
  --proto   awg | xray
  --ips     comma-separated public IPv4 list
  --sni     Xray Reality SNI/domain (default: video.yahoo.com)
  --prune   remove configs for IPs missing from current list
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

make_dirs() {
  mkdir -p "$BASE_DIR" "$OUT_DIR" "$STATE_DIR"
  chmod 700 "$BASE_DIR" "$OUT_DIR" "$STATE_DIR" || true
}

init_state() {
  if [[ ! -f "$STATE_FILE" ]]; then
    cat >"$STATE_FILE" <<EOF
{
  "proto": "",
  "xray": {
    "private_key": "",
    "public_key": "",
    "clients": {}
  },
  "awg": {
    "port": "",
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
      --prune) PRUNE="1"; shift 1 ;;
      -h|--help) usage; exit 0 ;;
      *) err "Unknown arg: $1" ;;
    esac
  done

  [[ -n "$PROTO" ]] || err "--proto is required"
  [[ "$PROTO" == "awg" || "$PROTO" == "xray" ]] || err "--proto must be awg or xray"
  [[ -n "$IPS_CSV" ]] || err "--ips is required"
}

split_ips() {
  IFS=',' read -r -a IPS_RAW <<<"$IPS_CSV"
  [[ ${#IPS_RAW[@]} -gt 0 ]] || err "No IPs parsed from --ips"

  IPS=()
  declare -A seen=()
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

state_proto() {
  jq -r '.proto // ""' "$STATE_FILE"
}

set_state_proto() {
  local proto="$1"
  tmp="$(mktemp)"
  jq --arg p "$proto" '.proto = $p' "$STATE_FILE" > "$tmp"
  mv "$tmp" "$STATE_FILE"
}

ensure_same_proto_or_empty() {
  local current
  current="$(state_proto)"
  if [[ -n "$current" && "$current" != "$PROTO" ]]; then
    err "State already initialized for proto '$current'. Use a separate server or wipe ${BASE_DIR} first."
  fi
  if [[ -z "$current" ]]; then
    set_state_proto "$PROTO"
  fi
}

json_array_from_ips() {
  printf '%s\n' "${IPS[@]}" | jq -R . | jq -s .
}

########################################
# XRAY
########################################

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

  priv="$(printf '%s\n' "$out" | sed -n 's/.*Private key: *//p' | head -n1 | tr -d '\r')"
  pub="$(printf '%s\n' "$out" | sed -n 's/.*Public key: *//p' | head -n1 | tr -d '\r')"

  if [[ -z "$priv" || -z "$pub" ]]; then
    err "Failed to parse xray x25519 output. Raw output was: $out"
  fi

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

xray_add_ip() {
  local ip="$1"
  local port uuid sid name url pub tmp

  port="$(rand_port)"
  while jq -e --argjson p "$port" '.xray.clients | to_entries[]? | select(.value.port == $p)' "$STATE_FILE" >/dev/null; do
    port="$(rand_port)"
  done

  uuid="$(rand_uuid)"
  sid="$(rand_hex 4)"
  name="xray-${ip//./-}"
  pub="$(jq -r '.xray.public_key' "$STATE_FILE")"

  url="vless://${uuid}@${ip}:${port}?type=tcp&security=reality&pbk=${pub}&fp=chrome&sni=${SNI}&sid=${sid}&spx=%2F&flow=xtls-rprx-vision#${name}"

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

  echo "$url" > "${OUT_DIR}/${name}.vless.txt"
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
  local priv
  priv="$(jq -r '.xray.private_key' "$STATE_FILE")"

  mkdir -p /usr/local/etc/xray
  local cfg
  cfg="$(mktemp)"

  {
    echo '{'
    echo '  "log": {"loglevel": "warning"},'
    echo '  "inbounds": ['
  } > "$cfg"

  local count=0 total
  total="$(jq '.xray.clients | length' "$STATE_FILE")"

  jq -r '
    .xray.clients
    | to_entries
    | sort_by(.key)
    | .[]
    | @base64
  ' "$STATE_FILE" | while IFS= read -r row; do
    local entry ip port uuid sid
    entry="$(echo "$row" | base64 -d)"
    ip="$(jq -r '.key' <<<"$entry")"
    port="$(jq -r '.value.port' <<<"$entry")"
    uuid="$(jq -r '.value.uuid' <<<"$entry")"
    sid="$(jq -r '.value.short_id' <<<"$entry")"

    cat >> "$cfg" <<EOF
    {
      "tag": "in_${ip//./_}",
      "listen": "$ip",
      "port": $port,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$uuid",
            "flow": "xtls-rprx-vision"
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
          "privateKey": "$priv",
          "shortIds": ["$sid"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
EOF
    count=$((count+1))
    [[ "$count" -lt "$total" ]] && echo "    ," >> "$cfg"
  done

  {
    echo '  ],'
    echo '  "outbounds": ['
  } >> "$cfg"

  count=0
  jq -r '
    .xray.clients
    | to_entries
    | sort_by(.key)
    | .[]
    | @base64
  ' "$STATE_FILE" | while IFS= read -r row; do
    local entry ip
    entry="$(echo "$row" | base64 -d)"
    ip="$(jq -r '.key' <<<"$entry")"
    cat >> "$cfg" <<EOF
    {
      "tag": "out_${ip//./_}",
      "protocol": "freedom",
      "settings": {},
      "sendThrough": "$ip"
    }
EOF
    count=$((count+1))
    [[ "$count" -lt "$total" ]] && echo "    ," >> "$cfg"
  done

  {
    echo '  ],'
    echo '  "routing": {'
    echo '    "domainStrategy": "AsIs",'
    echo '    "rules": ['
  } >> "$cfg"

  count=0
  jq -r '
    .xray.clients
    | to_entries
    | sort_by(.key)
    | .[]
    | @base64
  ' "$STATE_FILE" | while IFS= read -r row; do
    local entry ip
    entry="$(echo "$row" | base64 -d)"
    ip="$(jq -r '.key' <<<"$entry")"
    cat >> "$cfg" <<EOF
      {
        "type": "field",
        "inboundTag": ["in_${ip//./_}"],
        "outboundTag": "out_${ip//./_}"
      }
EOF
    count=$((count+1))
    [[ "$count" -lt "$total" ]] && echo "      ," >> "$cfg"
  done

  {
    echo '    ]'
    echo '  }'
    echo '}'
  } >> "$cfg"

  mv "$cfg" "$XRAY_CONFIG"
  chmod 600 "$XRAY_CONFIG"
}

enable_xray() {
  systemctl daemon-reload
  systemctl enable --now "$XRAY_SERVICE"
  systemctl restart "$XRAY_SERVICE"
}

xray_sync_firewall() {
  local desired_ports current_ports port
  desired_ports="$(jq -r '.xray.clients | to_entries[]? | .value.port' "$STATE_FILE" | sort -n || true)"
  current_ports="$(iptables -S INPUT | sed -n 's/^-A INPUT -p tcp -m tcp --dport \([0-9]\+\) -j ACCEPT$/\1/p' | sort -n || true)"

  while IFS= read -r port; do
    [[ -z "$port" ]] && continue
    iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport "$port" -j ACCEPT
  done <<< "$desired_ports"

  save_iptables
}

write_xray_summary() {
  : > "${OUT_DIR}/xray-clients.txt"
  jq -r '
    .xray.public_key as $pk
    | .xray.clients
    | to_entries
    | sort_by(.key)
    | .[]
    | [
        "NAME=" + .value.name,
        "PUBLIC_IP=" + .key,
        "PORT=" + (.value.port|tostring),
        "UUID=" + .value.uuid,
        "PUBLIC_KEY=" + $pk,
        "SHORT_ID=" + .value.short_id,
        "SNI=" + .value.sni,
        "URL=" + .value.url,
        ""
      ] | .[]
  ' "$STATE_FILE" >> "${OUT_DIR}/xray-clients.txt"
}

sync_xray() {
  local desired_json existing_json ip
  ensure_xray_installed
  ensure_xray_keys

  desired_json="$(json_array_from_ips)"
  existing_json="$(jq '.xray.clients | keys' "$STATE_FILE")"

  for ip in "${IPS[@]}"; do
    if xray_has_ip "$ip"; then
      log "Xray already exists for ${ip}, skipping"
    else
      xray_add_ip "$ip"
    fi
  done

  if [[ "$PRUNE" == "1" ]]; then
    jq -r '.xray.clients | keys[]?' "$STATE_FILE" | while IFS= read -r ip; do
      if ! jq -e --arg ip "$ip" '$ARGS.positional | index($ip)' --args "${IPS[@]}" >/dev/null; then
        xray_remove_ip "$ip"
      fi
    done
  fi

  build_xray_config
  xray_sync_firewall
  enable_xray
  write_xray_summary

  log "Done. Files:"
  log "  ${OUT_DIR}/xray-clients.txt"
  jq -r '.xray.clients | to_entries[]? | .value.name' "$STATE_FILE" | while IFS= read -r name; do
    [[ -n "$name" ]] && log "  ${OUT_DIR}/${name}.vless.txt"
  done

  echo
  echo "===== Xray import keys ====="
  cat "${OUT_DIR}/xray-clients.txt"
}

########################################
# AWG
########################################

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
  bash /root/install_amneziawg_en.sh --yes --route-all || true

  [[ -x /root/awg/manage_amneziawg.sh ]] || err "AWG base install did not finish. If upstream rebooted the server during install, run the same command once more."
}

get_awg_port() {
  awk -F= '/^export AWG_PORT=/{gsub(/'\''|"/,"",$2); print $2}' /root/awg/awgsetup_cfg.init | tail -n1
}

ensure_awg_port_saved() {
  local port tmp
  port="$(jq -r '.awg.port // ""' "$STATE_FILE")"
  if [[ -n "$port" ]]; then
    return
  fi

  port="$(get_awg_port)"
  [[ -n "$port" ]] || err "Could not detect AWG port"

  tmp="$(mktemp)"
  jq --arg p "$port" '.awg.port = $p' "$STATE_FILE" > "$tmp"
  mv "$tmp" "$STATE_FILE"
}

awg_has_ip() {
  local ip="$1"
  jq -e --arg ip "$ip" '.awg.clients[$ip] != null' "$STATE_FILE" >/dev/null
}

collect_awg_artifacts_for_name() {
  local name="$1"
  local conf vpnuri vpnuri_text
  conf="$(find /root/awg -maxdepth 3 -type f -name "${name}.conf" | head -n1 || true)"
  vpnuri="/root/awg/${name}.vpnuri"
  vpnuri_text=""
  [[ -f "$vpnuri" ]] && vpnuri_text="$(cat "$vpnuri")"

  jq -n \
    --arg conf "$conf" \
    --arg vpnuri_path "$vpnuri" \
    --arg vpnuri "$vpnuri_text" \
    '{conf_path:$conf, vpnuri_path:$vpnuri_path, vpnuri:$vpnuri}'
}

collect_awg_stats_json() {
  bash /root/awg/manage_amneziawg.sh stats --json > "${STATE_DIR}/awg-stats.json"
}

find_awg_vpn_ip_for_name() {
  local name="$1"
  collect_awg_stats_json
  jq -r --arg name "$name" '.[] | select(.name == $name) | .ip' "${STATE_DIR}/awg-stats.json" | head -n1
}

awg_add_ip() {
  local ip="$1"
  local name conf_json vpn_ip tmp port
  name="awg-${ip//./-}"

  bash /root/awg/manage_amneziawg.sh add "$name"
  port="$(jq -r '.awg.port' "$STATE_FILE")"
  bash /root/awg/manage_amneziawg.sh modify "$name" Endpoint "${ip}:${port}"

  vpn_ip="$(find_awg_vpn_ip_for_name "$name")"
  conf_json="$(collect_awg_artifacts_for_name "$name")"

  tmp="$(mktemp)"
  jq --arg ip "$ip" \
     --arg name "$name" \
     --arg vpn_ip "$vpn_ip" \
     --argjson meta "$conf_json" \
     '
     .awg.clients[$ip] = {
       "name": $name,
       "vpn_ip": $vpn_ip,
       "conf_path": $meta.conf_path,
       "vpnuri_path": $meta.vpnuri_path,
       "vpnuri": $meta.vpnuri
     }' \
     "$STATE_FILE" > "$tmp"
  mv "$tmp" "$STATE_FILE"

  log "Added AWG client for ${ip}"
}

awg_remove_peer_best_effort() {
  local name="$1"
  if bash /root/awg/manage_amneziawg.sh help 2>/dev/null | grep -qi 'remove'; then
    bash /root/awg/manage_amneziawg.sh remove "$name" || true
  else
    warn "AWG remove command not detected in upstream manager, only local state/files will be cleaned"
  fi
}

awg_remove_ip() {
  local ip="$1"
  local name vpn_ip tmp

  name="$(jq -r --arg ip "$ip" '.awg.clients[$ip].name // ""' "$STATE_FILE")"
  vpn_ip="$(jq -r --arg ip "$ip" '.awg.clients[$ip].vpn_ip // ""' "$STATE_FILE")"

  if [[ -n "$vpn_ip" ]]; then
    iptables -t nat -C POSTROUTING -s "${vpn_ip}/32" -j SNAT --to-source "$ip" 2>/dev/null \
      && iptables -t nat -D POSTROUTING -s "${vpn_ip}/32" -j SNAT --to-source "$ip" || true
  fi

  [[ -n "$name" ]] && awg_remove_peer_best_effort "$name"

  rm -f "${OUT_DIR}/${name}.conf" "${OUT_DIR}/${name}.vpnuri.txt"

  tmp="$(mktemp)"
  jq --arg ip "$ip" 'del(.awg.clients[$ip])' "$STATE_FILE" > "$tmp"
  mv "$tmp" "$STATE_FILE"

  log "Removed AWG client for ${ip}"
}

sync_awg_snat() {
  local nic="$1"
  jq -r '.awg.clients | to_entries[]? | @base64' "$STATE_FILE" | while IFS= read -r row; do
    local entry public_ip vpn_ip
    entry="$(echo "$row" | base64 -d)"
    public_ip="$(jq -r '.key' <<<"$entry")"
    vpn_ip="$(jq -r '.value.vpn_ip' <<<"$entry")"

    [[ -n "$vpn_ip" && "$vpn_ip" != "null" ]] || continue
    iptables -t nat -C POSTROUTING -s "${vpn_ip}/32" -o "$nic" -j SNAT --to-source "$public_ip" 2>/dev/null \
      || iptables -t nat -A POSTROUTING -s "${vpn_ip}/32" -o "$nic" -j SNAT --to-source "$public_ip"
  done

  save_iptables
}

refresh_awg_artifacts_into_state() {
  local tmp
  tmp="$(mktemp)"

  jq '
    . as $root
    | .awg.clients |= with_entries(
        .value.conf_path = .value.conf_path
      )
  ' "$STATE_FILE" > "$tmp"
  mv "$tmp" "$STATE_FILE"

  jq -r '.awg.clients | to_entries[]? | .value.name' "$STATE_FILE" | while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    local ip conf_json tmp2
    ip="$(jq -r --arg name "$name" '.awg.clients | to_entries[] | select(.value.name == $name) | .key' "$STATE_FILE" | head -n1)"
    conf_json="$(collect_awg_artifacts_for_name "$name")"
    tmp2="$(mktemp)"
    jq --arg ip "$ip" \
       --argjson meta "$conf_json" \
       '
       .awg.clients[$ip].conf_path = $meta.conf_path
       | .awg.clients[$ip].vpnuri_path = $meta.vpnuri_path
       | .awg.clients[$ip].vpnuri = $meta.vpnuri
       ' "$STATE_FILE" > "$tmp2"
    mv "$tmp2" "$STATE_FILE"

    [[ -n "$(jq -r --arg ip "$ip" '.awg.clients[$ip].conf_path // ""' "$STATE_FILE")" ]] && cp -f "$(jq -r --arg ip "$ip" '.awg.clients[$ip].conf_path' "$STATE_FILE")" "${OUT_DIR}/${name}.conf" 2>/dev/null || true
    [[ -n "$(jq -r --arg ip "$ip" '.awg.clients[$ip].vpnuri // ""' "$STATE_FILE")" ]] && echo "$(jq -r --arg ip "$ip" '.awg.clients[$ip].vpnuri' "$STATE_FILE")" > "${OUT_DIR}/${name}.vpnuri.txt" || true
  done
}

write_awg_summary() {
  : > "${OUT_DIR}/awg-clients.txt"
  jq -r '
    .awg.clients
    | to_entries
    | sort_by(.key)
    | .[]
    | [
        "NAME=" + .value.name,
        "PUBLIC_IP=" + .key,
        "VPN_IP=" + (.value.vpn_ip // ""),
        "CONF_PATH=" + (.value.conf_path // ""),
        "VPNURI_PATH=" + (.value.vpnuri_path // ""),
        "VPNURI=" + (.value.vpnuri // ""),
        ""
      ] | .[]
  ' "$STATE_FILE" >> "${OUT_DIR}/awg-clients.txt"
}

sync_awg() {
  local nic="$1"
  install_awg_base
  ensure_awg_port_saved

  for ip in "${IPS[@]}"; do
    if awg_has_ip "$ip"; then
      log "AWG already exists for ${ip}, skipping"
    else
      awg_add_ip "$ip"
    fi
  done

  if [[ "$PRUNE" == "1" ]]; then
    jq -r '.awg.clients | keys[]?' "$STATE_FILE" | while IFS= read -r ip; do
      if ! jq -e --arg ip "$ip" '$ARGS.positional | index($ip)' --args "${IPS[@]}" >/dev/null; then
        awg_remove_ip "$ip"
        remove_ip_alias "$nic" "$ip"
      fi
    done
  fi

  sync_awg_snat "$nic"
  refresh_awg_artifacts_into_state
  write_awg_summary

  log "Done. Files:"
  log "  ${OUT_DIR}/awg-clients.txt"
  jq -r '.awg.clients | to_entries[]? | .value.name' "$STATE_FILE" | while IFS= read -r name; do
    [[ -n "$name" ]] && [[ -f "${OUT_DIR}/${name}.conf" ]] && log "  ${OUT_DIR}/${name}.conf"
    [[ -n "$name" ]] && [[ -f "${OUT_DIR}/${name}.vpnuri.txt" ]] && log "  ${OUT_DIR}/${name}.vpnuri.txt"
  done

  echo
  echo "===== AWG import info ====="
  cat "${OUT_DIR}/awg-clients.txt"
}

main() {
  require_root
  parse_args "$@"
  split_ips
  make_dirs
  init_state
  ensure_same_proto_or_empty
  ensure_pkgs

  local nic
  nic="$(detect_nic)"
  [[ -n "$nic" ]] || err "Could not detect WAN interface"

  persist_sysctl_basic
  ensure_ip_aliases "$nic" "${IPS[@]}"

  if [[ "$PROTO" == "xray" ]]; then
    sync_xray
  else
    sync_awg "$nic"
  fi
}

main "$@"