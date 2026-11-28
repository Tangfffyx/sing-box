#!/usr/bin/env bash
# ============================================================
# 模块: 70_export.sh
# 职责: 客户端配置导出（链接生成 + 多格式输出）
# 依赖: 00_base.sh, 01_utils.sh, 10_config.sh, 20_protocol.sh,
#       30_route.sh, 40_relay.sh, 50_v2ray_api.sh
# ============================================================

# ---------- 编码工具 ----------

b64_std_no_wrap() {
  printf '%s' "${1:-}" | openssl base64 -A 2>/dev/null | tr -d '\n'
}

url_encode() {
  printf '%s' "${1:-}" | jq -sRr @uri
}

# ---------- V2RayN 链接构建器（每协议一个函数） ----------

uri_host() {
  local host="$1"
  if [[ "$host" == *:* && "$host" != \[*\] ]]; then printf '[%s]' "$host"; else printf '%s' "$host"; fi
}

tls_export_self_signed() {
  local tls="$1" cert inline subject issuer
  cert="$(jq -r '.certificate_path // empty' <<< "$tls")" || return 1
  inline="$(jq -r '.certificate // empty | if type == "array" then join("\n") else . end' <<< "$tls")"
  if [ -n "$cert" ] && [ -r "$cert" ]; then inline="$(cat "$cert")" || return 1; fi
  if [ -z "$inline" ]; then
    [[ "$cert" =~ ^/etc/sing-box/(hy2|anytls|trojan|tuic)-[0-9]+\.crt$ ]]
    return
  fi
  subject="$(openssl x509 -noout -subject -nameopt RFC2253 <<< "$inline" 2>/dev/null)" || return 1
  issuer="$(openssl x509 -noout -issuer -nameopt RFC2253 <<< "$inline" 2>/dev/null)" || return 1
  [ "${subject#subject=}" = "${issuer#issuer=}" ]
}

build_v2rayn_ss_link() {
  local server="$1" port="$2" method="$3" password="$4" name="$5" enc
  if [[ "$method" == 2022-* ]]; then
    enc="$(url_encode "$method"):$(url_encode "$password")"
  else
    enc="$(b64_std_no_wrap "$method:$password" | tr '/+' '_-' | tr -d '=')"
  fi
  printf 'ss://%s@%s:%s#%s' "$enc" "$(uri_host "$server")" "$port" "$(url_encode "$name")"
}

build_v2rayn_vmess_ws_link() {
  local server="$1" uuid="$2" host="$3" path="$4" name="$5" port="${6:-443}"
  local payload
  payload="$(jq -nc --arg ps "$name" --arg add "$server" --arg port "$port" --arg id "$uuid" \
    --arg host "$host" --arg path "$path" \
    '{v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:"0",scy:"auto",net:"ws",type:"none",host:$host,path:$path,tls:"tls",sni:$host}')"
  printf 'vmess://%s' "$(b64_std_no_wrap "$payload")"
}

build_v2rayn_vless_reality_link() {
  local server="$1" port="$2" uuid="$3" sni="$4" pbk="$5" sid="$6" flow="$7" name="$8"
  printf 'vless://%s@%s:%s?encryption=none&flow=%s&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s' \
    "$uuid" "$(uri_host "$server")" "$port" "$(url_encode "$flow")" "$(url_encode "$sni")" \
    "$(url_encode "$pbk")" "$(url_encode "$sid")" "$(url_encode "$name")"
}

build_v2rayn_vless_ws_link() {
  local server="$1" uuid="$2" host="$3" path="$4" name="$5" port="${6:-443}"
  printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&type=ws&host=%s&path=%s#%s' \
    "$uuid" "$(uri_host "$server")" "$port" "$(url_encode "$host")" "$(url_encode "$host")" \
    "$(url_encode "$path")" "$(url_encode "$name")"
}

build_v2rayn_anytls_link() {
  local server="$1" port="$2" password="$3" sni="$4" name="$5"
  local insecure="${6:-true}" alpn="${7-h2,http/1.1}" query
  query="sni=$(url_encode "$sni")&fp=chrome"
  [ -z "$alpn" ] || query+="&alpn=$(url_encode "$alpn")"
  [ "$insecure" = false ] || query+="&insecure=1"
  printf 'anytls://%s@%s:%s?%s#%s' \
    "$(url_encode "$password")" "$(uri_host "$server")" "$port" "$query" "$(url_encode "$name")"
}

