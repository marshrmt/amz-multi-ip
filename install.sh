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

XRAY_DIR="/usr/local/etc/xray"
XRAY_CONFIG="${XRAY_DIR}/config.json"
XRAY_SERVICE="xray"

AWG_DIR="/root/awg"
AWG_SERVER_CONF="/etc/amnezia/amneziawg/awg0.conf"

REPO_RAW_BASE="${REPO_RAW_BASE:-https://raw.githubusercontent.com/marshrmt/amz-multi-ip/main}"
XRAY_INSTALL_SCRIPT_URL="${REPO_RAW_BASE}/vendor/xray-install/install-release.sh"
AWG_VENDOR_BASE_URL="${REPO_RAW_BASE}/vendor/amneziawg-installer"
AWG_INSTALL_SCRIPT_URL="${AWG_VENDOR_BASE_URL}/install_amneziawg_en.sh"
AWG_SETUP_STATE_FILE="${AWG_DIR}/setup_state"

SCRIPT_ARGS=()

usage() {
  cat <<'EOF'
Usage:
  bash install.sh --proto xray --ips 1.2.3.4,1.2.3.5 [--sni video.yahoo.com] [--prune]
  bash install.sh --proto awg  --ips 1.2.3.4,1.2.3.5 [--prune]
  bash install.sh --proto both --ips 1.2.3.4,1.2.3.5 [--sni video.yahoo.com] [--prune]

Args:
  --proto   awg | xray | both
  --ips     comma-separated public IPv4 list
  --sni     Xray Reality SNI/domain (default: video.yahoo.com)
  --prune   remove configs for IPs missing from current list
EOF
}

log()  { echo -e "\033[1;32m[+]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
err()  { echo -e "\033[1;31m[-]\033[0m $*" >&2; exit 1; }

format_rerun_command() {
  local args=""

  if [[ ${#SCRIPT_ARGS[@]} -gt 0 ]]; then
    printf -v args '%q ' "${SCRIPT_ARGS[@]}"
    args="${args% }"
  fi

  printf 'curl -fsSL %s/install.sh | bash -s -- %s' "$REPO_RAW_BASE" "$args"
}

get_awg_resume_step() {
  local step=""

  [[ -f "$AWG_SETUP_STATE_FILE" ]] || return 1
  step="$(tr -d '\r\n[:space:]' < "$AWG_SETUP_STATE_FILE" 2>/dev/null || true)"
  [[ "$step" =~ ^[0-9]+$ ]] || return 1
  (( step > 0 && step < 99 )) || return 1

  printf '%s\n' "$step"
}

print_partial_xray_configs_if_any() {
  if jq -e '.xray.clients | length > 0' "$STATE_FILE" >/dev/null 2>&1; then
    echo
    printf '[xray]\n'
    print_selected_xray_configs
  fi
}

exit_awg_reboot_required() {
  local step="$1"

  warn "AWG installation requires a reboot and paused at step ${step}."

  if [[ "$PROTO" == "both" ]]; then
    log "Xray is already configured. After reboot, rerun the same command to continue AWG setup."
    print_partial_xray_configs_if_any
  else
    log "After reboot, rerun the same command to continue AWG setup."
  fi

  echo
  printf 'Reboot required. Resume with:\n%s\n' "$(format_rerun_command)"
  exit 0
}

require_root() {
  [[ $EUID -eq 0 ]] || err "Run as root."
}

rand_port() { shuf -i 47000-49000 -n 1; }
rand_hex()  { local n="${1:-8}"; openssl rand -hex "$n"; }
rand_uuid() { cat /proc/sys/kernel/random/uuid; }

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
      --ips)   IPS_CSV="${2:-}"; shift 2 ;;
      --sni)   SNI="${2:-}"; shift 2 ;;
      --prune) PRUNE="1"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) err "Unknown arg: $1" ;;
    esac
  done

  [[ "$PROTO" == "xray" || "$PROTO" == "awg" || "$PROTO" == "both" ]] || err "--proto must be xray, awg or both"
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

ensure_awg_forward_rules() {
  local nic="$1"

  iptables -C FORWARD -i awg0 -j ACCEPT 2>/dev/null \
    || iptables -I FORWARD 1 -i awg0 -j ACCEPT

  iptables -C FORWARD -i "$nic" -o awg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
    || iptables -I FORWARD 1 -i "$nic" -o awg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
}

