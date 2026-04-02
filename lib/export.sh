#!/usr/bin/env bash

# Export module extracted from sb.sh (Stage 1-1)


b64_std_no_wrap() {
  printf '%s' "${1:-}" | openssl base64 -A 2>/dev/null | tr -d '\n'
}

url_encode() {
  printf '%s' "${1:-}" | jq -sRr @uri
}

build_encoded_query() {
  local out="" key val sep=""
  while [ "$#" -ge 2 ]; do
    key="$1"; val="$2"
    out="${out}${sep}${key}=$(url_encode "$val")"
    sep="&"
    shift 2
  done
  printf '%s' "$out"
}

append_link_name_fragment() {
  local base="$1" name="$2"
  printf '%s#%s' "$base" "$(url_encode "$name")"
}

build_v2rayn_ss_link() {
  local server="$1" port="$2" method="$3" password="$4" name="$5"
  local userinfo enc
  userinfo="${method}:${password}"
  enc="$(b64_std_no_wrap "$userinfo")"
  printf 'ss://%s@%s:%s#%s' "$enc" "$server" "$port" "$(url_encode "$name")"
}

build_v2rayn_vmess_ws_link() {
  local server="$1" uuid="$2" host="$3" path="$4" name="$5"
  local payload enc
  payload="$(jq -nc \
    --arg ps "$name" \
    --arg add "$server" \
    --arg port "443" \
    --arg id "$uuid" \
    --arg aid "0" \
    --arg scy "auto" \
    --arg net "ws" \
    --arg type "none" \
    --arg host "$host" \
    --arg path "$path" \
    --arg tls "tls" \
    --arg sni "$host" \
    '{v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:$aid,scy:$scy,net:$net,type:$type,host:$host,path:$path,tls:$tls,sni:$sni}')"
  enc="$(b64_std_no_wrap "$payload")"
  printf 'vmess://%s' "$enc"
}

build_v2rayn_vless_reality_link() {
  local server="$1" port="$2" uuid="$3" sni="$4" pbk="$5" sid="$6" flow="$7" name="$8"
  local query
  query="$(build_encoded_query \
    encryption "none" \
    flow "$flow" \
    security "reality" \
    sni "$sni" \
    fp "chrome" \
    pbk "$pbk" \
    sid "$sid" \
    type "tcp")"
  append_link_name_fragment "vless://${uuid}@${server}:${port}?${query}" "$name"
}

build_v2rayn_vless_ws_link() {
  local server="$1" uuid="$2" host="$3" path="$4" name="$5"
  local query
  query="$(build_encoded_query \
    encryption "none" \
    security "tls" \
    sni "$host" \
    type "ws" \
    host "$host" \
    path "$path")"
  append_link_name_fragment "vless://${uuid}@${server}:443?${query}" "$name"
}

build_v2rayn_anytls_link() {
  local server="$1" port="$2" password="$3" sni="$4" name="$5"
  local query
  query="$(build_encoded_query sni "$sni" fp "chrome" alpn "h2,http/1.1" allowInsecure "1")"
  append_link_name_fragment "anytls://$(url_encode "$password")@${server}:${port}?${query}" "$name"
}

build_v2rayn_trojan_link() {
  local server="$1" port="$2" password="$3" sni="$4" name="$5"
  local query
  query="$(build_encoded_query security "tls" sni "$sni" alpn "h2,http/1.1" allowInsecure "1")"
  append_link_name_fragment "trojan://$(url_encode "$password")@${server}:${port}?${query}" "$name"
}

build_v2rayn_tuic_link() {
  local server="$1" port="$2" uuid="$3" password="$4" sni="$5" name="$6"
  local query
  query="$(build_encoded_query sni "$sni" alpn "h3" allow_insecure "1" congestion_control "bbr")"
  append_link_name_fragment "tuic://${uuid}:$(url_encode "$password")@${server}:${port}?${query}" "$name"
}