build_v2rayn_trojan_link() {
  local server="$1" port="$2" password="$3" sni="$4" name="$5"
  local insecure="${6:-true}" alpn="${7:-}" query
  query="security=tls&sni=$(url_encode "$sni")"
  [ -z "$alpn" ] || query+="&alpn=$(url_encode "$alpn")"
  [ "$insecure" = false ] || query+="&allowInsecure=1"
  printf 'trojan://%s@%s:%s?%s#%s' \
    "$(url_encode "$password")" "$(uri_host "$server")" "$port" "$query" "$(url_encode "$name")"
}

build_v2rayn_tuic_link() {
  local server="$1" port="$2" uuid="$3" password="$4" sni="$5" name="$6"
  local insecure="${7:-true}" alpn="${8:-h3}" cc="${9:-bbr}" query
  query="sni=$(url_encode "$sni")&alpn=$(url_encode "$alpn")&congestion_control=$(url_encode "$cc")"
  [ "$insecure" = false ] || query+="&allow_insecure=1"
  printf 'tuic://%s:%s@%s:%s?%s#%s' \
    "$uuid" "$(url_encode "$password")" "$(uri_host "$server")" "$port" "$query" "$(url_encode "$name")"
}

build_v2rayn_hysteria2_link() {
  local server="$1" port="$2" password="$3" sni="$4" obfs_type="$5" obfs_pass="$6" name="$7"
  local insecure="${8:-true}" query
  query="sni=$(url_encode "$sni")"
  [ "$insecure" = false ] || query+="&insecure=1"
  if [ -n "$obfs_type" ]; then
    query+="&obfs=$(url_encode "$obfs_type")&obfs-password=$(url_encode "$obfs_pass")"
  fi
  printf 'hysteria2://%s@%s:%s/?%s#%s' \
    "$(url_encode "$password")" "$(uri_host "$server")" "$port" "$query" "$(url_encode "$name")"
}

build_socks_link() {
  printf 'socks5://%s:%s@%s:%s' "$(url_encode "$3")" "$(url_encode "$4")" "$(uri_host "$1")" "$2"
}

# 从 meta 取某 hy2 节点的跳跃范围 "42310-45545"，没有返回空。
hy2_export_hop_range() {
  local tag="$1" meta_json="${2:-}"
  [ -n "$meta_json" ] || meta_json="$(meta_load 2>/dev/null || echo '{}')"
  hy2_hop_range_from_meta "$meta_json" "$tag"
}

# ---------- 导出上下文收集 ----------