save_awg_port_to_state() {
  local port="$1"
  local tmp

  [[ -n "$port" ]] || err "AWG port is empty"

  tmp="$(mktemp)"
  jq --arg p "$port" '.awg.port = $p' "$STATE_FILE" > "$tmp"
  mv "$tmp" "$STATE_FILE"
}

########################################
# XRAY
########################################

port_is_in_use_tcp() {
  local port="$1"
  ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)$port$"
}

port_is_in_use_udp() {
  local port="$1"
  ss -lunH 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)$port$"
}

port_is_in_use_anywhere() {
  local port="$1"
  port_is_in_use_tcp "$port" || port_is_in_use_udp "$port"
}

port_is_in_xray_state() {
  local port="$1"
  jq -e --argjson p "$port" '.xray.clients | to_entries[]? | select(.value.port == $p)' "$STATE_FILE" >/dev/null
}

get_awg_reserved_port() {
  local port

  port="$(jq -r '.awg.port // ""' "$STATE_FILE")"
  if [[ -n "$port" ]]; then
    printf '%s\n' "$port"
    return
  fi

  if [[ -f "${AWG_DIR}/awgsetup_cfg.init" ]]; then
    port="$(get_awg_port)"
    [[ -n "$port" ]] && printf '%s\n' "$port"
  fi
}

port_is_awg_reserved() {
  local port="$1"
  [[ -n "$port" && "$port" == "$(get_awg_reserved_port)" ]]
}

port_is_reserved() {
  local port="$1"
  port_is_in_use_anywhere "$port" || port_is_in_xray_state "$port" || port_is_awg_reserved "$port"
}

ensure_awg_port_not_in_xray() {
  local port

  port="$(get_awg_reserved_port)"
  [[ -n "$port" ]] || return 0

  if port_is_in_xray_state "$port"; then
    err "AWG port ${port} conflicts with an existing Xray port"
  fi
}

choose_random_port() {
  local port tries=0
  while :; do
    port="$(rand_port)"
    if ! port_is_reserved "$port"; then
      printf '%s\n' "$port"
      return
    fi
    tries=$((tries + 1))
    [[ "$tries" -lt 5000 ]] || err "Could not find a free port in 47000-49000"
  done
}

ensure_xray_installed() {
  if command -v xray >/dev/null 2>&1; then
    log "xray already installed"
    return
  fi

  log "Installing Xray"
  rm -f /root/install-release.sh
  curl -fsSL "$XRAY_INSTALL_SCRIPT_URL" -o /root/install-release.sh
  chmod +x /root/install-release.sh
  bash /root/install-release.sh install
}

ensure_xray_keys() {
  local priv pub out tmp

  priv="$(jq -r '.xray.private_key // ""' "$STATE_FILE")"
  pub="$(jq -r '.xray.public_key // ""' "$STATE_FILE")"

  if [[ -n "$priv" && -n "$pub" ]]; then
    return
  fi

  out="$(xray x25519 2>/dev/null || true)"

  priv="$(
    printf '%s\n' "$out" \
      | sed -n \
          -e 's/^PrivateKey: *//p' \
          -e 's/^Private key: *//p' \
      | head -n1 | tr -d '\r'
  )"

  pub="$(
    printf '%s\n' "$out" \
      | sed -n \
          -e 's/^Password (PublicKey): *//p' \
          -e 's/^Public key: *//p' \
      | head -n1 | tr -d '\r'
  )"

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

  mkdir -p "$XRAY_DIR"
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

