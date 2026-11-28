#!/usr/bin/env bash
# ============================================================
# 模块: 20_protocol.sh
# 职责: 协议构建器、TLS 域名选择、证书生成
# 依赖: 00_base.sh (协议注册表), 01_utils.sh
# ============================================================

# ---------- 协议 entry key 映射（基于注册表，取代 6 处 case） ----------

entry_key_prefix_by_type() {
  local proto="$1"
  local prefix="${PROTO_PREFIX[$proto]:-}"
  if [ -z "$prefix" ]; then return 1; fi
  echo "$prefix"
}

entry_key_from_parts() {
  local proto="$1" port="$2"
  local prefix
  prefix="$(entry_key_prefix_by_type "$proto")" || return 1
  echo "${prefix}-${port}"
}

entry_key_to_protocol_label() {
  local key="$1"
  # 从 entry_key 提取 prefix 并查注册表
  local prefix
  for prefix in "${!PREFIX_TO_PROTO[@]}"; do
    if [[ "$key" == "${prefix}-"* ]]; then
      echo "${PREFIX_TO_PROTO[$prefix]}"
      return 0
    fi
  done
  echo "unknown"
}

entry_key_to_port() {
  echo "$1" | awk -F- '{print $NF}'
}

# ---------- TLS 证书 ----------

ensure_self_signed_cert() {
  local cn="$1" crt_path="$2" key_path="$3"
  mkdir -p "$(dirname "$crt_path")" || return 1
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$key_path" -out "$crt_path" -days 36500 -nodes -subj "/CN=${cn}" >/dev/null 2>&1 || return 1
  [ -s "$crt_path" ] && [ -s "$key_path" ]
}

# 自签证书（按 <前缀>-<端口> 命名，如 hy2-443.crt）：设置 _TLS_CRT/_TLS_KEY，失败返回 1。
# AnyTLS/Trojan/TUIC/Hysteria2 共用同一套逻辑，证书文件一眼能看出属于哪个节点。
tls_cert_for_prefix() {
  local prefix="$1" port="$2" sni="$3"
  _TLS_CRT="/etc/sing-box/${prefix}-${port}.crt"
  _TLS_KEY="/etc/sing-box/${prefix}-${port}.key"
  local cert_public key_public
  if openssl x509 -in "$_TLS_CRT" -checkend 0 -noout >/dev/null 2>&1 &&
    cert_public="$(openssl x509 -in "$_TLS_CRT" -pubkey -noout 2>/dev/null)" &&
    key_public="$(openssl pkey -in "$_TLS_KEY" -pubout 2>/dev/null)" &&
    [ "$cert_public" = "$key_public" ]; then
    return 0
  fi
  ensure_self_signed_cert "$sni" "$_TLS_CRT" "$_TLS_KEY"
}

generate_reality_keypair_auto() {
  local out priv pub
  out="$(sing-box generate reality-keypair 2>/dev/null || true)"
  priv="$(printf '%s\n' "$out" | awk -F': *' '/PrivateKey/ {print $2; exit}')"
  pub="$(printf '%s\n' "$out" | awk -F': *' '/PublicKey/ {print $2; exit}')"
  if [ -n "$priv" ] && [ -n "$pub" ]; then
    printf '%s\t%s\n' "$priv" "$pub"
    return 0
  fi
  return 1
}

# Self-signed listeners have a stable SNI. Only Reality contacts a handshake host.
SELF_SIGNED_SNI="sing-box.local"
REALITY_DEFAULT_HANDSHAKE="www.microsoft.com"

protocol_password_urlsafe() (
  set -o pipefail
  openssl rand -base64 16 | tr '/+' '_-' | tr -d '=\n'
)

reality_handshake_check() {
  local name="$1" result
  [[ "$name" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && "$name" == *.* ]] || return 1
  result="$(run_with_timeout 8 openssl s_client -connect "${name}:443" -servername "$name" \
    -verify_hostname "$name" -verify_return_error -tls1_3 -alpn h2 </dev/null 2>&1)" || return 1
  grep -q 'ALPN protocol: h2' <<< "$result"
}

