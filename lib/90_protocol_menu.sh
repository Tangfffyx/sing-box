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

# ---------- 协议安装菜单 ----------

prompt_password_or_return() {
  local prompt="${1:-Password（回车随机生成）: }" outvar="$2" val
  read -r -p "$prompt" val
  printf -v "$outvar" '%s' "${val:-}"
  return 0
}

prompt_ss2022_password_or_return() {
  local outvar="$1" val
  read -r -p "Password（回车随机生成）: " val
  if [ -n "${val:-}" ] && ! ss2022_prepare_password_pair "$val" >/dev/null 2>&1; then
    warn "Shadowsocks 2022 Password 必须是解码后 16 字节的 base64；如需分别设置服务端/用户密码，请使用 base64:base64。"
    return 1
  fi
  printf -v "$outvar" '%s' "${val:-}"
  return 0
}

# ---------- 安装菜单通用助手 ----------
# protocol_install_menu 的工作状态放在以下全局变量里，助手函数直接读写它们，
# 避免用命令替换调用导致子 shell 丢状态。每次进入安装菜单时重新初始化。
#   _INSTALL_JSON        当前待提交的配置 JSON
#   _INSTALL_ADDED_KEYS  本次新增的节点 key（数组）
#   _INSTALL_PORT        install_pick_port 选出的端口
#   _INSTALL_ENTRY_KEY   install_pick_port 算出的节点 key

# 选端口并做冲突检查：成功设置 _INSTALL_PORT/_INSTALL_ENTRY_KEY，返回 0；
# 用户中途返回返回 1。调用方用 || { warn ...; pause; return 0; } 处理。
install_pick_port() {
  local proto="$1" prompt="$2" default="$3" conflict_desc="${4:-已被占用}"
  local port entry_key
  ask_port_or_return "$prompt" "$default" port || return 1
  entry_key="$(entry_key_from_parts "$proto" "$port")" || return 1
  while port_conflict_for_protocol "$_INSTALL_JSON" "$proto" "$port" "$entry_key"; do
    warn "端口 ${port} ${conflict_desc}，请更换。"
    ask_port_or_return "$prompt" "$default" port || return 1
    entry_key="$(entry_key_from_parts "$proto" "$port")" || return 1
  done
  _INSTALL_PORT="$port"
  _INSTALL_ENTRY_KEY="$entry_key"
}