export_collect_context() {
  local json="$1"
  local ip ws_domain vm_domain inventory
  ip="$(get_public_ip)"
  ws_domain="example.com"
  vm_domain="example.com"
  inventory="$(protocol_entry_inventory "$json")"

  if printf '%s
' "$inventory" | awk -F '	' '$2 == "vless-ws" {found=1} END{exit !found}'; then
    read -r -p "请输入 vless-ws 域名（默认: example.com）: " ws_domain
    ws_domain="${ws_domain:-example.com}"
  fi
  if printf '%s
' "$inventory" | awk -F '	' '$2 == "vmess-ws" {found=1} END{exit !found}'; then
    read -r -p "请输入 vmess-ws 域名（默认: example.com）: " vm_domain
    vm_domain="${vm_domain:-example.com}"
  fi

  jq -n --arg ip "$ip" --arg wsd "$ws_domain" --arg vmd "$vm_domain" '{ip:$ip,ws_domain:$wsd,vm_domain:$vmd}'
}

export_configs() {
  init_manager_env
  clear
  local json ctx ip ws_domain vm_domain relay_users_nl
  json="$(config_load)"
  ctx="$(export_collect_context "$json")"
  ip="$(echo "$ctx" | jq -r '.ip')"
  v_pbk="$(echo "$ctx" | jq -r '.v_pbk')"
  ws_domain="$(echo "$ctx" | jq -r '.ws_domain')"
  vm_domain="$(echo "$ctx" | jq -r '.vm_domain')"
  relay_users_nl="$(relay_list_table "$json" | awk -F '	' 'NF >= 2 {print $2}' | awk 'NF' | sort -u)"

  echo -e "${C}--- 节点配置导出 ---${NC}"

  local direct_tmp relay_tmp user_dir
  direct_tmp="$(mktemp)"
  relay_tmp="$(mktemp)"
  user_dir="$(mktemp -d)"

  while read -r inbound; do
    local tag type port sni path sid method server_p proto
    tag="$(echo "$inbound" | jq -r '.tag')"
    type="$(echo "$inbound" | jq -r '.type')"
    proto="$(inbound_protocol_name "$inbound")"
    port="$(echo "$inbound" | jq -r '.listen_port')"
    sni="$(echo "$inbound" | jq -r '.tls.server_name // "www.icloud.com"')"
    path="$(echo "$inbound" | jq -r '.transport.path // "/"')"
    sid="$(echo "$inbound" | jq -r '.tls.reality.short_id[0] // ""')"
    method="$(echo "$inbound" | jq -r '.method // "2022-blake3-aes-128-gcm"')"
    server_p="$(echo "$inbound" | jq -r '.password // empty')"

    while read -r user; do
      local name uuid pass flow out_name pw_out target_file business_user safe_user reality_public_key v2rayn_link
      name="$(echo "$user" | jq -r '.name // empty')"
      uuid="$(echo "$user" | jq -r '.uuid // empty')"
      pass="$(echo "$user" | jq -r '.password // empty')"
      flow="$(echo "$user" | jq -r '.flow // "xtls-rprx-vision"')"
      [ -z "$name" ] && continue
      out_name="$name"

      if [[ "$name" == *"@"* ]]; then
        business_user="$(user_business_name "$name")"
        safe_user="$(printf '%s' "$business_user" | tr '/ ' '__')"
        target_file="${user_dir}/${safe_user}.tmp"
      elif printf '%s
' "$relay_users_nl" | grep -Fxq "$name"; then
        target_file="$relay_tmp"
      else
        target_file="$direct_tmp"
      fi

      case "$proto" in
        vless-reality)
          [ -z "$uuid" ] && continue
          reality_public_key="$(meta_get_reality_public_key "$tag")"
          [ -n "$reality_public_key" ] || reality_public_key="PUBLIC_KEY_MISSING"
          {
            echo -e "
${W}[${out_name}]${NC}"
            echo -e " Clash: - {name: ${out_name}, type: vless, server: $ip, port: $port, uuid: $uuid, network: tcp, udp: true, tls: true, flow: ${flow}, servername: $sni, reality-opts: {public-key: $reality_public_key, short-id: '$sid'}, client-fingerprint: chrome}"
            echo ""
            echo -e " Quantumult X: vless=$ip:$port, method=none, password=$uuid, obfs=over-tls, obfs-host=$sni, reality-base64-pubkey=$reality_public_key, reality-hex-shortid=$sid, vless-flow=${flow}, udp-relay=true, tag=${out_name}"
            echo ""
            v2rayn_link="$(build_v2rayn_vless_reality_link "$ip" "$port" "$uuid" "$sni" "$reality_public_key" "$sid" "$flow" "$out_name")"
            echo -e " 通用链接: ${v2rayn_link}"
          } >> "$target_file"
          ;;
        anytls)
          [ -z "$pass" ] && continue
          {
            echo -e "
${W}[${out_name}]${NC}"
            echo -e " Clash: - {name: ${out_name}, type: anytls, server: $ip, port: $port, password: \"${pass}\", client-fingerprint: chrome, udp: true, sni: \"${sni}\", alpn: [h2, http/1.1], skip-cert-verify: true}"
            echo ""
            echo -e " Surge: ${out_name} = anytls, ${ip}, ${port}, password=${pass}, skip-cert-verify=true, sni=${sni}"
            echo ""
            v2rayn_link="$(build_v2rayn_anytls_link "$ip" "$port" "$pass" "$sni" "$out_name")"
            echo -e " 通用链接: ${v2rayn_link}"
          } >> "$target_file"
          ;;
        shadowsocks)
          [ -z "$pass" ] && continue
          if [ -n "$server_p" ] && [ "$server_p" != "$pass" ]; then pw_out="${server_p}:${pass}"; else pw_out="$pass"; fi
          {
            echo -e "
${W}[${out_name}]${NC}"
            echo -e " Clash: - {name: \"${out_name}\", type: ss, server: $ip, port: ${port}, cipher: ${method}, password: \"${pw_out}\", udp: true}"
            echo ""
            echo -e " Quantumult X: shadowsocks=$ip:${port}, method=${method}, password=${pw_out}, udp-relay=true, tag=${out_name}"
            echo ""
            echo -e " Surge: ${out_name} = ss, ${ip}, ${port}, encrypt-method=${method}, password=${pw_out}, udp-relay=true"
            echo ""
            v2rayn_link="$(build_v2rayn_ss_link "$ip" "$port" "$method" "$pw_out" "$out_name")"
            echo -e " 通用链接: ${v2rayn_link}"
          } >> "$target_file"
          ;;
        trojan)
          [ -z "$pass" ] && continue
          {
            echo -e "
${W}[${out_name}]${NC}"
            echo -e " Clash: - {name: \"${out_name}\", type: trojan, server: $ip, port: ${port}, password: \"${pass}\", client-fingerprint: chrome, udp: true, sni: \"${sni}\", alpn: [h2, http/1.1], skip-cert-verify: true}"
            echo ""
            echo -e " Quantumult X: trojan=${ip}:${port}, password=${pass}, over-tls=true, tls-host=${sni}, tls-verification=false, fast-open=false, udp-relay=true, tag=${out_name}"
            echo ""
            echo -e " Surge: ${out_name} = trojan, ${ip}, ${port}, password=${pass}, skip-cert-verify=true, sni=${sni}"
            echo ""
            v2rayn_link="$(build_v2rayn_trojan_link "$ip" "$port" "$pass" "$sni" "$out_name")"
            echo -e " 通用链接: ${v2rayn_link}"
          } >> "$target_file"
          ;;
        vmess-ws)
          [ -z "$uuid" ] && continue
          {
            echo -e "
${W}[${out_name}]${NC}"
            echo -e " Clash: - {name: ${out_name}, type: vmess, server: $ip, port: 443, uuid: ${uuid}, alterId: 0, cipher: auto, udp: true, tls: true, network: ws, servername: ${vm_domain}, ws-opts: {path: \"${path}\", headers: {Host: ${vm_domain}, max-early-data: 2048, early-data-header-name: Sec-WebSocket-Protocol}}}"
            echo ""
            echo -e " Quantumult X: vmess=$ip:443, method=chacha20-poly1305, password=${uuid}, obfs=wss, obfs-host=${vm_domain}, obfs-uri=${path}?ed=2048, fast-open=false, udp-relay=true, tag=${out_name}"
            echo ""
            echo -e " Surge: ${out_name} = vmess, ${ip}, 443, username=${uuid}, tls=true, vmess-aead=true, ws=true, ws-path=${path}?ed=2048, sni=${vm_domain}, ws-headers=Host:${vm_domain}, skip-cert-verify=false, udp-relay=true, tfo=false"
            echo ""
            v2rayn_link="$(build_v2rayn_vmess_ws_link "$ip" "$uuid" "$vm_domain" "${path}?ed=2048" "$out_name")"
            echo -e " 通用链接: ${v2rayn_link}"
          } >> "$target_file"
          ;;
        vless-ws)
          [ -z "$uuid" ] && continue
          {
            echo -e "
${W}[${out_name}]${NC}"
            echo -e " Clash: - {name: ${out_name}, type: vless, server: $ip, port: 443, uuid: ${uuid}, udp: true, tls: true, network: ws, servername: ${ws_domain}, ws-opts: {path: \"${path}\", headers: {Host: ${ws_domain}, max-early-data: 2048, early-data-header-name: Sec-WebSocket-Protocol}}}"
            echo ""
            echo -e " Quantumult X: vless=$ip:443,method=none,password=${uuid},obfs=wss,obfs-host=${ws_domain},obfs-uri=${path}?ed=2048,fast-open=false,udp-relay=true,tag=${out_name}"
            echo ""
            v2rayn_link="$(build_v2rayn_vless_ws_link "$ip" "$uuid" "$ws_domain" "${path}?ed=2048" "$out_name")"
            echo -e " 通用链接: ${v2rayn_link}"
          } >> "$target_file"
          ;;
        tuic)
          [ -z "$uuid" ] && continue
          [ -z "$pass" ] && continue
          {
            echo -e "
${W}[${out_name}]${NC}"
            echo -e " Clash: - {name: ${out_name}, type: tuic, server: $ip, port: $port, uuid: $uuid, password: $pass, alpn: [h3], disable-sni: false, reduce-rtt: false, udp-relay-mode: native, congestion-controller: bbr, skip-cert-verify: true, sni: $sni}"
            echo ""
            echo -e " Surge: ${out_name} = tuic-v5, ${ip}, ${port}, password=${pass}, sni=${sni}, uuid=${uuid}, alpn=h3, ecn=true"
            echo ""
            v2rayn_link="$(build_v2rayn_tuic_link "$ip" "$port" "$uuid" "$pass" "$sni" "$out_name")"
            echo -e " 通用链接: ${v2rayn_link}"
          } >> "$target_file"
          ;;
      esac
    done < <(echo "$inbound" | jq -c '.users[]?')
  done < <(echo "$json" | jq -c '.inbounds[]?')

  echo -e "
${C}直连节点${NC}"
  if [ -s "$direct_tmp" ]; then
    cat "$direct_tmp"
  else
    echo -e "  ${Y}当前没有直连节点。${NC}"
  fi

  echo -e "
${C}中转节点${NC}"
  if [ -s "$relay_tmp" ]; then
    cat "$relay_tmp"
  else
    echo -e "  ${Y}当前没有中转节点。${NC}"
  fi

  local user_file printed=0 user_name
  while IFS= read -r -d '' user_file; do
    printed=1
    user_name="$(basename "$user_file" .tmp)"
    echo -e "
${C}${user_name}节点${NC}"
    cat "$user_file"
  done < <(find "$user_dir" -maxdepth 1 -type f -name '*.tmp' -print0 | sort -z)

  if [ "$printed" -eq 0 ]; then
    echo -e "
${C}用户节点${NC}"
    echo -e "  ${Y}当前没有用户节点。${NC}"
  fi

  rm -rf "$user_dir" >/dev/null 2>&1 || true
  rm -f "$direct_tmp" "$relay_tmp" >/dev/null 2>&1 || true
  echo ""
  pause
}

