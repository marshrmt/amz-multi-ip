#!/bin/bash

# ==============================================================================
# Shared function library for AmneziaWG 2.0
# Author: @bivlked
# Version: 5.7.11
# Date: 2026-03-31
# Repository: https://github.com/bivlked/amneziawg-installer
# ==============================================================================
#
# This file contains shared functions for key generation, config rendering,
# peer management, and working with AWG 2.0 parameters.
# Intended to be included via source from the install and manage scripts.
# ==============================================================================

# --- Constants (can be overridden before source) ---
AWG_DIR="${AWG_DIR:-/root/awg}"
CONFIG_FILE="${CONFIG_FILE:-$AWG_DIR/awgsetup_cfg.init}"
SERVER_CONF_FILE="${SERVER_CONF_FILE:-/etc/amnezia/amneziawg/awg0.conf}"
KEYS_DIR="${KEYS_DIR:-$AWG_DIR/keys}"
# shellcheck disable=SC2034
AWG_COMMON_VERSION="5.7.11"

# --- Auto-cleanup of temporary files ---
# NOTE: trap is NOT set here to avoid overwriting the caller's trap handler.
# The calling script must invoke _awg_cleanup() in its own EXIT handler.
_AWG_TEMP_FILES=()

_awg_cleanup() {
    local f
    for f in "${_AWG_TEMP_FILES[@]}"; do
        [[ -f "$f" ]] && rm -f "$f"
    done
}

# mktemp wrapper with auto-cleanup
awg_mktemp() {
    local f
    f=$(mktemp) || return 1
    _AWG_TEMP_FILES+=("$f")
    echo "$f"
}

# --- Logging stubs (overridden by the calling script) ---
if ! declare -f log >/dev/null 2>&1; then
    log()       { echo "[INFO] $1"; }
    log_warn()  { echo "[WARN] $1" >&2; }
    log_error() { echo "[ERROR] $1" >&2; }
    log_debug() { echo "[DEBUG] $1"; }
fi

# ==============================================================================
# Utilities
# ==============================================================================

# Detect primary network interface
get_main_nic() {
    ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}'
}

