#!/usr/bin/env bash
# SOCKS5 link import and authenticated relay probes.

# Decode only URI userinfo. Never interpret pasted text as shell syntax.
relay_decode_userinfo() {
  local LC_ALL=C escaped="$1" decoded='' byte fragment
  [[ "$escaped" =~ ^([A-Za-z0-9._~-]|%[[:xdigit:]]{2})+$ ]] || return 1
  while [ -n "$escaped" ]; do
    if [ "${escaped:0:1}" = % ]; then
      fragment="${escaped:1:2}"
      [[ "${fragment,,}" != 00 ]] || return 1
      printf -v byte '%b' "\\x$fragment"
      escaped="${escaped:3}"
    else
      byte="${escaped:0:1}"
      escaped="${escaped:1}"
    fi
    [[ "$byte" != [[:cntrl:]] ]] || return 1
    decoded+="$byte"
  done
  [ "${#decoded}" -le 255 ] || return 1
  printf '%s' "$decoded"
}

relay_landing_host_valid() {
  local host="$1"
  if [[ "$host" == *:* ]]; then
    [[ "$host" =~ ^[[:xdigit:].:]+$ && "$host" != *:::* ]]
  else
    [[ "${#host}" -le 253 &&
      "$host" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*\.?$ ]]
  fi
}

relay_select_saved_landing() {
  local json="$1" outvar="$2" selected_id selected_index i result
  local -a ids=()
  mapfile -t ids < <(
    {
      relay_meta_landings_json | jq -r 'keys[]'
      relay_list_table "$json" | awk -F '\x01' '{n=$2; sub(/@.*/, "", n); sub(/^.*-to-/, "", n); if (n!="") print n}'
    } | sort -u
  )
  if [ "${#ids[@]}" -eq 0 ]; then warn "还没有保存的落地机。"; return 1; fi
  for i in "${!ids[@]}"; do printf '  %s. %s\n' "$((i+1))" "${ids[i]}"; done
  read -r -p "选落地机（回车返回）: " selected_index || return 1
  [[ "$selected_index" =~ ^[1-9][0-9]*$ ]] && [ "$selected_index" -le "${#ids[@]}" ] || return 1
  selected_id="${ids[selected_index-1]}"
  result="$(relay_known_landing_json "$json" "$selected_id")" || return 1
  [ "$result" != null ] || return 1
  printf -v "$outvar" '%s' "$result"
}

relay_commit_landing() {
  local config="$1" previous="$2" candidate="$3" normalized next
  normalized="$(relay_meta_json_from_meta "$previous")" || return 1
  normalized="$(relay_meta_upsert_landing_to_json "$normalized" "$candidate")" || return 1
  next="$(relay_meta_replace_in_meta_json "$previous" "$normalized")" || return 1
  relay_commit_projection "$config" "$previous" "$config" "$next"
}

relay_update_landing_menu() {
  local config previous old candidate id
  config="$(user_manager_config_for_edit)" || return 1
  previous="$(meta_load)" || return 1
  relay_select_saved_landing "$config" old || { pause; return 0; }
  candidate="$(relay_prompt_connection)" || { pause; return 0; }
  if relay_landing_matches "$old" "$candidate"; then
    ok "落地连接资料相同。"
    pause
    return 0
  fi
  relay_check_new_endpoint "$candidate" || { pause; return 0; }
  id="$(jq -r '.id' <<< "$old")"
  relay_affected_lines "$config" "$id"
  ask_confirm_yes "确认更换这些线路的落地？输入 yes 确认: " || return 0
  candidate="$(jq --arg id "$id" '.id=$id' <<< "$candidate")" || return 1
  relay_commit_landing "$config" "$previous" "$candidate" || return 1
  ok "落地已更新，客户端继续使用原链接。新落地默认使用原生 UDP。"
  pause
}

