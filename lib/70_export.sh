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
  printf 'vless://%s@%s:%s?encryption=none&flow=%s&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s' \
    "$uuid" "$server" "$port" \
    "$(url_encode "$flow")" \
    "$(url_encode "$sni")" \
    "$(url_encode "$pbk")" \
    "$(url_encode "$sid")" \
    "$(url_encode "$name")"
}

build_v2rayn_vless_ws_link() {
  local server="$1" uuid="$2" host="$3" path="$4" name="$5"
  printf 'vless://%s@%s:443?encryption=none&security=tls&sni=%s&type=ws&host=%s&path=%s#%s' \
    "$uuid" "$server" \
    "$(url_encode "$host")" \
    "$(url_encode "$host")" \
    "$(url_encode "$path")" \
    "$(url_encode "$name")"
}

build_v2rayn_anytls_link() {
  local server="$1" port="$2" password="$3" sni="$4" name="$5"
  # password 不做 url_encode：AnyTLS 客户端（mihomo/QX）实际未对 userinfo 做
  # URL 解码，编码后的 %2B/%3D 会被当成字面字符导致密码不匹配。
  # base64 字符集（A-Za-z0-9+/=）在 URL userinfo 中无歧义，可直接使用。
  printf 'anytls://%s@%s:%s?sni=%s&fp=chrome&alpn=%s&allowInsecure=1#%s' \
    "$password" "$server" "$port" \
    "$(url_encode "$sni")" \
    "$(url_encode "h2,http/1.1")" \
    "$(url_encode "$name")"
}

build_v2rayn_trojan_link() {
  local server="$1" port="$2" password="$3" sni="$4" name="$5"
  printf 'trojan://%s@%s:%s?security=tls&sni=%s&alpn=%s&allowInsecure=1#%s' \
    "$(url_encode "$password")" "$server" "$port" \
    "$(url_encode "$sni")" \
    "$(url_encode "h2,http/1.1")" \
    "$(url_encode "$name")"
}

build_v2rayn_tuic_link() {
  local server="$1" port="$2" uuid="$3" password="$4" sni="$5" name="$6"
  printf 'tuic://%s:%s@%s:%s?sni=%s&alpn=%s&allow_insecure=1&congestion_control=bbr#%s' \
    "$uuid" "$(url_encode "$password")" "$server" "$port" \
    "$(url_encode "$sni")" \
    "$(url_encode "h3")" \
    "$(url_encode "$name")"
}

build_v2rayn_hysteria2_link() {
  local server="$1" port="$2" password="$3" sni="$4" obfs_type="$5" obfs_pass="$6" name="$7"
  local query="sni=$(url_encode "$sni")"
  if [ -n "$obfs_type" ]; then
    query="${query}&obfs=$(url_encode "$obfs_type")&obfs-password=$(url_encode "$obfs_pass")"
  fi
  # 认证密码不做 url_encode：与 AnyTLS 链接同理，客户端不对 userinfo 做 URL 解码，
  # base64 字符集（A-Za-z0-9+/=）在 userinfo 中无歧义，可直接使用。
  # port 可能是单个端口（443）或跳跃范围（42310-45545），由调用方决定。
  printf 'hysteria2://%s@%s:%s/?%s#%s' \
    "$password" "$server" "$port" "$query" "$(url_encode "$name")"
}

# 从 meta 取某 hy2 节点的跳跃范围 "42310-45545"，没有返回空。
hy2_export_hop_range() {
  local tag="$1" meta_json="${2:-}"
  [ -n "$meta_json" ] || meta_json="$(meta_load 2>/dev/null || echo '{}')"
  hy2_hop_range_from_meta "$meta_json" "$tag"
}

# ---------- 导出上下文收集 ----------