# Detect server public IP (with caching)
_CACHED_PUBLIC_IP=""
get_server_public_ip() {
    if [[ -n "$_CACHED_PUBLIC_IP" ]]; then
        echo "$_CACHED_PUBLIC_IP"
        return 0
    fi
    local ip="" svc
    for svc in https://ifconfig.me https://api.ipify.org https://icanhazip.com https://ipinfo.io/ip; do
        ip=$(curl -4 -sf --max-time 5 "$svc" 2>/dev/null | tr -d '[:space:]')
        if [[ -n "$ip" && "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            _CACHED_PUBLIC_IP="$ip"
            echo "$ip"
            return 0
        fi
    done
    echo ""
    return 1
}

# ==============================================================================
# Loading / saving parameters
# ==============================================================================

# Safe configuration loader (whitelist parser, no source/eval)
# Parses only allowed keys in KEY=VALUE or export KEY=VALUE format
safe_load_config() {
    local config_file="${1:-$CONFIG_FILE}"
    if [[ ! -f "$config_file" ]]; then return 1; fi

    local line key value
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue
        line="${line#export }"
        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            if [[ "$value" == \'*\' ]]; then
                value="${value#\'}"
                value="${value%\'}"
            elif [[ "$value" == \"*\" ]]; then
                value="${value#\"}"
                value="${value%\"}"
            fi
            case "$key" in
                OS_ID|OS_VERSION|OS_CODENAME|AWG_PORT|AWG_TUNNEL_SUBNET|\
                DISABLE_IPV6|ALLOWED_IPS_MODE|ALLOWED_IPS|AWG_ENDPOINT|\
                AWG_Jc|AWG_Jmin|AWG_Jmax|AWG_S1|AWG_S2|AWG_S3|AWG_S4|\
                AWG_H1|AWG_H2|AWG_H3|AWG_H4|AWG_I1|NO_TWEAKS|AWG_APPLY_MODE)
                    export "$key=$value"
                    ;;
            esac
        fi
    done < "$config_file"
}

# Load AWG parameters from configuration file
load_awg_params() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Configuration file $CONFIG_FILE not found."
        return 1
    fi
    safe_load_config "$CONFIG_FILE" || {
        log_error "Failed to load $CONFIG_FILE"
        return 1
    }
    # Check required AWG 2.0 parameters
    local missing=0
    local param
    for param in AWG_Jc AWG_Jmin AWG_Jmax AWG_S1 AWG_S2 AWG_S3 AWG_S4 AWG_H1 AWG_H2 AWG_H3 AWG_H4; do
        if [[ -z "${!param}" ]]; then
            log_error "Parameter $param not found in $CONFIG_FILE"
            missing=1
        fi
    done
    if [[ $missing -eq 1 ]]; then
        return 1
    fi
    return 0
}

# ==============================================================================
# Key generation
# ==============================================================================

# Generate keypair (private + public)
# generate_keypair <name>
# Result: keys/<name>.private, keys/<name>.public
generate_keypair() {
    local name="$1"
    if [[ -z "$name" ]]; then
        log_error "generate_keypair: name not specified"
        return 1
    fi
    mkdir -p "$KEYS_DIR" || {
        log_error "Failed to create $KEYS_DIR"
        return 1
    }

    local privkey pubkey
    privkey=$(awg genkey) || {
        log_error "Failed to generate private key for '$name'"
        return 1
    }
    pubkey=$(echo "$privkey" | awg pubkey) || {
        log_error "Failed to generate public key for '$name'"
        return 1
    }

    echo "$privkey" > "$KEYS_DIR/${name}.private" || {
        log_error "Failed to write private key for '$name'"
        return 1
    }
    echo "$pubkey" > "$KEYS_DIR/${name}.public" || {
        log_error "Failed to write public key for '$name'"
        return 1
    }
    chmod 600 "$KEYS_DIR/${name}.private" "$KEYS_DIR/${name}.public" || {
        log_error "Failed to set permissions on keys for '$name'"
        return 1
    }
    log_debug "Keys for '$name' generated."
    return 0
}

# Generate server keys
# Result: server_private.key, server_public.key in AWG_DIR
generate_server_keys() {
    local privkey pubkey
    privkey=$(awg genkey) || {
        log_error "Failed to generate server private key"
        return 1
    }
    pubkey=$(echo "$privkey" | awg pubkey) || {
        log_error "Failed to generate server public key"
        return 1
    }

    echo "$privkey" > "$AWG_DIR/server_private.key" || return 1
    echo "$pubkey" > "$AWG_DIR/server_public.key" || return 1
    chmod 600 "$AWG_DIR/server_private.key" "$AWG_DIR/server_public.key" || {
        log_error "Failed to set permissions on server keys"
        return 1
    }
    log "Server keys generated."
    return 0
}

# ==============================================================================
# Config rendering
# ==============================================================================

# Render server config for AWG 2.0
# Uses global variables from load_awg_params()
# shellcheck disable=SC2154  # AWG_* vars loaded via load_awg_params -> source
render_server_config() {
    load_awg_params || return 1

    local server_privkey
    if [[ -f "$AWG_DIR/server_private.key" ]]; then
        server_privkey=$(cat "$AWG_DIR/server_private.key")
    else
        log_error "Server private key not found: $AWG_DIR/server_private.key"
        return 1
    fi

    local nic
    nic=$(get_main_nic)
    if [[ -z "$nic" ]]; then
        log_error "Failed to detect network interface."
        return 1
    fi

    local server_ip subnet_mask
    server_ip=$(echo "$AWG_TUNNEL_SUBNET" | cut -d'/' -f1)
    subnet_mask=$(echo "$AWG_TUNNEL_SUBNET" | cut -d'/' -f2)

    local conf_dir
    conf_dir=$(dirname "$SERVER_CONF_FILE")
    mkdir -p "$conf_dir" || {
        log_error "Failed to create $conf_dir"
        return 1
    }

    # PostUp/PostDown rules for routing
    local postup="iptables -I FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -s ${AWG_TUNNEL_SUBNET} -o ${nic} -j MASQUERADE"
    local postdown="iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -s ${AWG_TUNNEL_SUBNET} -o ${nic} -j MASQUERADE"

    # IPv6 rules if not disabled
    if [[ "${DISABLE_IPV6:-1}" -eq 0 ]]; then
        postup="${postup}; ip6tables -I FORWARD -i %i -j ACCEPT; ip6tables -t nat -A POSTROUTING -o ${nic} -j MASQUERADE"
        postdown="${postdown}; ip6tables -D FORWARD -i %i -j ACCEPT; ip6tables -t nat -D POSTROUTING -o ${nic} -j MASQUERADE"
    fi

    # Build config via temp file (atomic write)
    local tmpfile
    tmpfile=$(awg_mktemp) || { log_error "mktemp failed"; return 1; }

    cat > "$tmpfile" << EOF
[Interface]
PrivateKey = ${server_privkey}
Address = ${server_ip}/${subnet_mask}
MTU = 1280
ListenPort = ${AWG_PORT}
PostUp = ${postup}
PostDown = ${postdown}
Jc = ${AWG_Jc}
Jmin = ${AWG_Jmin}
Jmax = ${AWG_Jmax}
S1 = ${AWG_S1}
S2 = ${AWG_S2}
S3 = ${AWG_S3}
S4 = ${AWG_S4}
H1 = ${AWG_H1}
H2 = ${AWG_H2}
H3 = ${AWG_H3}
H4 = ${AWG_H4}
EOF

    # Add I1 only if set (CPS is optional)
    if [[ -n "${AWG_I1}" ]]; then
        echo "I1 = ${AWG_I1}" >> "$tmpfile"
    fi

    if ! mv "$tmpfile" "$SERVER_CONF_FILE"; then
        rm -f "$tmpfile"
        log_error "Failed to write server config"
        return 1
    fi
    chmod 600 "$SERVER_CONF_FILE"
    log "Server config created: $SERVER_CONF_FILE"
    return 0
}

# Render client config for AWG 2.0
# render_client_config <name> <client_ip> <client_privkey> <server_pubkey> <endpoint> <port>
render_client_config() {
    local name="$1"
    local client_ip="$2"
    local client_privkey="$3"
    local server_pubkey="$4"
    local endpoint="$5"
    local port="$6"

    load_awg_params || return 1

    local conf_file="$AWG_DIR/${name}.conf"
    local allowed_ips="${ALLOWED_IPS:-0.0.0.0/0}"

    local tmpfile
    tmpfile=$(awg_mktemp) || { log_error "mktemp failed"; return 1; }

    cat > "$tmpfile" << EOF
[Interface]
PrivateKey = ${client_privkey}
Address = ${client_ip}/32
DNS = 1.1.1.1
MTU = 1280
Jc = ${AWG_Jc}
Jmin = ${AWG_Jmin}
Jmax = ${AWG_Jmax}
S1 = ${AWG_S1}
S2 = ${AWG_S2}
S3 = ${AWG_S3}
S4 = ${AWG_S4}
H1 = ${AWG_H1}
H2 = ${AWG_H2}
H3 = ${AWG_H3}
H4 = ${AWG_H4}
EOF

    if [[ -n "${AWG_I1}" ]]; then
        echo "I1 = ${AWG_I1}" >> "$tmpfile"
    fi

    cat >> "$tmpfile" << EOF

[Peer]
PublicKey = ${server_pubkey}
Endpoint = ${endpoint}:${port}
AllowedIPs = ${allowed_ips}
PersistentKeepalive = 33
EOF

    if ! mv "$tmpfile" "$conf_file"; then
        rm -f "$tmpfile"
        log_error "Failed to write config for client '$name'"
        return 1
    fi
    chmod 600 "$conf_file"
    log_debug "Config for '$name' created: $conf_file"
    return 0
}

# ==============================================================================
# Config application (syncconf)
# ==============================================================================

# Apply configuration changes
# AWG_SKIP_APPLY=1: skip apply (for batch automation)
# AWG_APPLY_MODE=syncconf|restart: apply method (config or --apply-mode CLI)
# flock on .awg_apply.lock: prevents concurrent apply calls
apply_config() {
    # Skip apply (AWG_SKIP_APPLY=1 manage add/remove ...)
    if [[ "${AWG_SKIP_APPLY:-0}" == "1" ]]; then
        log_debug "apply_config skipped (AWG_SKIP_APPLY=1)."
        return 0
    fi

    # Inter-process lock for apply_config
    local apply_lockfile="${AWG_DIR}/.awg_apply.lock"
    local apply_fd
    exec {apply_fd}>"$apply_lockfile"
    if ! flock -x -w 120 "$apply_fd"; then
        log_warn "Failed to acquire apply_config lock."
        exec {apply_fd}>&-
        return 1
    fi

    local rc=0

    if [[ "${AWG_APPLY_MODE:-syncconf}" == "restart" ]]; then
        log "Restarting service (apply-mode=restart)..."
        systemctl restart awg-quick@awg0 2>/dev/null; rc=$?
        [[ $rc -ne 0 ]] && log_warn "Service restart error."
        exec {apply_fd}>&-
        return $rc
    fi

    local strip_out
    strip_out=$(timeout 10 awg-quick strip awg0 2>/dev/null) || {
        log_warn "awg-quick strip failed or timed out, falling back to full restart."
        systemctl restart awg-quick@awg0 2>/dev/null; rc=$?
        [[ $rc -ne 0 ]] && log_warn "Service restart error."
        exec {apply_fd}>&-
        return $rc
    }
    echo "$strip_out" | timeout 10 awg syncconf awg0 /dev/stdin 2>/dev/null || {
        log_warn "awg syncconf failed or timed out, falling back to full restart."
        systemctl restart awg-quick@awg0 2>/dev/null; rc=$?
        [[ $rc -ne 0 ]] && log_warn "Service restart error."
        exec {apply_fd}>&-
        return $rc
    }
    log_debug "Config applied (syncconf)."
    exec {apply_fd}>&-
}

# ==============================================================================
# Peer management
# ==============================================================================

# Get next free IP in subnet
get_next_client_ip() {
    local subnet_base
    subnet_base=$(echo "${AWG_TUNNEL_SUBNET:-10.9.9.1/24}" | cut -d'/' -f1 | cut -d'.' -f1-3)

    # Associative array for O(1) lookup
    declare -A used_set
    used_set["${subnet_base}.1"]=1
    if [[ -f "$SERVER_CONF_FILE" ]]; then
        while IFS= read -r ip; do
            used_set["$ip"]=1
        done < <(grep -oP 'AllowedIPs\s*=\s*\K[0-9.]+' "$SERVER_CONF_FILE")
    fi

    local i candidate
    for i in $(seq 2 254); do
        candidate="${subnet_base}.${i}"
        if [[ -z "${used_set[$candidate]+x}" ]]; then
            echo "$candidate"
            return 0
        fi
    done

    log_error "No free IPs in subnet ${subnet_base}.0/24"
    return 1
}

# [Peer] addition to server config (atomic via tmpfile + mv)
# NOTE: caller must hold flock on ${AWG_DIR}/.awg_config.lock
# add_peer_to_server <name> <pubkey> <client_ip>
add_peer_to_server() {
    local name="$1"
    local pubkey="$2"
    local client_ip="$3"

    if [[ -z "$name" || -z "$pubkey" || -z "$client_ip" ]]; then
        log_error "add_peer_to_server: insufficient arguments"
        return 1
    fi

    if grep -qxF "#_Name = ${name}" "$SERVER_CONF_FILE" 2>/dev/null; then
        log_error "Peer '$name' already exists in config"
        return 1
    fi

    # Add peer via temp file (atomic)
    local tmpfile
    tmpfile=$(awg_mktemp) || { log_error "mktemp failed"; return 1; }

    cp "$SERVER_CONF_FILE" "$tmpfile" || {
        rm -f "$tmpfile"
        log_error "Failed to copy server config"
        return 1
    }

    cat >> "$tmpfile" << EOF

[Peer]
#_Name = ${name}
PublicKey = ${pubkey}
AllowedIPs = ${client_ip}/32
EOF

    if ! mv "$tmpfile" "$SERVER_CONF_FILE"; then
        rm -f "$tmpfile"
        log_error "Failed to update server config"
        return 1
    fi
    chmod 600 "$SERVER_CONF_FILE"
    log "Peer '$name' added to server config."
    return 0
}

# Remove [Peer] from server config by name (with locking)
# remove_peer_from_server <name>
remove_peer_from_server() {
    local name="$1"

    if [[ -z "$name" ]]; then
        log_error "remove_peer_from_server: name not specified"
        return 1
    fi

    # Inter-process lock
    local lockfile="${AWG_DIR}/.awg_config.lock"
    local lock_fd
    exec {lock_fd}>"$lockfile"
    if ! flock -x -w 10 "$lock_fd"; then
        log_error "Failed to acquire config lock"
        exec {lock_fd}>&-
        return 1
    fi

    if ! grep -qxF "#_Name = ${name}" "$SERVER_CONF_FILE" 2>/dev/null; then
        log_error "Peer '$name' not found in config"
        exec {lock_fd}>&-
        return 1
    fi

    local tmpfile
    tmpfile=$(awg_mktemp) || { log_error "mktemp failed"; exec {lock_fd}>&-; return 1; }

    # Remove [Peer] block containing #_Name = name
    # Logic: buffer each [Peer] block, check name, print only if not matching
    awk -v target="$name" '
    BEGIN { buf=""; is_target=0 }
    /^\[Peer\]/ {
        # Print previous buffer if not target
        if (buf != "" && !is_target) printf "%s", buf
        buf = $0 "\n"
        is_target = 0
        next
    }
    /^\[/ && !/^\[Peer\]/ {
        # Any other section — flush buffer
        if (buf != "" && !is_target) printf "%s", buf
        buf = ""
        is_target = 0
        print
        next
    }
    {
        if (buf != "") {
            buf = buf $0 "\n"
            if ($0 == "#_Name = " target) is_target = 1
        } else {
            print
        }
    }
    END {
        if (buf != "" && !is_target) printf "%s", buf
    }
    ' "$SERVER_CONF_FILE" > "$tmpfile"

    # Normalize: squeeze multiple blank lines into one
    local tmpclean
    tmpclean=$(awg_mktemp) || { log_error "mktemp failed"; exec {lock_fd}>&-; return 1; }
    cat -s "$tmpfile" > "$tmpclean" && mv "$tmpclean" "$tmpfile"

    if ! mv "$tmpfile" "$SERVER_CONF_FILE"; then
        rm -f "$tmpfile"
        log_error "Failed to update server config"
        exec {lock_fd}>&-
        return 1
    fi
    chmod 600 "$SERVER_CONF_FILE"
    exec {lock_fd}>&-
    log "Peer '$name' removed from server config."
    return 0
}

# ==============================================================================
# Full client lifecycle
# ==============================================================================

# Generate QR code for client
# generate_qr <name>
generate_qr() {
    local name="$1"
    local conf_file="$AWG_DIR/${name}.conf"
    local png_file="$AWG_DIR/${name}.png"

    if [[ ! -f "$conf_file" ]]; then
        log_error "Client config '$name' not found: $conf_file"
        return 1
    fi

    if ! command -v qrencode &>/dev/null; then
        log_warn "qrencode is not installed, QR code not created for '$name'."
        return 1
    fi

    qrencode -t png -o "$png_file" < "$conf_file" || {
        log_error "Failed to generate QR code for '$name'"
        return 1
    }

    chmod 600 "$png_file"
    log_debug "QR code for '$name' created: $png_file"
    return 0
}

# Generate vpn:// URI for import into Amnezia Client
# generate_vpn_uri <name>
generate_vpn_uri() {
    local name="$1"
    local conf_file="$AWG_DIR/${name}.conf"
    local uri_file="$AWG_DIR/${name}.vpnuri"
    local endpoint_override=""

    if [[ ! -f "$conf_file" ]]; then
        log_error "Client config '$name' not found: $conf_file"
        return 1
    fi

    if ! command -v perl &>/dev/null; then
        log_warn "perl not found, vpn:// URI not created for '$name'."
        return 1
    fi

    if ! perl -MCompress::Zlib -MMIME::Base64 -e '1' 2>/dev/null; then
        log_warn "Perl modules Compress::Zlib/MIME::Base64 not found, vpn:// URI not created."
        return 1
    fi

    load_awg_params || return 1

    local client_privkey client_ip server_pubkey endpoint allowed_ips
    client_privkey=$(grep -oP 'PrivateKey\s*=\s*\K\S+' "$conf_file") || return 1
    client_ip=$(grep -oP 'Address\s*=\s*\K[0-9./]+' "$conf_file") || return 1
    server_pubkey=$(cat "$AWG_DIR/server_public.key" 2>/dev/null) || return 1
    local raw_endpoint
    raw_endpoint=$(grep -oP 'Endpoint\s*=\s*\K\S+' "$conf_file") || return 1
    if [[ "$raw_endpoint" == \[* ]]; then
        # IPv6: [addr]:port
        endpoint="${raw_endpoint%%]:*}"
        endpoint="${endpoint#\[}"
    else
        # IPv4/hostname: addr:port
        endpoint="${raw_endpoint%:*}"
    fi
    if [[ "$name" =~ ^awg-([0-9]+)-([0-9]+)-([0-9]+)-([0-9]+)$ ]]; then
        endpoint_override="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}.${BASH_REMATCH[4]}"
        endpoint="$endpoint_override"
    fi
    allowed_ips=$(grep -oP 'AllowedIPs\s*=\s*\K.+' "$conf_file" | tr -d ' ') || allowed_ips="0.0.0.0/0"

    local vpn_uri perl_err
    perl_err=$(awg_mktemp) || perl_err="/tmp/awg_perl_err.$$"
    # shellcheck disable=SC2016
    vpn_uri=$(perl -MCompress::Zlib -MMIME::Base64 -e '
        my ($conf_path, $h1,$h2,$h3,$h4, $jc,$jmin,$jmax,
            $s1,$s2,$s3,$s4, $i1, $port, $ep, $cip, $cpk, $spk, $aips) = @ARGV;

        open my $fh, "<", $conf_path or die;
        local $/; my $raw = <$fh>; close $fh;
        chomp $raw;
        $raw =~ s/^Endpoint\s*=\s*.*$/Endpoint = $ep:$port/m;

        sub je {
            my $s = shift;
            $s =~ s/\\/\\\\/g; $s =~ s/"/\\"/g;
            $s =~ s/\n/\\n/g;  $s =~ s/\r/\\r/g;
            $s =~ s/\t/\\t/g;  return $s;
        }

        my $inner = "{";
        $inner .= qq("H1":"$h1","H2":"$h2","H3":"$h3","H4":"$h4",);
        $inner .= qq("Jc":"$jc","Jmin":"$jmin","Jmax":"$jmax",);
        $inner .= qq("S1":"$s1","S2":"$s2","S3":"$s3","S4":"$s4",);
        if ($i1 ne "") {
            my $ei1 = je($i1);
            $inner .= qq("I1":"$ei1","I2":"","I3":"","I4":"","I5":"",);
        }
        my $eraw = je($raw);
        my @ips = split(/,/, $aips);
        my $ips_json = join(",", map { qq("$_") } @ips);
        $inner .= qq("allowed_ips":[$ips_json],);
        $inner .= qq("client_ip":"$cip","client_priv_key":"$cpk",);
        $inner .= qq("config":"$eraw",);
        $inner .= qq("hostName":"$ep","mtu":"1280",);
        $inner .= qq("persistent_keep_alive":"33","port":$port,);
        $inner .= qq("server_pub_key":"$spk"});

        my $einner = je($inner);
        my $outer = "{";
        $outer .= qq("containers":[{"awg":{"isThirdPartyConfig":true,);
        $outer .= qq("last_config":"$einner",);
        $outer .= qq("port":"$port","protocol_version":"2",);
        $outer .= qq("transport_proto":"udp"\},"container":"amnezia-awg"\}],);
        $outer .= qq("defaultContainer":"amnezia-awg",);
        $outer .= qq("description":"$ep",);
        $outer .= qq("dns1":"1.1.1.1","dns2":"1.0.0.1",);
        $outer .= qq("hostName":"$ep"});

        my $compressed = compress($outer);
        my $payload = pack("N", length($outer)) . $compressed;
        my $b64 = encode_base64($payload, "");
        $b64 =~ tr|+/|-_|;
        $b64 =~ s/=+$//;
        print "vpn://" . $b64;
    ' "$conf_file" \
        "$AWG_H1" "$AWG_H2" "$AWG_H3" "$AWG_H4" \
        "$AWG_Jc" "$AWG_Jmin" "$AWG_Jmax" \
        "$AWG_S1" "$AWG_S2" "$AWG_S3" "$AWG_S4" \
        "$AWG_I1" "$AWG_PORT" "$endpoint" \
        "$client_ip" "$client_privkey" "$server_pubkey" "$allowed_ips" 2>"$perl_err"
    )

    if [[ -z "$vpn_uri" ]]; then
        log_warn "Failed to generate vpn:// URI for '$name'."
        [[ -s "$perl_err" ]] && log_warn "Perl: $(cat "$perl_err")"
        rm -f "$perl_err"
        return 1
    fi
    rm -f "$perl_err"

    echo "$vpn_uri" > "$uri_file"
    chmod 600 "$uri_file"
    log_debug "vpn:// URI for '$name' created: $uri_file"
    return 0
}

# Full client creation cycle:
# keypair -> next IP -> client config -> add peer -> QR
# generate_client <name> [endpoint]
generate_client() {
    local name="$1"
    local endpoint="${2:-}"

    if [[ -z "$name" ]]; then
        log_error "generate_client: name not specified"
        return 1
    fi

    # Load parameters
    load_awg_params || return 1

    # Inter-process lock: atomicity of IP allocation + peer addition
    local lockfile="${AWG_DIR}/.awg_config.lock"
    local lock_fd
    exec {lock_fd}>"$lockfile"
    if ! flock -x -w 30 "$lock_fd"; then
        log_error "Failed to acquire config lock"
        exec {lock_fd}>&-
        return 1
    fi

    # Generate keys
    generate_keypair "$name" || { exec {lock_fd}>&-; return 1; }

    # Next free IP
    local client_ip
    client_ip=$(get_next_client_ip) || { exec {lock_fd}>&-; return 1; }

    # Read keys
    local client_privkey client_pubkey server_pubkey
    client_privkey=$(cat "$KEYS_DIR/${name}.private") || { exec {lock_fd}>&-; return 1; }
    client_pubkey=$(cat "$KEYS_DIR/${name}.public") || { exec {lock_fd}>&-; return 1; }

    if [[ ! -f "$AWG_DIR/server_public.key" ]]; then
        log_error "Server public key not found"
        exec {lock_fd}>&-
        return 1
    fi
    server_pubkey=$(cat "$AWG_DIR/server_public.key") || { exec {lock_fd}>&-; return 1; }

    # Endpoint: from argument, config, or auto-detect
    if [[ -z "$endpoint" ]]; then
        endpoint="${AWG_ENDPOINT:-}"
    fi
    if [[ -z "$endpoint" ]]; then
        endpoint=$(get_server_public_ip)
    fi
    if [[ -z "$endpoint" ]]; then
        log_error "Failed to determine server public IP. Use --endpoint=IP"
        exec {lock_fd}>&-
        return 1
    fi

    # Client config
    render_client_config "$name" "$client_ip" "$client_privkey" "$server_pubkey" "$endpoint" "${AWG_PORT}" || {
        log_error "Rollback: deleting keys for '$name'"
        rm -f "$KEYS_DIR/${name}.private" "$KEYS_DIR/${name}.public"
        exec {lock_fd}>&-
        return 1
    }

    # Add peer to server config
    if ! add_peer_to_server "$name" "$client_pubkey" "$client_ip"; then
        log_error "Rollback: deleting files for '$name'"
        rm -f "$AWG_DIR/${name}.conf" "$KEYS_DIR/${name}.private" "$KEYS_DIR/${name}.public"
        exec {lock_fd}>&-
        return 1
    fi

    # Release lock — peer written, remaining operations are non-critical
    exec {lock_fd}>&-

    # QR code (optional, failure is non-fatal)
    if ! generate_qr "$name"; then
        log_warn "QR code not created. Config: $AWG_DIR/${name}.conf"
    fi

    # vpn:// URI for Amnezia Client (optional)
    if ! generate_vpn_uri "$name"; then
        log_warn "vpn:// URI not created for '$name'."
    fi

    log "Client '$name' created (IP: $client_ip)."
    return 0
}

# Regenerate config and QR for existing client
# regenerate_client <name> [endpoint]
regenerate_client() {
    local name="$1"
    local endpoint="${2:-}"

    if [[ -z "$name" ]]; then
        log_error "regenerate_client: name not specified"
        return 1
    fi

    load_awg_params || return 1

    # Check that client exists in server config
    if ! grep -qxF "#_Name = ${name}" "$SERVER_CONF_FILE" 2>/dev/null; then
        log_error "Client '$name' not found in server config"
        return 1
    fi

    # Read client private key
    local client_privkey client_ip server_pubkey
    if [[ -f "$KEYS_DIR/${name}.private" ]]; then
        client_privkey=$(cat "$KEYS_DIR/${name}.private")
    elif [[ -f "$AWG_DIR/${name}.conf" ]]; then
        # Try to extract from existing config
        client_privkey=$(sed -n 's/^PrivateKey[ \t]*=[ \t]*//p' "$AWG_DIR/${name}.conf" | tr -d '[:space:]')
    fi

    if [[ -z "$client_privkey" ]]; then
        log_error "Private key for client '$name' not found"
        return 1
    fi

    # Client IP from server config
    # Find [Peer] block with #_Name = name, then AllowedIPs
    client_ip=$(awk -v target="$name" '
    /^\[Peer\]/ { in_peer=1; found=0; next }
    in_peer && $0 == "#_Name = " target { found=1; next }
    in_peer && found && /^AllowedIPs/ { gsub(/AllowedIPs[ \t]*=[ \t]*/, ""); gsub(/\/[0-9]+/, ""); print; exit }
    /^\[/ && !/^\[Peer\]/ { in_peer=0; found=0 }
    ' "$SERVER_CONF_FILE")

    if [[ -z "$client_ip" ]]; then
        log_error "Client IP for '$name' not found in server config"
        return 1
    fi

    server_pubkey=$(cat "$AWG_DIR/server_public.key" 2>/dev/null) || {
        log_error "Server public key not found"
        return 1
    }

    # Preserve user settings from current .conf (modified via modify command)
    local current_dns="1.1.1.1" current_keepalive="33" current_allowed_ips="${ALLOWED_IPS:-0.0.0.0/0}" current_endpoint=""
    if [[ -f "$AWG_DIR/${name}.conf" ]]; then
        local _v
        _v=$(sed -n 's/^DNS[ \t]*=[ \t]*//p' "$AWG_DIR/${name}.conf" | tr -d '[:space:]')
        [[ -n "$_v" ]] && current_dns="$_v"
        _v=$(sed -n 's/^PersistentKeepalive[ \t]*=[ \t]*//p' "$AWG_DIR/${name}.conf" | tr -d '[:space:]')
        [[ -n "$_v" ]] && current_keepalive="$_v"
        _v=$(sed -n '/^\[Peer\]/,$ s/^AllowedIPs[ \t]*=[ \t]*//p' "$AWG_DIR/${name}.conf" | tr -d '[:space:]')
        [[ -n "$_v" ]] && current_allowed_ips="$_v"
        _v=$(sed -n '/^\[Peer\]/,$ s/^Endpoint[ \t]*=[ \t]*//p' "$AWG_DIR/${name}.conf" | tr -d '[:space:]' | head -n1)
        if [[ -n "$_v" ]]; then
            if [[ "$_v" == \[* ]]; then
                current_endpoint="${_v%%]:*}"
                current_endpoint="${current_endpoint#\[}"
            else
                current_endpoint="${_v%:*}"
            fi
        fi
    fi

    # Endpoint
    if [[ -z "$endpoint" && -n "$current_endpoint" ]]; then
        endpoint="$current_endpoint"
    fi
    if [[ -z "$endpoint" ]]; then
        endpoint="${AWG_ENDPOINT:-}"
    fi
    if [[ -z "$endpoint" ]]; then
        endpoint=$(get_server_public_ip)
    fi
    if [[ -z "$endpoint" ]]; then
        log_error "Failed to determine server public IP."
        return 1
    fi

    # Config regeneration
    render_client_config "$name" "$client_ip" "$client_privkey" "$server_pubkey" "$endpoint" "${AWG_PORT}" || return 1

    # Restore user settings
    sed -i "s/^DNS = .*/DNS = ${current_dns}/" "$AWG_DIR/${name}.conf"
    sed -i "s/^PersistentKeepalive = .*/PersistentKeepalive = ${current_keepalive}/" "$AWG_DIR/${name}.conf"
    sed -i "s|^AllowedIPs = .*|AllowedIPs = ${current_allowed_ips}|" "$AWG_DIR/${name}.conf"

    # QR code
    generate_qr "$name"

    # vpn:// URI for Amnezia Client
    generate_vpn_uri "$name"

    log "Client config for '$name' regenerated."
    return 0
}

# ==============================================================================
# Validation
# ==============================================================================

# Validate AWG 2.0 server config
validate_awg_config() {
    if [[ ! -f "$SERVER_CONF_FILE" ]]; then
        log_error "Server config not found: $SERVER_CONF_FILE"
        return 1
    fi

    local ok=1
    local param
    local params=("Jc" "Jmin" "Jmax" "S1" "S2" "S3" "S4" "H1" "H2" "H3" "H4")

    for param in "${params[@]}"; do
        if ! grep -q "^${param} = " "$SERVER_CONF_FILE"; then
            log_error "Parameter '$param' not found in server config"
            ok=0
        fi
    done

    # I1 is optional but recommended for AWG 2.0
    if ! grep -q "^I1 = " "$SERVER_CONF_FILE"; then
        log_warn "Parameter I1 (CPS) not found — CPS concealment is not active"
    fi

    if [[ $ok -eq 1 ]]; then
        log "AWG 2.0 config validation: OK"
        return 0
    else
        return 1
    fi
}

# ==============================================================================
# Client expiry
# ==============================================================================

EXPIRY_DIR="${AWG_DIR}/expiry"
EXPIRY_CRON="/etc/cron.d/awg-expiry"

# Parse duration string to seconds: 1h, 12h, 1d, 7d, 30d
# parse_duration <duration_string>
parse_duration() {
    local input="$1"
    local num unit
    if [[ "$input" =~ ^([0-9]+)([hdw])$ ]]; then
        num="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[2]}"
    else
        log_error "Invalid duration format: '$input'. Use: 1h, 12h, 1d, 7d, 4w"
        return 1
    fi
    case "$unit" in
        h) echo $((num * 3600)) ;;
        d) echo $((num * 86400)) ;;
        w) echo $((num * 604800)) ;; # 7 days
        *) return 1 ;;
    esac
}

# Set client expiry
# set_client_expiry <name> <duration>
set_client_expiry() {
    local name="$1"
    local duration="$2"
    if ! grep -qxF "#_Name = ${name}" "$SERVER_CONF_FILE" 2>/dev/null; then
        log_error "Client '$name' not found."
        return 1
    fi
    local seconds
    seconds=$(parse_duration "$duration") || return 1
    local now
    now=$(date +%s)
    local expires_at=$((now + seconds))

    mkdir -p "$EXPIRY_DIR" || {
        log_error "Failed to create $EXPIRY_DIR"
        return 1
    }
    echo "$expires_at" > "$EXPIRY_DIR/$name" || {
        log_error "Failed to write expiry for '$name'"
        return 1
    }
    chmod 600 "$EXPIRY_DIR/$name"
    local expires_date
    expires_date=$(date -d "@$expires_at" '+%F %T' 2>/dev/null || echo "$expires_at")
    log "Expiry for '$name': $expires_date ($duration)"
    return 0
}

# Get client expiry (unix timestamp or empty)
# get_client_expiry <name>
get_client_expiry() {
    local name="$1"
    local efile="$EXPIRY_DIR/$name"
    if [[ -f "$efile" ]]; then
        cat "$efile"
    fi
}

# Format remaining time
# format_remaining <expires_at_timestamp>
format_remaining() {
    local expires_at="$1"
    local now
    now=$(date +%s)
    local diff=$((expires_at - now))
    if [[ $diff -le 0 ]]; then
        local ago=$(( (-diff) / 3600 ))
        if [[ $ago -ge 24 ]]; then
            echo "expired $(( ago / 24 ))d ago"
        elif [[ $ago -ge 1 ]]; then
            echo "expired ${ago}h ago"
        else
            local ago_mins=$(( (-diff) / 60 ))
            if [[ $ago_mins -ge 1 ]]; then
                echo "expired ${ago_mins}m ago"
            else
                echo "just expired"
            fi
        fi
        return 0
    fi
    local days=$((diff / 86400))
    local hours=$(( (diff % 86400) / 3600 ))
    if [[ $days -gt 0 ]]; then
        echo "${days}d ${hours}h"
    else
        local mins=$(( (diff % 3600) / 60 ))
        echo "${hours}h ${mins}m"
    fi
}

# Check and remove expired clients
check_expired_clients() {
    if [[ ! -d "$EXPIRY_DIR" ]]; then return 0; fi

    local removed=0
    local efile
    for efile in "$EXPIRY_DIR"/*; do
        [[ -f "$efile" ]] || continue
        local name
        name=$(basename "$efile")
        local expires_at
        expires_at=$(cat "$efile" 2>/dev/null)
        if [[ -z "$expires_at" || ! "$expires_at" =~ ^[0-9]+$ ]]; then
            log_warn "Malformed expiry data for '$name': '$(head -c 50 "$efile" 2>/dev/null)'"
            continue
        fi

        local now
        now=$(date +%s)
        if [[ $now -ge $expires_at ]]; then
            log "Client '$name' expired. Removing..."
            if remove_peer_from_server "$name" 2>/dev/null; then
                rm -f "$AWG_DIR/$name.conf" "$AWG_DIR/$name.png" "$AWG_DIR/$name.vpnuri"
                rm -f "$KEYS_DIR/${name}.private" "$KEYS_DIR/${name}.public"
                rm -f "$efile"
                log "Client '$name' removed (expired)."
                ((removed++))
            else
                log_warn "Failed to remove expired client '$name'."
            fi
        fi
    done

    if [[ $removed -gt 0 ]]; then
        log "Expired clients removed: $removed. Applying config..."
        apply_config
    fi
}

# Install cron job for auto-removal
install_expiry_cron() {
    if [[ -f "$EXPIRY_CRON" ]]; then
        log_debug "Expiry cron job already installed."
        return 0
    fi
    cat > "$EXPIRY_CRON" << CRONEOF
# AmneziaWG client expiry check — every 5 minutes
AWG_DIR=${AWG_DIR}
CONFIG_FILE=${CONFIG_FILE}
SERVER_CONF_FILE=${SERVER_CONF_FILE}
*/5 * * * * root /bin/bash -c 'source ${AWG_DIR}/awg_common.sh || exit 1; check_expired_clients' >> ${AWG_DIR}/expiry.log 2>&1
CRONEOF
    chmod 644 "$EXPIRY_CRON"
    log "Expiry cron job installed: $EXPIRY_CRON"
}

# Remove client expiry data
remove_client_expiry() {
    local name="$1"
    rm -f "$EXPIRY_DIR/$name" 2>/dev/null
    # Remove cron if no more clients with expiry
    if [[ -d "$EXPIRY_DIR" ]] && [[ -z "$(ls -A "$EXPIRY_DIR" 2>/dev/null)" ]]; then
        rm -f "$EXPIRY_CRON" 2>/dev/null
        log_debug "Expiry cron job removed (no clients with expiry)."
    fi
}