relay_diagnose_endpoint() {
  local landing="$1" attempt
  ui_echo "正在检查落地 TCP（最多 4 秒）。"
  if ! relay_probe_dns "$landing" tcp false; then printf '%s\n' tcp_failed; return; fi
  for attempt in 1 2; do
    ui_echo "正在验证原生 UDP 回包（第 ${attempt}/2 次）。"
    if relay_probe_dns "$landing" udp false; then printf '%s\n' native; return; fi
  done
  ui_echo "正在用临时配置验证 UDP over TCP（最多 4 秒）。"
  if relay_probe_dns "$landing" udp true; then printf '%s\n' uot; else printf '%s\n' unavailable; fi
}

relay_diagnostics_menu() {
  local config previous landing id enabled answer state candidate
  config="$(user_manager_config_for_edit)" || return 1
  previous="$(meta_load)" || return 1
  relay_select_saved_landing "$config" landing || { pause; return 0; }
  id="$(jq -r '.id' <<< "$landing")"
  enabled="$(jq -r '.udp_over_tcp == true' <<< "$landing")"
  if [ "$enabled" = true ]; then
    read -r -p "当前使用 UDP over TCP。r 恢复原生，回车诊断，q 返回: " answer || return 0
    case "$answer" in
      r|R)
        relay_affected_lines "$config" "$id"
        ask_confirm_yes "恢复这台落地的原生 UDP？输入 yes 确认: " || return 0
        candidate="$(jq 'del(.udp_over_tcp)' <<< "$landing")" || return 1
        relay_commit_landing "$config" "$previous" "$candidate" || return 1
        ok "已恢复原生 UDP。"; pause; return 0 ;;
      '') ;;
      *) return 0 ;;
    esac
  fi
  state="$(relay_diagnose_endpoint "$landing")" || return 1
  case "$state" in
    tcp_failed) warn "落地 TCP 转发未通过，先核对连接资料。" ;;
    native) ok "原生 UDP 已收到回包。继续使用当前设置。" ;;
    unavailable) warn "TCP 通过，两种 UDP 方式都未收到有效回包。当前设置保持。" ;;
    uot)
      ok "TCP 通过，只有 UDP over TCP 收到有效回包。"
      if [ "$enabled" = false ]; then
        relay_affected_lines "$config" "$id"
        if ask_confirm_yes "仅为这台落地启用 UDP over TCP？输入 yes 确认: "; then
          candidate="$(jq '.udp_over_tcp=true' <<< "$landing")" || return 1
          relay_commit_landing "$config" "$previous" "$candidate" || return 1
          ok "已为所选落地启用 UDP over TCP。"
        fi
      fi
      ;;
  esac
  pause
}

relay_parse_landing_link() {
  local link="$1" rest host port encoded_user encoded_pass username password
  [[ "$link" == socks5://* ]] || return 1
  rest="${link#socks5://}"
  if ! [[ "$rest" =~ ^([^:@]+):([^@]+)@(\[([[:xdigit:].:]+)\]|([a-zA-Z0-9.-]+)):([0-9]+)$ ]]; then
    return 1
  fi
  encoded_user="${BASH_REMATCH[1]}" encoded_pass="${BASH_REMATCH[2]}"
  host="${BASH_REMATCH[4]:-${BASH_REMATCH[5]}}" port="${BASH_REMATCH[6]}"
  [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] && is_valid_port "$port" && relay_landing_host_valid "$host" || return 1
  username="$(relay_decode_userinfo "$encoded_user")" || return 1
  password="$(relay_decode_userinfo "$encoded_pass")" || return 1
  relay_landing_to_meta_json '' "$host" "$port" "$username" "$password"
}

relay_prompt_connection() {
  local connection_answer endpoint
  read -rs -p "粘贴 SOCKS5 落地链接（m 手动填写，回车返回）: " connection_answer || return 1
  printf '\n' >&2
  case "$connection_answer" in
    '') return 1 ;;
    m|M)
      local endpoint_host endpoint_port endpoint_user endpoint_password
      relay_prompt_landing_details '' endpoint_host endpoint_port endpoint_user endpoint_password || return 1
      endpoint_host="${endpoint_host#[}"; endpoint_host="${endpoint_host%]}"
      relay_landing_host_valid "$endpoint_host" || { warn "落地地址无效。"; return 1; }
      endpoint="$(relay_landing_to_meta_json '' "$endpoint_host" "$endpoint_port" "$endpoint_user" "$endpoint_password")" || return 1
      ;;
    *)
      endpoint="$(relay_parse_landing_link "$connection_answer")" || { warn "落地链接格式无效。请复制完整的 socks5:// 链接。"; return 1; }
      ;;
  esac
  printf '%s\n' "$endpoint"
}