reality_public_key_from_private() (
  set -o pipefail
  local private="$1"
  [[ "$private" =~ ^[A-Za-z0-9_-]{43}$ ]] || return 1
  # RFC 8410 PKCS#8 wrapper for a raw 32-byte X25519 private key.
  { printf '\060\056\002\001\000\060\005\006\003\053\145\156\004\042\004\040'
    printf '%s=' "$private" | tr '_-' '/+' | openssl base64 -d -A
  } | openssl pkey -inform DER -pubout -outform DER 2>/dev/null |
    tail -c 32 | openssl base64 -A | tr '/+' '_-' | tr -d '=\n'
)

# ---------- SS 密码规范化 ----------

ss2022_normalize_password_pair() {
  local raw="$1"
  local sp up
  if [ -z "$raw" ]; then
    sp="$(openssl rand -base64 16)" || return 1
    up="$(openssl rand -base64 16)" || return 1
    echo "${sp}:${up}"
    return 0
  fi
  sp="${raw%%:*}"
  up=""
  [[ "$raw" == *:* ]] && up="${raw#*:}"
  if ! echo "$sp" | base64 -d >/dev/null 2>&1; then sp="$(openssl rand -base64 16)"; fi
  if [ -n "$up" ] && ! echo "$up" | base64 -d >/dev/null 2>&1; then up="$(openssl rand -base64 16)"; fi
  if [ -n "$up" ]; then echo "${sp}:${up}"; else echo "$sp"; fi
}

ss2022_password_part_valid() {
  local part="$1"
  local bytes
  [ -n "$part" ] || return 1
  bytes="$(printf '%s' "$part" | base64 -d 2>/dev/null | wc -c | tr -d ' ')" || return 1
  [ "$bytes" = "16" ]
}

ss2022_prepare_password_pair() {
  local raw="${1:-}" sp up
  if [ -z "$raw" ]; then
    sp="$(openssl rand -base64 16)" || return 1
    up="$(openssl rand -base64 16)" || return 1
    [ -n "$sp" ] && [ -n "$up" ] || return 1
    echo "${sp}:${up}"
    return 0
  fi

  sp="${raw%%:*}"
  if [[ "$raw" == *:* ]]; then
    up="${raw#*:}"
  else
    up="$sp"
  fi
  ss2022_password_part_valid "$sp" || return 1
  ss2022_password_part_valid "$up" || return 1
  echo "${sp}:${up}"
}

# ====================================================
# 协议 Inbound 构建器
# 每个协议一个函数，结构统一，互不依赖
# ====================================================

build_vless_reality_inbound() {
  local port="$1" sni="$2" priv="$3" sid="$4"
  local entry_key uuid sid_json
  entry_key="$(entry_key_from_parts vless-reality "$port")"
  uuid="$(sing-box generate uuid)" || return 1
  if [ -n "$sid" ]; then
    sid_json="[\"$sid\"]"
  else
    sid_json='[]'
  fi
  jq -n --arg tag "$entry_key" --arg uuid "$uuid" --arg sni "$sni" --arg priv "$priv" --argjson sid "$sid_json" --argjson port "$port" '
    {
      "type":"vless",
      "tag":$tag,
      "listen":"::",
      "listen_port":$port,
      "users":[{"name":$tag,"uuid":$uuid,"flow":"xtls-rprx-vision"}],
      "tls":{
        "enabled":true,
        "server_name":$sni,
        "reality":{
          "enabled":true,
          "handshake":{"server":$sni,"server_port":443},
          "private_key":$priv,
          "short_id":$sid
        }
      }
    }
  '
}

build_anytls_inbound() {
  local port="$1" sni="$2" pass="${3:-}"
  local entry_key crt key
  entry_key="$(entry_key_from_parts anytls "$port")"
  [ -n "$pass" ] || pass="$(protocol_password_urlsafe)" || return 1
  tls_cert_for_prefix "anytls" "$port" "$sni" || return 1
  crt="$_TLS_CRT"; key="$_TLS_KEY"
  jq -n --arg tag "$entry_key" --arg pass "$pass" --arg sni "$sni" --arg crt "$crt" --arg key "$key" --argjson port "$port" '
    {
      "type":"anytls",
      "tag":$tag,
      "listen":"::",
      "listen_port":$port,
      "users":[{"name":$tag,"password":$pass}],
      "tls":{
        "enabled":true,
        "server_name":$sni,
        "certificate_path":$crt,
        "key_path":$key,
        "alpn":["h2","http/1.1"]
      }
    }
  '
}

