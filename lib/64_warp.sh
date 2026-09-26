#!/usr/bin/env bash
# ============================================================
# 模块: 64_warp.sh
# 职责: 借用外部 WireProxy SOCKS，为 sing-box 管理 WARP 网站分流
# 依赖: 00_base.sh, 01_utils.sh, 10_config.sh, 30_route.sh, 50_v2ray_api.sh
# ============================================================

WARP_PROXY_FILE="/etc/wireguard/proxy.conf"
WARP_RULE_BASE_URL="https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set"
WARP_RULE_LOOKUP_URL="https://github.com/SagerNet/sing-geosite/tree/rule-set"
WARP_SCRIPT_DOC_URL="https://gitlab.com/fscarmen/warp"
WARP_SCRIPT_RAW_URL="https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh"

warp_hr() {
  echo -e "${B}--------------------------------------------------------${NC}"
}

warp_meta_json() {
  meta_load | jq -c '
    (.warp // {mode:"off", rules:[]})
    | .mode = (if (.mode // "off") == "rules" then "rules" else "off" end)
    | .rules = [
        (.rules // [])[]?
        | select((.file // "") != "")
        | .tag = ("relay-" + ((.file // "" | sub("\\.srs$"; "")) | gsub("[^A-Za-z0-9_-]"; "-")))
      ]
  '
}

warp_meta_rules_json() {
  warp_meta_json | jq -c '[.rules[]? | select((.tag // "") != "" and (.file // "") != "")] | unique_by(.tag)'
}

warp_meta_save_obj() {
  local warp_json="$1" meta_json
  meta_json="$(meta_load)"
  meta_json="$(echo "$meta_json" | jq --argjson w "$warp_json" '.warp = $w')" || return 1
  meta_save "$meta_json"
}

warp_meta_save_rules_obj() {
  local warp_json="$1"
  warp_json="$(echo "$warp_json" | jq '
    .mode = (if ((.rules // []) | length) > 0 then "rules" else "off" end)
    | .rules = (.rules // [])
  ')" || return 1
  warp_meta_save_obj "$warp_json"
}

warp_meta_normalize_obj() {
  local warp_json="$1"
  echo "$warp_json" | jq -c '
    .mode = (if ((.rules // []) | length) > 0 then "rules" else "off" end)
    | .rules = (.rules // [])
  '
}

warp_meta_replace_in_meta_json() {
  local meta_json="$1" warp_json="$2" normalized
  normalized="$(warp_meta_normalize_obj "$warp_json")" || return 1
  echo "$meta_json" | jq --argjson w "$normalized" '.warp = $w'
}

warp_rule_tag_for_file() {
  local file="$1" base tag
  base="${file%.srs}"
  tag="${base//[^A-Za-z0-9_-]/-}"
  echo "relay-${tag}"
}

warp_rule_url_for_file() {
  echo "${WARP_RULE_BASE_URL}/$1"
}

warp_rule_add_meta_to_json() {
  local warp_json="$1" name="$2" file="$3" tag url
  tag="$(warp_rule_tag_for_file "$file")"
  url="$(warp_rule_url_for_file "$file")"
  echo "$warp_json" | jq --arg name "$name" --arg file "$file" --arg tag "$tag" --arg url "$url" '
    .rules = ((.rules // []) + [{name:$name,file:$file,tag:$tag,url:$url}])
    | .rules |= unique_by(.tag)
  '
}

warp_rule_remove_meta_by_tags_json_from() {
  local warp_json="$1" tags_json="$2"
  echo "$warp_json" | jq --argjson tags "$tags_json" '
    .rules = [
      (.rules // [])[]
      | (.tag // "") as $tag
      | select(($tags | index($tag)) == null)
    ]
  '
}

warp_rule_remove_meta_by_files_json_from() {
  local warp_json="$1" files_json="$2"
  echo "$warp_json" | jq --argjson files "$files_json" '
    .rules = [
      (.rules // [])[]
      | (.file // "") as $file
      | select(($files | index($file)) == null)
    ]
  '
}

warp_normalize_rule_file() {
  local raw="${1:-}" value
  value="$(printf '%s' "$raw" | tr -d '[:space:]')"
  [ -n "$value" ] || return 1
  if [[ "$value" == *"://"* ]]; then
    err "请输入 rule-set 文件名，不要输入完整 URL。"
    return 1
  fi
  [[ "$value" == geosite-* ]] || value="geosite-${value}"
  [[ "$value" == *.srs ]] || value="${value}.srs"
  [[ "$value" =~ ^geosite-[A-Za-z0-9._@!+-]+\.srs$ ]] || {
    err "规则名格式无效：$value"
    return 1
  }
  echo "$value"
}

warp_validate_rule_file() {
  local file="$1" url
  url="$(warp_rule_url_for_file "$file")"
  curl_maybe_warp -fsIL --connect-timeout 10 --max-time 20 "$url" >/dev/null 2>&1
}

warp_rule_add_meta() {
  local name="$1" file="$2" warp_json
  warp_json="$(warp_rule_add_meta_to_json "$(warp_meta_json)" "$name" "$file")" || return 1
  warp_meta_save_rules_obj "$warp_json"
}

warp_rule_remove_meta_by_tags_json() {
  local tags_json="$1" warp_json
  warp_json="$(warp_rule_remove_meta_by_tags_json_from "$(warp_meta_json)" "$tags_json")" || return 1
  warp_meta_save_rules_obj "$warp_json"
}

warp_rule_remove_meta_by_files_json() {
  local files_json="$1" warp_json
  warp_json="$(warp_rule_remove_meta_by_files_json_from "$(warp_meta_json)" "$files_json")" || return 1
  warp_meta_save_rules_obj "$warp_json"
}

warp_rule_clear_meta() {
  warp_meta_save_obj '{"mode":"off","rules":[]}'
}

warp_init_env() {
  [ "${_WARP_ENV_READY:-0}" = "1" ] && return 0
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    err "请使用 root 运行此脚本。"
    return 1
  fi
  has_cmd jq || { err "未找到 jq，无法管理 WARP 分流。"; return 1; }
  has_cmd curl || { err "未找到 curl，无法校验规则文件。"; return 1; }
  _WARP_ENV_READY=1
}

warp_require_singbox() {
  has_cmd sing-box || {
    err "未找到 sing-box，无法写入 WARP 分流策略。"
    warn "请先在主菜单执行 1. 安装/更新 sing-box。"
    pause
    return 1
  }
  config_ensure_exists
  ensure_manager_file_permissions
}

warp_proxy_conf_bind_address() {
  [ -s "$WARP_PROXY_FILE" ] || return 1
  awk -F= '
    /^[[:space:]]*BindAddress[[:space:]]*=/ {
      value=$2
      gsub(/[[:space:]]/, "", value)
      if (value != "") print value
      exit
    }
  ' "$WARP_PROXY_FILE"
}

warp_ss_line_for_addr() {
  local addr="$1"
  [ -n "$addr" ] || return 1
  has_cmd ss || return 1
  ss -nltp 2>/dev/null | awk -v a="$addr" '$4 == a && $0 ~ /wireproxy/ {print; found=1; exit} END {exit !found}'
}

warp_wireproxy_socks_addr() {
  local addr
  addr="$(warp_proxy_conf_bind_address 2>/dev/null || true)"
  if [ -n "$addr" ] && warp_ss_line_for_addr "$addr" >/dev/null 2>&1; then
    echo "$addr"
    return 0
  fi
  has_cmd ss || return 1
  ss -nltp 2>/dev/null | awk '/wireproxy/ {print $4; found=1; exit} END {exit !found}'
}

warp_wireproxy_ready() {
  warp_wireproxy_socks_addr >/dev/null 2>&1
}

warp_wireproxy_port() {
  local addr port
  addr="$(warp_wireproxy_socks_addr)" || return 1
  port="${addr##*:}"
  port="${port%]}"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  echo "$port"
}

warp_wireproxy_display() {
  local addr
  addr="$(warp_wireproxy_socks_addr 2>/dev/null || true)"
  [ -n "$addr" ] && echo "$addr" || echo "无"
}

warp_preset_rule() {
  case "$1" in
    1) echo "AI 服务|geosite-category-ai-!cn.srs" ;;
    2) echo "Google|geosite-google.srs" ;;
    3) echo "Netflix|geosite-netflix.srs" ;;
    4) echo "Disney+|geosite-disney.srs" ;;
    5) echo "YouTube|geosite-youtube.srs" ;;
    6) echo "TikTok|geosite-tiktok.srs" ;;
    *) return 1 ;;
  esac
}

warp_rules_count() {
  warp_meta_rules_json | jq 'length'
}

warp_rules_print_summary() {
  local rules_json count
  rules_json="$(warp_meta_rules_json)"
  count="$(echo "$rules_json" | jq 'length')"
  if [ "$count" -eq 0 ]; then
    echo "当前分流至 WARP 的服务：无"
    return 0
  fi
  echo "当前分流至 WARP 的服务："
  echo "$rules_json" | jq -r '.[] | "  - \(.name)：\(.file)"'
}

warp_rules_print_numbered() {
  local idx=0 file name display
  while IFS=$'\x01' read -r file name; do
    [ -z "$file" ] && continue
    idx=$((idx+1))
    display="$(split_rule_preset_display_name "$file")"
    [ -n "$display" ] || display="$name"
    [ -n "$display" ] || display="$file"
    printf '  %s. %s：%s\n' "$idx" "$display" "$file"
  done < <(warp_meta_rules_json | jq -r '.[] | (.file // "") + "" + (.name // "")')
}

warp_config_project_json() {
  local json="$1" rules_json="$2" ready="$3" port="$4"
  echo "$json" | jq \
    --argjson rules "$rules_json" \
    --argjson ready "$ready" \
    --argjson port "$port" '
    def rule_set_array:
      ((.rule_set // []) | if type == "array" then . else [.] end);
    ($rules | map(.tag // "") | unique) as $managed_tags
    |
    .route = (.route // {"rules":[],"final":"reject"})
    | .route.rules = (.route.rules // [])
    | .route.rules = (
        .route.rules
        | map(select(
            ((.outbound // "") != "warp")
            and ((rule_set_array | any(. as $tag | ($tag | startswith("warp-geosite-")) or (($managed_tags | index($tag)) != null))) | not)
          ))
      )
    | .route.rule_set = (
        ((.route.rule_set // [])
          | map(
              (.tag // "") as $tag
              | select((($tag | startswith("warp-geosite-")) or (($managed_tags | index($tag)) != null)) | not)
            )
        )
        + (if $ready then
            ($rules | map({type:"remote", tag:.tag, format:"binary", url:.url, http_client:{version:2,detour:"direct"}}))
          else [] end)
      )
    | .outbounds = (
        ((.outbounds // []) | map(select((.tag // "") != "warp")))
        + (if $ready then [{type:"socks", tag:"warp", server:"127.0.0.1", server_port:$port}] else [] end)
      )
  '
}

warp_apply_meta_json_state() {
  local meta_json="$1" json warp_json rules_json ready port projected rebuilt
  warp_require_singbox || return 1
  warp_json="$(echo "$meta_json" | jq -c '
    (.warp // {mode:"off", rules:[]})
    | .mode = (if (.mode // "off") == "rules" then "rules" else "off" end)
    | .rules = [
        (.rules // [])[]?
        | select((.file // "") != "")
        | .tag = ("relay-" + ((.file // "" | sub("\\.srs$"; "")) | gsub("[^A-Za-z0-9_-]"; "-")))
      ]
  ')" || return 1
  meta_json="$(warp_meta_replace_in_meta_json "$meta_json" "$warp_json")" || return 1
  json="$(config_load)"
  rules_json="$(echo "$warp_json" | jq -c '[.rules[]? | select((.tag // "") != "" and (.file // "") != "")] | unique_by(.tag)')" || return 1
  ready=false
  port=0
  if warp_wireproxy_ready; then
    ready=true
    port="$(warp_wireproxy_port)" || return 1
  fi
  projected="$(warp_config_project_json "$json" "$rules_json" "$ready" "$port")" || return 1
  rebuilt="$(route_rebuild "$projected" "$meta_json")" || return 1
  _CONFIG_APPLY_QUIET_OK=1 _CONFIG_SKIP_USAGE_SYNC=1 config_and_meta_apply "$rebuilt" "$meta_json"
}

warp_apply_current_state() {
  warp_apply_meta_json_state "$(meta_load)"
}

warp_require_wireproxy_ready() {
  if warp_wireproxy_ready; then
    return 0
  fi
  err "WireProxy SOCKS 未就绪，无法添加 WARP 分流。"
  warn "请先按页面提示安装 fscarmen WARP 脚本的 WireProxy 方案。"
  pause
  return 1
}

warp_add_preset_rules() {
  local raw="$1" picks=() names=() files=() pick item name file files_json meta_json relay_json warp_json
  warp_require_singbox || return 1
  warp_require_wireproxy_ready || return 1
  mapfile -t picks < <(parse_plus_selections "$raw")
  [ "${#picks[@]}" -gt 0 ] || return 1
  for pick in "${picks[@]}"; do
    if ! [[ "$pick" =~ ^[1-6]$ ]]; then
      err "只能使用 1-6，并用 + 连接。"
      pause
      return 1
    fi
  done
  for pick in "${picks[@]}"; do
    item="$(warp_preset_rule "$pick")" || return 1
    name="${item%%|*}"
    file="${item#*|}"
    names+=("$name")
    files+=("$file")
  done
  files_json="$(split_rule_files_json_from_args "${files[@]}")" || return 1
  split_rule_confirm_relay_to_warp "$files_json" || {
    warn "已取消，未修改 WARP 分流规则。"
    pause
    return 0
  }
  meta_json="$(meta_load)"
  relay_json="$(relay_rule_remove_meta_by_files_json_from "$(relay_meta_json)" "$files_json")" || return 1
  warp_json="$(warp_meta_json)"
  for pick in "${!files[@]}"; do
    warp_json="$(warp_rule_add_meta_to_json "$warp_json" "${names[$pick]}" "${files[$pick]}")" || return 1
  done
  meta_json="$(relay_meta_replace_in_meta_json "$meta_json" "$relay_json")" || return 1
  meta_json="$(warp_meta_replace_in_meta_json "$meta_json" "$warp_json")" || return 1
  warp_apply_meta_json_state "$meta_json" || return 1
  ok "WARP 分流规则已应用。"
  pause
}

warp_custom_rule_menu() {
  local raw file name files_json meta_json relay_json warp_json
  warp_require_singbox || return 1
  warp_require_wireproxy_ready || return 1
  clear
  print_rect_title "自定义网站规则"
  echo "请先在以下页面查找规则名："
  echo "$WARP_RULE_LOOKUP_URL"
  echo
  echo "例如：openai 或 geosite-openai 或 geosite-openai.srs"
  read -r -p "请输入规则名（回车返回）：" raw
  [ -n "${raw:-}" ] || return 0
  file="$(warp_normalize_rule_file "$raw")" || { pause; return 1; }
  if ! warp_validate_rule_file "$file"; then
    err "未在 SagerNet rule-set 中找到：$file"
    pause
    return 1
  fi
  name="自定义：${file%.srs}"
  files_json="$(split_rule_files_json_from_args "$file")" || return 1
  split_rule_confirm_relay_to_warp "$files_json" || {
    warn "已取消，未修改 WARP 分流规则。"
    pause
    return 0
  }
  meta_json="$(meta_load)"
  relay_json="$(relay_rule_remove_meta_by_files_json_from "$(relay_meta_json)" "$files_json")" || return 1
  warp_json="$(warp_rule_add_meta_to_json "$(warp_meta_json)" "$name" "$file")" || return 1
  meta_json="$(relay_meta_replace_in_meta_json "$meta_json" "$relay_json")" || return 1
  meta_json="$(warp_meta_replace_in_meta_json "$meta_json" "$warp_json")" || return 1
  warp_apply_meta_json_state "$meta_json" || return 1
  ok "自定义 WARP 分流已添加：$file"
  pause
}

warp_rules_delete_menu() {
  local rules_json count raw n tag tags_json has_delete_all=0 meta_json warp_json
  local -a idx=()
  local -a selected_tags=()
  rules_json="$(warp_meta_rules_json)"
  count="$(echo "$rules_json" | jq 'length')"
  [ "$count" -gt 0 ] || { warn "当前没有可删除的 WARP 分流。"; pause; return 0; }

  clear
  print_rect_title "删除 WARP 分流"
  warp_hr
  echo "当前分流至 WARP 的服务："
  warp_rules_print_numbered
  warp_hr
  echo -e "  ${C}99.${NC} 删除全部分流"
  echo -e "  ${R}0.${NC} 返回上一级"
  echo
  echo "多个编号用+连接，例如：1+3"
  read -r -p "请输入要删除的编号：" raw
  [ -n "${raw:-}" ] || return 0
  [ "$raw" = "0" ] && return 0

  mapfile -t idx < <(parse_plus_selections "$raw")
  [ "${#idx[@]}" -gt 0 ] || { warn "未选择任何分流。"; pause; return 0; }
  for n in "${idx[@]}"; do
    [ "$n" = "99" ] && has_delete_all=1
  done
  if [ "$has_delete_all" = "1" ]; then
    if [ "${#idx[@]}" -ne 1 ]; then
      err "删除全部分流不能和其它编号一起使用。"
      pause
      return 1
    fi
    ask_confirm_yn "确认删除全部 WARP 分流？(y/N): " || return 0
    meta_json="$(warp_meta_replace_in_meta_json "$(meta_load)" '{"mode":"off","rules":[]}')" || return 1
    warp_apply_meta_json_state "$meta_json" || return 1
    ok "已删除全部 WARP 分流。"
    pause
    return 0
  fi

  for n in "${idx[@]}"; do
    if ! [[ "$n" =~ ^[0-9]+$ ]] || [ "$n" -lt 1 ] || [ "$n" -gt "$count" ]; then
      err "编号超出范围：$n"
      pause
      return 1
    fi
    tag="$(echo "$rules_json" | jq -r --argjson i "$((n-1))" '.[$i].tag')"
    [ -n "$tag" ] && [ "$tag" != "null" ] && selected_tags+=("$tag")
  done
  tags_json="$(printf '%s\n' "${selected_tags[@]}" | jq -R . | jq -s '.')" || { pause; return 1; }
  warp_json="$(warp_rule_remove_meta_by_tags_json_from "$(warp_meta_json)" "$tags_json")" || return 1
  meta_json="$(warp_meta_replace_in_meta_json "$(meta_load)" "$warp_json")" || return 1
  warp_apply_meta_json_state "$meta_json" || return 1
  ok "已删除指定 WARP 分流。"
  pause
}

warp_print_header() {
  print_rect_title "WARP 分流管理"
  warp_hr
  echo "说明：WARP 分流依赖 fscarmen WARP 脚本的 WireProxy 方案。"
  echo "详情：$WARP_SCRIPT_DOC_URL"
  warp_hr
}

warp_print_status() {
  if warp_wireproxy_ready; then
    echo "WireProxy SOCKS：已就绪"
  else
    echo "WireProxy SOCKS：未就绪"
  fi
  echo "本地 SOCKS：$(warp_wireproxy_display)"
  echo
  split_rule_overview_lines
  warp_hr
}

warp_print_install_hint() {
  echo "请先安装 WireProxy 方案："
  echo
  echo "wget -N $WARP_SCRIPT_RAW_URL"
  echo "bash menu.sh w"
  echo
  echo "安装完成后重新进入本菜单即可。"
  echo
}

warp_manager_menu() {
  local act count
  warp_init_env || { pause; return 0; }
  while true; do
    clear
    warp_print_header
    warp_print_status
    count="$(warp_rules_count)"
    if ! warp_wireproxy_ready; then
      warp_print_install_hint
      if [ "$count" -gt 0 ]; then
        echo -e "  ${C}8.${NC} 删除分流"
      fi
      echo -e "  ${R}0.${NC} 返回上一级"
      read -r -p "请选择操作: " act
      case "${act:-}" in
        0|q|Q|"") return 0 ;;
        8) [ "$count" -gt 0 ] && warp_rules_delete_menu || { warn "无效输入：$act"; sleep 1; } ;;
        *) warn "无效输入：$act"; sleep 1 ;;
      esac
      continue
    fi

    echo -e "  ${C}1.${NC} AI 服务"
    echo -e "  ${C}2.${NC} Google"
    echo -e "  ${C}3.${NC} Netflix"
    echo -e "  ${C}4.${NC} Disney+"
    echo -e "  ${C}5.${NC} YouTube"
    echo -e "  ${C}6.${NC} TikTok"
    echo -e "  ${C}7.${NC} 自定义网站规则"
    echo -e "  ${C}8.${NC} 删除分流"
    echo -e "  ${R}0.${NC} 返回上一级"
    echo
    echo "1-6支持用+连接，例如：1+3+6"
    read -r -p "请选择操作: " act
    case "${act:-}" in
      0|q|Q|"") return 0 ;;
      7) warp_custom_rule_menu || true ;;
      8) warp_rules_delete_menu || true ;;
      *+*|[1-6]) warp_add_preset_rules "$act" || true ;;
      *) warn "无效输入：$act"; sleep 1 ;;
    esac
  done
}
