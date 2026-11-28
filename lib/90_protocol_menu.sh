#!/usr/bin/env bash
# ============================================================
# 模块: 90_protocol_menu.sh
# 职责: 协议管理菜单、安装/卸载协议、系统工具与状态概览
# 依赖: 00_base.sh, 10_config.sh, 20_protocol.sh, 30_route.sh
# ============================================================

# ---------- 协议状态摘要 ----------

protocol_status_summary() {
  local json="$1"
  local all_lines proto label ports
  all_lines="$(protocol_entry_inventory "$json")"

  for proto in "${SUPPORTED_PROTOCOLS[@]}"; do
    label="$proto"
    ports="$(printf '%s\n' "$all_lines" | awk -F '\x01' -v p="$proto" 'NF >= 3 && $2 == p { print $3 }' | sort -n | uniq | paste -sd'|' -)"

    if [ -n "$ports" ]; then
      printf '%s\t%s\t%s\n' "$label" "已安装" "$ports"
    else
      printf '%s\t%s\t%s\n' "$label" "未安装" ""
    fi
  done
}

protocol_entry_table() {
  local json="$1"
  protocol_entry_inventory "$json" | sort_tsv_by_protocol 1
}

# ---------- Protocol installation ----------
install_port_available() {
  local json="$1" meta="$2" proto="$3" port="$4" layer listeners
  ! port_conflict_for_protocol "$json" "$proto" "$port" || return 1
  for layer in $(protocol_transport_layer "$proto"); do
    if [ "$layer" = udp ] &&
      hy2_hop_range_in_use_by_meta "$meta" "$port" "$port"; then return 1; fi
    if has_cmd ss; then
      listeners="$(ss "-Hln${layer:0:1}" 2>/dev/null)" || continue
      if awk -v port="$port" '$4 ~ (":" port "$") { found=1 } END { exit !found }' <<< "$listeners"; then
        return 1
      fi
    fi
  done
}

install_recommended_port() {
  local json="$1" meta="$2" proto="$3" first fallback port
  case "$proto" in
    shadowsocks) first=8080; fallback=8081 ;;
    socks) first=1080; fallback=1081 ;;
    vmess-ws) first=8001; fallback=8003 ;;
    vless-ws) first=8002; fallback=8003 ;;
    *) first=443; fallback=8443 ;;
  esac
  if install_port_available "$json" "$meta" "$proto" "$first"; then
    printf '%s\n' "$first"
    return
  fi
  for ((port=fallback; port<fallback+100; port++)); do
    if install_port_available "$json" "$meta" "$proto" "$port"; then
      printf '%s\n' "$port"
      return
    fi
  done
  return 1
}