build_ss_inbound() {
  local port="$1" raw_password="${2:-}"
  local entry_key server_p user_p normalized_pw
  entry_key="$(entry_key_from_parts shadowsocks "$port")"
  normalized_pw="$(ss2022_prepare_password_pair "$raw_password")" || return 1
  server_p="${normalized_pw%%:*}"
  user_p="${normalized_pw#*:}"
  jq -n --arg tag "$entry_key" --arg sp "$server_p" --arg up "$user_p" --argjson port "$port" '
    {
      "type":"shadowsocks",
      "tag":$tag,
      "listen":"::",
      "listen_port":$port,
      "method":"2022-blake3-aes-128-gcm",
      "password":$sp,
      "users":[{"name":$tag,"password":$up}]
    }
  '
}

build_trojan_inbound() {
  local port="$1" sni="$2" pass="${3:-}"
  local entry_key crt key
  entry_key="$(entry_key_from_parts trojan "$port")"
  [ -n "$pass" ] || pass="$(protocol_password_urlsafe)" || return 1
  tls_cert_for_prefix "trojan" "$port" "$sni" || return 1
  crt="$_TLS_CRT"; key="$_TLS_KEY"
  jq -n --arg tag "$entry_key" --arg pass "$pass" --arg sni "$sni" --arg crt "$crt" --arg key "$key" --argjson port "$port" '
    {
      "type":"trojan",
      "tag":$tag,
      "listen":"::",
      "listen_port":$port,
      "users":[{"name":$tag,"password":$pass}],
      "tls":{
        "enabled":true,
        "server_name":$sni,
        "certificate_path":$crt,
        "key_path":$key
      }
    }
  '
}

build_vmess_ws_inbound() {
  local port="$1" listen="$2" path="$3"
  local entry_key uuid
  entry_key="$(entry_key_from_parts vmess-ws "$port")"
  uuid="$(sing-box generate uuid)" || return 1
  jq -n --arg tag "$entry_key" --arg uuid "$uuid" --arg listen "$listen" --arg path "$path" --argjson port "$port" '
    {
      "type":"vmess",
      "tag":$tag,
      "listen":$listen,
      "listen_port":$port,
      "users":[{"name":$tag,"uuid":$uuid}],
      "transport":{"type":"ws","path":$path,"max_early_data":2048,"early_data_header_name":"Sec-WebSocket-Protocol"}
    }
  '
}

build_vless_ws_inbound() {
  local port="$1" listen="$2" path="$3"
  local entry_key uuid
  entry_key="$(entry_key_from_parts vless-ws "$port")"
  uuid="$(sing-box generate uuid)" || return 1
  jq -n --arg tag "$entry_key" --arg uuid "$uuid" --arg listen "$listen" --arg path "$path" --argjson port "$port" '
    {
      "type":"vless",
      "tag":$tag,
      "listen":$listen,
      "listen_port":$port,
      "users":[{"name":$tag,"uuid":$uuid}],
      "transport":{"type":"ws","path":$path,"max_early_data":2048,"early_data_header_name":"Sec-WebSocket-Protocol"}
    }
  '
}

build_tuic_inbound() {
  local port="$1" sni="$2" pass="${3:-}"
  local entry_key uuid crt key
  entry_key="$(entry_key_from_parts tuic "$port")"
  uuid="$(sing-box generate uuid)" || return 1
  [ -n "$pass" ] || pass="$(random_b64_password 12)" || return 1
  tls_cert_for_prefix "tuic" "$port" "$sni" || return 1
  crt="$_TLS_CRT"; key="$_TLS_KEY"
  jq -n --arg tag "$entry_key" --arg uuid "$uuid" --arg pass "$pass" --arg sni "$sni" --arg crt "$crt" --arg key "$key" --argjson port "$port" '
    {
      "type":"tuic",
      "tag":$tag,
      "listen":"::",
      "listen_port":$port,
      "users":[{"name":$tag,"uuid":$uuid,"password":$pass}],
      "tls":{"enabled":true,"server_name":$sni,"alpn":["h3"],"certificate_path":$crt,"key_path":$key},
      "congestion_control":"bbr",
      "zero_rtt_handshake":false
    }
  '
}