list_missing_xray_ports() {
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

ensure_xray_healthy() {
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

    missing="$(list_missing_xray_ports)"
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
  err "Xray did not start correctly or ports are not listening. Missing ports: $(list_missing_xray_ports)"
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
  ensure_xray_healthy
  write_xray_summary

  log "Xray done"
}

########################################
# AWG
########################################

install_awg_base() {
  local port actual_port installer_rc=0 resume_step=""

  if [[ -x "${AWG_DIR}/manage_amneziawg.sh" ]]; then
    log "AWG installer already present"
    refresh_awg_vendor_scripts
    return
  fi

  port="$(jq -r '.awg.port // ""' "$STATE_FILE")"
  [[ -n "$port" ]] || err "AWG port must be reserved before installation"

  log "Installing AWG 2.0 base via bivlked installer"
  cd /root
  rm -f install_amneziawg_en.sh
  curl -fsSL "$AWG_INSTALL_SCRIPT_URL" -o /root/install_amneziawg_en.sh
  chmod +x /root/install_amneziawg_en.sh

  if AMZ_AWG_VENDOR_BASE_URL="$AWG_VENDOR_BASE_URL" bash /root/install_amneziawg_en.sh --yes --route-all --disallow-ipv6 --port="${port}"; then
    installer_rc=0
  else
    installer_rc=$?
  fi

  if [[ "$installer_rc" -ne 0 ]]; then
    if resume_step="$(get_awg_resume_step)"; then
      exit_awg_reboot_required "$resume_step"
    fi

    err "AWG base install failed with exit code ${installer_rc}"
  fi

  if [[ ! -x "${AWG_DIR}/manage_amneziawg.sh" ]]; then
    if resume_step="$(get_awg_resume_step)"; then
      exit_awg_reboot_required "$resume_step"
    fi

    err "AWG base install did not finish. If installer rebooted the server, run the same command again."
  fi

  actual_port="$(get_awg_port)"
  [[ -n "$actual_port" ]] || err "Could not detect AWG port after installation"
  save_awg_port_to_state "$actual_port"
  refresh_awg_vendor_scripts
}

refresh_awg_vendor_scripts() {
  [[ -d "$AWG_DIR" ]] || return 0

  curl -fsSL "${AWG_VENDOR_BASE_URL}/awg_common_en.sh" -o "${AWG_DIR}/awg_common.sh" || {
    warn "Could not refresh awg_common.sh from repo"
    return 0
  }
  chmod 700 "${AWG_DIR}/awg_common.sh" || true

  curl -fsSL "${AWG_VENDOR_BASE_URL}/manage_amneziawg_en.sh" -o "${AWG_DIR}/manage_amneziawg.sh" || {
    warn "Could not refresh manage_amneziawg.sh from repo"
    return 0
  }
  chmod 700 "${AWG_DIR}/manage_amneziawg.sh" || true
}

get_awg_port() {
  awk -F= '/^export AWG_PORT=/{gsub(/'\''|"/,"",$2); print $2}' "${AWG_DIR}/awgsetup_cfg.init" | tail -n1
}

get_awg_tunnel_subnet() {
  awk -F= '/^export AWG_TUNNEL_SUBNET=/{gsub(/'\''|"/,"",$2); print $2}' "${AWG_DIR}/awgsetup_cfg.init" | tail -n1
}

force_awg_ipv4_only_defaults() {
  [[ -f "${AWG_DIR}/awgsetup_cfg.init" ]] || return 0

  if grep -q '^export DISABLE_IPV6=' "${AWG_DIR}/awgsetup_cfg.init"; then
    sed -i "s/^export DISABLE_IPV6=.*/export DISABLE_IPV6=1/" "${AWG_DIR}/awgsetup_cfg.init"
  else
    printf 'export DISABLE_IPV6=1\n' >> "${AWG_DIR}/awgsetup_cfg.init"
  fi

  if grep -q '^export ALLOWED_IPS=' "${AWG_DIR}/awgsetup_cfg.init"; then
    sed -i "s|^export ALLOWED_IPS=.*|export ALLOWED_IPS='0.0.0.0/0'|" "${AWG_DIR}/awgsetup_cfg.init"
  else
    printf "export ALLOWED_IPS='0.0.0.0/0'\n" >> "${AWG_DIR}/awgsetup_cfg.init"
  fi
}

ensure_awg_port_saved() {
  local port
  port="$(jq -r '.awg.port // ""' "$STATE_FILE")"
  if [[ -n "$port" ]]; then
    return
  fi

  if [[ -f "${AWG_DIR}/awgsetup_cfg.init" ]]; then
    port="$(get_awg_port)"
  fi

  if [[ -z "$port" ]]; then
    port="$(choose_random_port)"
    log "Reserved AWG port ${port}/udp"
  fi

  save_awg_port_to_state "$port"
}

scope_awg_masquerade_to_tunnel_subnet() {
  local nic="$1"
  local subnet

  [[ -f "$AWG_SERVER_CONF" ]] || return 0

  subnet="$(get_awg_tunnel_subnet)"
  [[ -n "$subnet" ]] || return 0

  sed -i \
    -e "s#iptables -t nat -A POSTROUTING -o ${nic} -j MASQUERADE#iptables -t nat -A POSTROUTING -s ${subnet} -o ${nic} -j MASQUERADE#g" \
    -e "s#iptables -t nat -D POSTROUTING -o ${nic} -j MASQUERADE#iptables -t nat -D POSTROUTING -s ${subnet} -o ${nic} -j MASQUERADE#g" \
    "$AWG_SERVER_CONF"
}

cleanup_legacy_awg_masquerade_rules() {
  local nic="$1"
  local subnet

  subnet="$(get_awg_tunnel_subnet)"
  [[ -n "$subnet" ]] || return 0

  while iptables -t nat -C POSTROUTING -o "$nic" -j MASQUERADE 2>/dev/null; do
    iptables -t nat -D POSTROUTING -o "$nic" -j MASQUERADE || true
  done

  while iptables -t nat -C POSTROUTING -s "$subnet" -o "$nic" -j MASQUERADE 2>/dev/null; do
    iptables -t nat -D POSTROUTING -s "$subnet" -o "$nic" -j MASQUERADE || true
  done

  iptables -t nat -A POSTROUTING -s "$subnet" -o "$nic" -j MASQUERADE
}

strip_awg_ipv6_server_rules() {
  [[ -f "$AWG_SERVER_CONF" ]] || return 0

  perl -0pi -e 's/; ip6tables -I FORWARD -i %i -j ACCEPT; ip6tables -t nat -A POSTROUTING -o [^;]+ -j MASQUERADE//g; s/; ip6tables -D FORWARD -i %i -j ACCEPT; ip6tables -t nat -D POSTROUTING -o [^;]+ -j MASQUERADE//g' "$AWG_SERVER_CONF"
}

cleanup_awg_ipv6_runtime_rules() {
  local nic="$1"

  command -v ip6tables >/dev/null 2>&1 || return 0

  while ip6tables -C FORWARD -i awg0 -j ACCEPT 2>/dev/null; do
    ip6tables -D FORWARD -i awg0 -j ACCEPT || true
  done

  while ip6tables -t nat -C POSTROUTING -o "$nic" -j MASQUERADE 2>/dev/null; do
    ip6tables -t nat -D POSTROUTING -o "$nic" -j MASQUERADE || true
  done
}

enforce_awg_client_ipv4_only() {
  local name="$1"
  local conf_path="${AWG_DIR}/${name}.conf"
  local current_endpoint=""
  local allowed_ips="0.0.0.0/0"

  if [[ -x "${AWG_DIR}/manage_amneziawg.sh" ]]; then
    bash "${AWG_DIR}/manage_amneziawg.sh" modify "$name" AllowedIPs "$allowed_ips" >/dev/null 2>&1 || true
  fi

  [[ -f "$conf_path" ]] || return 0

  current_endpoint="$(sed -n '/^\[Peer\]/,$ s/^Endpoint[ \t]*=[ \t]*//p' "$conf_path" | tr -d '[:space:]' | head -n1)"
  sed -i "s|^AllowedIPs = .*|AllowedIPs = ${allowed_ips}|" "$conf_path"

  if [[ -x "${AWG_DIR}/manage_amneziawg.sh" && -n "$current_endpoint" ]]; then
    bash "${AWG_DIR}/manage_amneziawg.sh" modify "$name" Endpoint "$current_endpoint" >/dev/null 2>&1 || true
  fi
}

awg_has_ip() {
  local ip="$1"
  jq -e --arg ip "$ip" '.awg.clients[$ip] != null' "$STATE_FILE" >/dev/null
}

awg_name_exists() {
  local name="$1"
  grep -qxF "#_Name = ${name}" "$AWG_SERVER_CONF" 2>/dev/null \
    || [[ -f "${AWG_DIR}/${name}.conf" ]] \
    || [[ -f "${AWG_DIR}/${name}.vpnuri" ]]
}

list_awg_server_client_names() {
  [[ -f "$AWG_SERVER_CONF" ]] || return 0
  grep '^#_Name = ' "$AWG_SERVER_CONF" | sed 's/^#_Name = //' || true
}

awg_ip_from_name() {
  local name="$1"
  local ip

  [[ "$name" == awg-* ]] || return 0
  ip="${name#awg-}"
  ip="${ip//-/.}"

  if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    printf '%s\n' "$ip"
  fi
}

ip_is_wanted() {
  local ip="$1"
  local wanted

  for wanted in "${IPS[@]}"; do
    if [[ "$wanted" == "$ip" ]]; then
      return 0
    fi
  done

  return 1
}

find_awg_conf_for_name() {
  local name="$1"
  local conf

  conf="${AWG_DIR}/${name}.conf"
  if [[ -f "$conf" ]]; then
    printf '%s\n' "$conf"
    return
  fi

  find "$AWG_DIR" -maxdepth 3 -type f -name "${name}.conf" | head -n1 || true
}

extract_awg_vpn_ip_from_conf() {
  local conf_path="$1"

  [[ -n "$conf_path" && -f "$conf_path" ]] || return 0
  grep -oPm1 '^\s*Address\s*=\s*\K[0-9.]+' "$conf_path" || true
}

ensure_awg_artifacts_for_name() {
  local name="$1"
  local conf_path vpnuri_path

  conf_path="$(find_awg_conf_for_name "$name")"
  vpnuri_path="${AWG_DIR}/${name}.vpnuri"

  if [[ -n "$conf_path" && -f "$conf_path" && -f "$vpnuri_path" ]]; then
    return
  fi

  bash "${AWG_DIR}/manage_amneziawg.sh" regen "$name" >/dev/null 2>&1 || true
}

collect_awg_artifacts_for_name() {
  local name="$1"
  local conf vpnuri vpnuri_text vpn_ip

  ensure_awg_artifacts_for_name "$name"

  conf="$(find_awg_conf_for_name "$name")"
  vpnuri="${AWG_DIR}/${name}.vpnuri"
  vpnuri_text=""
  [[ -f "$vpnuri" ]] && vpnuri_text="$(cat "$vpnuri")"
  vpn_ip="$(extract_awg_vpn_ip_from_conf "$conf")"

  jq -n \
    --arg conf "$conf" \
    --arg vpnuri_path "$vpnuri" \
    --arg vpnuri "$vpnuri_text" \
    --arg vpn_ip "$vpn_ip" \
    '{conf_path:$conf, vpnuri_path:$vpnuri_path, vpnuri:$vpnuri, vpn_ip:$vpn_ip}'
}

validate_awg_artifacts_json() {
  local name="$1"
  local conf_json="$2"
  local conf_path vpnuri vpn_ip

  conf_path="$(jq -r '.conf_path // ""' <<<"$conf_json")"
  vpnuri="$(jq -r '.vpnuri // ""' <<<"$conf_json")"
  vpn_ip="$(jq -r '.vpn_ip // ""' <<<"$conf_json")"

  [[ -n "$conf_path" && -f "$conf_path" ]] || err "Could not find AWG config file for ${name}"
  [[ -n "$vpnuri" ]] || err "Could not find AWG vpnuri for ${name}"
  [[ -n "$vpn_ip" ]] || err "Could not parse AWG VPN IP for ${name}"
}

write_awg_output_files() {
  local ip="$1"
  local name conf_path vpnuri

  name="$(jq -r --arg ip "$ip" '.awg.clients[$ip].name // ""' "$STATE_FILE")"
  conf_path="$(jq -r --arg ip "$ip" '.awg.clients[$ip].conf_path // ""' "$STATE_FILE")"
  vpnuri="$(jq -r --arg ip "$ip" '.awg.clients[$ip].vpnuri // ""' "$STATE_FILE")"

  [[ -n "$conf_path" && -f "$conf_path" ]] && cp -f "$conf_path" "${OUT_DIR}/${name}.conf" || true
  [[ -n "$vpnuri" ]] && printf '%s\n' "$vpnuri" > "${OUT_DIR}/${name}.vpnuri.txt" || true
}

upsert_awg_state_for_ip() {
  local ip="$1"
  local name="$2"
  local conf_json="$3"
  local tmp

  [[ -n "$conf_json" ]] || err "Could not collect AWG artifacts for ${name}"

  tmp="$(mktemp)"
  jq --arg ip "$ip" \
     --arg name "$name" \
     --argjson meta "$conf_json" \
     '
     .awg.clients[$ip] = {
       "name": $name,
       "vpn_ip": $meta.vpn_ip,
       "conf_path": $meta.conf_path,
       "vpnuri_path": $meta.vpnuri_path,
       "vpnuri": $meta.vpnuri
     }' \
     "$STATE_FILE" > "$tmp"
  mv "$tmp" "$STATE_FILE"

  write_awg_output_files "$ip"
}

refresh_awg_ip_state() {
  local ip="$1"
  local name="$2"
  local conf_json

  conf_json="$(collect_awg_artifacts_for_name "$name")"
  validate_awg_artifacts_json "$name" "$conf_json"
  upsert_awg_state_for_ip "$ip" "$name" "$conf_json"
}

awg_add_ip() {
  local ip="$1"
  local name port

  name="awg-${ip//./-}"
  port="$(jq -r '.awg.port' "$STATE_FILE")"

  bash "${AWG_DIR}/manage_amneziawg.sh" add "$name"
  bash "${AWG_DIR}/manage_amneziawg.sh" modify "$name" Endpoint "${ip}:${port}" || true
  enforce_awg_client_ipv4_only "$name"

  refresh_awg_ip_state "$ip" "$name"
  log "Added AWG client for ${ip}"
}

awg_import_existing_ip() {
  local ip="$1"
  local name port

  name="awg-${ip//./-}"
  port="$(jq -r '.awg.port' "$STATE_FILE")"

  bash "${AWG_DIR}/manage_amneziawg.sh" modify "$name" Endpoint "${ip}:${port}" || true
  enforce_awg_client_ipv4_only "$name"
  refresh_awg_ip_state "$ip" "$name"
  log "Imported existing AWG client for ${ip}"
}

awg_refresh_existing_ip() {
  local ip="$1"
  local name port

  name="$(jq -r --arg ip "$ip" '.awg.clients[$ip].name // ""' "$STATE_FILE")"
  [[ -n "$name" ]] || name="awg-${ip//./-}"
  port="$(jq -r '.awg.port' "$STATE_FILE")"

  if awg_name_exists "$name"; then
    bash "${AWG_DIR}/manage_amneziawg.sh" modify "$name" Endpoint "${ip}:${port}" || true
  fi

  enforce_awg_client_ipv4_only "$name"
  refresh_awg_ip_state "$ip" "$name"
}

awg_remove_peer_best_effort() {
  local name="$1"
  if bash "${AWG_DIR}/manage_amneziawg.sh" help 2>/dev/null | grep -qi 'remove'; then
    bash "${AWG_DIR}/manage_amneziawg.sh" remove "$name" || true
  else
    warn "AWG remove command not detected in upstream manager, only local state/files will be cleaned"
  fi
}

awg_drop_ip_from_state() {
  local ip="$1"
  local tmp

  if ! jq -e --arg ip "$ip" '.awg.clients[$ip] != null' "$STATE_FILE" >/dev/null 2>&1; then
    return 0
  fi

  tmp="$(mktemp)"
  jq --arg ip "$ip" 'del(.awg.clients[$ip])' "$STATE_FILE" > "$tmp"
  mv "$tmp" "$STATE_FILE"
}

awg_remove_name() {
  local nic="$1"
  local name="$2"
  local public_ip vpn_ip conf_path

  public_ip="$(awg_ip_from_name "$name")"
  conf_path="$(find_awg_conf_for_name "$name")"
  vpn_ip="$(extract_awg_vpn_ip_from_conf "$conf_path")"

  if [[ -n "$vpn_ip" && -n "$public_ip" ]]; then
    while iptables -t nat -C POSTROUTING -s "${vpn_ip}/32" -o "$nic" -j SNAT --to-source "$public_ip" 2>/dev/null; do
      iptables -t nat -D POSTROUTING -s "${vpn_ip}/32" -o "$nic" -j SNAT --to-source "$public_ip" || true
    done
  fi

  awg_remove_peer_best_effort "$name"
  rm -f "${AWG_DIR}/${name}.conf" "${AWG_DIR}/${name}.png" "${AWG_DIR}/${name}.vpnuri"
  rm -f "${OUT_DIR}/${name}.conf" "${OUT_DIR}/${name}.vpnuri.txt"

  if [[ -n "$public_ip" ]]; then
    awg_drop_ip_from_state "$public_ip"
  fi

  log "Removed AWG client ${name}"
}

awg_remove_ip() {
  local nic="$1"
  local ip="$2"
  local name vpn_ip tmp

  name="$(jq -r --arg ip "$ip" '.awg.clients[$ip].name // ""' "$STATE_FILE")"
  vpn_ip="$(jq -r --arg ip "$ip" '.awg.clients[$ip].vpn_ip // ""' "$STATE_FILE")"

  if [[ -n "$vpn_ip" ]]; then
    while iptables -t nat -C POSTROUTING -s "${vpn_ip}/32" -o "$nic" -j SNAT --to-source "$ip" 2>/dev/null; do
      iptables -t nat -D POSTROUTING -s "${vpn_ip}/32" -o "$nic" -j SNAT --to-source "$ip" || true
    done
  fi

  [[ -n "$name" ]] && awg_remove_peer_best_effort "$name"
  rm -f "${OUT_DIR}/${name}.conf" "${OUT_DIR}/${name}.vpnuri.txt"

  tmp="$(mktemp)"
  jq --arg ip "$ip" 'del(.awg.clients[$ip])' "$STATE_FILE" > "$tmp"
  mv "$tmp" "$STATE_FILE"

  log "Removed AWG client for ${ip}"
}

prune_unwanted_awg_server_clients() {
  local nic="$1"
  local name public_ip

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    public_ip="$(awg_ip_from_name "$name")"

    [[ -n "$public_ip" ]] || continue

    if ! ip_is_wanted "$public_ip"; then
      awg_remove_name "$nic" "$name"
      remove_ip_alias "$nic" "$public_ip"
    fi
  done < <(list_awg_server_client_names)
}

sync_awg_snat() {
  local nic="$1"

  ensure_awg_forward_rules "$nic"

  jq -r '.awg.clients | to_entries[]? | @base64' "$STATE_FILE" | while IFS= read -r row; do
    local entry public_ip vpn_ip
    entry="$(echo "$row" | base64 -d)"
    public_ip="$(jq -r '.key' <<<"$entry")"
    vpn_ip="$(jq -r '.value.vpn_ip' <<<"$entry")"

    [[ -n "$vpn_ip" && "$vpn_ip" != "null" ]] || continue

    while iptables -t nat -C POSTROUTING -s "${vpn_ip}/32" -o "$nic" -j SNAT --to-source "$public_ip" 2>/dev/null; do
      iptables -t nat -D POSTROUTING -s "${vpn_ip}/32" -o "$nic" -j SNAT --to-source "$public_ip" || true
    done

    # Specific per-client SNAT must stay above the generic MASQUERADE from awg-quick.
    iptables -t nat -I POSTROUTING 1 -s "${vpn_ip}/32" -o "$nic" -j SNAT --to-source "$public_ip"
  done
}

refresh_awg_artifacts_into_state() {
  jq -r '.awg.clients | to_entries[]? | .value.name' "$STATE_FILE" | while IFS= read -r name; do
    [[ -z "$name" ]] && continue

    local ip conf_json tmp
    ip="$(jq -r --arg name "$name" '.awg.clients | to_entries[] | select(.value.name == $name) | .key' "$STATE_FILE" | head -n1)"
    conf_json="$(collect_awg_artifacts_for_name "$name")"

    tmp="$(mktemp)"
    jq --arg ip "$ip" \
       --argjson meta "$conf_json" \
       '
       .awg.clients[$ip].vpn_ip = $meta.vpn_ip
       | .awg.clients[$ip].conf_path = $meta.conf_path
       | .awg.clients[$ip].vpnuri_path = $meta.vpnuri_path
       | .awg.clients[$ip].vpnuri = $meta.vpnuri
       ' "$STATE_FILE" > "$tmp"
    mv "$tmp" "$STATE_FILE"

    write_awg_output_files "$ip"
  done
}

ensure_awg_healthy() {
  local port attempt active_port

  port="$(jq -r '.awg.port // ""' "$STATE_FILE")"
  [[ -n "$port" ]] || err "AWG port is empty in state"

  for attempt in 1 2 3; do
    systemctl enable --now awg-quick@awg0 >/dev/null 2>&1 || true
    systemctl restart awg-quick@awg0 >/dev/null 2>&1 || true
    sleep 1

    active_port="$(
      awg show awg0 2>/dev/null \
        | sed -n 's/^[[:space:]]*listening port:[[:space:]]*//p' \
        | head -n1 \
        | tr -d '\r'
    )"

    if systemctl is-active --quiet awg-quick@awg0 && [[ "$active_port" == "$port" ]]; then
      return 0
    fi

    warn "AWG restart attempt ${attempt} did not confirm listening port ${port} (actual: ${active_port:-unknown})"
  done

  systemctl status awg-quick@awg0 --no-pager -l || true
  awg show || true
  err "AWG did not start correctly or listening port ${port} was not confirmed"
}