install_hy2_range_available() {
  local json="$1" meta="$2" port="$3" start="$4" end="$5" listeners
  hy2_hop_range_valid "$start" "$end" "$port" || return 1
  ! hy2_hop_range_in_use_by_meta "$meta" "$start" "$end" || return 1
  if jq -e --argjson start "$start" --argjson end "$end" '
    any(.inbounds[]?; .listen_port >= $start and .listen_port <= $end and
       (.type == "hysteria2" or .type == "hysteria" or .type == "tuic" or
        (.type == "shadowsocks" and (.network // "") != "tcp")))
  ' <<< "$json" >/dev/null; then return 1; fi
  if has_cmd ss && listeners="$(ss -Hlnu 2>/dev/null)"; then
    if awk -v start="$start" -v end="$end" '
      {n=split($4,a,":"); if (a[n]+0 >= start && a[n]+0 <= end) used=1}
      END {exit !used}
    ' <<< "$listeners"; then return 1; fi
  fi
}

install_hy2_recommended_range() {
  local json="$1" meta="$2" port="$3" start end
  for ((start=HY2_HOP_DEFAULT_START, end=HY2_HOP_DEFAULT_END; end<=65535; start+=3500, end+=3500)); do
    if install_hy2_range_available "$json" "$meta" "$port" "$start" "$end"; then
      printf '%s-%s\n' "$start" "$end"
      return
    fi
  done
  return 1
}

protocol_preserved_edit() {
  local json="$1" meta="$2" tag="$3" host="$4" port="$5" mapping="$6"
  [ -n "$(find_inbound_by_entry_key "$json" "$tag")" ] || return 1
  jq --arg tag "$tag" --arg host "$host" --arg port "$port" --arg mapping "$mapping" '
    if $mapping == "reset" then del(.[$tag].public_endpoint)
    else .[$tag].public_endpoint = {host:$host, port:($port | tonumber)} end
  ' <<< "$meta"
}

protocol_save_public_endpoint() {
  local json meta candidate
  json="$(user_manager_config_for_edit)" || return 1
  meta="$(meta_load)" || return 1
  candidate="$(protocol_preserved_edit "$json" "$meta" "$@")" || return 1
  meta_save "$candidate"
}

protocol_edit_menu() {
  local json="$1" lines=() selected tag proto port meta current host public_port answer
  mapfile -t lines < <(protocol_entry_table "$json")
  [ "${#lines[@]}" -gt 0 ] || { warn "当前没有可编辑节点。"; pause; return 0; }
  local i
  for i in "${!lines[@]}"; do
    IFS=$'\x01' read -r tag proto port <<< "${lines[i]}"
    printf '  %s. %s (%s)\n' "$((i+1))" "$tag" "$port"
  done
  read -r -p "选择要编辑导出地址的节点（回车返回）: " selected || return 0
  [[ "$selected" =~ ^[1-9][0-9]*$ ]] && [ "$selected" -le "${#lines[@]}" ] || return 0
  IFS=$'\x01' read -r tag proto port <<< "${lines[selected-1]}"
  case "$proto" in
    *-ws) say "WebSocket 公网地址请在「接入已有 CDN」中验证并保存。"; pause; return 0 ;;
  esac
  meta="$(meta_load)" || return 1
  current="$(jq -r --arg tag "$tag" '.[$tag].public_endpoint.host // empty' <<< "$meta")"
  public_port="$(jq -r --arg tag "$tag" --arg port "$port" '.[$tag].public_endpoint.port // $port' <<< "$meta")"
  say "监听端口 ${port}。保留原凭据、证书、路径和监听设置。"
  read -r -p "导出地址 [${current:-自动}]（域名、IPv4 或 IPv6，回车返回，输入 - 恢复自动）: " host || return 0
  [ -n "$host" ] || return 0
  if [ "$host" = - ]; then
    with_manager_lock protocol_save_public_endpoint "$tag" '' 0 reset || return 1
  else
    host="${host#[}"; host="${host%]}"
    [[ "$host" =~ ^[A-Za-z0-9:.%-]+$ ]] || { warn "请输入域名或 IP，不带 URL 路径。"; return 1; }
    read -r -p "公网端口 [$public_port]: " answer || return 0
    public_port="${answer:-$public_port}"
    [[ "$public_port" =~ ^[1-9][0-9]{0,4}$ ]] && ((public_port <= 65535)) || { warn "公网端口无效。"; return 1; }
    with_manager_lock protocol_save_public_endpoint "$tag" "$host" "$public_port" save || return 1
  fi
  # Export-only edits leave the runtime and existing remote client links intact.
  ok "导出地址已更新。"
  pause
}

# 按 meta 快照清理一批已删除的 hy2 节点的跳跃规则与记录（卸载/清空配置共用）。
# 参数：meta JSON，之后是 entry_key 列表。只删没有其它节点在用的范围。
# 回显更新后的 meta JSON；调用方在有变化时 meta_save。
hy2_hop_cleanup_removed() {
  local meta_json="${1:-}"; shift
  [ -n "$meta_json" ] || meta_json='{}'
  local _meta_out="$meta_json" _tag _range _port _after
  for _tag in "$@"; do
    _range="$(hy2_hop_range_from_meta "$_meta_out" "$_tag")"
    [ -n "$_range" ] || continue
    hy2_parse_hop_range "$_range" || continue
    _port="$(entry_key_to_port "$_tag")"
    _after="$(hy2_hop_range_del_from_meta "$_meta_out" "$_tag")"
    if hy2_hop_range_in_use_by_meta "$_after" "$_HOP_START" "$_HOP_END" "$_tag"; then
      _meta_out="$_after"
      continue
    fi
    hy2_hop_remove "$_HOP_START" "$_HOP_END" "$_port"
    _meta_out="$_after"
  done
  echo "$_meta_out"
}

protocol_commit_changes() {
  local previous="$1" previous_meta="$2" proposed="$3" meta="$4" latest latest_meta
  latest="$(user_manager_config_for_edit)" || return 1
  latest_meta="$(meta_load)" || return 1
  if [ "$(jq -Sc . <<< "$previous")" != "$(jq -Sc . <<< "$latest")" ] ||
    [ "$(jq -Sc . <<< "$previous_meta")" != "$(jq -Sc . <<< "$latest_meta")" ]; then
    warn "节点资料已变化，请重新打开菜单确认。"
    return 1
  fi
  if user_db_exists; then
    _USER_KEEP_LATEST_DB=1 _USER_MANAGER_APPLY_QUIET_OK=1 user_manager_apply_changes '' "$proposed" "$meta"
  elif user_db_is_first_use; then
    proposed="$(route_rebuild "$proposed" "$meta")" || return 1
    config_and_meta_apply "$proposed" "$meta"
  else
    user_db_restore_hint
    return 1
  fi
}

protocol_install_menu() {
  local previous="$1" proposed="$1" previous_meta meta tag proto port choice answer custom
  local host sni pair sid inbound obfs range start end cert_name path listen pass
  local opt ws_kind clock_needed=0 installed='[]'
  local -a picks=() chosen=() pending_clock=() hop_tags=() hop_ranges=()
  meta="$(meta_load)" || return 1
  previous_meta="$meta"
  print_rect_title "安装节点"
  for ((opt=0; opt<7; opt++)); do
    proto="${SUPPORTED_PROTOCOLS[opt]}"
    printf '  %s. %s\n' "$((opt+1))" "$proto"
  done
  printf '  8. WebSocket 节点（默认 VLESS-WS）\n'
  read -r -p "选择协议（用 + 多选，回车返回）: " choice || return 0
  [ -n "$choice" ] || return 0
  mapfile -t picks < <(parse_plus_selections "$choice")
  for opt in "${picks[@]}"; do
    if ! [[ "$opt" =~ ^[1-8]$ ]]; then warn "请选择列表里的协议。"; return 1; fi
    if [ "$opt" -eq 8 ]; then
      read -r -p "WebSocket 协议（回车 VLESS，m 选 VMess，b 两种都装）: " ws_kind || return 0
      case "$ws_kind" in
        '') chosen+=(vless-ws) ;;
        m|M) chosen+=(vmess-ws) ;;
        b|B) chosen+=(vmess-ws vless-ws) ;;
        *) warn "请选择回车、m 或 b。"; return 1 ;;
      esac
    else
      chosen+=("${SUPPORTED_PROTOCOLS[opt-1]}")
    fi
  done

  for proto in "${chosen[@]}"; do
    range='' obfs='' pass='' listen=127.0.0.1 cert_name="$SELF_SIGNED_SNI"
    port="$(install_recommended_port "$proposed" "$meta" "$proto")" || {
      warn "$proto 暂无推荐端口。"; continue;
    }
    if [ "$proto" = hysteria2 ]; then
      obfs=gecko
      range="$(install_hy2_recommended_range "$proposed" "$meta" "$port")" || range=''
    fi
    printf '\n  %s · %s %s\n' "$proto" "$(protocol_transport_layer "$proto")" "$port"
    case "$proto" in
      hysteria2) printf '  Gecko，端口跳跃 %s\n' "${range:-待选择}" ;;
      vless-reality) printf '  握手目标 %s，自动生成密钥、Short ID 和 UUID\n' "$REALITY_DEFAULT_HANDSHAKE" ;;
      socks) printf '  推荐在落地机安装。装好后复制落地链接，到中转机粘贴。\n' ;;
      *-ws) printf '  本机监听 %s，自动生成 UUID 和路径。\n' "$listen" ;;
      *) printf '  自动生成连接凭据。\n' ;;
    esac
    read -r -p "回车使用推荐值，c 自定义，q 跳过: " answer || return 0
    custom=0
    case "$answer" in
      '') ;;
      c|C) custom=1 ;;
      q|Q) continue ;;
      *) warn "请选择回车、c 或 q。"; continue ;;
    esac
    if [ "$custom" = 1 ]; then
      read -r -p "监听端口 [$port]: " answer || return 0
      port="${answer:-$port}"
      if ! [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] || ((port>65535)); then
        warn "监听端口无效。"; continue
      fi
      tag="$(entry_key_from_parts "$proto" "$port")" || return 1
      if [ -n "$(find_inbound_by_entry_key "$proposed" "$tag")" ]; then
        warn "$tag 已安装。可在「编辑节点」中更新导出地址，原连接资料会保留。"; continue
      fi
      if ! install_port_available "$proposed" "$meta" "$proto" "$port"; then
        warn "端口 $port 已被占用或处于现有跳跃范围内。"; continue
      fi
      case "$proto" in
        anytls|hysteria2|trojan|tuic|socks|shadowsocks)
          read -r -p "凭据（回车自动生成）: " pass || return 0 ;;
        *-ws)
          read -r -p "本机监听地址 [$listen]: " answer || return 0
          listen="${answer:-$listen}" ;;
      esac
      if [ "$proto" = hysteria2 ]; then
        range="$(install_hy2_recommended_range "$proposed" "$meta" "$port")" || range=''
        read -r -p "混淆（回车 Gecko，s Salamander，n 关闭）: " answer || return 0
        case "$answer" in '') ;; s|S) obfs=salamander ;; n|N) obfs='' ;; *) warn "混淆选项无效。"; continue ;; esac
        read -r -p "端口跳跃范围 [${range:-需填写}]，n 关闭: " answer || return 0
        case "$answer" in n|N) range='' ;; *) range="${answer:-$range}" ;; esac
      fi
    fi
    if [ "$proto" = hysteria2 ]; then
      if [ -n "$range" ]; then
        if ! hy2_parse_hop_range "$range" ||
          ! install_hy2_range_available "$proposed" "$meta" "$port" "$_HOP_START" "$_HOP_END"; then
          warn "UDP 跳跃范围无效或已占用。"; continue
        fi
        start="$_HOP_START"; end="$_HOP_END"
      elif [ "$custom" = 0 ]; then
        warn "没有可用的跳跃范围，请在自定义中指定范围。"; continue
      fi
    fi
    tag="$(entry_key_from_parts "$proto" "$port")" || return 1
    case "$proto" in
      hysteria2) inbound="$(build_hysteria2_inbound "$port" "$cert_name" "$pass" "$obfs")" || return 1 ;;
      vless-reality)
        host="$REALITY_DEFAULT_HANDSHAKE"
        if [ "$custom" = 1 ]; then
          read -r -p "Reality 握手域名 [$host]: " answer || return 0
          host="${answer:-$host}"
        fi
        if ! run_with_spinner "验证 Reality 握手目标" reality_handshake_check "$host"; then
          warn "无法验证 $host 的域名证书、TLS 1.3 或 HTTP/2。请选择自定义，换一个握手域名。"
          continue
        fi
        pair="$(generate_reality_keypair_auto)" || return 1
        sid="$(openssl rand -hex 4)" || return 1
        inbound="$(build_vless_reality_inbound "$port" "$host" "${pair%%$'\t'*}" "$sid")" || return 1
        meta="$(jq --arg tag "$tag" --arg public "${pair#*$'\t'}" '
          .[$tag] = ((.[$tag] // {}) + {public_key:$public, private_key_auto_generated:true})
        ' <<< "$meta")" || return 1 ;;
      anytls) inbound="$(build_anytls_inbound "$port" "$cert_name" "$pass")" || return 1 ;;
      shadowsocks)
        if ! inbound="$(build_ss_inbound "$port" "$pass")"; then
          warn "SS2022 密钥须是解码后 16 字节的 Base64，可分别指定两段。"; continue
        fi ;;
      socks) inbound="$(build_socks_inbound "$port" "$pass")" || return 1 ;;
      tuic) inbound="$(build_tuic_inbound "$port" "$cert_name" "$pass")" || return 1 ;;
      trojan) inbound="$(build_trojan_inbound "$port" "$cert_name" "$pass")" || return 1 ;;
      vmess-ws|vless-ws)
        answer=''
        if [ "$custom" = 1 ]; then read -r -p 'WS 路径（回车自动生成）: ' answer || return 0; fi
        path="$(normalize_ws_path "$answer")" || return 1
        if [ "$proto" = vmess-ws ]; then
          inbound="$(build_vmess_ws_inbound "$port" "$listen" "$path")" || return 1
        else
          inbound="$(build_vless_ws_inbound "$port" "$listen" "$path")" || return 1
        fi ;;
    esac
    case "$proto" in shadowsocks|vmess-ws) clock_needed=1; pending_clock+=("$tag") ;; esac
    if [ "$proto" = hysteria2 ] && [ -n "$range" ]; then
      hop_tags+=("$tag"); hop_ranges+=("$range")
      meta="$(hy2_hop_range_set_in_meta "$meta" "$tag" "$start" "$end")" || return 1
    fi
    proposed="$(jq --argjson inbound "$inbound" '.inbounds += [$inbound]' <<< "$proposed")" || return 1
    installed="$(jq --arg tag "$tag" '. + [$tag]' <<< "$installed")" || return 1
  done

  if [ "$clock_needed" = 1 ] && ! protocol_install_time_guard; then
    warn "已暂缓本批 SS2022 和 VMess，其余节点继续。"
    for tag in "${pending_clock[@]}"; do
      proposed="$(remove_inbound_by_entry_key "$proposed" "$tag")" || return 1
      installed="$(jq --arg tag "$tag" 'map(select(. != $tag))' <<< "$installed")" || return 1
    done
  fi
  [ "$installed" != '[]' ] || return 0
  with_manager_lock protocol_commit_changes "$previous" "$previous_meta" "$proposed" "$meta" || return 1

  for opt in "${!hop_tags[@]}"; do
    tag="${hop_tags[opt]}"
    port="$(entry_key_to_port "$tag")"
    hy2_parse_hop_range "${hop_ranges[opt]}" || return 1
    if hy2_hop_apply "$_HOP_START" "$_HOP_END" "$port" &&
      hy2_hop_rule_verified "$_HOP_START" "$_HOP_END" "$port"; then
      ok "端口跳跃已启用。请在云安全组放行 UDP ${_HOP_START}-${_HOP_END} 和 UDP ${port}。"
    else
      warn "$tag 的跳跃规则未通过验证，导出将使用主端口。"
      hy2_hop_remove "$_HOP_START" "$_HOP_END" "$port" || true
      meta="$(meta_load)" &&
        meta="$(hy2_hop_range_del_from_meta "$meta" "$tag")" &&
        meta_save "$meta" || warn "跳跃记录未能清理，请检查管理资料。"
    fi
  done
  if [ "${#hop_tags[@]}" -gt 0 ]; then
    hy2_hop_restore_sync || warn "开机恢复未验证，请检查端口跳跃服务。"
  fi
  ok "节点已安装。"
  if jq -e 'any(.[]; startswith("vmess-ws-") or startswith("vless-ws-"))' <<< "$installed" >/dev/null; then
    say "在「接入已有 CDN」中验证 WebSocket 公网入口后即可导出。"
  fi
  export_configs "__admin__" "$installed" || true
}

