#!/usr/bin/env bash
# ============================================================
# 模块: 64_warp.sh
# 职责: 管理 WARP 网站分流和生效状态
# 依赖: 00_base.sh, 01_utils.sh, 10_config.sh, 30_route.sh, 50_v2ray_api.sh
# ============================================================

WARP_PROXY_FILE="/etc/wireguard/proxy.conf"
WARP_RULE_BASE_URL="https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set"
WARP_RULE_LOOKUP_URL="https://github.com/SagerNet/sing-geosite/tree/rule-set"

warp_hr() {
  ui_hr
}

warp_meta_json() {
  warp_meta_json_from_meta "$(meta_load)"
}

warp_meta_json_from_meta() {
  jq -c '
    (.warp // {mode:"off", rules:[]})
    | .mode = (if (.mode // "off") == "rules" then "rules" else "off" end)
    | .rules = [
        (.rules // [])[]?
        | select((.file // "") != "")
        | .tag = ("relay-" + ((.file // "" | sub("\\.srs$"; "")) | gsub("[^A-Za-z0-9_-]"; "-")))
      ]
  ' <<< "$1"
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
  split_rule_normalize_file "$@"
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
    err "尚未安装 sing-box，无法写入 WARP 分流规则。"
    warn "请先在主菜单进入「安装与卸载」安装 sing-box。"
    pause
    return 1
  }
  config_ensure_exists
  ensure_manager_file_permissions
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
  local json="$1" rules="$2" backend="$3"
  jq --argjson rules "$rules" --argjson backend "$backend" '
    ($rules | map(.tag)) as $wanted
    | ([.route.rules[]? | select(.outbound == "warp") | .rule_set // [] |
        if type == "array" then .[] else . end] + $wanted | unique) as $managed
    | .route = (.route // {rules:[]})
    | .route.rules = [.route.rules[]? | select(.outbound != "warp")]
    | .route.rule_set = (
        [.route.rule_set[]? | .tag as $tag
          | select(($tag|startswith("warp-geosite-")|not) and ($managed|index($tag))==null)]
        + ($rules | map({type:"remote",tag:.tag,format:"binary",url:.url,http_client:{version:2,detour:"direct"}}))
      )
    | .outbounds = ([.outbounds[]? | select(.tag != "warp")]
        + (if $backend.type == "socks" then [$backend] else [] end))
    | .endpoints = ([.endpoints[]? | select(.tag != "warp")]
        + (if $backend.type == "wireguard" then [$backend] else [] end))
    | if .endpoints == [] then del(.endpoints) else . end
    | if $backend.type == "wireguard" then
        .dns.servers = ([.dns.servers[]? | select(.tag != "sb-warp-resolver")]
          + [{type:"local",tag:"sb-warp-resolver"}])
      elif any(.dns.servers[]?; .tag=="sb-warp-resolver") then
        .dns.servers |= map(select(.tag != "sb-warp-resolver"))
        | if .dns == {servers:[]} then del(.dns) else . end
      else . end
  ' <<< "$json"
}

warp_apply_meta_json_state() {
  local previous="$1" meta_json="$2" backend="$3" json rules projected rebuilt
  json="$(user_manager_config_for_edit)" || return 1
  rules="$(jq -c '.warp.rules // [] | unique_by(.tag)' <<< "$meta_json")" || return 1
  if [ "$rules" = '[]' ]; then
    backend=null
  elif [ "$backend" = null ]; then
    backend="$(jq -c 'first((.outbounds[]?, .endpoints[]?)|select(.tag=="warp")) // null' <<< "$json")" || return 1
    [ "$backend" != null ] || { err "当前分流缺少出口，请重新选择要启用的网站。"; return 1; }
  fi
  projected="$(warp_config_project_json "$json" "$rules" "$backend")" || return 1
  rebuilt="$(relay_project_partial_state_with_meta "$projected" "$meta_json")" || return 1
  if [ "$(jq -Sc . <<< "$json")" = "$(jq -Sc . <<< "$rebuilt")" ] &&
     [ "$(jq -Sc . <<< "$previous")" = "$(jq -Sc . <<< "$meta_json")" ]; then
    return 0
  fi
  if ! run_with_spinner "应用 WARP 分流" with_manager_lock protocol_commit_changes "$json" "$previous" "$rebuilt" "$meta_json"; then
    err "分流应用失败。请查看上方配置检查或回滚结果。"
    return 1
  fi
}

warp_validate_download() (
  local file="$1" dir url
  umask 077
  dir="$(mktemp -d)" || return 1
  trap 'rm -rf "$dir"' EXIT
  url="$(warp_rule_url_for_file "$file")" || return 1
  curl -q -fsSL --proto '=https' --connect-timeout 8 --max-time 20 "$url" -o "$dir/rule.srs" &&
    sing-box rule-set decompile -o "$dir/rule.json" "$dir/rule.srs" >/dev/null
)

warp_enable_rules() {
  local files_json previous relay_json warp_json next backend file item
  local -a items=("$@") files=()
  for item in "${items[@]}"; do files+=("${item#*|}"); done
  files_json="$(split_rule_files_json_from_args "${files[@]}")" || return 1
  previous="$(meta_load)" || return 1
  split_rule_confirm_relay_to_warp "$files_json" || return 1
  warp_json="$(warp_meta_json_from_meta "$previous")" || return 1
  for item in "${items[@]}"; do
    file="${item#*|}"
    if ! jq -e --arg file "$file" 'any(.rules[]?; .file==$file)' <<< "$warp_json" >/dev/null; then
      if ! run_with_spinner "下载并检查 $file" warp_validate_download "$file"; then
        err "规则下载或格式检查失败：$file"
        return 1
      fi
    fi
    warp_json="$(warp_rule_add_meta_to_json "$warp_json" "${item%%|*}" "$file")" || return 1
  done
  warp_prepare_backend backend || return 1
  relay_json="$(relay_meta_json_from_meta "$previous")" || return 1
  relay_json="$(relay_rule_remove_meta_by_files_json_from "$relay_json" "$files_json")" || return 1
  next="$(relay_meta_replace_in_meta_json "$previous" "$relay_json")" || return 1
  next="$(warp_meta_replace_in_meta_json "$next" "$warp_json")" || return 1
  warp_apply_meta_json_state "$previous" "$next" "$backend" || return 1
  ok "所选网站已走 WARP。"
}

warp_add_preset_rules() {
  local raw="$1" pick
  local -a picks=() items=()
  mapfile -t picks < <(parse_plus_selections "$raw")
  [ "${#picks[@]}" -gt 0 ] || return 1
  for pick in "${picks[@]}"; do
    if ! [[ "$pick" =~ ^[1-6]$ ]]; then
      err "请输入 1–6，多个编号用 + 连接。"
      return 1
    fi
    items+=("$(warp_preset_rule "$pick")")
  done
  warp_require_singbox && warp_enable_rules "${items[@]}"
}

warp_custom_rule_menu() {
  local raw file
  clear
  print_rect_title "自定义网站规则"
  echo "输入规则名，例如 openai。规则列表：$WARP_RULE_LOOKUP_URL"
  read -r -p "规则名（回车返回）: " raw || return 0
  [ -n "$raw" ] || return 0
  file="$(warp_normalize_rule_file "$raw")" || return 1
  warp_require_singbox && warp_enable_rules "${file%.srs}|$file"
}

warp_rules_delete_menu() {
  local rules_json count raw n tag tags_json has_delete_all=0 meta_json warp_json previous
  local -a idx=()
  local -a selected_tags=()
  previous="$(meta_load)" || return 1
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
    ask_confirm_yn "确认取消全部 WARP 分流？(y/N): " || return 0
    meta_json="$(warp_meta_replace_in_meta_json "$previous" '{"mode":"off","rules":[]}')" || return 1
    warp_apply_meta_json_state "$previous" "$meta_json" null || return 1
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
  meta_json="$(warp_meta_replace_in_meta_json "$previous" "$warp_json")" || return 1
  warp_apply_meta_json_state "$previous" "$meta_json" null || return 1
  ok "已删除指定 WARP 分流。"
  pause
}

warp_manager_menu() {
  local act
  warp_init_env || { pause; return 0; }
  while true; do
    clear
    print_rect_title "WARP 分流"
    echo "让选中的网站走 WARP。首次使用会自动配置。"
    split_rule_overview_lines
    warp_hr
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
    read -r -p "选择网站或操作: " act || return 0
    case "${act:-}" in
      0|q|Q|"") return 0 ;;
      7) warp_custom_rule_menu || true; pause ;;
      8) warp_rules_delete_menu || true ;;
      *+*|[1-6]) warp_add_preset_rules "$act" || true; pause ;;
      *) warn "无效输入：$act"; sleep 1 ;;
    esac
  done
}