export_collect_context() {
  local json="$1" meta="${2:-}"
  [ -n "$meta" ] || meta='{}'
  local ip=""
  if jq -e --argjson meta "$meta" "${JQ_DETECT_PROTOCOL}"'
    all(.inbounds[]?; (detect_protocol) as $p | $p == "" or ($p|endswith("-ws")) or ($meta[.tag].public_endpoint.host // "") != "")
  ' <<< "$json" >/dev/null; then
    ip=""
  elif [ -z "${_CACHED_PUBLIC_IP:-}" ] && [ -t 1 ] && [ -t 2 ]; then
    local ip_tmp
    ip_tmp="$(mktemp /tmp/sb-ip.XXXXXX)"
    if run_with_spinner "正在获取服务器公网 IP..." bash -c '
      ip=$(curl -s4 --max-time 3 --connect-timeout 2 ifconfig.me 2>/dev/null || true)
      [ -z "$ip" ] && ip=$(curl -s4 --max-time 3 --connect-timeout 2 api.ipify.org 2>/dev/null || true)
      [ -z "$ip" ] && ip=$(curl -s4 --max-time 3 --connect-timeout 2 icanhazip.com 2>/dev/null | tr -d "\n" || true)
      printf "%s" "${ip:-IP}" > "'"$ip_tmp"'"
    '; then
      ip="$(cat "$ip_tmp" 2>/dev/null || echo IP)"
      _CACHED_PUBLIC_IP="$ip"
    else
      ip="$(get_public_ip)"
    fi
    rm -f "$ip_tmp" >/dev/null 2>&1 || true
  else
    ip="$(get_public_ip)"
  fi
  jq -n --arg ip "$ip" '{ip:$ip}'
}

# ---------- 主导出函数 ----------

export_collect_records() {
  local filter_user="${1:-__admin__}" allowed_tags="${2:-}"
  [ "$filter_user" != admin ] || filter_user=__admin__
  local json meta_json ctx ip db
  local tag proto port sni path sid method server_p obfs_type obfs_pass
  local name uuid pass flow out_name pw_out business_user reality_public_key v2rayn_link
  local hop_range qx_line clash_line tls cc endpoint node_host node_port cdn_label early ws_options
  local public_address insecure qx_verify alpn_csv yn yh yp ys ypath yobf
  local -A tls_policy=() reality_keys=()
  json="$(config_load)" || return 1
  if [ -n "$allowed_tags" ]; then
    json="$(jq --argjson tags "$allowed_tags" '
      .inbounds |= map(.tag as $tag | select(($tags | index($tag)) != null))
    ' <<< "$json")" || return 1
  fi
  meta_json="$(meta_load 2>/dev/null || echo '{}')"
  [ -n "$meta_json" ] || meta_json='{}'

  db='null'
  if declare -F user_db_exists >/dev/null && user_db_exists; then
    db="$(user_db_load)" || return 1
    db="$(user_manager_evaluate_state "$db")" || return 1
  elif declare -F user_db_is_first_use >/dev/null && ! user_db_is_first_use; then
    user_db_restore_hint
    return 1
  fi
  ctx="$(export_collect_context "$json" "$meta_json")" || return 1
  ip="$(jq -r '.ip // ""' <<< "$ctx")" || return 1

  # 单次 jq 展开全部 inbound × user，减少高频子进程 fork
  while IFS=$'\x01' read -r tag proto port sni path sid method server_p obfs_type obfs_pass name uuid pass flow tls cc endpoint; do
    [ -z "$name" ] && continue
    out_name="$name"

    business_user=admin
    if [[ "$name" == *"@"* ]]; then business_user="$(user_business_name "$name")"; fi
    [ "$filter_user" = __all__ ] || [ "$filter_user" = "$business_user" ] ||
      { [ "$filter_user" = __admin__ ] && [ "$business_user" = admin ]; } || continue
    IFS=$'\x01' read -r node_host node_port cdn_label early < <(
      jq -r '[.host // "", (.port // "" | tostring), (.operator_evidence.operator // ""),
              (.early_data // 0 | tostring)] | join("\u0001")' <<< "$endpoint"
    )
    case "$proto" in
      vmess-ws|vless-ws)
        node_port="${node_port:-443}"
        if [ -z "$node_host" ]; then
          export_record "$out_name" "$proto" "" "" "" "请在「接入已有 CDN」中验证并保存公网入口。"
          continue
        fi
        if jq -e '.verified == true' <<< "$endpoint" >/dev/null; then
          if [ -n "$cdn_label" ]; then cdn_label="${cdn_label}入口"; else cdn_label="CDN 自动"; fi
          case "$proto" in
            vmess-ws) out_name="$out_name · VMess-WS · $cdn_label" ;;
            vless-ws) out_name="$out_name · VLESS-WS · $cdn_label" ;;
          esac
        fi
        ;;
      *)
        node_host="${node_host:-$ip}"
        node_port="${node_port:-$port}"
        ;;
    esac
    public_address="$(uri_host "$node_host"):$node_port"
    if [ -z "${tls_policy[$tag]+set}" ]; then
      tls_policy[$tag]=false
      if tls_export_self_signed "$tls"; then tls_policy[$tag]=true; fi
    fi
    insecure="${tls_policy[$tag]}"
    qx_verify=true
    [ "$insecure" = false ] || qx_verify=false
    alpn_csv="$(jq -r '(.alpn // []) | join(",")' <<< "$tls")"
    IFS=$'\x01' read -r yn yh yp ys ypath yobf < <(
      jq -nr --args '$ARGS.positional | map(@json) | join("\u0001")' -- \
        "$out_name" "$node_host" "$pass" "$sni" "$path" "$obfs_pass"
    )
    v2rayn_link='' clash_line='' qx_line=''
    case "$proto" in
      vless-reality)
        [ -n "$uuid" ] || continue
        if [ -z "${reality_keys[$tag]+set}" ]; then
          reality_public_key="$(jq -r --arg tag "$tag" '.[$tag].public_key // empty' <<< "$meta_json")"
          if [ -z "$reality_public_key" ]; then
            reality_public_key="$(reality_public_key_from_private "$(jq -r '.reality.private_key // empty' <<< "$tls")")" || reality_public_key=''
          fi
          reality_keys[$tag]="$reality_public_key"
        fi
        reality_public_key="${reality_keys[$tag]}"
        if [ -z "$reality_public_key" ]; then
          export_record "$out_name" "$proto" "" "" "" "Reality 公钥无法恢复，请检查密钥资料。"
          continue
        fi
        v2rayn_link="$(build_v2rayn_vless_reality_link "$node_host" "$node_port" "$uuid" "$sni" "$reality_public_key" "$sid" "$flow" "$out_name")"
        clash_line="{name: $yn, type: vless, server: $yh, port: $node_port, uuid: $uuid, network: tcp, udp: true, tls: true, flow: $flow, servername: $ys, reality-opts: {public-key: $reality_public_key, short-id: '$sid'}, client-fingerprint: chrome}"
        qx_line="vless=$public_address, method=none, password=$uuid, obfs=over-tls, obfs-host=$sni, reality-base64-pubkey=$reality_public_key, reality-hex-shortid=$sid, vless-flow=$flow, udp-relay=true, tag=$out_name"
        ;;
      anytls)
        [ -n "$pass" ] || continue
        v2rayn_link="$(build_v2rayn_anytls_link "$node_host" "$node_port" "$pass" "$sni" "$out_name" "$insecure" "$alpn_csv")"
        clash_line="{name: $yn, type: anytls, server: $yh, port: $node_port, password: $yp, client-fingerprint: chrome, udp: true, sni: $ys, skip-cert-verify: $insecure"
        if [ -n "$alpn_csv" ]; then clash_line+=", alpn: $(jq -c '.alpn' <<< "$tls")"; fi
        clash_line+='}'
        qx_line="anytls=$public_address, password=$pass, over-tls=true, tls-host=$sni, tls-verification=$qx_verify, udp-relay=true, tag=$out_name"
        ;;
      shadowsocks)
        [ -n "$pass" ] || continue
        pw_out="$pass"
        [ -z "$server_p" ] || pw_out="$server_p:$pass"
        v2rayn_link="$(build_v2rayn_ss_link "$node_host" "$node_port" "$method" "$pw_out" "$out_name")"
        clash_line="{name: $yn, type: ss, server: $yh, port: $node_port, cipher: $method, password: $(jq -Rn --arg value "$pw_out" '$value'), udp: true}"
        qx_line="shadowsocks=$public_address, method=$method, password=$pw_out, udp-relay=true, tag=$out_name"
        ;;
      trojan)
        [ -n "$pass" ] || continue
        v2rayn_link="$(build_v2rayn_trojan_link "$node_host" "$node_port" "$pass" "$sni" "$out_name" "$insecure" "$alpn_csv")"
        clash_line="{name: $yn, type: trojan, server: $yh, port: $node_port, password: $yp, client-fingerprint: chrome, udp: true, sni: $ys, skip-cert-verify: $insecure"
        if [ -n "$alpn_csv" ]; then clash_line+=", alpn: $(jq -c '.alpn' <<< "$tls")"; fi
        clash_line+='}'
        qx_line="trojan=$public_address, password=$pass, over-tls=true, tls-host=$sni, tls-verification=$qx_verify, fast-open=false, udp-relay=true, tag=$out_name"
        ;;
      vmess-ws|vless-ws)
        [ -n "$uuid" ] || continue
        if [ "$proto" = vmess-ws ]; then
          v2rayn_link="$(build_v2rayn_vmess_ws_link "$node_host" "$uuid" "$node_host" "$path" "$out_name" "$node_port")"
          clash_line="type: vmess, alterId: 0, cipher: auto"
          qx_line="vmess=$public_address, method=chacha20-poly1305"
        else
          v2rayn_link="$(build_v2rayn_vless_ws_link "$node_host" "$uuid" "$node_host" "$path" "$out_name" "$node_port")"
          clash_line="type: vless"
          qx_line="vless=$public_address, method=none"
        fi
        ws_options="path: $ypath, headers: {Host: $yh}"
        if [ "$early" = 2048 ]; then
          ws_options+=", max-early-data: 2048, early-data-header-name: Sec-WebSocket-Protocol"
        fi
        clash_line="{name: $yn, $clash_line, server: $yh, port: $node_port, uuid: $uuid, udp: true, tls: true, network: ws, servername: $yh, ws-opts: {$ws_options}}"
        qx_line+=", password=$uuid, obfs=wss, obfs-host=$node_host, obfs-uri=$path, tls-verification=true, udp-relay=true, tag=$out_name"
        ;;
      hysteria2)
        [ -n "$pass" ] || continue
        hop_range="$(hy2_export_hop_range "$tag" "$meta_json")"
        v2rayn_link="$(build_v2rayn_hysteria2_link "$node_host" "${hop_range:-$node_port}" "$pass" "$sni" "$obfs_type" "$obfs_pass" "$out_name" "$insecure")"
        clash_line="{name: $yn, type: hysteria2, server: $yh, port: $node_port, password: $yp, sni: $ys, skip-cert-verify: $insecure"
        [ -z "$obfs_type" ] || clash_line+=", obfs: $obfs_type, obfs-password: $yobf"
        [ -z "$hop_range" ] || clash_line+=", ports: \"$hop_range\", hop-interval: 30"
        clash_line+='}'
        if [ "$obfs_type" != gecko ] && [ -z "$hop_range" ]; then
          qx_line="hysteria2=$public_address, password=$pass, tls-host=$sni, tls-verification=$qx_verify, udp-relay=true"
          [ "$obfs_type" != salamander ] || qx_line+=", salamander-password=$obfs_pass"
          qx_line+=", tag=$out_name"
        fi
        ;;
      tuic)
        [ -n "$uuid" ] && [ -n "$pass" ] || continue
        v2rayn_link="$(build_v2rayn_tuic_link "$node_host" "$node_port" "$uuid" "$pass" "$sni" "$out_name" "$insecure" "${alpn_csv:-h3}" "$cc")"
        clash_line="{name: $yn, type: tuic, server: $yh, port: $node_port, uuid: $uuid, password: $yp, alpn: $(jq -c '.alpn // ["h3"]' <<< "$tls"), disable-sni: false, reduce-rtt: false, udp-relay-mode: native, congestion-controller: $cc, skip-cert-verify: $insecure, sni: $ys}"
        ;;
      socks)
        [ -n "$pass" ] || continue
        v2rayn_link="$(build_socks_link "$node_host" "$node_port" "$name" "$pass")"
        clash_line="{name: $yn, type: socks5, server: $yh, port: $node_port, username: $yn, password: $yp, udp: true}"
        qx_line="socks5=$public_address, username=$name, password=$pass, tag=$out_name"
        ;;
      *) continue ;;
    esac
    local notice=''
    if [ "$proto" = tuic ]; then
      notice="TUIC 本期提供通用链接和 Clash / Mihomo。"
    elif [ "$proto" = hysteria2 ] && [ -z "$qx_line" ]; then
      notice="Quantumult X: 此混淆或跳跃组合待真机验证。"
    fi
    export_record "$out_name" "$proto" "$v2rayn_link" "$clash_line" "$qx_line" "$notice"
  done < <(
    printf '%s\n' "$json" | jq -r --argjson meta "$meta_json" --argjson db "$db" "${JQ_SHARED}"'
      [.inbounds[]?]
      | sort_by(protocol_sort_index(.tag // ""))
      | .[]
      | . as $in
      | ($in | detect_protocol) as $proto
      | ($in.users // [])[]? as $user
      | ($user.name // $user.username // "") as $auth
      | (if ($auth|contains("@")) then ($auth|split("@")[1]) else "admin" end) as $account
      | ($auth|node_part(.)|if contains("-to-") then . else $in.tag end) as $node
      | select(if $db == null then $account == "admin" else
          $db.users[$account] as $u | $u.enabled == true and
          ($account == "admin" or $u.allow_all_nodes == true or (($u.nodes // [])|index($node)) != null) end)

      | ($meta[$in.tag] // {}) as $saved
      | (if ($proto|endswith("-ws")) then
           [$saved.cdn_entries[]? | select(.verified == true and .path == $in.transport.path)] as $raw
           | (if ($raw | length) == 1 then $raw | map(del(.operator_evidence)) else $raw end) as $verified
           | ($saved.public_endpoint // {}) as $old
           | ($verified + [($old | select(.host != null
               and all($verified[]; .host != $old.host or .port != ($old.port // 443))))])
         else [$saved.public_endpoint // {}] end) as $entries
      | (if ($entries | length) == 0 then [{}] else $entries end)[] as $endpoint
      | [
          ($in.tag // ""),
          $proto,
          (($in.listen_port // 0) | tostring),
          ($in.tls.server_name // ""),
          ($in.transport.path // "/"),
          ($in.tls.reality.short_id[0] // ""),
          ($in.method // "2022-blake3-aes-128-gcm"),
          ($in.password // ""),
          ($in.obfs.type // ""),
          ($in.obfs.password // ""),
          ($user.name // $user.username // ""),
          ($user.uuid // ""),
          ($user.password // ""),
          ($user.flow // ""),
          (($in.tls // {}) | tojson),
          ($in.congestion_control // "bbr"),
          ($endpoint | tojson)
        ] | join("\u0001")
    '
  )
}

# Internal export records carry strings without terminal formatting.
export_record() {
  jq -nc --arg name "$1" --arg proto "$2" --arg link "$3" \
    --arg clash "$4" --arg qx "$5" --arg notice "$6" '
      {name:$name,proto:$proto,link:$link,clash:(if $clash=="" then "" else "- "+$clash end),qx:$qx,notice:$notice}'
}

export_plain_preview() {
  jq -r '.[] | "\n[\(.name)]",
    (if .link != "" then (if .proto=="socks" then " 落地链接: " else " 通用链接: " end)+.link else empty end),
    (if .clash != "" then " Clash: "+.clash else empty end),
    (if .qx != "" then " Quantumult X: "+.qx else empty end),
    (if .notice != "" then " "+.notice else empty end)' <<< "$1"
}

export_qr() {
  printf '%s' "$1" | qrencode -t ANSIUTF8 -l M -m 4 2>/dev/null
}

export_format_menu() {
  local record="$1"
  if [ -n "$record" ] && jq -e '.proto == "socks"' <<< "$record" >/dev/null; then
    printf '%s\n' '1. 落地链接'
  else
    printf '%s\n' '1. 通用链接'
  fi
  printf '%s\n' '2. Clash / Mihomo' '3. Quantumult X'
  if [ -n "$record" ]; then
    jq -r '.notice | select(length>0)' <<< "$record"
  fi
}

export_detail_card() {
  local record="$1" cols="$2" lines="${3:-100}" uri qr='' first clean width i
  local -a image=() options=()
  jq -r '.name' <<< "$record" | tr -d '[:cntrl:]'
  printf '\n'
  uri="$(jq -r '.link' <<< "$record")"
  if [ -n "$uri" ] && has_cmd qrencode; then
    qr="$(export_qr "$uri")" || qr=''
  fi
  if [ -n "$qr" ]; then
    mapfile -t image <<< "$qr"
    first="${image[0]}"
    clean="$(sed $'s/\033\\[[0-9;]*m//g' <<< "$first")"
    width="$(printf '%s' "$clean" | wc -m | tr -d ' ')"
    if (( width + 24 <= cols && ${#image[@]} + 5 <= lines )); then
      mapfile -t options < <(export_format_menu "$record" | head -n 3)
      for i in "${!image[@]}"; do
        printf '%s' "${image[i]}"
        if [ "$i" -lt "${#options[@]}" ]; then
          printf '\033[%dG%s' "$((width+3))" "${options[i]}"
        fi
        printf '\n'
      done
      jq -r '.notice | select(length>0)' <<< "$record"
      return
    elif (( width <= cols && ${#image[@]} + 7 <= lines )); then
      printf '%s\n' "$qr"
    else
      printf '%s\n' "$uri"
    fi
  elif [ -n "$uri" ]; then
    printf '%s\n' "$uri"
  fi
  export_format_menu "$record"
}

export_print_format() {
  local rows="$1" choice="$2" key
  case "$choice" in 1) key=link ;; 2) key=clash ;; 3) key=qx ;; *) return 1 ;; esac
  if ! jq -e --arg key "$key" 'any(.[]; .[$key] != "")' <<< "$rows" >/dev/null; then
    warn "所选节点缺少该格式或必要资料。"
    return 1
  fi
  jq -r --arg key "$key" '.[] | .[$key] | select(length>0)' <<< "$rows"
}

export_configs() {
  local account="${1:-__admin__}" tags="${2:-}" rows selected choice count record detail cols lines allow_all=0
  init_manager_env || return 1
  [ "$#" -ne 0 ] || allow_all=1
  rows="$(export_collect_records "$account" "$tags" | jq -cs '.')" || return 1
  if [ ! -t 0 ] || [ ! -t 1 ]; then
    export_plain_preview "$rows"
    return
  fi
  cols="$(tput cols 2>/dev/null || printf '%s\n' "${COLUMNS:-80}")"
  lines="$(tput lines 2>/dev/null || printf '%s\n' "${LINES:-40}")"
  [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
  [[ "$lines" =~ ^[0-9]+$ ]] || lines=40
  while true; do
    count="$(jq 'length' <<< "$rows")"
    if [ "$count" -eq 0 ] && [ "$allow_all" -eq 0 ]; then
      warn "没有可导出的节点。"
      return 0
    fi
    detail=0
    if [ "$count" -eq 1 ]; then
      selected=1
      detail=1
    else
      print_rect_title "导出配置"
      jq -r 'to_entries[] | "  \(.key+1). \(.value.name|gsub("[[:cntrl:]]"; ""))"' <<< "$rows"
      if [ "$count" -gt 1 ]; then printf '  b. 按一种格式批量导出\n'; fi
      if [ "$allow_all" -eq 1 ]; then printf '  a. 导出全部用户\n'; fi
      read -r -p "选择节点（回车返回）: " selected || return 0
      case "$selected" in
        ''|0|q) return 0 ;;
        a)
          [ "$allow_all" -eq 1 ] || continue
          rows="$(export_collect_records __all__ "$tags" | jq -cs '.')" || return 1
          allow_all=0
          continue ;;
        b)
          [ "$count" -gt 1 ] || continue
          export_format_menu ''
          read -r -p "选择批量导出格式（回车返回）: " choice || return 0
          export_print_format "$rows" "$choice" || true
          pause
          continue ;;
      esac
      if ! [[ "$selected" =~ ^[1-9][0-9]*$ ]] || [ "$selected" -gt "$count" ] 2>/dev/null; then
        warn "请选择列表中的节点。"
        continue
      fi
    fi
    record="$(jq -c --argjson index "$((selected-1))" '.[$index]' <<< "$rows")" || continue
    export_detail_card "$record" "$cols" "$lines"
    if [ "$allow_all" -eq 1 ]; then printf 'a. 导出全部用户\n'; fi
    if ! has_cmd qrencode && jq -e '.link != ""' <<< "$record" >/dev/null; then
      printf '%s\n' 'r. 安装本地二维码工具'
    fi
    while read -r -p "选择格式（回车返回）: " choice; do
      case "$choice" in
        ''|0|q) break ;;
        a)
          [ "$allow_all" -eq 1 ] || continue
          rows="$(export_collect_records __all__ "$tags" | jq -cs '.')" || return 1
          allow_all=0
          detail=0
          break ;;
        r)
          if ! has_cmd qrencode; then
            if run_with_spinner "安装本地二维码工具" install_pkg qrencode; then
              export_detail_card "$record" "$cols" "$lines"
            else
              warn "二维码工具安装失败，可以继续复制链接。"
            fi
          fi ;;
        1|2|3) export_print_format "[$record]" "$choice" || true ;;
        *) warn "请选择 1、2 或 3。" ;;
      esac
    done
    if [ "$detail" -eq 1 ]; then return 0; fi
  done
}