# ---------- 协议卸载菜单 ----------

protocol_remove_menu() {
  local json="$1"
  local lines=() choice_arr updated_json="$json" c entry_key related sel _rtype
  # 卸载前快照 Hysteria2 跳跃范围（meta 中），成功后按此清理防火墙规则
  local _remove_meta new_meta
  _remove_meta="$(meta_load 2>/dev/null)" || _remove_meta='{}'
  [ -n "$_remove_meta" ] || _remove_meta='{}'
  new_meta="$_remove_meta"
  local -a _removed_hy2_keys=()
  mapfile -t lines < <(protocol_entry_table "$json")
  if [ ${#lines[@]} -eq 0 ]; then
    warn "当前没有可卸载的协议。"
    pause
    return 0
  fi
  echo -e "\n${R}已安装协议如下（多个用 + 连接，如 1+2）:${NC}"
  local i=1
  for line in "${lines[@]}"; do
    IFS=$'\x01' read -r entry_key type port <<< "$line"
    echo -e " [$i] ${entry_key}"
    i=$((i+1))
  done
  read -r -p "请输入要卸载的协议编号（回车返回）: " sel
  mapfile -t choice_arr < <(parse_plus_selections "${sel:-}")
  [ ${#choice_arr[@]} -eq 0 ] && { warn "未选择任何协议。"; pause; return 0; }

  for c in "${choice_arr[@]}"; do
    if ! [[ "$c" =~ ^[0-9]+$ ]] || [ "$c" -lt 1 ] || [ "$c" -gt "${#lines[@]}" ]; then
      warn "无效协议编号：$c，已返回上一级。"
      pause
      return 0
    fi
  done

  local _cert_files_to_clean=()
  for c in "${choice_arr[@]}"; do
    IFS=$'\x01' read -r entry_key _rtype _ <<< "${lines[$((c-1))]}"
    if ws_cdn_has_managed_entry "$_remove_meta" "$entry_key"; then
      warn "$entry_key 仍有脚本托管的 CDN 路径。请先在「接入已有 CDN」中移除该入口。"
      pause
      return 1
    fi
    if [ "$_rtype" = "hysteria2" ]; then _removed_hy2_keys+=("$entry_key"); fi
    related="$(relay_list_table "$updated_json" | awk -F '\x01' -v ek="$entry_key" '{u=$2; sub(/@.*/, "", u)} $1 == ek {print u}' | awk 'NF' | sort -u)" || {
      err "读取关联中转失败，已中止卸载。"
      pause
      return 1
    }
    if [ -n "$related" ]; then
      warn "卸载 ${entry_key} 将同时删除以下关联中转："
      echo "$related" | sed 's/^/  - /'
    fi
    updated_json="$(remove_relays_for_entry_key "$updated_json" "$entry_key")" || {
      err "删除关联中转失败，已中止，未写入配置。"
      pause
      return 1
    }
    local _crt _key
    _crt="$(echo "$updated_json" | jq -r --arg ek "$entry_key" '.inbounds[]? | select((.tag // "") == $ek) | .tls.certificate_path // empty' | head -n1)"
    _key="$(echo "$updated_json" | jq -r --arg ek "$entry_key" '.inbounds[]? | select((.tag // "") == $ek) | .tls.key_path // empty' | head -n1)"
    [ -n "$_crt" ] && [[ "$_crt" == /etc/sing-box/* ]] && _cert_files_to_clean+=("$_crt")
    [ -n "$_key" ] && [[ "$_key" == /etc/sing-box/* ]] && _cert_files_to_clean+=("$_key")
    updated_json="$(remove_inbound_by_entry_key "$updated_json" "$entry_key")" || {
      err "删除协议失败，已中止，未写入配置。"
      pause
      return 1
    }
    new_meta="$(jq --arg entry "$entry_key" 'del(.[$entry])' <<< "$new_meta")" || return 1
  done

  local _apply_ok=0
  if with_manager_lock protocol_commit_changes "$json" "$_remove_meta" "$updated_json" "$new_meta"; then
    _apply_ok=1
  else
    warn "协议卸载失败，已返回上一级。"
  fi
  if [ "$_apply_ok" -eq 1 ] && [ ${#_cert_files_to_clean[@]} -gt 0 ]; then
    for _f in "${_cert_files_to_clean[@]}"; do
      rm -f "$_f" >/dev/null 2>&1 || true
    done
  fi
  # 卸载成功的 hy2 节点：没有其它节点在用的跳跃范围就删规则、清记录
  if [ "$_apply_ok" -eq 1 ] && [ ${#_removed_hy2_keys[@]} -gt 0 ]; then
    hy2_hop_cleanup_removed "$_remove_meta" "${_removed_hy2_keys[@]}" >/dev/null
    # 没有跳跃范围剩下时，顺带拆掉开机自恢复服务。
    hy2_hop_restore_sync || warn "开机自恢复服务同步失败，请手动检查。"
  fi
  [ "$_apply_ok" -eq 1 ] && ok "协议已卸载。"
  pause
  return 0
}

# ---------- 协议管理主菜单 ----------

protocol_manager() {
  init_manager_env || { pause; return 0; }
  while true; do
    clear
    local json
    json="$(user_manager_config_for_edit)" || return 1
    print_rect_title "节点管理"
    local _proto_tmp
    _proto_tmp="$(mktemp)"
    if protocol_status_summary "$json" >"$_proto_tmp" && [ -s "$_proto_tmp" ]; then
      local proto_width=15 proto_pad status_color port_text
      echo -e "${C}当前状态${NC}"
      echo -e "${B}--------------------------------------------------------${NC}"
      while IFS=$'\t' read -r proto status ports; do
        proto_pad=$(printf "%-${proto_width}s" "$proto")
        if [ "$status" = "已安装" ]; then
          status_color="$G"
        else
          status_color="$Y"
        fi
        if [ -n "$ports" ]; then
          port_text="（端口${ports//|/|端口}）"
          printf "  - %b%s%b  %b【%s】%b%b%s%b\n" "$W" "$proto_pad" "$NC" "$status_color" "$status" "$NC" "$C" "$port_text" "$NC"
        else
          printf "  - %b%s%b  %b【%s】%b\n" "$W" "$proto_pad" "$NC" "$status_color" "$status" "$NC"
        fi
      done < "$_proto_tmp"
    else
      echo -e "${Y}当前没有任何协议。${NC}"
    fi
    rm -f "$_proto_tmp" >/dev/null 2>&1 || true
    echo -e "${B}--------------------------------------------------------${NC}"
    echo -e "  ${C}1.${NC} 安装协议"
    echo -e "  ${C}2.${NC} 卸载协议"
    echo -e "  ${C}3.${NC} 编辑节点导出地址"
    echo -e "  ${C}4.${NC} 接入已有 CDN"
    echo -e "  ${R}0.${NC} 返回主菜单"
    read -r -p "请选择操作: " act
    case "${act:-}" in
      1) protocol_install_menu "$json" || true ;;
      2) protocol_remove_menu "$json" || true ;;
      3) protocol_edit_menu "$json" || true ;;
      4) ws_cdn_menu "$json" || true ;;
      0|q|Q|"") return 0 ;;
      *) warn "无效输入：$act"; sleep 1 ;;
    esac
  done
}

# ---------- 其它工具入口 ----------

clear_config_json() {
  init_manager_env || { pause; return 0; }
  clear
  echo -e "${Y}--- 清空/重置配置文件 ---${NC}"
  echo -e "${Y}注意：该操作将清空当前 config.json。${NC}"
  ask_confirm_yes || { warn "已取消清空/重置。"; pause; return 0; }
  # 原子提交：config 重置 + meta 删 .warp/.relay 在同一把锁内一起做，避免分裂
  local empty_config empty_meta current_config _clear_meta
  current_config="$(user_manager_config_for_edit)" || return 1
  _clear_meta="$(meta_load)" || return 1
  if jq -e 'any(to_entries[] | select(.value|type=="object") | .value.cdn_entries[]?; .mode == "nginx")' <<< "$_clear_meta" >/dev/null; then
    warn "还有脚本托管的 CDN 路径。请先在「接入已有 CDN」中移除这些入口。"
    pause
    return 1
  fi
  empty_config="$(config_min_template)"
  empty_meta="$(jq --argjson config "$current_config" '
    reduce ($config.inbounds[]?.tag // empty) as $tag (del(.warp,.relay); del(.[$tag]))
  ' <<< "$_clear_meta")" || return 1
  if with_manager_lock protocol_commit_changes "$current_config" "$_clear_meta" "$empty_config" "$empty_meta"; then
    ok "配置已清空，分流状态已重置。"
    # 清空配置会删掉所有 hy2 入站，顺带清理其跳跃规则，避免残留重定向
    local -a _clear_keys=()
    mapfile -t _clear_keys < <(echo "$_clear_meta" | jq -r 'to_entries[] | select(.key | startswith("hy2-")) | select(.value.hop_start != null) | .key')
    if [ ${#_clear_keys[@]} -gt 0 ]; then
      hy2_hop_cleanup_removed "$_clear_meta" "${_clear_keys[@]}" >/dev/null
      # 所有 hy2 节点都清掉了，顺带拆掉开机自恢复服务。
      hy2_hop_restore_sync || warn "开机自恢复服务同步失败，请手动检查。"
    fi
  else
    err "配置或分流状态清空失败。"
  fi
  pause
}

view_realtime_log() {
  clear
  print_rect_title "查看实时日志"
  if [ ! -f "$SCRIPT_LOG_FILE" ]; then
    warn "当前暂无日志文件：$SCRIPT_LOG_FILE"
    pause
    return 0
  fi

  echo -e "${Y}正在显示最近 10 行日志，并进入实时跟踪；按 Ctrl+C 返回菜单。${NC}"

  local old_trap
  old_trap="$(trap -p INT || true)"

  trap 'echo ""; trap - INT; return 0' INT
  tail -n 10 -f "$SCRIPT_LOG_FILE"
  trap - INT

  if [ -n "$old_trap" ]; then
    eval "$old_trap"
  fi

  echo ""
  return 0
}

view_config_formatted() {
  init_manager_env || { pause; return 0; }
  clear
  echo -e "${C}--- 查看格式化配置 ---${NC}"
  sing-box format -c "$CONFIG_FILE" || err "sing-box format 执行失败。"
  echo ""
  pause
}

singbox_status_summary() {
  local _status _version _state _upstream _suffix
  case "$INIT_SYSTEM" in
    systemd)
      _state="$(systemctl is-active sing-box 2>/dev/null || true)"
      case "$_state" in
        active) _status="${G}● 运行中${NC}" ;;
        failed) _status="${Y}● 异常${NC}" ;;
        activating) _status="${Y}● 启动中${NC}" ;;
        *) _status="${R}○ 已停止${NC}" ;;
      esac
      ;;
    openrc)
      _state="$(rc-service sing-box status 2>&1 || true)"
      case "$_state" in
        *crashed*) _status="${Y}● 异常${NC}" ;;
        *started*|*running*) _status="${G}● 运行中${NC}" ;;
        *stopped*) _status="${R}○ 已停止${NC}" ;;
        *)
          if singbox_service_active; then
            _status="${G}● 运行中${NC}"
          else
            _status="${R}○ 已停止${NC}"
          fi
          ;;
      esac
      ;;
    *)
      if singbox_service_active; then
        _status="${G}● 运行中${NC}"
      else
        _status="${R}○ 已停止${NC}"
      fi
      ;;
  esac
  _version=""
  if [ -x "$SINGBOX_BIN" ]; then
    _version="$("$SINGBOX_BIN" version 2>/dev/null | awk '/^sing-box version / {print $3; exit}')"
  fi
  [ -n "$_version" ] || _version="未安装"

  _suffix=""
  _upstream="$(get_cached_upstream_version 2>/dev/null || true)"
  if [ "$_version" != "未安装" ] && [ -n "$_upstream" ]; then
    if [ "$_version" != "$_upstream" ] && version_ge "$_upstream" "$_version"; then
      _suffix="  ${Y}↑ 有新版 v${_upstream}${NC}"
    fi
  fi

  if [ "$_version" = "未安装" ]; then
    printf '  %b运行状态：%b%b  %b(未安装内核)%b\n' "$D" "$NC" "$_status" "$Y" "$NC"
  else
    printf '  %b运行状态：%b%b  %bv%s%b%b\n' "$D" "$NC" "$_status" "$C" "$_version" "$NC" "$_suffix"
  fi
}

# 主界面轻量概览：零网络请求，纯本地快速统计节点/中转/用户/扩展状态
singbox_dashboard_summary() {
  singbox_status_summary
  local node_cnt=0 relay_cnt=0 user_cnt=0 disabled_cnt=0
  if [ -s "$CONFIG_FILE" ] && has_cmd jq; then
    read -r node_cnt relay_cnt < <(
      jq -r '
        [
          ((.inbounds // []) | length),
          ([.outbounds[]? | select((.tag // "") | startswith("to-"))] | length)
        ] | @tsv
      ' "$CONFIG_FILE" 2>/dev/null || printf '0\t0\n'
    )
  fi
  if [ -s "$USER_DB_FILE" ] && has_cmd jq; then
    read -r user_cnt disabled_cnt < <(
      jq -r '
        [
          ((.users // {}) | length),
          ([(.users // {})[] | select(.enabled != true)] | length)
        ] | @tsv
      ' "$USER_DB_FILE" 2>/dev/null || printf '0\t0\n'
    )
  fi
  local user_txt="${user_cnt} 位用户"
  [ "${disabled_cnt:-0}" -gt 0 ] && user_txt="${user_cnt} 位用户 (${disabled_cnt} 停用)"
  printf '  %b节点概览：%b%b%s%b 个节点 · %b%s%b 条中转 · %b%s%b\n' \
    "$D" "$NC" "$W" "${node_cnt:-0}" "$NC" "$W" "${relay_cnt:-0}" "$NC" "$W" "$user_txt" "$NC"

  local warp_txt="${D}未开启${NC}" tg_txt="${D}未启用${NC}"
  if [ -s "$META_FILE" ] && has_cmd jq; then
    local w_cnt
    w_cnt="$(jq -r 'if (.warp.mode // "off") == "rules" then ((.warp.rules // []) | length) else 0 end' "$META_FILE" 2>/dev/null || echo 0)"
    [ "${w_cnt:-0}" -gt 0 ] && warp_txt="${G}已开启(${w_cnt}条)${NC}"
  fi
  if [ -s "$TG_CONFIG_FILE" ] && has_cmd jq; then
    local tg_en tg_role
    read -r tg_en tg_role < <(jq -r '[(.enabled // false | tostring), (.role // "")] | @tsv' "$TG_CONFIG_FILE" 2>/dev/null || printf 'false\t\n')
    if [ "$tg_en" = "true" ]; then
      case "$tg_role" in
        center) tg_txt="${G}中心端${NC}" ;;
        agent)  tg_txt="${G}节点端${NC}" ;;
        *)      tg_txt="${G}已启用${NC}" ;;
      esac
    fi
  fi
  printf '  %b扩展功能：%bWARP 分流 %b  ·  Telegram %b\n' "$D" "$NC" "$warp_txt" "$tg_txt"
}

singbox_restart() {
  clear
  print_rect_title "重启 sing-box"
  if run_with_spinner "正在重启 sing-box 并检查状态..." reload_or_restart_singbox_safe; then
    ok "sing-box 已重启并运行正常。"
  else
    err "重启失败，请查看实时日志排查原因。"
  fi
  echo ""
  pause
}

singbox_start() {
  clear
  print_rect_title "启动 sing-box"
  local rc=0
  case "$INIT_SYSTEM" in
    systemd) run_with_spinner "正在启动 sing-box..." systemctl start sing-box || rc=1 ;;
    openrc)  run_with_spinner "正在启动 sing-box..." openrc_start_service sing-box || rc=1 ;;
    *) err "未识别的系统服务管理器，无法启动。"; pause; return 1 ;;
  esac
  sleep 1
  if [ "$rc" -eq 0 ] && singbox_service_active; then
    ok "sing-box 已启动并运行正常。"
  else
    err "启动失败，请检查配置或查看日志。"
  fi
  echo ""
  pause
}

singbox_stop() {
  clear
  print_rect_title "停止 sing-box"
  case "$INIT_SYSTEM" in
    systemd) run_with_spinner "正在停止 sing-box..." systemctl stop sing-box && ok "sing-box 已停止。" || err "停止失败。" ;;
    openrc)  run_with_spinner "正在停止 sing-box..." openrc_stop_service sing-box && ok "sing-box 已停止。" || err "停止失败。" ;;
    *) err "未识别的系统服务管理器，无法停止。" ;;
  esac
  echo ""
  pause
}

system_tools_menu() {
  while true; do
    clear
    print_rect_title "系统工具"
    singbox_status_summary
    cron_job_status_line "实时同步" "$PERIODIC_SYNC_CRON_MARK"
    cron_job_status_line "日常维护" "$DAILY_MAINTENANCE_CRON_MARK"
    ui_hr
    local toggle_label
    if singbox_service_active; then
      toggle_label="停止 sing-box 服务"
    else
      toggle_label="启动 sing-box 服务"
    fi
    echo -e "  ${C}1.${NC} 重启 sing-box 服务"
    echo -e "  ${C}2.${NC} ${toggle_label}"
    echo -e "  ${C}3.${NC} 查看实时运行日志"
    echo -e "  ${C}4.${NC} 查看当前配置文件"
    echo -e "  ${Y}5.${NC} 重置全部节点配置 ${D}(清空 config.json)${NC}"
    echo -e "  ${D}0. 返回主菜单${NC}"
    ui_hr
    local act
    read -r -p "请选择操作（回车返回）: " act
    case "${act:-}" in
      1) singbox_restart ;;
      2)
        if singbox_service_active; then
          singbox_stop
        else
          singbox_start
        fi
        ;;
      3) view_realtime_log ;;
      4) view_config_formatted ;;
      5) clear_config_json ;;
      0|q|Q|"") return 0 ;;
      *) warn "无效输入：$act"; sleep 1 ;;
    esac
  done
}
