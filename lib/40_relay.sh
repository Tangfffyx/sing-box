#!/usr/bin/env bash
# ============================================================
# 模块: 40_relay.sh
# 职责: 中转节点列表、全量中转、部分流量中转、删除、菜单
# 依赖: 00_base.sh, 10_config.sh, 20_protocol.sh, 30_route.sh
# ============================================================

RELAY_RULE_BASE_URL="https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set"
RELAY_RULE_LOOKUP_URL="https://github.com/SagerNet/sing-geosite/tree/rule-set"

relay_hr() {
  ui_hr
}

relay_partial_outbound_tag() {
  local land="$1"
  echo "relay-${land}"
}

# ---------- 中转节点列表（纯数据查询） ----------

relay_list_table() {
  local json="$1"
  echo "$json" | jq -r "${JQ_SHARED}"'
    . as $root
    | [
        .inbounds[]?
        | select((detect_protocol) != "")
        | .tag as $entry
        | (.users // [])[]?
        | (.name // .username // empty) as $name
        | (node_part($name)) as $node
        | select($name != "" and $node != $entry and ($node | contains("-to-")))
        | [
            $root.route.rules[]?
            | select((auth_users_array | index($name)) != null)
            | .outbound // empty
            | select(. != "" and . != "direct")
          ] as $outs
        | [
            (["out-" + $node] + (if ($node | contains("-to-")) then ["out-to-" + (($node | capture(".*-to-(?<land>.+)$").land)), "to-" + (($node | capture(".*-to-(?<land>.+)$").land))] else [] end))[] as $cand
            | $root.outbounds[]?
            | .tag // empty
            | select(. == $cand)
          ] as $fallback_outs
        | [$entry, $name, (if ($outs | length) > 0 then $outs[0] elif ($fallback_outs | length) > 0 then $fallback_outs[0] else "" end)]
      ]
    | unique
    | .[]
    | join("\u0001")
  ' || return 1
}

# ---------- UI: 显示全量中转节点 ----------

show_managed_relay_lines() {
  local json="$1"
  local found=0
  local seen=""
  local relay_node
  while IFS=$'\x01' read -r entry relay_user out_tag; do
    [ -z "${relay_user:-}" ] && continue
    relay_node="$(user_node_part "$relay_user")"
    [ -n "$relay_node" ] || continue
    if printf '%s\n' "$seen" | grep -Fxq "$relay_node"; then
      continue
    fi
    seen="${seen}${relay_node}"$'\n'
    found=1
    echo -e "  - ${G}${relay_node}${NC}"
  done < <(relay_list_table "$json")
  [ $found -eq 1 ]
}

relay_full_summary_lines() {
  local json="$1" summary
  summary="$(
    relay_list_table "$json" | awk -F '\x01' '
      function node_part(s) { sub(/@.*/, "", s); return s }
      function land_part(s) { sub(/^.*-to-/, "", s); return s }
      NF >= 2 {
        node = node_part($2)
        if (node !~ /-to-/) next
        entry = node
        sub(/-to-.*/, "", entry)
        land = land_part(node)
        key = entry SUBSEP land
        if (!(key in seen)) {
          seen[key] = 1
          if (!(entry in entry_seen)) {
            entry_seen[entry] = 1
            entries[++entry_count] = entry
          }
          lands[entry] = lands[entry] (lands[entry] == "" ? "" : "、") land
        }
      }
      END {
        if (entry_count == 0) {
          print "全部流量转发：未启用"
        } else {
          print "全部流量转发："
          for (i = 1; i <= entry_count; i++) {
            entry = entries[i]
            printf "  - %-18s → 落地机：%s\n", entry, lands[entry]
          }
        }
      }
    '
  )"
  printf '%s\n' "$summary"
}

# ---------- SOCKS 落地 ----------

relay_prompt_landing_id() {
  local land_var="$1" _land
  read -r -p "落地标识（回车返回，如 sg01）: " _land
  [ -z "${_land:-}" ] && { warn "已取消，返回上一级。"; return 1; }
  if ! [[ "$_land" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    warn "落地标识仅允许字母、数字、点、下划线、短横线。"
    return 1
  fi
  printf -v "$land_var" '%s' "$_land"
}

relay_prompt_landing_details() {
  local ip_var="$2" port_var="$3" username_var="$4" password_var="$5"
  local _ip _relay_port _username _password

  read -r -p "落地地址（域名或 IP，回车返回）: " _ip
  [ -z "${_ip:-}" ] && { warn "已取消，返回上一级。"; return 1; }

  read -r -p "落地 SOCKS 端口（默认: 1080）: " _relay_port
  _relay_port="${_relay_port:-1080}"
  if ! is_valid_port "$_relay_port"; then
    warn "落地 SOCKS 端口无效，已返回上一级。"
    return 1
  fi

  read -r -p "落地 SOCKS Username（无认证可留空）: " _username
  if [ -n "${_username:-}" ]; then
    read -rs -p "落地 SOCKS 密码: " _password || return 1
    printf '\n' >&2
  else
    _password=""
  fi

  printf -v "$ip_var" '%s' "$_ip"
  printf -v "$port_var" '%s' "$_relay_port"
  printf -v "$username_var" '%s' "${_username:-}"
  printf -v "$password_var" '%s' "${_password:-}"
  return 0
}

relay_landing_to_meta_json() {
  local land="$1" ip="$2" port="$3" username="${4:-}" password="${5:-}"
  jq -n --arg id "$land" --arg server "$ip" --arg username "$username" --arg password "$password" --argjson port "$port" '
    {id:$id, server:$server, port:$port, username:$username, password:$password}
  '
}

relay_landing_from_outbound_json() {
  local json="$1" land="$2" tag="$3"
  echo "$json" | jq -c --arg id "$land" --arg tag "$tag" '
    .outbounds[]?
    | select((.tag // "") == $tag and (.type // "") == "socks")
    | {
        id:$id,
        server:(.server // ""),
        port:(.server_port // 0),
        username:(.username // ""),
        password:(.password // ""),
        udp_over_tcp:((.udp_over_tcp // false) | if type == "object" then .enabled == true else . == true end)
      }
  ' | head -n1
}

relay_known_landing_json() {
  local json="$1" land="$2" existing=""
  existing="$(relay_meta_json | jq -c --arg id "$land" '.landings[$id] | select(. != null) | . + {id:$id}' 2>/dev/null || true)"
  if [ -n "$existing" ]; then
    echo "$existing"
    return 0
  fi
  existing="$(relay_landing_from_outbound_json "$json" "$land" "$(relay_outbound_tag "" "$land")" 2>/dev/null || true)"
  if [ -z "$existing" ]; then
    local legacy_tag
    legacy_tag="$(relay_list_table "$json" | awk -F '\x01' -v land="$land" '
      {n=$2; sub(/@.*/, "", n); tail="-to-" land
       if (substr(n,length(n)-length(tail)+1)==tail && $3!="") {print $3; exit}}')"
    if [ -n "$legacy_tag" ]; then
      existing="$(relay_landing_from_outbound_json "$json" "$land" "$legacy_tag")"
    fi
  fi
  if [ -n "$existing" ]; then
    echo "$existing"
    return 0
  fi
  existing="$(relay_landing_from_outbound_json "$json" "$land" "$(relay_partial_outbound_tag "$land")" 2>/dev/null || true)"
  if [ -n "$existing" ]; then
    echo "$existing"
    return 0
  fi
  echo "null"
}

relay_landing_display() {
  local landing_json="$1"
  echo "$landing_json" | jq -r '
    "\(.id // "default")（\(.server // ""):\(.port // 0)" +
    (if (.username // "") != "" then "，认证：" + (.username // "") else "，无认证" end) +
    "）"
  '
}

relay_choose_landing_or_return() {
  local json="$1" outvar="$2" selected reply candidate old id i
  local -a available=()
  mapfile -t available < <(relay_meta_landings_json | jq -r 'keys[]')
  for i in "${!available[@]}"; do
    printf '  %s. %s\n' "$((i+1))" "${available[i]}"
  done
  if [ "${#available[@]}" -gt 0 ]; then
    read -r -p "选已有落地编号，回车粘贴新链接，q 返回: " reply || return 1
    if [[ "$reply" =~ ^[1-9][0-9]*$ ]] && [ "$reply" -le "${#available[@]}" ]; then
      selected="$(relay_known_landing_json "$json" "${available[reply-1]}")" || return 1
      printf -v "$outvar" '%s' "$selected"
      return 0
    fi
    [ -z "$reply" ] || return 1
  fi

  candidate="$(relay_prompt_connection)" || return 1
  relay_prompt_landing_id id || return 1
  old="$(relay_known_landing_json "$json" "$id")"
  candidate="$(jq --arg id "$id" '.id=$id' <<< "$candidate")" || return 1
  if relay_landing_matches "$old" "$candidate"; then
    printf -v "$outvar" '%s' "$old"
    return 0
  fi
  relay_check_new_endpoint "$candidate" || return 1
  if [ "$old" != null ]; then
    relay_affected_lines "$json" "$id"
    ask_confirm_yes "更新这个标识的落地？输入 yes 确认: " || return 1
  fi
  printf -v "$outvar" '%s' "$candidate"
}

# Adding an existing entry/landing pair leaves all original authentications intact.
relay_add_full_config() {
  local base="$1" entry="$2" landing="$3" id user tag inbound auth outbound
  id="$(jq -r '.id' <<< "$landing")" || return 1
  user="$(relay_user_name "$entry" "$id")"; tag="$(relay_outbound_tag "$entry" "$id")"
  inbound="$(find_inbound_by_entry_key "$base" "$entry")" || return 1
  [ -n "$inbound" ] || return 1
  auth="$(find_user_obj_in_inbound "$inbound" "$user")"
  if [ -n "$auth" ]; then
    printf '%s\n' "$base"
    return
  fi
  auth="$(build_user_object_from_inbound "$inbound" "$user")" || return 1
  outbound="$(relay_probe_config "$landing" false | jq -c --arg tag "$tag" '.outbounds[0] | .tag=$tag')" || return 1
  jq --arg entry "$entry" --arg user "$user" --arg tag "$tag" --argjson auth "$auth" --argjson outbound "$outbound" '
    (.inbounds[] | select(.tag == $entry)).users |= ((. // []) + [$auth])
    | .outbounds = ((.outbounds // []) | map(select(.tag != $tag)) + [$outbound])
    | .route.rules += [{auth_user:[$user],outbound:$tag}]
  ' <<< "$base"
}

relay_commit_projection() {
  local previous_config="$1" previous_meta="$2" next_config="$3" next_meta="$4" projected
  if [ "$(jq -Sc . <<< "$previous_meta")" = "$(jq -Sc . <<< "$next_meta")" ] &&
    [ "$(jq -Sc . <<< "$previous_config")" = "$(jq -Sc . <<< "$next_config")" ]; then return 0; fi
  projected="$(relay_project_partial_state_with_meta "$next_config" "$next_meta")" || return 1
  with_manager_lock protocol_commit_changes "$previous_config" "$previous_meta" "$projected" "$next_meta"
}

relay_add() {
  init_manager_env || { pause; return 0; }
  local json lines=() entry choice i tag proto port landing previous meta next relay_json
  json="$(user_manager_config_for_edit)" || return 1
  previous="$(meta_load)" || return 1
  mapfile -t lines < <(protocol_entry_inventory "$json" | sort_tsv_by_protocol 1 | head -100)
  if [ "${#lines[@]}" -eq 0 ]; then warn "请先安装一个本机入站节点。"; pause; return 0; fi
  if [ "${#lines[@]}" -eq 1 ]; then
    choice=1
  else
    for i in "${!lines[@]}"; do
      IFS=$'\x01' read -r tag proto port <<< "${lines[i]}"
      printf '  %s. %s\n' "$((i+1))" "$tag"
    done
    read -r -p "选择客户端连接的本机节点（回车返回）: " choice || return 0
    [[ "$choice" =~ ^[1-9][0-9]*$ ]] && [ "$choice" -le "${#lines[@]}" ] || return 0
  fi
  IFS=$'\x01' read -r entry _ _ <<< "${lines[choice-1]}"
  relay_choose_landing_or_return "$json" landing || return 0
  next="$(relay_add_full_config "$json" "$entry" "$landing")" || return 1
  relay_json="$(relay_meta_json_from_meta "$previous")" || return 1
  relay_json="$(relay_meta_upsert_landing_to_json "$relay_json" "$landing")" || return 1
  meta="$(relay_meta_replace_in_meta_json "$previous" "$relay_json")" || return 1
  relay_commit_projection "$json" "$previous" "$next" "$meta" || return 1
  ok "中转已保存。已有客户端连接凭据已保留。"
  pause
}

# ---------- 部分流量中转元数据 ----------

relay_meta_json_from_meta() {
  local meta_json="$1"
  echo "$meta_json" | jq -c '
    (.relay // {}) as $relay
    | ($relay.landing // null) as $legacy_landing
    | (
        if (($relay.landings // null) | type) == "object" then
          ($relay.landings // {})
        elif (($legacy_landing // null) | type) == "object" then
          {($legacy_landing.id // "default"): $legacy_landing}
        else
          {}
        end
      ) as $landings
    | ($legacy_landing.id // "default") as $legacy_id
    | {
        landings: $landings,
        rules: [
          ($relay.rules // [])[]?
          | (.landing_id = (.landing_id // $legacy_id))
          | select((.tag // "") != "" and (.file // "") != "" and (.landing_id // "") != "")
        ]
      }
  '
}

relay_meta_json() {
  relay_meta_json_from_meta "$(meta_load)"
}

relay_meta_rules_json() {
  relay_meta_json | jq -c '[.rules[]? | select((.tag // "") != "" and (.file // "") != "" and (.landing_id // "") != "")] | unique_by(.tag)'
}

relay_meta_landings_json() {
  relay_meta_json | jq -c '.landings // {}'
}

relay_meta_save_obj() {
  local relay_json="$1" meta_json
  meta_json="$(meta_load)"
  meta_json="$(echo "$meta_json" | jq --argjson r "$relay_json" '.relay = $r')" || return 1
  meta_save "$meta_json"
}

relay_meta_save_rules_obj() {
  local relay_json="$1"
  relay_json="$(echo "$relay_json" | jq '
    .landings = (.landings // {})
    | .rules = (.rules // [])
  ')" || return 1
  relay_meta_save_obj "$relay_json"
}

relay_meta_normalize_obj() {
  local relay_json="$1"
  echo "$relay_json" | jq -c '
    .landings = (.landings // {})
    | .rules = (.rules // [])
  '
}

relay_meta_replace_in_meta_json() {
  local meta_json="$1" relay_json="$2" normalized
  normalized="$(relay_meta_normalize_obj "$relay_json")" || return 1
  echo "$meta_json" | jq --argjson r "$normalized" '.relay = $r'
}

relay_meta_upsert_landing() {
  local landing_json="$1" relay_json
  relay_json="$(relay_meta_json | jq --argjson landing "$landing_json" '
    .landings = (.landings // {})
    | .landings[$landing.id] = $landing
  ')" || return 1
  relay_meta_save_rules_obj "$relay_json"
}

relay_rule_tag_for_file() {
  local file="$1" base tag
  base="${file%.srs}"
  tag="${base//[^A-Za-z0-9_-]/-}"
  echo "relay-${tag}"
}

relay_rule_url_for_file() {
  echo "${RELAY_RULE_BASE_URL}/$1"
}

relay_meta_upsert_landing_to_json() {
  local relay_json="$1" landing_json="$2"
  echo "$relay_json" | jq --argjson landing "$landing_json" '
    .landings = (.landings // {})
    | .landings[$landing.id] = $landing
  '
}

relay_rule_add_meta_to_json() {
  local relay_json="$1" name="$2" file="$3" landing_json="$4" tag url
  tag="$(relay_rule_tag_for_file "$file")"
  url="$(relay_rule_url_for_file "$file")"
  echo "$relay_json" | jq --arg name "$name" --arg file "$file" --arg tag "$tag" --arg url "$url" --argjson landing "$landing_json" '
    .landings = (.landings // {})
    | .landings[$landing.id] = $landing
    | .rules = (
        ((.rules // []) | map(select((.tag // "") != $tag)))
        + [{name:$name,file:$file,tag:$tag,url:$url,landing_id:$landing.id}]
      )
  '
}

relay_rule_remove_meta_by_tags_json_from() {
  local relay_json="$1" tags_json="$2"
  echo "$relay_json" | jq --argjson tags "$tags_json" '
    .rules = [
      (.rules // [])[]
      | (.tag // "") as $tag
      | select(($tags | index($tag)) == null)
    ]
  '
}

relay_rule_remove_meta_by_files_json_from() {
  local relay_json="$1" files_json="$2"
  echo "$relay_json" | jq --argjson files "$files_json" '
    .rules = [
      (.rules // [])[]
      | (.file // "") as $file
      | select(($files | index($file)) == null)
    ]
  '
}

relay_normalize_rule_file() {
  split_rule_normalize_file "$@"
}

relay_validate_rule_file() {
  split_rule_validate_remote_file "$@"
}

relay_preset_rule() {
  split_rule_preset_item "$@"
}

relay_rule_add_meta() {
  local name="$1" file="$2" landing_json="$3" relay_json
  relay_json="$(relay_rule_add_meta_to_json "$(relay_meta_json)" "$name" "$file" "$landing_json")" || return 1
  relay_meta_save_rules_obj "$relay_json"
}

relay_rule_remove_meta_by_tags_json() {
  local tags_json="$1" relay_json
  relay_json="$(relay_rule_remove_meta_by_tags_json_from "$(relay_meta_json)" "$tags_json")" || return 1
  relay_meta_save_rules_obj "$relay_json"
}

relay_rule_remove_meta_by_files_json() {
  local files_json="$1" relay_json
  relay_json="$(relay_rule_remove_meta_by_files_json_from "$(relay_meta_json)" "$files_json")" || return 1
  relay_meta_save_rules_obj "$relay_json"
}

relay_rule_clear_meta() {
  relay_meta_save_obj '{"landings":{},"rules":[]}'
}

relay_rules_count() {
  relay_meta_rules_json | jq 'length'
}

relay_rules_print_summary() {
  local relay_json rules_json count
  relay_json="$(relay_meta_json)"
  rules_json="$(echo "$relay_json" | jq -c '.rules // []')"
  count="$(echo "$rules_json" | jq 'length')"
  if [ "$count" -eq 0 ]; then
    echo "部分流量转发：无"
    return 0
  fi
  echo "部分流量转发："
  echo "$relay_json" | jq -r '
    (.landings // {}) as $landings
    | (.rules // [])
    | sort_by(.landing_id // "", .name // "")
    | group_by(.landing_id // "")
    | .[]
    | (.[0].landing_id // "未设置") as $landing_id
    | "  - \($landing_id)：\([.[].name] | join("、"))"
  '
}

relay_rules_print_numbered() {
  local idx=0 file name display landing
  while IFS=$'\x01' read -r file name landing; do
    [ -z "$file" ] && continue
    idx=$((idx+1))
    display="$(split_rule_preset_display_name "$file")"
    [ -n "$display" ] || display="$name"
    [ -n "$display" ] || display="$file"
    printf '  %s. %s -> %s：%s\n' "$idx" "$display" "$landing" "$file"
  done < <(relay_meta_rules_json | jq -r '.[] | (.file // "") + "" + (.name // "") + "" + (.landing_id // "")')
}

relay_select_or_prompt_partial_landing() {
  local json="$1" outvar="$2"
  relay_choose_landing_or_return "$json" "$outvar"
}

relay_config_project_json() {
  local json="$1" rules_json="$2" landings_json="$3"
  echo "$json" | jq \
    --argjson rules "$rules_json" \
    --argjson landings "$landings_json" '
    def socks_out($base; $tag; $landing):
      ($base | del(.username,.password,.udp_over_tcp)) +
      ({type:"socks", version:"5", tag:$tag, server:($landing.server // ""), server_port:(($landing.port // 0) | tonumber)}
      | if (($landing.username // "") != "") then . + {username:$landing.username, password:($landing.password // "")} else . end
      | if $landing.udp_over_tcp == true then . + {udp_over_tcp:true} else . end);
    def full_landing:
      . as $tag |
      if startswith("to-") then sub("^to-"; "")
      elif startswith("out-to-") then sub("^out-to-"; "")
      elif test("^out-.+-to-.+$") then
        ($landings | keys | map(. as $id | select($tag | endswith("-to-" + $id))) | max_by(length)) // ""
      else "" end;
    def rule_set_array:
      ((.rule_set // []) | if type == "array" then . else [.] end);
    ($rules | map(.tag // "") | unique) as $managed_tags
    |
    ($rules | map(.landing_id // "") | unique | map(select(. != "" and (($landings[.] // null) != null)))) as $used_landings
    |
    .route = (.route // {"rules":[],"final":"reject"})
    | .route.rules = (.route.rules // [])
    | .route.rules = (
        .route.rules
        | map(select(
            (((.outbound // "") == "relay-partial") | not)
            and (((.outbound // "") | startswith("relay-")) | not)
            and ((rule_set_array | any(. as $tag | ($managed_tags | index($tag)) != null)) | not)
          ))
      )
    | .route.rule_set = (
        ((.route.rule_set // [])
          | map((.tag // "") as $tag | select(($managed_tags | index($tag)) == null))
        )
        + (if (($rules | length) > 0 and ($used_landings | length) > 0) then
            ($rules | map(. as $rule | select(($used_landings | index($rule.landing_id // "")) != null) | {type:"remote", tag:$rule.tag, format:"binary", url:$rule.url, http_client:{version:2,detour:"direct"}}))
          else [] end)
      )
    | .outbounds = (
        ((.outbounds // [])
          | map(
              (.tag // "") as $tag
              | ($tag | full_landing) as $id
              | if .type == "socks" and $id != "" and $landings[$id] != null then
                  socks_out(.; $tag; $landings[$id])
                else .
                end
            )
          | map(select(((.tag // "") != "relay-partial") and (((.tag // "") | startswith("relay-")) | not)))
        )
        + (if ($used_landings | length) > 0 then
            ($used_landings | map(. as $landing_id | socks_out({}; ("relay-" + $landing_id); $landings[$landing_id])))
          else [] end)
      )
  '
}

relay_project_partial_state_with_meta() {
  local json="$1" meta_json="$2" relay_json rules_json landings_json projected
  relay_json="$(relay_meta_json_from_meta "$meta_json")" || return 1
  meta_json="$(relay_meta_replace_in_meta_json "$meta_json" "$relay_json")" || return 1
  rules_json="$(echo "$relay_json" | jq -c '[.rules[]? | select((.tag // "") != "" and (.file // "") != "" and (.landing_id // "") != "")] | unique_by(.tag)')" || return 1
  landings_json="$(echo "$relay_json" | jq -c '.landings // {}')" || return 1
  projected="$(relay_config_project_json "$json" "$rules_json" "$landings_json")" || return 1
  route_rebuild "$projected" "$meta_json"
}

relay_project_partial_state() {
  relay_project_partial_state_with_meta "$1" "$(meta_load)"
}

relay_apply_meta_json_state() {
  local meta_json="$1" json projected normalized_relay
  normalized_relay="$(relay_meta_json_from_meta "$meta_json")" || return 1
  meta_json="$(relay_meta_replace_in_meta_json "$meta_json" "$normalized_relay")" || return 1
  json="$(user_manager_config_for_edit)" || return 1
  projected="$(relay_project_partial_state_with_meta "$json" "$meta_json")" || return 1
  if user_db_exists; then
    _USER_KEEP_LATEST_DB=1 _USER_MANAGER_APPLY_QUIET_OK=1 user_manager_apply_changes '' "$projected" "$meta_json"
  else
    _CONFIG_APPLY_QUIET_OK=1 _CONFIG_SKIP_USAGE_SYNC=1 config_and_meta_apply "$projected" "$meta_json"
  fi
}

relay_apply_partial_state() {
  relay_apply_meta_json_state "$(meta_load)"
}

relay_add_preset_rules() {
  local raw="$1" picks=() names=() files=() pick preset item name file landing_json json files_json has_warp_conflict=0
  local meta_json relay_json warp_json
  local previous
  init_manager_env || return 1
  json="$(user_manager_config_for_edit)" || return 1
  previous="$(meta_load)" || return 1
  mapfile -t picks < <(parse_plus_selections "$raw")
  [ "${#picks[@]}" -gt 0 ] || return 1
  for pick in "${picks[@]}"; do
    if ! [[ "$pick" =~ ^[2-7]$ ]]; then
      err "只能使用 2-7，并用 + 连接。"
      pause
      return 1
    fi
  done
  for pick in "${picks[@]}"; do
    preset=$((pick - 1))
    item="$(relay_preset_rule "$preset")" || return 1
    name="${item%%|*}"
    file="${item#*|}"
    names+=("$name")
    files+=("$file")
  done
  files_json="$(split_rule_files_json_from_args "${files[@]}")" || return 1
  if split_rule_has_warp_conflicts "$files_json"; then
    has_warp_conflict=1
    split_rule_confirm_warp_to_relay "$files_json" || {
      warn "已取消，未修改部分流量中转规则。"
      pause
      return 0
    }
  fi
  relay_select_or_prompt_partial_landing "$json" landing_json || { pause; return 0; }
  meta_json="$previous"
  warp_json="$(warp_rule_remove_meta_by_files_json_from "$(warp_meta_json)" "$files_json")" || return 1
  relay_json="$(relay_meta_json_from_meta "$previous")"
  for pick in "${!files[@]}"; do
    relay_json="$(relay_rule_add_meta_to_json "$relay_json" "${names[$pick]}" "${files[$pick]}" "$landing_json")" || return 1
  done
  meta_json="$(warp_meta_replace_in_meta_json "$meta_json" "$warp_json")" || return 1
  meta_json="$(relay_meta_replace_in_meta_json "$meta_json" "$relay_json")" || return 1
  relay_commit_projection "$json" "$previous" "$json" "$meta_json" || return 1
  ok "部分流量中转规则已应用。"
  pause
}

relay_custom_rule_menu() {
  local raw file name landing_json json files_json has_warp_conflict=0 meta_json relay_json warp_json
  local previous
  init_manager_env || return 1
  json="$(user_manager_config_for_edit)" || return 1
  previous="$(meta_load)" || return 1
  clear
  print_rect_title "自定义网站规则"
  echo "请先在以下页面查找规则名："
  echo "$RELAY_RULE_LOOKUP_URL"
  echo
  echo "例如：openai 或 geosite-openai 或 geosite-openai.srs"
  read -r -p "请输入规则名（回车返回）：" raw
  [ -n "${raw:-}" ] || return 0
  file="$(relay_normalize_rule_file "$raw")" || { pause; return 1; }
  if ! relay_validate_rule_file "$file"; then
    err "未在 SagerNet rule-set 中找到：$file"
    pause
    return 1
  fi
  name="自定义：${file%.srs}"
  files_json="$(split_rule_files_json_from_args "$file")" || return 1
  if split_rule_has_warp_conflicts "$files_json"; then
    has_warp_conflict=1
    split_rule_confirm_warp_to_relay "$files_json" || {
      warn "已取消，未修改部分流量中转规则。"
      pause
      return 0
    }
  fi
  relay_select_or_prompt_partial_landing "$json" landing_json || { pause; return 0; }
  meta_json="$previous"
  warp_json="$(warp_rule_remove_meta_by_files_json_from "$(warp_meta_json)" "$files_json")" || return 1
  relay_json="$(relay_rule_add_meta_to_json "$(relay_meta_json_from_meta "$previous")" "$name" "$file" "$landing_json")" || return 1
  meta_json="$(warp_meta_replace_in_meta_json "$meta_json" "$warp_json")" || return 1
  meta_json="$(relay_meta_replace_in_meta_json "$meta_json" "$relay_json")" || return 1
  relay_commit_projection "$json" "$previous" "$json" "$meta_json" || return 1
  ok "自定义部分流量中转已添加：$file"
  pause
}

# ---------- 删除中转规则 ----------

relay_delete() {
  init_manager_env || { pause; return 0; }
  local json lines=() node_lines=() partial_json partial_count item_lines=() choice picks=()
  local updated_json line entry relay_user out_tag node_key users_json type payload display idx part
  local partial_changed=0 full_changed=0 has_delete_all=0 tags_json tag final_json meta_json relay_json
  local -a selected_tags=()

  json="$(user_manager_config_for_edit)" || return 1
  mapfile -t lines < <(relay_list_table "$json")
  mapfile -t node_lines < <(
    printf '%s\n' "${lines[@]}" | awk -F '\x01' '
      function node_part(s) { sub(/@.*/, "", s); return s }
      NF>=2 {
        node=node_part($2)
        if (!(node in seen)) {
          seen[node]=1
          print $1 "\001" node "\001" $3
        }
      }' | sort_tsv_by_protocol 2
  )
  partial_json="$(relay_meta_rules_json)"
  partial_count="$(echo "$partial_json" | jq 'length')"
  if [ ${#node_lines[@]} -eq 0 ] && [ "$partial_count" -eq 0 ]; then
    warn "当前没有中转规则。"
    pause
    return 0
  fi

  clear
  print_rect_title "删除中转规则"
  relay_hr
  local i=1
  if [ ${#node_lines[@]} -gt 0 ]; then
    echo "全部流量转发至落地机："
    for line in "${node_lines[@]}"; do
      IFS=$'\x01' read -r entry relay_user out_tag <<< "$line"
      display="全部流量：${relay_user}"
      item_lines+=("full"$'\x01'"$relay_user"$'\x01'"$display")
      echo -e "  ${C}${i}.${NC} ${display}"
      i=$((i+1))
    done
  fi
  if [ "$partial_count" -gt 0 ]; then
    echo "部分流量转发至落地机："
    while IFS=$'\x01' read -r tag display; do
      item_lines+=("partial"$'\x01'"$tag"$'\x01'"部分流量：${display}")
      echo -e "  ${C}${i}.${NC} 部分流量：${display}"
      i=$((i+1))
    done < <(echo "$partial_json" | jq -r '.[] | [(.tag // ""), ((.landing_id // "未设置") + "：" + (.name // "") + "：" + (.file // ""))] | join("\u0001")')
  fi
  relay_hr
  echo -e "  ${C}99.${NC} 删除全部中转规则"
  echo -e "  ${R}0.${NC} 返回上一级"
  echo
  echo "多个编号用+连接，例如：1+3"
  read -r -p "请输入要删除的编号：" choice
  [ -n "${choice:-}" ] || return 0
  [ "$choice" = "0" ] && return 0

  mapfile -t picks < <(parse_plus_selections "$choice")
  [ "${#picks[@]}" -gt 0 ] || { warn "未选择任何中转规则。"; pause; return 0; }
  for part in "${picks[@]}"; do
    [ "$part" = "99" ] && has_delete_all=1
  done
  if [ "$has_delete_all" = "1" ]; then
    if [ "${#picks[@]}" -ne 1 ]; then
      err "删除全部中转规则不能和其它编号一起使用。"
      pause
      return 1
    fi
    ask_confirm_yn "确认删除全部中转规则？(y/N): " || return 0
  fi

  updated_json="$json"
  meta_json="$(meta_load)"
  relay_json="$(relay_meta_json)"
  if [ "$has_delete_all" = "1" ]; then
    for line in "${node_lines[@]}"; do
      IFS=$'\x01' read -r entry node_key out_tag <<< "$line"
      users_json="$({
        printf '%s\n' "${lines[@]}" | awk -F '\x01' -v n="$node_key" '
          function node_part(s) { sub(/@.*/, "", s); return s }
          node_part($2)==n { print $2 }'
      } | awk 'NF' | sort -u | jq -R . | jq -s '.')"
      updated_json="$(remove_relays_by_user_names "$updated_json" "$users_json")" || {
        err "删除全部流量中转失败，已中止，未写入配置。"
        pause
        return 1
      }
      full_changed=1
    done
    relay_json='{"landings":{},"rules":[]}'
    [ "$partial_count" -gt 0 ] && partial_changed=1
  else
    for part in "${picks[@]}"; do
      if ! [[ "$part" =~ ^[0-9]+$ ]] || [ "$part" -lt 1 ] || [ "$part" -gt "${#item_lines[@]}" ]; then
        err "编号超出范围：$part"
        pause
        return 1
      fi
      idx=$((part-1))
      IFS=$'\x01' read -r type payload display <<< "${item_lines[$idx]}"
      case "$type" in
        full)
          node_key="$payload"
          users_json="$({
            printf '%s\n' "${lines[@]}" | awk -F '\x01' -v n="$node_key" '
              function node_part(s) { sub(/@.*/, "", s); return s }
              node_part($2)==n { print $2 }'
          } | awk 'NF' | sort -u | jq -R . | jq -s '.')"
          updated_json="$(remove_relays_by_user_names "$updated_json" "$users_json")" || {
            err "删除全部流量中转失败，已中止，未写入配置。"
            pause
            return 1
          }
          full_changed=1
          ;;
        partial)
          selected_tags+=("$payload")
          partial_changed=1
          ;;
      esac
    done
    if [ ${#selected_tags[@]} -gt 0 ]; then
      tags_json="$(printf '%s\n' "${selected_tags[@]}" | jq -R . | jq -s '.')" || { pause; return 1; }
      relay_json="$(relay_rule_remove_meta_by_tags_json_from "$relay_json" "$tags_json")" || return 1
    fi
  fi

  meta_json="$(relay_meta_replace_in_meta_json "$meta_json" "$relay_json")" || return 1
  final_json="$(relay_project_partial_state_with_meta "$updated_json" "$meta_json")" || {
    err "重建中转规则失败，已中止，未写入配置。"
    pause
    return 1
  }

  local _delete_ok=0
  if user_db_exists; then
    local db_json
    sync_user_usage_counters || true
    db_json="$(user_db_load)" || return 1
    db_json="$(user_db_cleanup_missing_nodes "$db_json" "$final_json")"
    if _USER_KEEP_LATEST_DB=1 _USER_MANAGER_APPLY_QUIET_OK=1 user_manager_apply_changes "$db_json" "$final_json" "$meta_json"; then
      _delete_ok=1
    fi
  else
    if _CONFIG_APPLY_QUIET_OK=1 config_and_meta_apply "$final_json" "$meta_json"; then
      _delete_ok=1
    fi
  fi

  if [ "$_delete_ok" -eq 1 ]; then
    if [ "$full_changed" -eq 1 ] && [ "$partial_changed" -eq 1 ]; then
      ok "中转规则已删除。"
    elif [ "$full_changed" -eq 1 ]; then
      ok "全部流量中转已删除。"
    else
      ok "部分流量中转已删除。"
    fi
  else
    warn "中转规则删除失败，已返回上一级。"
  fi
  pause
  return 0
}

# ---------- 中转管理主菜单 ----------

manage_relay_nodes() {
  init_manager_env || { pause; return 0; }
  while true; do
    clear
    local json act count
    json="$(user_manager_config_for_edit)" || return 1
    print_rect_title "中转管理"
    say "客户端连接本机，流量从落地机出去。请先在落地机用本脚本安装 SOCKS5，再复制落地链接。"
    echo "当前中转规则："
    while IFS= read -r line; do
      echo "  $line"
    done < <(relay_full_summary_lines "$json")
    echo
    while IFS= read -r line; do
      echo "  $line"
    done < <(split_rule_overview_lines)
    relay_hr
    echo "----- 全部流量转发至落地机 -----"
    echo -e "  ${C}1.${NC} 本机作为中转机"
    echo
    echo "----- 部分流量转发至落地机 -----"
    echo -e "  ${C}2.${NC} AI 服务"
    echo -e "  ${C}3.${NC} Google"
    echo -e "  ${C}4.${NC} Netflix"
    echo -e "  ${C}5.${NC} Disney+"
    echo -e "  ${C}6.${NC} YouTube"
    echo -e "  ${C}7.${NC} TikTok"
    echo -e "  ${C}8.${NC} 自定义网站规则"
    count="$(relay_rules_count)"
    if [ "$count" -gt 0 ] || relay_list_table "$json" | awk 'NF {found=1} END {exit !found}'; then
      echo -e "  ${C}9.${NC} 删除中转规则"
    fi
    echo -e "  ${R}0.${NC} 返回主菜单"
    echo
    printf "  u. 更新落地连接   t. 中转诊断\n"
    echo "2-7支持用+连接，例如：2+4+7"
    read -r -p "请选择操作: " act
    case "${act:-}" in
      1) relay_add || true ;;
      8) relay_custom_rule_menu || true ;;
      9) relay_delete || true ;;
      u|U) relay_update_landing_menu || true ;;
      t|T) relay_diagnostics_menu || true ;;
      0|q|Q|"") return 0 ;;
      *+*|[2-7]) relay_add_preset_rules "$act" || true ;;
      *) warn "无效输入：$act"; sleep 1 ;;
    esac
  done
}
