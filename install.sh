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
PRIMARY_NIC=""
AMZ_PUBLIC_ROUTE_SCRIPT="/usr/local/sbin/amz-multi-public-routes.sh"
AMZ_PUBLIC_ROUTE_SERVICE="amz-multi-public-routes.service"
AMZ_PUBLIC_ROUTE_TIMER="amz-multi-public-routes.timer"
AMZ_PUBLIC_ROUTE_HOOK="/etc/networkd-dispatcher/routable.d/50-amz-multi-public-routes"
AMZ_AWG_ROUTE_SCRIPT="/usr/local/sbin/amz-multi-awg-routes.sh"
AMZ_AWG_ROUTE_SERVICE="amz-multi-awg-routes.service"

declare -Ag RESOLVED_IP_NICS=()

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
warn() { echo -e "\033[1;33m[!]\033[0m $*" >&2; }
err()  { echo -e "\033[1;31m[-]\033[0m $*" >&2; exit 1; }
route_debug() { echo -e "\033[0;36m[route-debug]\033[0m $*" >&2; }

on_err() {
  local rc="$?"
  echo -e "\033[1;31m[-]\033[0m install.sh failed at line ${1}: ${2} (exit ${rc})" >&2
  exit "$rc"
}

trap 'on_err "${LINENO}" "${BASH_COMMAND}"' ERR

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
  ip route get 1.1.1.1 2>/dev/null | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true
}

ensure_pkgs() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y \
    curl wget jq iptables iptables-persistent ca-certificates \
    openssl uuid-runtime unzip tar perl qrencode netcat-openbsd \
    networkd-dispatcher
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
  sysctl --system >/dev/null || warn "sysctl --system returned a non-zero status; continuing"
}

route_dev_from_output() {
  local route_line="$1"
  awk '/ dev / {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' <<<"$route_line"
}

route_via_from_output() {
  local route_line="$1"
  awk '/ via / {for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}' <<<"$route_line"
}

ipv4_to_int() {
  local ip="$1"
  local a b c d
  IFS=. read -r a b c d <<<"$ip"
  printf '%s\n' "$(( (a << 24) | (b << 16) | (c << 8) | d ))"
}

int_to_ipv4() {
  local value="$1"
  printf '%d.%d.%d.%d\n' \
    "$(( (value >> 24) & 255 ))" \
    "$(( (value >> 16) & 255 ))" \
    "$(( (value >> 8) & 255 ))" \
    "$(( value & 255 ))"
}

cidr_prefix() {
  local cidr="$1"
  printf '%s\n' "${cidr#*/}"
}

cidr_for_nic_ip() {
  local nic="$1"
  local public_ip="$2"
  ip -o -4 addr show dev "$nic" scope global 2>/dev/null \
    | awk -v ip="$public_ip" '$4 ~ ("^" ip "/") {print $4; exit}'
}