# 把一个已生成的 inbound 写入 _INSTALL_JSON（同 tag 覆盖），并记入新增节点。
install_append_inbound() {
  local entry_key="$1" inbound="$2"
  _INSTALL_JSON="$(echo "$_INSTALL_JSON" | jq --arg ek "$entry_key" --argjson inb "$inbound" \
    '.inbounds |= map(select(.tag != $ek)) | .inbounds += [$inb]')"
  _INSTALL_ADDED_KEYS+=("$entry_key")
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

protocol_install_menu() {
  local json="$1"
  local choice_arr sel
  local -a added_node_keys=()
  local -a reality_meta_tags=()
  local -a reality_meta_pubs=()
  local -a hy2_meta_tags=()
  local -a hy2_meta_ranges=()
  local -a hy2_old_ranges=()
  local i=1 proto desc
  echo -e "\n${W}可安装的协议${NC} ${D}（支持多选，用 + 连接，如 1+3）${NC}"
  ui_hr
  for proto in "${SUPPORTED_PROTOCOLS[@]}"; do
    desc="${PROTO_DESC[$proto]:-}"
    printf '  %b%d.%b %-15s %b%s%b\n' "$C" "$i" "$NC" "$proto" "$D" "$desc" "$NC"
    i=$((i+1))
  done
  ui_hr
  read -r -p "请输入协议编号（回车返回）: " sel
  [ -z "${sel:-}" ] && return 0
  mapfile -t choice_arr < <(parse_plus_selections "${sel:-}")
  [ ${#choice_arr[@]} -eq 0 ] && return 0

  local c port listen sni path priv sid entry_key inbound pub generated_pair uuid pass method server_pass user_pass username
  local obfs_type obfs_pass obfs_choice hop_answer hop_range hop_enabled hop_start hop_end
  for c in "${choice_arr[@]}"; do
    if ! [[ "$c" =~ ^[0-9]+$ ]] || [ "$c" -lt 1 ] || [ "$c" -gt "${#SUPPORTED_PROTOCOLS[@]}" ]; then
      warn "编号无效：$c"
      sleep 1
      return 0
    fi
  done

  _INSTALL_JSON="$json"
  _INSTALL_ADDED_KEYS=()
  # Hysteria2 跳跃范围的旧值快照（用于重装换范围、关闭跳跃时清理旧规则）
  local _meta_snapshot
  _meta_snapshot="$(meta_load 2>/dev/null)" || _meta_snapshot='{}'
  [ -n "$_meta_snapshot" ] || _meta_snapshot='{}'

  for c in "${choice_arr[@]}"; do
    proto="${SUPPORTED_PROTOCOLS[$((c-1))]}"
    case "$proto" in
      vless-reality)
        install_pick_port vless-reality "Reality 监听端口 (默认: 443): " "443" || { warn "已返回上一级。"; pause; return 0; }
        port="$_INSTALL_PORT"; entry_key="$_INSTALL_ENTRY_KEY"
        read -r -p "Private Key（回车自动生成）: " priv
        pub=""
        if [ -z "$priv" ]; then
          generated_pair="$(generate_reality_keypair_auto 2>/dev/null || true)"
          priv="${generated_pair%%$'\t'*}"
          pub="${generated_pair#*$'\t'}"
          if [ -z "$priv" ] || [ -z "$pub" ]; then
            warn "自动生成 Reality 密钥对失败，已返回上一级。"
            pause
            return 0
          fi
          param_echo "Private Key" "$priv"
          param_echo "Public Key" "$pub"
        else
          read -r -p "Public Key（必填，与 Private Key 配对，回车返回）: " pub
          if [ -z "$pub" ]; then
            warn "手动输入 Private Key 时必须同时提供 Public Key，已返回上一级。"
            pause
            return 0
          fi
        fi
        read -r -p "Short ID (回车随机生成8位hex): " sid
        if [ -z "$sid" ]; then
          sid="$(openssl rand -hex 4 2>/dev/null || true)"
          if [ -z "$sid" ]; then sid="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-8)"; fi
          param_echo "Short ID" "$sid"
        fi
        sni="$(choose_tls_domain "Reality")" || return 0
        inbound="$(build_vless_reality_inbound "$port" "$sni" "$priv" "$sid")"
        uuid="$(echo "$inbound" | jq -r '.users[0].uuid // empty')"
        param_echo "UUID" "$uuid"
        install_append_inbound "$entry_key" "$inbound"
        if [ -n "$pub" ]; then
          reality_meta_tags+=("$entry_key")
          reality_meta_pubs+=("$pub")
        fi
        ;;
      anytls)
        install_pick_port anytls "AnyTLS 端口 (默认: 443): " "443" || { warn "已返回上一级。"; pause; return 0; }
        port="$_INSTALL_PORT"; entry_key="$_INSTALL_ENTRY_KEY"
        sni="$(choose_tls_domain "AnyTLS")" || return 0
        prompt_password_or_return "Password（回车随机生成）: " pass || { pause; return 0; }
        if ! inbound="$(build_anytls_inbound "$port" "$sni" "$pass")"; then
          err "生成 AnyTLS 配置失败：证书文件未能生成，已返回上一级。"
          pause
          return 0
        fi
        pass="$(echo "$inbound" | jq -r '.users[0].password // empty')"
        param_echo "Password" "$pass"
        install_append_inbound "$entry_key" "$inbound"
        ;;
      hysteria2)
        install_pick_port hysteria2 "Hysteria2 端口（默认443，可与TCP协议的443端口并存）: " "443" "已被其它 Hysteria2 占用" || { warn "已返回上一级。"; pause; return 0; }
        port="$_INSTALL_PORT"; entry_key="$_INSTALL_ENTRY_KEY"
        sni="$(choose_tls_domain "Hysteria2")" || return 0
        prompt_password_or_return "Password（回车随机生成）: " pass || { pause; return 0; }
        # 混淆：默认 gecko，可切 salamander 或不启用；混淆密码与认证密码分开两个。
        read -r -p "混淆类型（1=gecko 默认，2=salamander，3=不启用，回车默认1）: " obfs_choice
        case "${obfs_choice:-1}" in
          2) obfs_type="salamander" ;;
          3) obfs_type="" ;;
          *) obfs_type="gecko" ;;
        esac
        obfs_pass=""
        if [ -n "$obfs_type" ]; then
          prompt_password_or_return "混淆密码（回车随机生成）: " obfs_pass || { pause; return 0; }
          [ -n "$obfs_pass" ] || obfs_pass="$(random_b64_password 16)"
          param_echo "混淆类型" "$obfs_type"
          param_echo "混淆密码" "$obfs_pass"
        fi
        # 端口跳跃：默认开，范围默认 42310-45545；sing-box 只监听 UDP 443，跳跃靠防火墙重定向。
        hop_enabled=1
        hop_start="$HY2_HOP_DEFAULT_START"; hop_end="$HY2_HOP_DEFAULT_END"
        read -r -p "启用端口跳跃（默认开，输入 n 关闭，回车默认开）: " hop_answer
        if [[ "${hop_answer:-}" =~ ^[Nn]$ ]]; then
          hop_enabled=0
        else
          while true; do
            read -r -p "端口跳跃范围 (默认: ${hop_start}-${hop_end}，回车用默认): " hop_range
            hop_range="${hop_range:-${hop_start}-${hop_end}}"
            if ! hy2_parse_hop_range "$hop_range"; then
              warn "范围格式不对，应为 起始-结束，如 42310-45545。"
              continue
            fi
            hop_start="$_HOP_START"; hop_end="$_HOP_END"
            if ! hy2_hop_range_valid "$hop_start" "$hop_end" "$port"; then
              warn "范围无效：起始 ≥1024、结束 ≤65535、结束大于起始，且不能包含监听端口 ${port}。"
              continue
            fi
            if hy2_hop_range_in_use_by_meta "$_meta_snapshot" "$hop_start" "$hop_end" "$entry_key"; then
              warn "范围 ${hop_start}-${hop_end} 已被其它 Hysteria2 节点占用，请换一个范围。"
              continue
            fi
            break
          done
        fi
        if ! inbound="$(build_hysteria2_inbound "$port" "$sni" "$pass" "$obfs_type" "$obfs_pass")"; then
          err "生成 Hysteria2 配置失败：证书文件未能生成，已返回上一级。"
          pause
          return 0
        fi
        pass="$(echo "$inbound" | jq -r '.users[0].password // empty')"
        param_echo "Password" "$pass"
        install_append_inbound "$entry_key" "$inbound"
        hy2_meta_tags+=("$entry_key")
        if [ "$hop_enabled" -eq 1 ]; then
          hy2_meta_ranges+=("${hop_start}-${hop_end}")
        else
          hy2_meta_ranges+=("")
        fi
        hy2_old_ranges+=("$(hy2_hop_range_from_meta "$_meta_snapshot" "$entry_key")")
        ;;
      shadowsocks)
        install_pick_port shadowsocks "Shadowsocks 监听端口 (默认: 8080): " "8080" "已被同层协议占用" || { warn "已返回上一级。"; pause; return 0; }
        port="$_INSTALL_PORT"; entry_key="$_INSTALL_ENTRY_KEY"
        prompt_ss2022_password_or_return pass || { pause; return 0; }
        if ! inbound="$(build_ss_inbound "$port" "$pass")"; then
          err "生成 Shadowsocks 配置失败，已返回上一级。"
          pause
          return 0
        fi
        method="$(echo "$inbound" | jq -r '.method // empty')"
        server_pass="$(echo "$inbound" | jq -r '.password // empty')"
        user_pass="$(echo "$inbound" | jq -r '.users[0].password // empty')"
        if [ -n "$server_pass" ] && [ "$server_pass" != "$user_pass" ]; then
          pass="${server_pass}:${user_pass}"
        else
          pass="$user_pass"
        fi
        param_echo "Method" "$method"
        param_echo "Password" "$pass"
        install_append_inbound "$entry_key" "$inbound"
        ;;
      socks)
        install_pick_port socks "SOCKS 监听端口 (默认: 1080): " "1080" "已被同层协议占用" || { warn "已返回上一级。"; pause; return 0; }
        port="$_INSTALL_PORT"; entry_key="$_INSTALL_ENTRY_KEY"
        prompt_password_or_return "Password（回车随机生成）: " pass || { pause; return 0; }
        [ -n "$pass" ] || pass="$(random_b64_password 12)"
        if ! inbound="$(build_socks_inbound "$port" "$pass")"; then
          err "生成 SOCKS 配置失败，已返回上一级。"
          pause
          return 0
        fi
        username="$(echo "$inbound" | jq -r '.users[0].username // empty')"
        pass="$(echo "$inbound" | jq -r '.users[0].password // empty')"
        param_echo "Username" "$username"
        param_echo "Password" "$pass"
        install_append_inbound "$entry_key" "$inbound"
        ;;
      trojan)
        install_pick_port trojan "Trojan 端口 (默认: 443): " "443" || { warn "已返回上一级。"; pause; return 0; }
        port="$_INSTALL_PORT"; entry_key="$_INSTALL_ENTRY_KEY"
        sni="$(choose_tls_domain "Trojan")" || return 0
        prompt_password_or_return "Password（回车随机生成）: " pass || { pause; return 0; }
        if ! inbound="$(build_trojan_inbound "$port" "$sni" "$pass")"; then
          err "生成 Trojan 配置失败：证书文件未能生成，已返回上一级。"
          pause
          return 0
        fi
        pass="$(echo "$inbound" | jq -r '.users[0].password // empty')"
        param_echo "Password" "$pass"
        install_append_inbound "$entry_key" "$inbound"
        ;;
      vmess-ws)
        read -r -p "vmess-ws 监听地址 (默认: 127.0.0.1): " listen; listen="${listen:-127.0.0.1}"
        install_pick_port vmess-ws "vmess-ws 监听端口 (默认: 8001): " "8001" || { warn "已返回上一级。"; pause; return 0; }
        port="$_INSTALL_PORT"; entry_key="$_INSTALL_ENTRY_KEY"
        read -r -p "WS Path (回车随机生成): " path; path="$(normalize_ws_path "${path:-}")"
        param_echo "WS Path" "$path"
        inbound="$(build_vmess_ws_inbound "$port" "$listen" "$path")"
        uuid="$(echo "$inbound" | jq -r '.users[0].uuid // empty')"
        param_echo "UUID" "$uuid"
        install_append_inbound "$entry_key" "$inbound"
        ;;
      vless-ws)
        read -r -p "vless-ws 监听地址 (默认: 127.0.0.1): " listen; listen="${listen:-127.0.0.1}"
        install_pick_port vless-ws "vless-ws 监听端口 (默认: 8002): " "8002" || { warn "已返回上一级。"; pause; return 0; }
        port="$_INSTALL_PORT"; entry_key="$_INSTALL_ENTRY_KEY"
        read -r -p "WS Path (回车随机生成): " path; path="$(normalize_ws_path "${path:-}")"
        param_echo "WS Path" "$path"
        inbound="$(build_vless_ws_inbound "$port" "$listen" "$path")"
        uuid="$(echo "$inbound" | jq -r '.users[0].uuid // empty')"
        param_echo "UUID" "$uuid"
        install_append_inbound "$entry_key" "$inbound"
        ;;
      tuic)
        install_pick_port tuic "TUIC 端口（默认443，可与TCP协议的443端口并存）: " "443" "已被其它 TUIC 占用" || { warn "已返回上一级。"; pause; return 0; }
        port="$_INSTALL_PORT"; entry_key="$_INSTALL_ENTRY_KEY"
        sni="$(choose_tls_domain "TUIC")" || return 0
        prompt_password_or_return "Password（回车随机生成）: " pass || { pause; return 0; }
        if ! inbound="$(build_tuic_inbound "$port" "$sni" "$pass")"; then
          err "生成 TUIC 配置失败：证书文件未能生成，已返回上一级。"
          pause
          return 0
        fi
        uuid="$(echo "$inbound" | jq -r '.users[0].uuid // empty')"
        pass="$(echo "$inbound" | jq -r '.users[0].password // empty')"
        param_echo "UUID" "$uuid"
        param_echo "Password" "$pass"
        install_append_inbound "$entry_key" "$inbound"
        ;;
    esac
  done

  updated_json="$_INSTALL_JSON"
  added_node_keys=("${_INSTALL_ADDED_KEYS[@]}")
  updated_json="$(route_rebuild "$updated_json")"
  # 构造候选 meta：把所有 reality 公钥和 Hysteria2 跳跃范围写进去，与 config 一起原子提交
  local candidate_meta i
  candidate_meta="$(meta_load 2>/dev/null)" || candidate_meta='{}'
  [ -n "$candidate_meta" ] || candidate_meta='{}'
  for i in "${!reality_meta_tags[@]}"; do
    candidate_meta="$(echo "$candidate_meta" | jq \
      --arg t "${reality_meta_tags[$i]}" --arg pk "${reality_meta_pubs[$i]}" \
      '.[$t] = ((.[$t] // {}) + {public_key:$pk, private_key_auto_generated:true})')" || {
      err "构造 reality meta 失败。"
      pause
      return 1
    }
  done
  for i in "${!hy2_meta_tags[@]}"; do
    if [ -n "${hy2_meta_ranges[$i]}" ]; then
      hy2_parse_hop_range "${hy2_meta_ranges[$i]}" || {
        err "构造 Hysteria2 跳跃 meta 失败：范围格式无效。"
        pause
        return 1
      }
      candidate_meta="$(hy2_hop_range_set_in_meta "$candidate_meta" "${hy2_meta_tags[$i]}" "$_HOP_START" "$_HOP_END")" || {
        err "构造 Hysteria2 跳跃 meta 失败。"
        pause
        return 1
      }
    else
      candidate_meta="$(hy2_hop_range_del_from_meta "$candidate_meta" "${hy2_meta_tags[$i]}")" || {
        err "构造 Hysteria2 跳跃 meta 失败。"
        pause
        return 1
      }
    fi
  done
  local _install_ok=0
  if user_db_exists; then
    local db_json node_key
    sync_user_usage_counters || true
    db_json="$(user_db_load)"
    for node_key in "${added_node_keys[@]}"; do
      db_json="$(user_db_on_node_added "$db_json" "$node_key")"
    done
    if _USER_KEEP_LATEST_DB=1 _USER_MANAGER_APPLY_QUIET_OK=1 user_manager_apply_changes "$db_json" "$updated_json" "$candidate_meta"; then
      _install_ok=1
    else
      warn "协议安装/更新失败，已返回上一级。"
    fi
  else
    if _CONFIG_APPLY_QUIET_OK=1 config_and_meta_apply "$updated_json" "$candidate_meta"; then
      _install_ok=1
    else
      warn "协议安装/更新失败，已返回上一级。"
    fi
  fi
  if [ "$_install_ok" -eq 1 ]; then
    ok "协议已安装/更新。"
    # Hysteria2 端口跳跃同步：配置已成功应用后才动防火墙
    local _hy2_i _hy2_tag _hy2_new _hy2_old _hy2_port _hy2_meta_now
    for _hy2_i in "${!hy2_meta_tags[@]}"; do
      _hy2_tag="${hy2_meta_tags[$_hy2_i]}"
      _hy2_new="${hy2_meta_ranges[$_hy2_i]}"
      _hy2_old="${hy2_old_ranges[$_hy2_i]}"
      _hy2_port="$(entry_key_to_port "$_hy2_tag")"
      if [ -n "$_hy2_new" ]; then
        hy2_parse_hop_range "$_hy2_new" || continue
        if hy2_hop_apply "$_HOP_START" "$_HOP_END" "$_hy2_port"; then
          if hy2_hop_rule_verified "$_HOP_START" "$_HOP_END" "$_hy2_port"; then
            ok "端口跳跃已启用：UDP ${_HOP_START}-${_HOP_END} -> ${_hy2_port}（${_hy2_tag}）。"
            say "云安全组还需放行 UDP ${_HOP_START}-${_HOP_END} 和 UDP ${_hy2_port}，脚本无法代劳。"
          else
            warn "端口跳跃重定向已执行，但验证未通过（防火墙里查不到 UDP ${_HOP_START}-${_HOP_END} -> ${_hy2_port} 的规则），请手动检查 iptables 后重试。"
          fi
        else
          warn "端口跳跃重定向设置失败（${_hy2_tag}）：配置已保存但跳跃未生效，已清理该节点的跳跃记录，可手动执行 iptables 重定向后重新安装。"
          _hy2_meta_now="$(meta_load 2>/dev/null)" || _hy2_meta_now='{}'
          _hy2_meta_now="$(hy2_hop_range_del_from_meta "$_hy2_meta_now" "$_hy2_tag")" \
            && meta_save "$_hy2_meta_now" || warn "跳跃记录清理失败，请手动检查 meta.json。"
          continue
        fi
        # 换范围：旧范围没有其它节点用就删掉
        if [ -n "$_hy2_old" ] && [ "$_hy2_old" != "$_hy2_new" ]; then
          hy2_parse_hop_range "$_hy2_old" || continue
          _hy2_meta_now="$(meta_load 2>/dev/null)" || _hy2_meta_now='{}'
          if ! hy2_hop_range_in_use_by_meta "$_hy2_meta_now" "$_HOP_START" "$_HOP_END" "$_hy2_tag"; then
            hy2_hop_remove "$_HOP_START" "$_HOP_END" "$_hy2_port"
          fi
        fi
      else
        # 本次关闭跳跃：旧范围没有其它节点用就删掉
        if [ -n "$_hy2_old" ]; then
          hy2_parse_hop_range "$_hy2_old" || continue
          _hy2_meta_now="$(meta_load 2>/dev/null)" || _hy2_meta_now='{}'
          if ! hy2_hop_range_in_use_by_meta "$_hy2_meta_now" "$_HOP_START" "$_HOP_END" "$_hy2_tag"; then
            hy2_hop_remove "$_HOP_START" "$_HOP_END" "$_hy2_port"
          fi
        fi
      fi
    done
    # 同步开机自恢复服务：还有跳跃范围就确保装好，一个不剩就拆掉。
    if [ ${#hy2_meta_tags[@]} -gt 0 ]; then
      hy2_hop_restore_sync || warn "开机自恢复服务同步失败：重启后跳跃规则可能丢失，请手动检查。"
    fi
    echo ""
    if ask_confirm_default_yes "是否立即导出节点配置？[Y/n]: "; then
      export_configs || true
      return 0
    fi
    return 0
  fi
  pause
  return 0
}

# ---------- 协议卸载菜单 ----------

protocol_remove_menu() {
  local json="$1"
  local lines=() choice_arr updated_json="$json" c entry_key related sel _rtype
  # 卸载前快照 Hysteria2 跳跃范围（meta 中），成功后按此清理防火墙规则
  local _remove_meta
  _remove_meta="$(meta_load 2>/dev/null)" || _remove_meta='{}'
  [ -n "$_remove_meta" ] || _remove_meta='{}'
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
  done

  updated_json="$(route_rebuild "$updated_json")" || {
    err "重建路由失败，已中止，未写入配置。"
    pause
    return 1
  }
  local _apply_ok=0
  if user_db_exists; then
    local db_json
    sync_user_usage_counters || true
    db_json="$(user_db_load)"
    if _USER_KEEP_LATEST_DB=1 _USER_MANAGER_APPLY_QUIET_OK=1 user_manager_apply_changes "$db_json" "$updated_json"; then
      _apply_ok=1
    else
      warn "协议卸载失败，已返回上一级。"
    fi
  else
    if _CONFIG_APPLY_QUIET_OK=1 config_apply "$updated_json"; then
      _apply_ok=1
    else
      warn "协议卸载失败，已返回上一级。"
    fi
  fi
  if [ "$_apply_ok" -eq 1 ] && [ ${#_cert_files_to_clean[@]} -gt 0 ]; then
    for _f in "${_cert_files_to_clean[@]}"; do
      rm -f "$_f" >/dev/null 2>&1 || true
    done
  fi
  # 卸载成功的 hy2 节点：没有其它节点在用的跳跃范围就删规则、清记录
  if [ "$_apply_ok" -eq 1 ] && [ ${#_removed_hy2_keys[@]} -gt 0 ]; then
    local _hop_meta_new
    _hop_meta_new="$(hy2_hop_cleanup_removed "$_remove_meta" "${_removed_hy2_keys[@]}")"
    if [ "$_hop_meta_new" != "$_remove_meta" ]; then
      meta_save "$_hop_meta_new" || warn "Hysteria2 跳跃记录清理失败，请手动检查 meta.json。"
    fi
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
    json="$(config_load)"
    print_rect_title "协议管理"
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
    echo -e "  ${R}0.${NC} 返回主菜单"
    read -r -p "请选择操作: " act
    case "${act:-}" in
      1) protocol_install_menu "$json" || true ;;
      2) protocol_remove_menu "$json" || true ;;
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
  local empty_config empty_meta
  empty_config="$(config_min_template)"
  empty_meta="$(meta_load 2>/dev/null | jq 'del(.warp, .relay)' 2>/dev/null)"
  [ -n "$empty_meta" ] || empty_meta='{}'
  if config_and_meta_apply "$empty_config" "$empty_meta"; then
    ok "配置已清空，分流状态已重置。"
    # 清空配置会删掉所有 hy2 入站，顺带清理其跳跃规则，避免残留重定向
    local _clear_meta _clear_new_meta
    local -a _clear_keys=()
    _clear_meta="$(meta_load 2>/dev/null)" || _clear_meta='{}'
    mapfile -t _clear_keys < <(echo "$_clear_meta" | jq -r 'to_entries[] | select(.key | startswith("hy2-")) | select(.value.hop_start != null) | .key')
    if [ ${#_clear_keys[@]} -gt 0 ]; then
      _clear_new_meta="$(hy2_hop_cleanup_removed "$_clear_meta" "${_clear_keys[@]}")"
      if [ "$_clear_new_meta" != "$_clear_meta" ]; then
        meta_save "$_clear_new_meta" || warn "Hysteria2 跳跃记录清理失败，请手动检查 meta.json。"
      fi
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
    echo -e "  ${C}5.${NC} 一键校准系统时间"
    echo -e "  ${Y}6.${NC} 重置全部节点配置 ${D}(清空 config.json)${NC}"
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
      5) sync_system_time_chrony ;;
      6) clear_config_json ;;
      0|q|Q|"") return 0 ;;
      *) warn "无效输入：$act"; sleep 1 ;;
    esac
  done
}
