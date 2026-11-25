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
  openssl req -x509 -newkey ec:<(openssl ecparam -name prime256v1) \
    -keyout "$key_path" -out "$crt_path" -days 36500 -nodes -subj "/CN=${cn}" >/dev/null 2>&1 || return 1
  [ -s "$crt_path" ] && [ -s "$key_path" ]
}

# 自签证书（按 <前缀>-<端口> 命名，如 hy2-443.crt）：设置 _TLS_CRT/_TLS_KEY，失败返回 1。
# AnyTLS/Trojan/TUIC/Hysteria2 共用同一套逻辑，证书文件一眼能看出属于哪个节点。
tls_cert_for_prefix() {
  local prefix="$1" port="$2" sni="$3"
  _TLS_CRT="/etc/sing-box/${prefix}-${port}.crt"
  _TLS_KEY="/etc/sing-box/${prefix}-${port}.key"
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

# ---------- TLS 域名选择 ----------

get_tls_domain_candidates() {
  cat <<'EOF_TLS'
assets.adobedtm.com
lpcdn.lpsnmedia.net
s.go-mpulse.net
d0.m.awsstatic.com
a0.awsstatic.com
devblogs.microsoft.com
ds-aksb-a.akamaihd.net
tag.demandbase.com
electronics.sony.com
tag-logger.demandbase.com
d3agakyjgjv5i8.cloudfront.net
ms-python.gallerycdn.vsassets.io
img-prod-cms-rt-microsoft-com.akamaized.net
cdn.bizible.com
store-images.s-microsoft.com
catalog.gamepass.com
www.nvidia.com
mscom.demdex.net
drivers.amd.com
azure.microsoft.com
downloadmirror.intel.com
prod.us-east-1.ui.gcr-chat.marketing.aws.dev
r.bing.com
www.intel.com
ms-vscode.gallerycdn.vsassets.io
rum.hlx.page
www.tesla.com
ts2.tc.mm.bing.net
res-1.cdn.office.net
cdn-dynmedia-1.microsoft.com
EOF_TLS
}

benchmark_tls_domain_ms() {
  local domain="$1" t1 t2
  t1="$(now_ms)"
  run_with_timeout 1 openssl s_client -connect "${domain}:443" -servername "$domain" </dev/null >/dev/null 2>&1 || return 1
  t2="$(now_ms)"
  if [[ "$t1" =~ ^[0-9]+$ ]] && [[ "$t2" =~ ^[0-9]+$ ]] && [ "$t2" -ge "$t1" ]; then
    echo $((t2 - t1))
  else
    echo 999
  fi
}

auto_pick_tls_domain() {
  local best_domain="" best_ms=999999 ms domain
  local -a candidates=()
  mapfile -t candidates < <(get_tls_domain_candidates)
  # 随机抽取 10 个域名测速，避免全量串行等待过久
  local total=${#candidates[@]}
  if [ "$total" -gt 10 ]; then
    local -a sampled=()
    local -a indices=()
    while [ ${#sampled[@]} -lt 10 ]; do
      local r=$((RANDOM % total))
      local dup=0 idx
      for idx in "${indices[@]}"; do
        [ "$idx" -eq "$r" ] && { dup=1; break; }
      done
      [ $dup -eq 0 ] && { sampled+=("${candidates[$r]}"); indices+=("$r"); }
    done
    candidates=("${sampled[@]}")
  fi
  for domain in "${candidates[@]}"; do
    [ -n "$domain" ] || continue
    ms="$(benchmark_tls_domain_ms "$domain" 2>/dev/null || true)"
    if [ -n "$ms" ] && [[ "$ms" =~ ^[0-9]+$ ]] && [ "$ms" -lt "$best_ms" ]; then
      best_ms="$ms"
      best_domain="$domain"
    fi
  done
  [ -n "$best_domain" ] || return 1
  printf '%s\t%s\n' "$best_domain" "$best_ms"
}

choose_tls_domain() {
  local proto_label="$1" choice manual picked picked_ms
  ui_echo "1. 手动输入"
  ui_echo "2. 自动测速选择推荐域名"
  read -r -p "请选择域名填写方式（回车默认2. 自动测速选择推荐域名）: " choice
  case "${choice:-2}" in
    1)
      read -r -p "请输入${proto_label}域名（回车返回）: " manual
      if [ -z "${manual:-}" ]; then
        warn "输入无效，已返回上一级。"
        pause >&2
        return 1
      fi
      param_echo "SNI" "$manual"
      echo "$manual"
      ;;
    *)
      picked="$(auto_pick_tls_domain 2>/dev/null || true)"
      if [ -n "$picked" ]; then
        picked_ms="${picked#*$'\t'}"
        picked="${picked%%$'\t'*}"
        param_echo "SNI" "${picked} (${picked_ms} ms)"
        echo "$picked"
      else
        warn "自动测速失败，已返回上一级。"
        pause >&2
        return 1
      fi
      ;;
  esac
}

# ---------- SS 密码规范化 ----------

ss2022_normalize_password_pair() {
  local raw="$1"
  local sp up
  if [ -z "$raw" ]; then
    sp="$(random_b64_password 16)"
    up="$(random_b64_password 16)"
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
    sp="$(random_b64_password 16)"
    up="$(random_b64_password 16)"
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
  uuid="$(sing-box generate uuid)"
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
  [ -n "$pass" ] || pass="$(random_b64_password 16)"
  tls_cert_for_prefix "anytls" "$port" "$sni" || return 1
  crt="$_TLS_CRT"; key="$_TLS_KEY"
  jq -n --arg tag "$entry_key" --arg pass "$pass" --arg sni "$sni" --arg crt "$crt" --arg key "$key" --argjson port "$port" '
    {
      "type":"anytls",
      "tag":$tag,
      "listen":"::",
      "listen_port":$port,
      "users":[{"name":$tag,"password":$pass}],
      "padding_scheme":[],
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
  [ -n "$pass" ] || pass="$(random_b64_password 16)"
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
  uuid="$(sing-box generate uuid)"
  jq -n --arg tag "$entry_key" --arg uuid "$uuid" --arg listen "$listen" --arg path "$path" --argjson port "$port" '
    {
      "type":"vmess",
      "tag":$tag,
      "listen":$listen,
      "listen_port":$port,
      "users":[{"name":$tag,"uuid":$uuid,"alterId":0}],
      "transport":{"type":"ws","path":$path,"max_early_data":2048,"early_data_header_name":"Sec-WebSocket-Protocol"}
    }
  '
}

build_vless_ws_inbound() {
  local port="$1" listen="$2" path="$3"
  local entry_key uuid
  entry_key="$(entry_key_from_parts vless-ws "$port")"
  uuid="$(sing-box generate uuid)"
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
  uuid="$(sing-box generate uuid)"
  [ -n "$pass" ] || pass="$(random_b64_password 12)"
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
      "congestion_control":"bbr"
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
  [ -n "$pass" ] || pass="$(random_b64_password 16)"
  if [ -n "$obfs_type" ]; then
    [ -n "$obfs_pass" ] || obfs_pass="$(random_b64_password 16)"
  fi
  tls_cert_for_prefix "hy2" "$port" "$sni" || return 1
  crt="$_TLS_CRT"; key="$_TLS_KEY"
  # 带宽不限：不写 up_mbps/down_mbps；不设 gecko min/max 包大小，用 sing-box 默认 512/1200。
  jq -n --arg tag "$entry_key" --arg pass "$pass" --arg sni "$sni" --arg crt "$crt" --arg key "$key" \
    --arg obfs_type "$obfs_type" --arg obfs_pass "$obfs_pass" --argjson port "$port" '
    {
      "type":"hysteria2",
      "tag":$tag,
      "listen":"::",
      "listen_port":$port,
      "users":[{"name":$tag,"password":$pass}],
      "tls":{"enabled":true,"server_name":$sni,"alpn":["h3"],"certificate_path":$crt,"key_path":$key}
    }
    | if $obfs_type != "" then .obfs = {"type":$obfs_type,"password":$obfs_pass} else . end
  '
}

build_socks_inbound() {
  local port="$1" password="${2:-}"
  local entry_key
  entry_key="$(entry_key_from_parts socks "$port")"
  [ -n "$password" ] || password="$(random_b64_password 12)"
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

# ---------- 证书清理 ----------

cleanup_inbound_generated_cert_files() {
  local json="$1" entry_key="$2"
  local crt key
  crt="$(echo "$json" | jq -r --arg ek "$entry_key" '.inbounds[]? | select((.tag // "") == $ek) | .tls.certificate_path // empty' | head -n1)"
  key="$(echo "$json" | jq -r --arg ek "$entry_key" '.inbounds[]? | select((.tag // "") == $ek) | .tls.key_path // empty' | head -n1)"
  if [ -n "$crt" ] && [[ "$crt" == /etc/sing-box/* ]]; then
    rm -f "$crt" >/dev/null 2>&1 || true
  fi
  if [ -n "$key" ] && [[ "$key" == /etc/sing-box/* ]]; then
    rm -f "$key" >/dev/null 2>&1 || true
  fi
}

# ---------- 用户对象构建（按协议类型分派） ----------

build_user_object_from_inbound() {
  local inbound="$1" full_name="$2"
  local inbound_type
  inbound_type="$(echo "$inbound" | jq -r '.type')"
  case "$inbound_type" in
    vless)
      if echo "$inbound" | jq -e '.tls.reality.enabled == true' >/dev/null 2>&1; then
        jq -n --arg name "$full_name" --arg uuid "$(sing-box generate uuid)" '{name:$name,uuid:$uuid,flow:"xtls-rprx-vision"}'
      else
        jq -n --arg name "$full_name" --arg uuid "$(sing-box generate uuid)" '{name:$name,uuid:$uuid}'
      fi
      ;;
    vmess)
      jq -n --arg name "$full_name" --arg uuid "$(sing-box generate uuid)" '{name:$name,uuid:$uuid,alterId:0}'
      ;;
    shadowsocks|anytls|trojan|hysteria2)
      jq -n --arg name "$full_name" --arg pass "$(random_b64_password 16)" '{name:$name,password:$pass}'
      ;;
    tuic)
      jq -n --arg name "$full_name" --arg uuid "$(sing-box generate uuid)" --arg pass "$(random_b64_password 12)" '{name:$name,uuid:$uuid,password:$pass}'
      ;;
    socks)
      jq -n --arg username "$full_name" --arg pass "$(random_b64_password 12)" '{username:$username,password:$pass}'
      ;;
    *)
      return 1
      ;;
  esac
}

find_user_obj_in_inbound() {
  local inbound="$1" full_name="$2"
  echo "$inbound" | jq -c --arg n "$full_name" '(.users // [])[]? | select(((.name // .username // "") == $n))' | head -n1
}