network_from_cidr() {
  local cidr="$1"
  local ip prefix ip_int mask_int network_int

  ip="${cidr%/*}"
  prefix="${cidr#*/}"
  [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
  (( prefix >= 0 && prefix <= 32 )) || return 1

  ip_int="$(ipv4_to_int "$ip")"

  if (( prefix == 0 )); then
    mask_int=0
  else
    mask_int=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
  fi

  network_int=$(( ip_int & mask_int ))
  printf '%s/%s\n' "$(int_to_ipv4 "$network_int")" "$prefix"
}

list_ip_bindings() {
  local ip="$1"
  ip -o -4 addr show scope global 2>/dev/null | awk -v ip="$ip" '$4 ~ ("^" ip "/") {print $2 " " $4}'
}

network_file_for_nic() {
  local nic="$1"
  networkctl status "$nic" --no-pager 2>/dev/null \
    | sed -n 's/^[[:space:]]*Network File:[[:space:]]*//p' \
    | head -n1
}

networkd_dropin_dir_for_nic() {
  local nic="$1"
  local network_file base_name

  network_file="$(network_file_for_nic "$nic")"
  [[ -n "$network_file" ]] || return 1

  base_name="$(basename "$network_file")"
  [[ -n "$base_name" ]] || return 1

  printf '/etc/systemd/network/%s.d\n' "$base_name"
}

ip_exists_anywhere() {
  local ip="$1"
  list_ip_bindings "$ip" | grep -q .
}

find_existing_nic_for_ip() {
  local ip="$1"
  local primary_nic="$2"
  local line nic cidr prefix first_nic="" chosen_nic="" primary_has_32=0
  local -a bindings=()

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    bindings+=("$line")
  done < <(list_ip_bindings "$ip")

  if [[ "${#bindings[@]}" -eq 0 ]]; then
    return 1
  fi

  if [[ "${#bindings[@]}" -eq 1 ]]; then
    printf '%s\n' "${bindings[0]%% *}"
    return 0
  fi

  for line in "${bindings[@]}"; do
    nic="${line%% *}"
    cidr="${line#* }"
    prefix="${cidr#*/}"
    [[ -z "$first_nic" ]] && first_nic="$nic"

    if [[ "$nic" == "$primary_nic" && "$prefix" == "32" ]]; then
      primary_has_32=1
      continue
    fi

    if [[ "$prefix" != "32" ]]; then
      chosen_nic="$nic"
      break
    fi

    if [[ -z "$chosen_nic" && "$nic" != "$primary_nic" ]]; then
      chosen_nic="$nic"
    fi
  done

  if [[ "$primary_has_32" -eq 1 && -n "$chosen_nic" && "$chosen_nic" != "$primary_nic" ]]; then
    warn "Detected conflicting alias for ${ip} on ${primary_nic}; keeping ${chosen_nic} and removing ${ip}/32 from ${primary_nic}"
    ip addr del "${ip}/32" dev "$primary_nic" 2>/dev/null || true
    printf '%s\n' "$chosen_nic"
    return 0
  fi

  if [[ -n "$chosen_nic" ]]; then
    printf '%s\n' "$chosen_nic"
    return 0
  fi

  printf '%s\n' "$first_nic"
}

ensure_ip_aliases() {
  local nic="$1"; shift
  local ip existing_nic
  for ip in "$@"; do
    if existing_nic="$(find_existing_nic_for_ip "$ip" "$nic" 2>/dev/null)"; then
      RESOLVED_IP_NICS["$ip"]="$existing_nic"
      continue
    fi

    if ! ip -4 addr show dev "$nic" | grep -qw "$ip"; then
      log "Adding $ip to $nic"
      ip addr add "${ip}/32" dev "$nic" || true
    fi

    RESOLVED_IP_NICS["$ip"]="$nic"
  done
}

remove_ip_alias() {
  local nic="$1"
  local ip="$2"

  if ip -o -4 addr show dev "$nic" 2>/dev/null | awk -v ip="$ip" '$4 == ip"/32" {found=1} END{exit found?0:1}'; then
    ip addr del "${ip}/32" dev "$nic" || true
  fi
}

resolve_nic_for_ip() {
  local ip="$1"
  local nic

  if [[ -n "${RESOLVED_IP_NICS[$ip]+x}" ]]; then
    printf '%s\n' "${RESOLVED_IP_NICS[$ip]}"
    return 0
  fi

  if nic="$(find_existing_nic_for_ip "$ip" "$PRIMARY_NIC" 2>/dev/null)"; then
    RESOLVED_IP_NICS["$ip"]="$nic"
    printf '%s\n' "$nic"
    return 0
  fi

  printf '%s\n' "$PRIMARY_NIC"
}

routing_table_id_for_public_ip() {
  local public_ip="$1"
  local nic="${2:-$(resolve_nic_for_ip "$public_ip")}"
  local ifindex=0
  if [[ -r "/sys/class/net/${nic}/ifindex" ]]; then
    ifindex="$(cat "/sys/class/net/${nic}/ifindex" 2>/dev/null || echo 0)"
  fi
  printf '%s\n' "$((200 + ifindex))"
}

routing_priority_for_public_ip() {
  local public_ip="$1"
  local nic="${2:-$(resolve_nic_for_ip "$public_ip")}"
  local ifindex=0
  if [[ -r "/sys/class/net/${nic}/ifindex" ]]; then
    ifindex="$(cat "/sys/class/net/${nic}/ifindex" 2>/dev/null || echo 0)"
  fi
  printf '%s\n' "$((1000 + ifindex))"
}

clear_policy_route_for_public_ip() {
  local public_ip="$1"
  local nic="${2:-$(resolve_nic_for_ip "$public_ip")}"
  local table priority

  table="$(routing_table_id_for_public_ip "$public_ip" "$nic")"
  priority="$(routing_priority_for_public_ip "$public_ip" "$nic")"

  route_debug "Clearing public-IP rules for ${public_ip}: nic=${nic} table=${table} priority=${priority}"
  while ip rule del from "${public_ip}/32" table "$table" priority "$priority" 2>/dev/null; do :; done
  while ip rule del from "${public_ip}/32" table "$table" 2>/dev/null; do :; done
  while ip rule del from "${public_ip}/32" 2>/dev/null; do :; done
  ip route flush table "$table" 2>/dev/null || true
}

routing_table_id_for_vpn_ip() {
  local vpn_ip="$1"
  local last_octet
  IFS=. read -r _ _ _ last_octet <<<"$vpn_ip"
  printf '%s\n' "$((11000 + last_octet))"
}

routing_priority_for_vpn_ip() {
  local vpn_ip="$1"
  local last_octet
  IFS=. read -r _ _ _ last_octet <<<"$vpn_ip"
  printf '%s\n' "$((11000 + last_octet))"
}

clear_policy_route_for_vpn_ip() {
  local vpn_ip="$1"
  local table priority

  table="$(routing_table_id_for_vpn_ip "$vpn_ip")"
  priority="$(routing_priority_for_vpn_ip "$vpn_ip")"

  while ip rule del from "${vpn_ip}/32" table "$table" priority "$priority" 2>/dev/null; do :; done
  while ip rule del from "${vpn_ip}/32" table "$table" 2>/dev/null; do :; done
  ip route flush table "$table" 2>/dev/null || true
}

connected_route_for_nic_ip() {
  local nic="$1"
  local public_ip="$2"
  local cidr prefix

  cidr="$(cidr_for_nic_ip "$nic" "$public_ip")"
  if [[ -n "$cidr" ]]; then
    prefix="$(cidr_prefix "$cidr")"
    if [[ "$prefix" == "32" ]]; then
      network_from_cidr "${public_ip%.*}.0/24"
      return 0
    fi
    network_from_cidr "$cidr"
    return 0
  fi

  ip -4 route show table main dev "$nic" proto kernel scope link 2>/dev/null \
    | awk -v src="$public_ip" '$0 ~ (" src " src "($| )") {print $1; exit}'
}

guess_gateway_for_connected_route() {
  local connected_route="$1"
  local public_ip="$2"
  local network prefix network_int public_int gateway_int

  [[ -n "$connected_route" ]] || return 1

  network="${connected_route%/*}"
  prefix="${connected_route#*/}"

  [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
  (( prefix <= 30 )) || return 1

  network_int="$(ipv4_to_int "$network")"
  public_int="$(ipv4_to_int "$public_ip")"
  gateway_int=$((network_int + 1))

  (( gateway_int != public_int )) || return 1
  int_to_ipv4 "$gateway_int"
}

gateway_for_nic_ip() {
  local nic="$1"
  local public_ip="$2"
  local gateway connected_route cidr prefix

  cidr="$(cidr_for_nic_ip "$nic" "$public_ip")"
  prefix=""
  [[ -n "$cidr" ]] && prefix="$(cidr_prefix "$cidr")"

  connected_route="$(connected_route_for_nic_ip "$nic" "$public_ip")"
  if [[ "$prefix" == "32" ]]; then
    if gateway="$(guess_gateway_for_connected_route "$connected_route" "$public_ip" 2>/dev/null)"; then
      warn "Guessing gateway ${gateway} for ${public_ip} on ${nic} from ${connected_route}"
      printf '%s\n' "$gateway"
      return 0
    fi
  fi

  gateway="$(ip -4 route show table main default dev "$nic" 2>/dev/null | awk '/^default via / {print $3; exit}')"
  if [[ -n "$gateway" ]]; then
    route_debug "Gateway for ${public_ip} on ${nic} found in main table default: ${gateway}"
    printf '%s\n' "$gateway"
    return 0
  fi

  if gateway="$(guess_gateway_for_connected_route "$connected_route" "$public_ip" 2>/dev/null)"; then
    warn "Guessing gateway ${gateway} for ${public_ip} on ${nic} from ${connected_route}"
    printf '%s\n' "$gateway"
    return 0
  fi

  gateway="$(
    networkctl status "$nic" --no-pager 2>/dev/null \
      | sed -n 's/^[[:space:]]*Gateway:[[:space:]]*//p' \
      | head -n1 \
      | awk '{print $1}'
  )"
  if [[ -n "$gateway" ]]; then
    route_debug "Gateway for ${public_ip} on ${nic} found via networkctl: ${gateway}"
    printf '%s\n' "$gateway"
    return 0
  fi

  return 1
}

dump_public_route_debug() {
  local public_ip="$1"
  local nic="$2"
  local table priority

  table="$(routing_table_id_for_public_ip "$public_ip" "$nic")"
  priority="$(routing_priority_for_public_ip "$public_ip" "$nic")"

  route_debug "State for ${public_ip}: expected_nic=${nic} table=${table} priority=${priority}"
  route_debug "Bindings for ${public_ip}:"
  list_ip_bindings "$public_ip" 2>/dev/null | sed 's/^/[route-debug]   /' || true
  route_debug "ip route get 1.1.1.1 from ${public_ip}:"
  (ip -4 route get 1.1.1.1 from "$public_ip" 2>/dev/null || true) | sed 's/^/[route-debug]   /'
  route_debug "ip rule:"
  (ip rule 2>/dev/null || true) | sed 's/^/[route-debug]   /'
  route_debug "ip route show table ${table}:"
  (ip route show table "$table" 2>/dev/null || true) | sed 's/^/[route-debug]   /'
  route_debug "ip -4 addr show dev ${nic}:"
  (ip -4 addr show dev "$nic" 2>/dev/null || true) | sed 's/^/[route-debug]   /'
  if [[ -n "$PRIMARY_NIC" && "$PRIMARY_NIC" != "$nic" ]]; then
    route_debug "ip -4 addr show dev ${PRIMARY_NIC}:"
    (ip -4 addr show dev "$PRIMARY_NIC" 2>/dev/null || true) | sed 's/^/[route-debug]   /'
  fi
}

source_egress_matches_ip() {
  local public_ip="$1"
  local actual_ip

  actual_ip="$(timeout 8 curl -4 --interface "$public_ip" -fsS https://api.ipify.org 2>/dev/null || true)"
  [[ -n "$actual_ip" ]] || return 1
  [[ "$actual_ip" == "$public_ip" ]]
}

ip_is_bound_to_nic() {
  local public_ip="$1"
  local nic="$2"

  ip -o -4 addr show dev "$nic" scope global 2>/dev/null \
    | awk -v ip="$public_ip" '$4 ~ ("^" ip "/") {found=1} END{exit found?0:1}'
}

write_public_ip_networkd_dropins() {
  local -A nics_with_aliases=()
  local ip nic cidr prefix dropin_dir dropin_file network_file

  log "Configuring native systemd-networkd address persistence where available"

  for ip in "${IPS[@]}"; do
    nic="$(resolve_nic_for_ip "$ip")"
    cidr="$(cidr_for_nic_ip "$nic" "$ip" || true)"
    prefix=""
    [[ -n "$cidr" ]] && prefix="$(cidr_prefix "$cidr")"

    if [[ "$prefix" == "32" ]]; then
      nics_with_aliases["$nic"]=1
    fi
  done

  for nic in "${!nics_with_aliases[@]}"; do
    network_file="$(network_file_for_nic "$nic" || true)"
    dropin_dir="$(networkd_dropin_dir_for_nic "$nic" || true)"

    if [[ -z "$dropin_dir" ]]; then
      warn "Could not determine systemd-networkd base file for ${nic}; keeping dispatcher fallback only"
      continue
    fi

    mkdir -p "$dropin_dir"
    dropin_file="${dropin_dir}/50-amz-multi-addresses.conf"

    {
      printf '[Network]\n'
      for ip in "${IPS[@]}"; do
        if [[ "$(resolve_nic_for_ip "$ip")" != "$nic" ]]; then
          continue
        fi

        cidr="$(cidr_for_nic_ip "$nic" "$ip" || true)"
        prefix=""
        [[ -n "$cidr" ]] && prefix="$(cidr_prefix "$cidr")"
        [[ "$prefix" == "32" ]] || continue

        printf 'Address=%s/32\n' "$ip"
      done
    } >"$dropin_file"

    chmod 644 "$dropin_file"
    log "Installed native address drop-in ${dropin_file} for ${nic} (base ${network_file:-unknown})"
  done
}

apply_policy_route_for_public_ip() {
  local public_ip="$1"
  local nic="$2"
  local gateway connected_route table priority

  clear_policy_route_for_public_ip "$public_ip" "$nic"

  remove_ip_alias "$PRIMARY_NIC" "$public_ip"

  connected_route="$(connected_route_for_nic_ip "$nic" "$public_ip")"
  [[ -n "$connected_route" ]] || err "Could not determine connected route for ${public_ip} on ${nic}"

  gateway="$(gateway_for_nic_ip "$nic" "$public_ip")" \
    || err "Could not determine gateway for ${public_ip} on ${nic}. Fix netplan for this NIC first."

  table="$(routing_table_id_for_public_ip "$public_ip" "$nic")"
  priority="$(routing_priority_for_public_ip "$public_ip" "$nic")"

  route_debug "Applying public-IP fix for ${public_ip}: nic=${nic} connected_route=${connected_route} gateway=${gateway} table=${table} priority=${priority}"
  route_debug "Removing stale /32 alias from ${PRIMARY_NIC} for ${public_ip} if present"
  route_debug "Running: ip route replace ${connected_route} dev ${nic} src ${public_ip} table ${table}"
  ip route replace "$connected_route" dev "$nic" src "$public_ip" table "$table" 2>/dev/null || true
  route_debug "Running: ip route replace default via ${gateway} dev ${nic} table ${table}"
  ip route replace default via "$gateway" dev "$nic" table "$table" 2>/dev/null || true
  route_debug "Running: ip rule add from ${public_ip}/32 table ${table} priority ${priority}"
  ip rule add from "${public_ip}/32" table "$table" priority "$priority" 2>/dev/null || true
  ip route flush cache
  dump_public_route_debug "$public_ip" "$nic"
}

ensure_source_route_for_ip() {
  local public_ip="$1"
  local expected_nic route_line route_dev probe_ok=1

  expected_nic="$(resolve_nic_for_ip "$public_ip")"
  route_line="$(ip -4 route get 1.1.1.1 from "$public_ip" 2>/dev/null || true)"
  route_dev="$(route_dev_from_output "$route_line")"

  if [[ "$route_dev" == "$expected_nic" ]] && source_egress_matches_ip "$public_ip"; then
    return 0
  fi

  if ! source_egress_matches_ip "$public_ip"; then
    probe_ok=0
    route_debug "Egress probe for ${public_ip} failed or returned a different IP"
  fi

  if [[ "$expected_nic" != "$PRIMARY_NIC" || "$probe_ok" -eq 0 ]]; then
    warn "Source route for ${public_ip} exits via ${route_dev:-unknown}, attempting auto-fix on ${expected_nic}"
    dump_public_route_debug "$public_ip" "$expected_nic"
    apply_policy_route_for_public_ip "$public_ip" "$expected_nic"
    route_line="$(ip -4 route get 1.1.1.1 from "$public_ip" 2>/dev/null || true)"
    route_dev="$(route_dev_from_output "$route_line")"
    route_debug "After auto-fix, route for ${public_ip}: ${route_line:-<empty>}"
  fi

  [[ -n "$route_dev" ]] || err "Could not build source route for ${public_ip}. Server networking for this IP is not ready."
  if [[ "$route_dev" != "$expected_nic" ]]; then
    dump_public_route_debug "$public_ip" "$expected_nic"
    err "Source route for ${public_ip} exits via ${route_dev}, but ${public_ip} is bound to ${expected_nic}. Fix netplan/policy routing for this IP first."
  fi
  if ! source_egress_matches_ip "$public_ip"; then
    dump_public_route_debug "$public_ip" "$expected_nic"
    err "Source route for ${public_ip} looks correct, but egress probe still does not return ${public_ip}. Fix provider routing for this IP first."
  fi

  return 0
}

validate_source_routes_for_ips() {
  local ip

  for ip in "${IPS[@]}"; do
    ensure_source_route_for_ip "$ip"
  done

  return 0
}

apply_policy_route_for_vpn_ip() {
  local vpn_ip="$1"
  local public_ip="$2"
  local nic="$3"
  local route_line route_dev route_via table priority connected_route

  clear_policy_route_for_vpn_ip "$vpn_ip"

  if [[ "$nic" == "$PRIMARY_NIC" ]]; then
    return 0
  fi

  route_line="$(ip -4 route get 1.1.1.1 from "$public_ip" 2>/dev/null || true)"
  route_dev="$(route_dev_from_output "$route_line")"
  route_via="$(route_via_from_output "$route_line")"

  [[ -n "$route_dev" ]] || err "Could not determine route device for ${public_ip}"
  [[ "$route_dev" == "$nic" ]] || err "Route for ${public_ip} exits via ${route_dev}, but AWG needs ${nic}. Fix server networking for ${public_ip} first."
  [[ -n "$route_via" ]] || err "Could not determine gateway for ${public_ip} on ${nic}"

  table="$(routing_table_id_for_vpn_ip "$vpn_ip")"
  priority="$(routing_priority_for_vpn_ip "$vpn_ip")"
  connected_route="$(connected_route_for_nic_ip "$nic" "$public_ip")"

  if [[ -n "$connected_route" ]]; then
    ip route add "$connected_route" dev "$nic" src "$public_ip" table "$table" 2>/dev/null || true
  fi

  ip route add default via "$route_via" dev "$nic" table "$table" 2>/dev/null || true
  ip rule add from "${vpn_ip}/32" table "$table" priority "$priority" 2>/dev/null || true
}

write_public_ip_policy_route_service() {
  local script_path="$AMZ_PUBLIC_ROUTE_SCRIPT"
  local unit_path="/etc/systemd/system/${AMZ_PUBLIC_ROUTE_SERVICE}"
  local timer_path="/etc/systemd/system/${AMZ_PUBLIC_ROUTE_TIMER}"
  local hook_path="$AMZ_PUBLIC_ROUTE_HOOK"
  local ip nic connected_route gateway table priority cidr prefix

  log "Configuring public IP persistence via networkd-dispatcher"

  cat >"$script_path" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
EOF

  for ip in "${IPS[@]}"; do
    nic="$(resolve_nic_for_ip "$ip")"
    cidr="$(cidr_for_nic_ip "$nic" "$ip" || true)"
    prefix=""
    [[ -n "$cidr" ]] && prefix="$(cidr_prefix "$cidr")"

    table="$(routing_table_id_for_public_ip "$ip" "$nic")"
    priority="$(routing_priority_for_public_ip "$ip" "$nic")"
    connected_route="$( (ip route show table "$table" 2>/dev/null || true) | awk '!/^default/ {print $1; exit}' )"
    gateway="$( (ip route show table "$table" 2>/dev/null || true) | awk '/^default via / {print $3; exit}' )"

    if [[ "$prefix" == "32" ]]; then
      log "Persistence: will restore alias ${ip}/32 on ${nic}"
      printf 'ip addr add %q dev %q 2>/dev/null || true\n' "${ip}/32" "$nic" >>"$script_path"
    else
      log "Persistence: ${ip} already has native prefix on ${nic} (${cidr})"
    fi

    if [[ -z "$connected_route" || -z "$gateway" ]]; then
      [[ "$nic" != "$PRIMARY_NIC" ]] || continue
      connected_route="$(connected_route_for_nic_ip "$nic" "$ip" || true)"
      gateway="$(gateway_for_nic_ip "$nic" "$ip" || true)"
    fi

    if [[ -z "$connected_route" || -z "$gateway" ]]; then
      log "Persistence: ${ip} does not need a dedicated source route on ${nic}"
      continue
    fi

    log "Persistence: will restore route for ${ip} via ${gateway} on ${nic} (table ${table}, priority ${priority}, connected ${connected_route})"

    {
      printf 'while ip rule del from %q table %q priority %q 2>/dev/null; do :; done\n' "${ip}/32" "$table" "$priority"
      printf 'while ip rule del from %q table %q 2>/dev/null; do :; done\n' "${ip}/32" "$table"
      printf 'while ip rule del from %q 2>/dev/null; do :; done\n' "${ip}/32"
      printf 'ip route flush table %q 2>/dev/null || true\n' "$table"
      printf 'ip addr del %q dev %q 2>/dev/null || true\n' "${ip}/32" "$PRIMARY_NIC"
      printf 'ip route replace %q dev %q src %q table %q 2>/dev/null || true\n' "$connected_route" "$nic" "$ip" "$table"
      printf 'ip route replace default via %q dev %q table %q 2>/dev/null || true\n' "$gateway" "$nic" "$table"
      printf 'ip rule add from %q table %q priority %q 2>/dev/null || true\n' "${ip}/32" "$table" "$priority"
    } >>"$script_path"
  done

  chmod 700 "$script_path"

  cat >"$unit_path" <<EOF
[Unit]
Description=amz-multi public IP policy routes
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${script_path}

[Install]
WantedBy=multi-user.target
EOF

  mkdir -p "$(dirname "$hook_path")"
  cat >"$hook_path" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
exec ${script_path}
EOF
  chmod 700 "$hook_path"
  log "Installed networkd-dispatcher hook ${hook_path}"

  if [[ -f "$timer_path" ]]; then
    log "Removing legacy timer-based persistence ${AMZ_PUBLIC_ROUTE_TIMER}"
  fi
  systemctl disable --now "$AMZ_PUBLIC_ROUTE_TIMER" >/dev/null 2>&1 || true
  rm -f "$timer_path"
  systemctl daemon-reload
  systemctl enable --now "$AMZ_PUBLIC_ROUTE_SERVICE" >/dev/null 2>&1 || true
  systemctl enable --now networkd-dispatcher.service >/dev/null 2>&1 || true
  log "Applying public IP persistence immediately"
  systemctl restart "$AMZ_PUBLIC_ROUTE_SERVICE" >/dev/null 2>&1 || err "Failed to run ${AMZ_PUBLIC_ROUTE_SERVICE}"

  return 0
}

validate_public_ip_persistence() {
  local failures=0
  local ip nic route_line route_dev route_via alias_state route_state egress_state cidr prefix dropin_dir dropin_file native_state

  log "Validating public IP persistence"

  if [[ -x "$AMZ_PUBLIC_ROUTE_SCRIPT" ]]; then
    log "Persistence script is present: ${AMZ_PUBLIC_ROUTE_SCRIPT}"
  else
    warn "Persistence script is missing or not executable: ${AMZ_PUBLIC_ROUTE_SCRIPT}"
    failures=1
  fi

  if [[ -x "$AMZ_PUBLIC_ROUTE_HOOK" ]]; then
    log "networkd-dispatcher hook is present: ${AMZ_PUBLIC_ROUTE_HOOK}"
  else
    warn "networkd-dispatcher hook is missing or not executable: ${AMZ_PUBLIC_ROUTE_HOOK}"
    failures=1
  fi

  if systemctl is-enabled "$AMZ_PUBLIC_ROUTE_SERVICE" >/dev/null 2>&1; then
    log "Persistence service is enabled: ${AMZ_PUBLIC_ROUTE_SERVICE}"
  else
    warn "Persistence service is not enabled: ${AMZ_PUBLIC_ROUTE_SERVICE}"
    failures=1
  fi

  if systemctl is-active --quiet networkd-dispatcher.service; then
    log "networkd-dispatcher is active"
  else
    warn "networkd-dispatcher is not active"
    failures=1
  fi

  for ip in "${IPS[@]}"; do
    nic="$(resolve_nic_for_ip "$ip")"
    cidr="$(cidr_for_nic_ip "$nic" "$ip" || true)"
    prefix=""
    [[ -n "$cidr" ]] && prefix="$(cidr_prefix "$cidr")"
    route_line="$(ip -4 route get 1.1.1.1 from "$ip" 2>/dev/null || true)"
    route_dev="$(route_dev_from_output "$route_line")"
    route_via="$(route_via_from_output "$route_line")"
    alias_state="ok"
    route_state="ok"
    egress_state="ok"
    native_state="n/a"

    if ! ip_is_bound_to_nic "$ip" "$nic"; then
      alias_state="missing"
      failures=1
    fi

    if [[ -z "$route_dev" || "$route_dev" != "$nic" ]]; then
      route_state="bad(${route_dev:-none})"
      failures=1
    fi

    if ! source_egress_matches_ip "$ip"; then
      egress_state="bad"
      failures=1
    fi

    if [[ "$prefix" == "32" ]]; then
      dropin_dir="$(networkd_dropin_dir_for_nic "$nic" || true)"
      dropin_file="${dropin_dir}/50-amz-multi-addresses.conf"

      if [[ -n "$dropin_dir" && -f "$dropin_file" ]] && grep -qxF "Address=${ip}/32" "$dropin_file"; then
        native_state="ok"
      else
        native_state="missing"
        failures=1
      fi
    fi

    if [[ "$alias_state" == "ok" && "$route_state" == "ok" && "$egress_state" == "ok" && "$native_state" != "missing" ]]; then
      log "Persistence check OK: ${ip} on ${nic} via ${route_via:-direct} native=${native_state}"
    else
      warn "Persistence check FAILED: ${ip} on ${nic} alias=${alias_state} route=${route_state} via=${route_via:-none} egress=${egress_state} native=${native_state}"
    fi
  done

  if [[ "$failures" -ne 0 ]]; then
    err "Public IP persistence validation failed"
  fi

  log "Public IP persistence is healthy"
}

write_awg_policy_route_service() {
  local script_path="$AMZ_AWG_ROUTE_SCRIPT"
  local unit_path="/etc/systemd/system/${AMZ_AWG_ROUTE_SERVICE}"
  local ip nic vpn_ip

  cat >"$script_path" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

route_dev_from_output() {
  local route_line="$1"
  awk '/ dev / {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' <<<"$route_line"
}

route_via_from_output() {
  local route_line="$1"
  awk '/ via / {for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}' <<<"$route_line"
}

routing_table_id_for_vpn_ip() {
  local vpn_ip="$1"
  local last_octet
  IFS=. read -r _ _ _ last_octet <<<"$vpn_ip"
  printf '%s\n' "$((11000 + last_octet))"
}

routing_priority_for_vpn_ip() {
  local vpn_ip="$1"
  local last_octet
  IFS=. read -r _ _ _ last_octet <<<"$vpn_ip"
  printf '%s\n' "$((11000 + last_octet))"
}

clear_all_amz_awg_policy_routes() {
  local last_octet table
  for last_octet in $(seq 1 254); do
    table="$((11000 + last_octet))"
    while ip rule del table "$table" 2>/dev/null; do :; done
    ip route flush table "$table" 2>/dev/null || true
  done
}

connected_route_for_nic_ip() {
  local nic="$1"
  local public_ip="$2"
  ip -4 route show table main dev "$nic" proto kernel scope link 2>/dev/null \
    | awk -v src="$public_ip" '$0 ~ (" src " src "($| )") {print $1; exit}'
}

apply_route() {
  local vpn_ip="$1"
  local public_ip="$2"
  local nic="$3"
  local route_line route_dev route_via connected_route table priority

  route_line="$(ip -4 route get 1.1.1.1 from "$public_ip" 2>/dev/null || true)"
  route_dev="$(route_dev_from_output "$route_line")"
  route_via="$(route_via_from_output "$route_line")"
  [[ -n "$route_dev" && "$route_dev" == "$nic" && -n "$route_via" ]] || return 0

  connected_route="$(connected_route_for_nic_ip "$nic" "$public_ip")"
  table="$(routing_table_id_for_vpn_ip "$vpn_ip")"
  priority="$(routing_priority_for_vpn_ip "$vpn_ip")"

  if [[ -n "$connected_route" ]]; then
    ip route add "$connected_route" dev "$nic" src "$public_ip" table "$table" 2>/dev/null || true
  fi

  ip route add default via "$route_via" dev "$nic" table "$table" 2>/dev/null || true
  ip rule add from "${vpn_ip}/32" table "$table" priority "$priority" 2>/dev/null || true
}

clear_all_amz_awg_policy_routes
EOF

  while IFS= read -r ip; do
    [[ -z "$ip" ]] && continue
    nic="$(resolve_nic_for_ip "$ip")"
    vpn_ip="$(jq -r --arg ip "$ip" '.awg.clients[$ip].vpn_ip // ""' "$STATE_FILE")"
    [[ -n "$vpn_ip" ]] || continue

    if [[ "$nic" != "$PRIMARY_NIC" ]]; then
      printf 'apply_route %q %q %q\n' "$vpn_ip" "$ip" "$nic" >>"$script_path"
    fi
  done < <(jq -r '.awg.clients | keys[]?' "$STATE_FILE")

  chmod 700 "$script_path"

  cat >"$unit_path" <<EOF
[Unit]
Description=amz-multi AWG policy routes
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${script_path}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now "$AMZ_AWG_ROUTE_SERVICE" >/dev/null 2>&1 || true
}

save_iptables() {
  netfilter-persistent save >/dev/null 2>&1 || iptables-save >/etc/iptables/rules.v4
}

ensure_awg_forward_rule_for_nic() {
  local nic="$1"

  iptables -C FORWARD -i awg0 -j ACCEPT 2>/dev/null \
    || iptables -I FORWARD 1 -i awg0 -j ACCEPT

  iptables -C FORWARD -i "$nic" -o awg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
    || iptables -I FORWARD 1 -i "$nic" -o awg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
}

ensure_awg_forward_rules() {
  local nic="$1"
  ensure_awg_forward_rule_for_nic "$nic"
}

delete_awg_snat_rules_for_vpn_ip() {
  local vpn_ip="$1"
  local line cmd
  local -a args

  while IFS= read -r line; do
    [[ "$line" == *"-s ${vpn_ip}/32 "* ]] || continue
    [[ "$line" == *" -j SNAT "* ]] || continue

    cmd="${line/-A /-D }"
    read -r -a args <<<"$cmd"
    iptables -t nat "${args[@]}" || true
  done < <(iptables -t nat -S POSTROUTING 2>/dev/null || true)
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
    sed -i "s|^export ALLOWED_IPS=.*|export ALLOWED_IPS='0.0.0.0/0, ::/0'|" "${AWG_DIR}/awgsetup_cfg.init"
  else
    printf "export ALLOWED_IPS='0.0.0.0/0, ::/0'\n" >> "${AWG_DIR}/awgsetup_cfg.init"
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
  local allowed_ips="0.0.0.0/0, ::/0"

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
  local name="$1"
  local public_ip vpn_ip conf_path

  public_ip="$(awg_ip_from_name "$name")"
  conf_path="$(find_awg_conf_for_name "$name")"
  vpn_ip=""

  if [[ -n "$public_ip" ]]; then
    vpn_ip="$(jq -r --arg ip "$public_ip" '.awg.clients[$ip].vpn_ip // ""' "$STATE_FILE" 2>/dev/null || true)"
  fi

  if [[ -z "$vpn_ip" ]]; then
    vpn_ip="$(extract_awg_vpn_ip_from_conf "$conf_path")"
  fi

  if [[ -n "$vpn_ip" ]]; then
    delete_awg_snat_rules_for_vpn_ip "$vpn_ip"
    clear_policy_route_for_vpn_ip "$vpn_ip"
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
  local ip="$1"
  local name vpn_ip tmp

  name="$(jq -r --arg ip "$ip" '.awg.clients[$ip].name // ""' "$STATE_FILE")"
  vpn_ip="$(jq -r --arg ip "$ip" '.awg.clients[$ip].vpn_ip // ""' "$STATE_FILE")"

  if [[ -n "$vpn_ip" ]]; then
    delete_awg_snat_rules_for_vpn_ip "$vpn_ip"
    clear_policy_route_for_vpn_ip "$vpn_ip"
  fi

  [[ -n "$name" ]] && awg_remove_peer_best_effort "$name"
  rm -f "${OUT_DIR}/${name}.conf" "${OUT_DIR}/${name}.vpnuri.txt"

  tmp="$(mktemp)"
  jq --arg ip "$ip" 'del(.awg.clients[$ip])' "$STATE_FILE" > "$tmp"
  mv "$tmp" "$STATE_FILE"

  log "Removed AWG client for ${ip}"
}

prune_unwanted_awg_server_clients() {
  local name public_ip resolved_nic

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    public_ip="$(awg_ip_from_name "$name")"

    [[ -n "$public_ip" ]] || continue

    if ! ip_is_wanted "$public_ip"; then
      resolved_nic="$(resolve_nic_for_ip "$public_ip")"
      awg_remove_name "$name"
      remove_ip_alias "$resolved_nic" "$public_ip"
    fi
  done < <(list_awg_server_client_names)
}

sync_awg_snat() {
  local nic="$1"

  ensure_awg_forward_rules "$nic"

  jq -r '.awg.clients | to_entries[]? | @base64' "$STATE_FILE" | while IFS= read -r row; do
    local entry public_ip vpn_ip resolved_nic
    entry="$(echo "$row" | base64 -d)"
    public_ip="$(jq -r '.key' <<<"$entry")"
    vpn_ip="$(jq -r '.value.vpn_ip' <<<"$entry")"

    [[ -n "$vpn_ip" && "$vpn_ip" != "null" ]] || continue

    resolved_nic="$(resolve_nic_for_ip "$public_ip")"
    ensure_awg_forward_rule_for_nic "$resolved_nic"
    delete_awg_snat_rules_for_vpn_ip "$vpn_ip"
    apply_policy_route_for_vpn_ip "$vpn_ip" "$public_ip" "$resolved_nic"

    # Specific per-client SNAT must stay above the generic MASQUERADE from awg-quick.
    iptables -t nat -I POSTROUTING 1 -s "${vpn_ip}/32" -o "$resolved_nic" -j SNAT --to-source "$public_ip"
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
    prune_unwanted_awg_server_clients

    while IFS= read -r ip; do
      local resolved_nic
      [[ -z "$ip" ]] && continue
      keep=0
      for wanted in "${IPS[@]}"; do
        if [[ "$wanted" == "$ip" ]]; then
          keep=1
          break
        fi
      done

      if [[ "$keep" -eq 0 ]]; then
        resolved_nic="$(resolve_nic_for_ip "$ip")"
        awg_remove_ip "$ip"
        remove_ip_alias "$resolved_nic" "$ip"
      fi
    done < <(jq -r '.awg.clients | keys[]?' "$STATE_FILE")
  fi

  sync_awg_snat "$nic"
  refresh_awg_artifacts_into_state
  write_awg_policy_route_service
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
  nic="$(detect_nic || true)"
  [[ -n "$nic" ]] || err "Could not detect WAN interface"
  PRIMARY_NIC="$nic"

  persist_sysctl_basic
  ensure_ip_aliases "$nic" "${IPS[@]}"
  log "Checking source routing for requested IPs"
  validate_source_routes_for_ips
  log "Source routing checks completed"
  write_public_ip_networkd_dropins
  write_public_ip_policy_route_service
  log "Source routing persistence prepared"
  validate_public_ip_persistence

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