build_hysteria2_inbound() {
  local port="$1" sni="$2" pass="${3:-}" obfs_type="${4:-}" obfs_pass="${5:-}"
  local entry_key crt key
  entry_key="$(entry_key_from_parts hysteria2 "$port")"
  case "$obfs_type" in
    ""|salamander|gecko) ;;
    *) err "不支持的 Hysteria2 混淆类型：$obfs_type（仅支持 salamander/gecko/不启用）。"; return 1 ;;
  esac
  [ -n "$pass" ] || pass="$(protocol_password_urlsafe)" || return 1
  if [ -n "$obfs_type" ]; then
    [ -n "$obfs_pass" ] || obfs_pass="$(protocol_password_urlsafe)" || return 1
  fi
  tls_cert_for_prefix "hy2" "$port" "$sni" || return 1
  crt="$_TLS_CRT"; key="$_TLS_KEY"
  # 带宽不限：不写 up_mbps/down_mbps；不设 gecko min/max 包大小，用 sing-box 默认 512/1200。
  # 忽略客户端上报带宽、双端强制走 BBR：不写 up/down 时 ignore_client_bandwidth=true 才会生效，
  # 客户端报多少都不切 Brutal；若以后填了 up/down，二者会冲突，届时须去掉这一行。
  jq -n --arg tag "$entry_key" --arg pass "$pass" --arg sni "$sni" --arg crt "$crt" --arg key "$key" \
    --arg obfs_type "$obfs_type" --arg obfs_pass "$obfs_pass" --argjson port "$port" '
    {
      "type":"hysteria2",
      "tag":$tag,
      "listen":"::",
      "listen_port":$port,
      "users":[{"name":$tag,"password":$pass}],
      "ignore_client_bandwidth":true,
      "tls":{"enabled":true,"server_name":$sni,"certificate_path":$crt,"key_path":$key}
    }
    | if $obfs_type != "" then .obfs = {"type":$obfs_type,"password":$obfs_pass} else . end
  '
}

build_socks_inbound() {
  local port="$1" password="${2:-}"
  local entry_key
  entry_key="$(entry_key_from_parts socks "$port")"
  [ -n "$password" ] || password="$(random_b64_password 12)" || return 1
  jq -n --arg tag "$entry_key" --arg password "$password" --argjson port "$port" '
    {
      "type":"socks",
      "tag":$tag,
      "listen":"::",
      "listen_port":$port,
      "users":[{"username":$tag,"password":$password}]
    }
  '
}

# ---------- 用户对象构建（按协议类型分派） ----------

build_user_object_from_inbound() {
  local inbound="$1" full_name="$2"
  local inbound_type uuid password
  inbound_type="$(jq -r '.type' <<< "$inbound")" || return 1
  case "$inbound_type" in
    vless|vmess|tuic) uuid="$(sing-box generate uuid)" || return 1 ;;
  esac
  case "$inbound_type" in
    shadowsocks) password="$(openssl rand -base64 16)" || return 1 ;;
    anytls|trojan|hysteria2) password="$(protocol_password_urlsafe)" || return 1 ;;
    tuic|socks) password="$(random_b64_password 12)" || return 1 ;;
  esac
  case "$inbound_type" in
    vless|vmess)
      jq -n --arg name "$full_name" --arg uuid "$uuid" --argjson inbound "$inbound" '
        {name:$name,uuid:$uuid}
        | if $inbound.tls.reality.enabled == true then .flow="xtls-rprx-vision" else . end
      '
      ;;
    shadowsocks|anytls|trojan|hysteria2)
      jq -n --arg name "$full_name" --arg pass "$password" '{name:$name,password:$pass}'
      ;;
    tuic)
      jq -n --arg name "$full_name" --arg uuid "$uuid" --arg pass "$password" '{name:$name,uuid:$uuid,password:$pass}'
      ;;
    socks)
      jq -n --arg username "$full_name" --arg pass "$password" '{username:$username,password:$pass}'
      ;;
    *) return 1 ;;
  esac
}

find_user_obj_in_inbound() {
  local inbound="$1" full_name="$2"
  echo "$inbound" | jq -c --arg n "$full_name" '(.users // [])[]? | select(((.name // .username // "") == $n))' | head -n1
}