export_collect_context() {
  local json="$1"
  local ip ws_domain vm_domain inventory
  if [ -z "${_CACHED_PUBLIC_IP:-}" ] && [ -t 1 ] && [ -t 2 ]; then
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
  ws_domain="example.com"
  vm_domain="example.com"
  inventory="$(protocol_entry_inventory "$json")"

  if printf '%s\n' "$inventory" | awk -F '\x01' '$2 == "vless-ws" {found=1} END{exit !found}'; then
    read -r -p "请输入 vless-ws 域名（默认: example.com）: " ws_domain
    ws_domain="${ws_domain:-example.com}"
  fi
  if printf '%s\n' "$inventory" | awk -F '\x01' '$2 == "vmess-ws" {found=1} END{exit !found}'; then
    read -r -p "请输入 vmess-ws 域名（默认: example.com）: " vm_domain
    vm_domain="${vm_domain:-example.com}"
  fi

  jq -n --arg ip "$ip" --arg wsd "$ws_domain" --arg vmd "$vm_domain" '{ip:$ip,ws_domain:$wsd,vm_domain:$vmd}'
}

# ---------- 主导出函数 ----------

export_configs() {
  local filter_user="${1:-}"
  init_manager_env || { pause; return 0; }
  clear
  print_rect_title "导出节点配置"
  local json meta_json ctx ip ws_domain vm_domain relay_users_nl
  local tag proto port sni path sid method server_p obfs_type obfs_pass
  local name uuid pass flow out_name pw_out target_file business_user safe_user reality_public_key v2rayn_link
  local hop_range qx_line clash_line
  json="$(config_load)"
  meta_json="$(meta_load 2>/dev/null || echo '{}')"
  [ -n "$meta_json" ] || meta_json='{}'

  # 交互模式下若有普通多用户，允许按用户筛选导出，避免长篇刷屏
  if [ -z "$filter_user" ] && [ -t 0 ] && [ -t 1 ] && user_db_exists; then
    local -a biz_users=()
    mapfile -t biz_users < <(user_db_load | jq -r '.users | keys[] | select(. != "admin")' 2>/dev/null)
    if [ "${#biz_users[@]}" -gt 0 ]; then
      echo ""
      echo -e "  ${C}0.${NC} 导出全部（管理员直连/中转 + 全部用户）"
      echo -e "  ${C}1.${NC} 仅导出管理员（直连 + 中转）"
      local u_idx=2 u_name
      for u_name in "${biz_users[@]}"; do
        echo -e "  ${C}${u_idx}.${NC} 仅导出用户：${u_name}"
        u_idx=$((u_idx + 1))
      done
      ui_hr
      local scope_ans
      read -r -p "请选择导出范围（回车导出全部）: " scope_ans
      case "${scope_ans:-0}" in
        0|"") filter_user="" ;;
        1) filter_user="__admin__" ;;
        *)
          if [[ "$scope_ans" =~ ^[0-9]+$ ]] && [ "$scope_ans" -ge 2 ] && [ "$scope_ans" -le $((${#biz_users[@]} + 1)) ]; then
            filter_user="${biz_users[$((scope_ans - 2))]}"
          else
            warn "编号无效，将导出全部配置。"
            filter_user=""
          fi
          ;;
      esac
    fi
  fi

  ctx="$(export_collect_context "$json")"
  IFS=$'\x01' read -r ip ws_domain vm_domain < <(
    printf '%s\n' "$ctx" | jq -r '[.ip, .ws_domain, .vm_domain] | join("\u0001")'
  )
  relay_users_nl="$(relay_list_table "$json" | awk -F '\x01' 'NF >= 2 {print $2}' | awk 'NF' | sort -u)"

  local direct_tmp relay_tmp user_dir
  direct_tmp="$(mktemp)"
  relay_tmp="$(mktemp)"
  user_dir="$(mktemp -d)"
  _export_cleanup() {
    rm -rf "$user_dir" >/dev/null 2>&1 || true
    rm -f "$direct_tmp" "$relay_tmp" >/dev/null 2>&1 || true
  }
  trap '_export_cleanup; trap - RETURN' RETURN

  # 单次 jq 展开全部 inbound × user，减少高频子进程 fork
  while IFS=$'\x01' read -r tag proto port sni path sid method server_p obfs_type obfs_pass name uuid pass flow; do
    [ -z "$name" ] && continue
    out_name="$name"

    if [[ "$name" == *"@"* ]]; then
      business_user="$(user_business_name "$name")"
      if [ -n "$filter_user" ] && [ "$filter_user" != "$business_user" ]; then
        continue
      fi
      safe_user="$(printf '%s' "$business_user" | tr '/ ' '__')"
      target_file="${user_dir}/${safe_user}.tmp"
    else
      if [ -n "$filter_user" ] && [ "$filter_user" != "__admin__" ]; then
        continue
      fi
      if printf '%s\n' "$relay_users_nl" | grep -Fxq "$name"; then
        target_file="$relay_tmp"
      else
        target_file="$direct_tmp"
      fi
    fi

    case "$proto" in
      vless-reality)
        [ -z "$uuid" ] && continue
        reality_public_key="$(printf '%s\n' "$meta_json" | jq -r --arg t "$tag" '.[$t].public_key // ""')"
        [ -n "$reality_public_key" ] || reality_public_key="PUBLIC_KEY_MISSING"
        {
          echo -e "\n${W}[${out_name}]${NC}"
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
          echo -e "\n${W}[${out_name}]${NC}"
          echo -e " Clash: - {name: ${out_name}, type: anytls, server: $ip, port: $port, password: \"${pass}\", client-fingerprint: chrome, udp: true, sni: \"${sni}\", alpn: [h2, http/1.1], skip-cert-verify: true}"
          echo ""
          echo -e " Quantumult X: anytls=${ip}:${port}, password=${pass}, over-tls=true, tls-host=${sni}, udp-relay=true, tag=${out_name}"
          echo ""
          v2rayn_link="$(build_v2rayn_anytls_link "$ip" "$port" "$pass" "$sni" "$out_name")"
          echo -e " 通用链接: ${v2rayn_link}"
          echo ""
          echo -e " Surge: ${out_name} = anytls, ${ip}, ${port}, password=${pass}, skip-cert-verify=true, sni=${sni}"
        } >> "$target_file"
        ;;
      shadowsocks)
        [ -z "$pass" ] && continue
        if [ -n "$server_p" ]; then pw_out="${server_p}:${pass}"; else pw_out="$pass"; fi
        {
          echo -e "\n${W}[${out_name}]${NC}"
          echo -e " Clash: - {name: \"${out_name}\", type: ss, server: $ip, port: ${port}, cipher: ${method}, password: \"${pw_out}\", udp: true}"
          echo ""
          echo -e " Quantumult X: shadowsocks=$ip:${port}, method=${method}, password=${pw_out}, udp-relay=true, tag=${out_name}"
          echo ""
          v2rayn_link="$(build_v2rayn_ss_link "$ip" "$port" "$method" "$pw_out" "$out_name")"
          echo -e " 通用链接: ${v2rayn_link}"
          echo ""
          echo -e " Surge: ${out_name} = ss, ${ip}, ${port}, encrypt-method=${method}, password=${pw_out}, udp-relay=true"
        } >> "$target_file"
        ;;
      trojan)
        [ -z "$pass" ] && continue
        {
          echo -e "\n${W}[${out_name}]${NC}"
          echo -e " Clash: - {name: \"${out_name}\", type: trojan, server: $ip, port: ${port}, password: \"${pass}\", client-fingerprint: chrome, udp: true, sni: \"${sni}\", alpn: [h2, http/1.1], skip-cert-verify: true}"
          echo ""
          echo -e " Quantumult X: trojan=${ip}:${port}, password=${pass}, over-tls=true, tls-host=${sni}, tls-verification=false, fast-open=false, udp-relay=true, tag=${out_name}"
          echo ""
          v2rayn_link="$(build_v2rayn_trojan_link "$ip" "$port" "$pass" "$sni" "$out_name")"
          echo -e " 通用链接: ${v2rayn_link}"
          echo ""
          echo -e " Surge: ${out_name} = trojan, ${ip}, ${port}, password=${pass}, skip-cert-verify=true, sni=${sni}"
        } >> "$target_file"
        ;;
      vmess-ws)
        [ -z "$uuid" ] && continue
        {
          echo -e "\n${W}[${out_name}]${NC}"
          echo -e " Clash: - {name: ${out_name}, type: vmess, server: $ip, port: 443, uuid: ${uuid}, alterId: 0, cipher: auto, udp: true, tls: true, network: ws, servername: ${vm_domain}, ws-opts: {path: \"${path}\", headers: {Host: ${vm_domain}}, max-early-data: 2048, early-data-header-name: Sec-WebSocket-Protocol}}"
          echo ""
          echo -e " Quantumult X: vmess=$ip:443, method=chacha20-poly1305, password=${uuid}, obfs=wss, obfs-host=${vm_domain}, obfs-uri=${path}?ed=2048, fast-open=false, udp-relay=true, tag=${out_name}"
          echo ""
          v2rayn_link="$(build_v2rayn_vmess_ws_link "$ip" "$uuid" "$vm_domain" "${path}?ed=2048" "$out_name")"
          echo -e " 通用链接: ${v2rayn_link}"
          echo ""
          echo -e " Surge: ${out_name} = vmess, ${ip}, 443, username=${uuid}, tls=true, vmess-aead=true, ws=true, ws-path=${path}?ed=2048, sni=${vm_domain}, ws-headers=Host:${vm_domain}, skip-cert-verify=false, udp-relay=true, tfo=false"
        } >> "$target_file"
        ;;
      vless-ws)
        [ -z "$uuid" ] && continue
        {
          echo -e "\n${W}[${out_name}]${NC}"
          echo -e " Clash: - {name: ${out_name}, type: vless, server: $ip, port: 443, uuid: ${uuid}, udp: true, tls: true, network: ws, servername: ${ws_domain}, ws-opts: {path: \"${path}\", headers: {Host: ${ws_domain}}, max-early-data: 2048, early-data-header-name: Sec-WebSocket-Protocol}}"
          echo ""
          echo -e " Quantumult X: vless=$ip:443,method=none,password=${uuid},obfs=wss,obfs-host=${ws_domain},obfs-uri=${path}?ed=2048,fast-open=false,udp-relay=true,tag=${out_name}"
          echo ""
          v2rayn_link="$(build_v2rayn_vless_ws_link "$ip" "$uuid" "$ws_domain" "${path}?ed=2048" "$out_name")"
          echo -e " 通用链接: ${v2rayn_link}"
        } >> "$target_file"
        ;;
      hysteria2)
        [ -z "$pass" ] && continue
        hop_range="$(hy2_export_hop_range "$tag" "$meta_json")"
        {
          echo -e "\n${W}[${out_name}]${NC}"
          clash_line=" Clash: - {name: ${out_name}, type: hysteria2, server: $ip, port: $port, password: $pass, sni: $sni, skip-cert-verify: true"
          if [ -n "$obfs_type" ]; then
            clash_line="${clash_line}, obfs: ${obfs_type}, obfs-password: ${obfs_pass}"
          fi
          if [ -n "$hop_range" ]; then
            clash_line="${clash_line}, ports: \"${hop_range}\", hop-interval: 30"
          fi
          clash_line="${clash_line}}"
          echo -e "$clash_line"
          echo ""
          qx_line=" Quantumult X: hysteria2=${ip}:${port}, password=${pass}, tls-host=${sni}, tls-verification=false, udp-relay=true"
          if [ -n "$hop_range" ]; then
            qx_line="${qx_line}, port-hopping=${hop_range}, port-hopping-interval=30"
          fi
          if [ "$obfs_type" = "gecko" ]; then
            qx_line="${qx_line}, gecko-password=${obfs_pass}"
          elif [ "$obfs_type" = "salamander" ]; then
            qx_line="${qx_line}, salamander-password=${obfs_pass}"
          fi
          qx_line="${qx_line}, tag=${out_name}"
          echo -e "$qx_line"
          echo ""
          if [ -n "$hop_range" ]; then
            v2rayn_link="$(build_v2rayn_hysteria2_link "$ip" "$hop_range" "$pass" "$sni" "$obfs_type" "$obfs_pass" "$out_name")"
          else
            v2rayn_link="$(build_v2rayn_hysteria2_link "$ip" "$port" "$pass" "$sni" "$obfs_type" "$obfs_pass" "$out_name")"
          fi
          echo -e " 通用链接: ${v2rayn_link}"
        } >> "$target_file"
        ;;
      tuic)
        [ -z "$uuid" ] && continue
        [ -z "$pass" ] && continue
        {
          echo -e "\n${W}[${out_name}]${NC}"
          echo -e " Clash: - {name: ${out_name}, type: tuic, server: $ip, port: $port, uuid: $uuid, password: $pass, alpn: [h3], disable-sni: false, reduce-rtt: false, udp-relay-mode: native, congestion-controller: bbr, skip-cert-verify: true, sni: $sni}"
          echo ""
          v2rayn_link="$(build_v2rayn_tuic_link "$ip" "$port" "$uuid" "$pass" "$sni" "$out_name")"
          echo -e " 通用链接: ${v2rayn_link}"
          echo ""
          echo -e " Surge: ${out_name} = tuic-v5, ${ip}, ${port}, password=${pass}, sni=${sni}, uuid=${uuid}, alpn=h3, ecn=true"
        } >> "$target_file"
        ;;
      socks)
        [ -z "$name" ] && continue
        [ -z "$pass" ] && continue
        {
          echo -e "\n${W}[${out_name}]${NC}"
          echo -e " 参数: server=${ip}  port=${port}  username=${name}  password=${pass}"
        } >> "$target_file"
        ;;
    esac
  done < <(
    printf '%s\n' "$json" | jq -r "${JQ_SHARED}"'
      [.inbounds[]?]
      | sort_by(protocol_sort_index(.tag // ""))
      | .[]
      | . as $in
      | ($in | detect_protocol) as $proto
      | ($in.users // [])[]?
      | [
          ($in.tag // ""),
          $proto,
          (($in.listen_port // 0) | tostring),
          ($in.tls.server_name // "www.icloud.com"),
          ($in.transport.path // "/"),
          ($in.tls.reality.short_id[0] // ""),
          ($in.method // "2022-blake3-aes-128-gcm"),
          ($in.password // ""),
          ($in.obfs.type // ""),
          ($in.obfs.password // ""),
          (.name // .username // ""),
          (.uuid // ""),
          (.password // ""),
          (.flow // "xtls-rprx-vision")
        ] | join("\u0001")
    '
  )

  if [ -z "$filter_user" ] || [ "$filter_user" = "__admin__" ]; then
    echo -e "\n${C}直连节点${NC}"
    if [ -s "$direct_tmp" ]; then
      cat "$direct_tmp"
    else
      echo -e "  ${D}暂无直连节点${NC}"
    fi

    if [ -s "$relay_tmp" ] || [ -z "$filter_user" ]; then
      echo -e "\n${C}中转节点${NC}"
      if [ -s "$relay_tmp" ]; then
        cat "$relay_tmp"
      else
        echo -e "  ${D}暂无中转节点${NC}"
      fi
    fi
  fi

  if [ "$filter_user" != "__admin__" ]; then
    local user_file printed=0 user_name
    while IFS= read -r -d '' user_file; do
      printed=1
      user_name="$(basename "$user_file" .tmp)"
      echo -e "\n${C}用户：${user_name}${NC}"
      cat "$user_file"
    done < <(find "$user_dir" -maxdepth 1 -type f -name '*.tmp' -print0 | sort -z)

    if [ "$printed" -eq 0 ] && [ -n "$filter_user" ]; then
      echo -e "\n${Y}用户 ${filter_user} 暂无可用节点（请确认已分配节点权限且已启用）。${NC}"
    elif [ "$printed" -eq 0 ]; then
      echo -e "\n${C}用户节点${NC}"
      echo -e "  ${D}暂无其他用户节点${NC}"
    fi
  fi

  echo ""
  pause
}