write_awg_summary() {
  : > "${OUT_DIR}/awg-clients.txt"
  jq -r '
    .awg.clients
    | to_entries
    | sort_by(.key)
    | .[]
    | .key, (.value.vpnuri // ""), "==="
  ' "$STATE_FILE" >> "${OUT_DIR}/awg-clients.txt"
  perl -0pi -e 's/\n===\n?\z/\n/s' "${OUT_DIR}/awg-clients.txt"
}

sync_awg() {
  local nic="$1"
  local ip wanted keep name

  ensure_awg_port_saved
  ensure_awg_port_not_in_xray
  install_awg_base
  ensure_awg_port_saved
  ensure_awg_port_not_in_xray
  force_awg_ipv4_only_defaults
  strip_awg_ipv6_server_rules
  scope_awg_masquerade_to_tunnel_subnet "$nic"
  cleanup_legacy_awg_masquerade_rules "$nic"

  for ip in "${IPS[@]}"; do
    if awg_has_ip "$ip"; then
      log "AWG already exists for ${ip}, skipping create"
      awg_refresh_existing_ip "$ip"
      continue
    fi

    name="awg-${ip//./-}"
    if awg_name_exists "$name"; then
      log "AWG already exists on server for ${ip}, importing"
      awg_import_existing_ip "$ip"
      continue
    fi

    awg_add_ip "$ip"
  done

  if [[ "$PRUNE" == "1" ]]; then
    prune_unwanted_awg_server_clients "$nic"

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
        awg_remove_ip "$nic" "$ip"
        remove_ip_alias "$nic" "$ip"
      fi
    done < <(jq -r '.awg.clients | keys[]?' "$STATE_FILE")
  fi

  sync_awg_snat "$nic"
  refresh_awg_artifacts_into_state
  ensure_awg_healthy
  cleanup_awg_ipv6_runtime_rules "$nic"
  cleanup_legacy_awg_masquerade_rules "$nic"
  save_iptables
  write_awg_summary

  log "AWG done"
}

########################################
# OUTPUT
########################################

print_selected_xray_configs() {
  local ip value printed=0

  for ip in "${IPS[@]}"; do
    value="$(jq -r --arg ip "$ip" '.xray.clients[$ip].url // ""' "$STATE_FILE")"

    [[ -n "$value" ]] || continue

    if [[ "$printed" -eq 1 ]]; then
      printf '===\n'
    fi

    printf '%s\n%s\n' "$ip" "$value"
    printed=1
  done
}

print_selected_awg_configs() {
  local ip value printed=0

  for ip in "${IPS[@]}"; do
    value="$(jq -r --arg ip "$ip" '.awg.clients[$ip].vpnuri // ""' "$STATE_FILE")"

    [[ -n "$value" ]] || continue

    if [[ "$printed" -eq 1 ]]; then
      printf '===\n'
    fi

    printf '%s\n%s\n' "$ip" "$value"
    printed=1
  done
}

print_selected_console_configs() {
  if [[ "$PROTO" == "xray" ]]; then
    print_selected_xray_configs
    return
  fi

  if [[ "$PROTO" == "awg" ]]; then
    print_selected_awg_configs
    return
  fi

  printf '[xray]\n'
  print_selected_xray_configs
  printf '\n[awg]\n'
  print_selected_awg_configs
}

########################################
# MAIN
########################################

main() {
  SCRIPT_ARGS=("$@")

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

  if [[ "$PROTO" == "both" ]]; then
    ensure_awg_port_saved
    sync_xray
    sync_awg "$nic"
  elif [[ "$PROTO" == "xray" ]]; then
    sync_xray
  else
    ensure_awg_port_saved
    sync_awg "$nic"
  fi

  echo
  print_selected_console_configs
}

main "$@"
