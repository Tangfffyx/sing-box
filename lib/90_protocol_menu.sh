#!/usr/bin/env bash
# ============================================================
# 模块: 90_protocol_menu.sh
# 职责: 协议管理菜单、安装/卸载协议、规范化接管
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

# ---------- 规范化接管 ----------

normalize_takeover(){
  init_manager_env || { pause; return 0; }
  clear
  local json work_json
  local -a inv_lines=() issue_lines=() action_lines=()
  local -A target_seen=()
  local tag_updates=0 direct_updates=0 relay_user_updates=0 relay_out_updates=0 skipped=0

  json="$(config_load)"
  work_json="$json"
  mapfile -t inv_lines < <(protocol_entry_inventory_ext "$json")

  echo -e "${C}--- 规范化接管 ---${NC}"

  if [ ${#inv_lines[@]} -eq 0 ]; then
    warn "未识别到可接管的核心协议对象。"
    pause
    return 0
  fi

  local line idx oldtag proto port target current_count
  for line in "${inv_lines[@]}"; do
    IFS=$'\x01' read -r idx oldtag proto port <<< "$line"
    target="$(entry_key_from_parts "$proto" "$port")" || continue
    target_seen["$target"]=$(( ${target_seen["$target"]:-0} + 1 ))
  done

  for line in "${inv_lines[@]}"; do
    IFS=$'\x01' read -r idx oldtag proto port <<< "$line"
    target="$(entry_key_from_parts "$proto" "$port")" || continue

    if [ "${target_seen[$target]:-0}" -gt 1 ]; then
      issue_lines+=("主入站目标名冲突：${proto}:${port} -> ${target}（已跳过）")
      skipped=$((skipped+1))
      continue
    fi

    current_count="$(echo "$work_json" | jq -r --arg t "$target" --argjson idx "$idx" '[.inbounds | to_entries[] | select((.value.tag // "") == $t and .key != $idx)] | length')"
    if [ "$current_count" -gt 0 ]; then
      issue_lines+=("主入站目标 tag 已被其它对象占用：${target}（已跳过）")
      skipped=$((skipped+1))
      continue
    fi

    if [ "$oldtag" != "$target" ]; then
      work_json="$(echo "$work_json" | jq --argjson idx "$idx" --arg t "$target" '.inbounds[$idx].tag = $t')" || {
        err "规范化主入站 tag 失败：$proto:$port"
        pause
        return 1
      }
      action_lines+=("主入站：${oldtag:-<空>} -> ${target}")
      tag_updates=$((tag_updates+1))
    fi

    local -a user_lines=() relay_names=() direct_candidates=()
    local user_line uidx uname relay_user out_tag land new_user new_out direct_old

    mapfile -t user_lines < <(echo "$work_json" | jq -r --argjson idx "$idx" '.inbounds[$idx].users // [] | to_entries[] | [.key, (.value.name // .value.username // "")] | join("\u0001")')
    mapfile -t relay_names < <(relay_list_table "$work_json" | awk -F '\x01' -v ek="$target" '$1 == ek {print $2}')

    for user_line in "${user_lines[@]}"; do
      IFS=$'\x01' read -r uidx uname <<< "$user_line"
      local is_relay=0 rn
      for rn in "${relay_names[@]}"; do
        if [ "$uname" = "$rn" ] && [ -n "$uname" ]; then
          is_relay=1
          break
        fi
      done
      if [ "$proto" != "socks" ] && [ $is_relay -eq 0 ] && [[ "$uname" != *"@"* ]]; then
        direct_candidates+=("$uidx:$uname")
      fi
    done

    if [ ${#direct_candidates[@]} -eq 1 ]; then
      direct_old="${direct_candidates[0]#*:}"
      uidx="${direct_candidates[0]%%:*}"
      if [ "$direct_old" != "$target" ]; then
        work_json="$(echo "$work_json" | jq --argjson idx "$idx" --argjson uidx "$uidx" --arg old "$direct_old" --arg new "$target" '
          if (.inbounds[$idx].users[$uidx].name? // "") == $old then
            .inbounds[$idx].users[$uidx].name = $new
          elif (.inbounds[$idx].users[$uidx].username? // "") == $old then
            .inbounds[$idx].users[$uidx].username = $new
          else . end
          | .route.rules |= map(
              if (.auth_user? != null) then
                .auth_user |= (
                  if type == "array" then map(if . == $old then $new else . end)
                  elif . == $old then $new
                  else . end
                )
              else . end
            )
        ')" || {
          err "规范化直连用户失败：$target"
          pause
          return 1
        }
        action_lines+=("直连用户：${direct_old:-<空>} -> ${target}")
        direct_updates=$((direct_updates+1))
      fi
    elif [ ${#direct_candidates[@]} -gt 1 ]; then
      issue_lines+=("主入站存在多个直连候选用户，未自动规范化：${target}")
      skipped=$((skipped+1))
    fi

    while IFS=$'\x01' read -r _ relay_user out_tag; do
      [ -z "${relay_user:-}" ] && continue
      [[ "$relay_user" == *"@"* ]] && continue
      land=""
      if [[ "$out_tag" =~ ^out-.*-to-(.+)$ ]]; then
        land="${BASH_REMATCH[1]}"
      elif [[ "$out_tag" =~ ^out-to-(.+)$ ]]; then
        land="${BASH_REMATCH[1]}"
      elif [[ "$out_tag" =~ ^to-(.+)$ ]]; then
        land="${BASH_REMATCH[1]}"
      elif [[ "$relay_user" =~ -to-(.+)$ ]]; then
        land="${BASH_REMATCH[1]}"
      fi

      if [ -z "$land" ] || [ -z "$out_tag" ]; then
        issue_lines+=("中转关系不完整，未自动接管：${relay_user:-<空>} -> ${out_tag:-<空>}")
        skipped=$((skipped+1))
        continue
      fi

      new_user="$(relay_user_name "$target" "$land")"
      new_out="$(relay_outbound_tag "$target" "$land")"

      if [ "$relay_user" != "$new_user" ]; then
        work_json="$(echo "$work_json" | jq --argjson idx "$idx" --arg old "$relay_user" --arg new "$new_user" '
          (.inbounds[$idx].users // []) |= map(
            if (.name // "") == $old then .name = $new
            elif (.username // "") == $old then .username = $new
            else . end
          )
          | .route.rules |= map(
              if (.auth_user? != null) then
                .auth_user |= (
                  if type == "array" then map(if . == $old then $new else . end)
                  elif . == $old then $new
                  else . end
                )
              else . end
            )
        ')" || {
          err "规范化中转用户失败：$relay_user"
          pause
          return 1
        }
        action_lines+=("中转用户：${relay_user} -> ${new_user}")
        relay_user_updates=$((relay_user_updates+1))
      fi

      if [ "$out_tag" != "$new_out" ]; then
        if echo "$work_json" | jq -e --arg o "$new_out" --arg old "$out_tag" '.outbounds[]? | select((.tag // "") == $new_out and (.tag // "") != $old)' >/dev/null 2>&1; then
          issue_lines+=("目标 outbound tag 已存在，未自动规范化：${out_tag} -> ${new_out}")
          skipped=$((skipped+1))
        else
          work_json="$(echo "$work_json" | jq --arg old "$out_tag" --arg new "$new_out" '
            .outbounds |= map(if (.tag // "") == $old then .tag = $new else . end)
            | .route.rules |= map(if (.outbound // "") == $old then .outbound = $new else . end)
          ')" || {
            err "规范化中转 outbound 失败：$out_tag"
            pause
            return 1
          }
          action_lines+=("中转 outbound：${out_tag} -> ${new_out}")
          relay_out_updates=$((relay_out_updates+1))
        fi
      fi
    done < <(relay_list_table "$work_json" | awk -F '\x01' -v ek="$target" '$1 == ek {print $1"\001"$2"\001"$3}')
  done

  echo -e "${B}--------------------------------------------------------${NC}"
  echo -e "${C}预览结果${NC}"
  echo -e "  主入站规范化：${tag_updates}"
  echo -e "  直连用户规范化：${direct_updates}"
  echo -e "  中转用户规范化：${relay_user_updates}"
  echo -e "  中转 outbound 规范化：${relay_out_updates}"
  if [ ${#action_lines[@]} -gt 0 ]; then
    echo -e "${B}--------------------------------------------------------${NC}"
    echo -e "${C}计划执行${NC}"
    local a
    for a in "${action_lines[@]}"; do
      echo -e "  - ${a}"
    done
  fi
  if [ ${#issue_lines[@]} -gt 0 ]; then
    echo -e "${B}--------------------------------------------------------${NC}"
    echo -e "${Y}发现但未自动处理${NC}"
    local it
    for it in "${issue_lines[@]}"; do
      echo -e "  - ${it}"
    done
  fi

  if [ $tag_updates -eq 0 ] && [ $direct_updates -eq 0 ] && [ $relay_user_updates -eq 0 ] && [ $relay_out_updates -eq 0 ]; then
    warn "没有可自动规范化的对象。"
    pause
    return 0
  fi

  echo ""
  ask_confirm_yes "输入 YES 确认执行规范化接管，其它任意输入取消: " || { warn "已取消规范化接管。"; pause; return 0; }

  work_json="$(route_rebuild "$work_json")" || {
    err "规范化接管后重建路由失败，已取消写入。"
    pause
    return 1
  }

  if config_apply "$work_json"; then
    ok "规范化接管完成。"
  else
    err "规范化接管应用失败。"
    pause
    return 1
  fi

  pause
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
  local i=1 proto
  echo -e "\n${C}可安装协议（多个用 + 连接，如 1+3+5）:${NC}"
  for proto in "${SUPPORTED_PROTOCOLS[@]}"; do
    echo -e "  [$i] $proto"
    i=$((i+1))
  done
  read -r -p "请输入要安装的协议编号（回车返回）: " sel
  mapfile -t choice_arr < <(parse_plus_selections "${sel:-}")
  [ ${#choice_arr[@]} -eq 0 ] && { warn "未选择任何协议，已返回上一级。"; pause; return 0; }

  local c port listen sni path priv sid entry_key inbound pub generated_pair uuid pass method server_pass user_pass username
  local obfs_type obfs_pass obfs_choice hop_answer hop_range hop_enabled hop_start hop_end
  for c in "${choice_arr[@]}"; do
    if ! [[ "$c" =~ ^[0-9]+$ ]] || [ "$c" -lt 1 ] || [ "$c" -gt "${#SUPPORTED_PROTOCOLS[@]}" ]; then
      warn "无效协议编号：$c，已返回上一级。"
      pause
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
        active) _status="${G}运行中${NC}" ;;
        failed) _status="${Y}异常${NC}" ;;
        activating) _status="${Y}启动中${NC}" ;;
        *) _status="${R}已停止${NC}" ;;
      esac
      ;;
    openrc)
      _state="$(rc-service sing-box status 2>&1 || true)"
      case "$_state" in
        *crashed*) _status="${Y}异常${NC}" ;;
        *started*|*running*) _status="${G}运行中${NC}" ;;
        *stopped*) _status="${R}已停止${NC}" ;;
        *)
          if singbox_service_active; then
            _status="${G}运行中${NC}"
          else
            _status="${R}已停止${NC}"
          fi
          ;;
      esac
      ;;
    *)
      if singbox_service_active; then
        _status="${G}运行中${NC}"
      else
        _status="${R}已停止${NC}"
      fi
      ;;
  esac
  _version=""
  if [ -x "$SINGBOX_BIN" ]; then
    _version="$("$SINGBOX_BIN" version 2>/dev/null | awk '/^sing-box version / {print $3; exit}')"
  fi
  [ -n "$_version" ] || _version="未知"

  _suffix=""
  _upstream="$(get_cached_upstream_version 2>/dev/null || true)"
  if [ "$_version" != "未知" ] && [ -n "$_upstream" ]; then
    if [ "$_version" != "$_upstream" ] && version_ge "$_upstream" "$_version"; then
      _suffix="  ${Y}(有新版 ${_upstream})${NC}"
    fi
  elif [ "$_version" != "未知" ] && [ -z "$_upstream" ]; then
    _suffix="  ${Y}(新版检测: 未知)${NC}"
  fi

  printf '  %bsing-box%b : %b  版本 %b%s%b%b\n' "$W" "$NC" "$_status" "$G" "$_version" "$NC" "$_suffix"
}

singbox_start() {
  clear
  print_rect_title "启动 sing-box"
  case "$INIT_SYSTEM" in
    systemd)
      if systemctl start sing-box; then
        sleep 1
        if systemctl is-active --quiet sing-box 2>/dev/null; then
          ok "sing-box 已启动并正常运行。"
        else
          err "启动命令已执行，但服务未能正常运行，请检查配置或日志。"
        fi
      else
        err "启动失败，请检查配置或日志。"
      fi
      ;;
    openrc)
      if openrc_start_service sing-box >/dev/null 2>&1; then
        sleep 1
        if openrc_service_running sing-box; then
          ok "sing-box 已启动并正常运行。"
        else
          err "启动命令已执行，但服务未能正常运行，请检查配置或日志。"
        fi
      else
        err "启动失败，请检查配置或日志。"
      fi
      ;;
    *) err "未识别的 init 系统，无法启动 sing-box。" ;;
  esac
  echo ""
  pause
}

singbox_stop() {
  clear
  print_rect_title "停止 sing-box"
  case "$INIT_SYSTEM" in
    systemd)
      systemctl stop sing-box && ok "sing-box 已停止。" || err "停止失败。"
      ;;
    openrc)
      openrc_stop_service sing-box >/dev/null 2>&1 && ok "sing-box 已停止。" || err "停止失败。"
      ;;
    *) err "未识别的 init 系统，无法停止 sing-box。" ;;
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
    echo -e "${B}----------------------------------------${NC}"
    echo -e "  ${C}1.${NC} 启动 sing-box"
    echo -e "  ${C}2.${NC} 停止 sing-box"
    echo -e "  ${C}3.${NC} 查看 sing-box 实时日志"
    echo -e "  ${C}4.${NC} 查看 config 配置文件"
    echo -e "  ${C}5.${NC} 清空/重置 config 配置文件"
    echo -e "  ${C}6.${NC} 一键校准系统时间"
    echo -e "  ${C}7.${NC} 规范化接管旧配置"
    echo -e "  ${R}0.${NC} 返回主菜单"
    read -r -p "请选择操作: " act
    case "${act:-}" in
      1) singbox_start ;;
      2) singbox_stop ;;
      3) view_realtime_log ;;
      4) view_config_formatted ;;
      5) clear_config_json ;;
      6) sync_system_time_chrony ;;
      7) normalize_takeover ;;
      0|q|Q|"") return 0 ;;
      *) warn "无效输入：$act"; sleep 1 ;;
    esac
  done
}