relay_landing_matches() {
  jq -en --argjson old "$1" --argjson next "$2" '
    def endpoint: [.server, (.port | tonumber), (.username // ""), (.password // "")];
    $old != null and ($old | endpoint) == ($next | endpoint)
  ' >/dev/null
}

relay_affected_lines() {
  local json="$1" land="$2"
  printf '%s\n' '受影响的线路：'
  relay_list_table "$json" | awk -F '\x01' -v land="$land" '
    {name=$2; sub(/@.*/, "",name); end="-to-" land
     if (length(name)>length(end) && substr(name,length(name)-length(end)+1)==end && !seen[name]++) print "  全量 · " name}'
  relay_meta_json | jq -r --arg land "$land" '.rules[]? | select(.landing_id == $land) | "  网站 · " + .name'
}

relay_probe_target() { printf '%s\n' '1.1.1.1:53'; }

relay_probe_config() {
  local landing="$1" use_uot="$2"
  jq -c --argjson uot "$use_uot" '
    {log:{disabled:true},outbounds:[({type:"socks",tag:"probe",version:"5",
       server:.server,server_port:(.port | tonumber)}
       + (if (.username // "") != "" then {username:.username,password:(.password // "")} else {} end)
       + (if $uot then {udp_over_tcp:true} else {} end))]}
  ' <<< "$landing"
}

relay_probe_dns() (
  local landing="$1" network="$2" use_uot="$3" temp offset=0 wire_id prefix='' header
  umask 077
  temp="$(mktemp -d)" || return 1
  trap 'rm -rf "$temp"' EXIT
  relay_probe_config "$landing" "$use_uot" > "$temp/probe.json" || return 1
  wire_id="$(openssl rand -hex 2)" || return 1
  if [ "$network" = tcp ]; then prefix='\000\035'; fi
  {
    printf '%b' "$prefix\\x${wire_id:0:2}\\x${wire_id:2:2}\001\000\000\001\000\000\000\000\000\000\007example\003com\000\000\001\000\001"
    sleep 1
  } | run_with_timeout 4 sing-box -c "$temp/probe.json" tools connect -o probe -n "$network" \
    "$(relay_probe_target)" > "$temp/reply" 2>/dev/null || true
  [ "$network" != tcp ] || offset=2
  [ "$(wc -c < "$temp/reply")" -ge "$((offset + 29))" ] || return 1
  header="$(od -An -v -tx1 -j "$offset" -N 29 "$temp/reply" | tr -d '[:space:]')"
  [[ "$header" == "$wire_id"[89abcdef]* &&
     "${header:8:4}" = 0001 &&
     "${header:24}" = 076578616d706c6503636f6d0000010001 ]]
)

relay_check_new_endpoint() {
  local landing="$1"
  ui_echo "正在验证落地 SOCKS5 的 TCP 转发和认证。"
  if ! run_with_spinner "正在验证落地连接" relay_probe_dns "$landing" tcp false; then
    warn "落地 TCP 验证失败。请检查地址、端口、认证和落地机的外网访问。"
    return 1
  fi
}
