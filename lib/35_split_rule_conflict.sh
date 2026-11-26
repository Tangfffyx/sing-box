#!/usr/bin/env bash
# ============================================================
# 模块: 35_split_rule_conflict.sh
# 职责: WARP 分流与部分流量中转之间的规则归属互斥
# 依赖: 00_base.sh, 01_utils.sh, 40_relay.sh, 64_warp.sh
# ============================================================

split_rule_files_json_from_args() {
  if [ "$#" -eq 0 ]; then
    echo '[]'
    return 0
  fi
  printf '%s\n' "$@" | awk 'NF' | jq -R . | jq -s 'unique'
}

split_rule_relay_conflicts_json() {
  local files_json="$1"
  relay_meta_rules_json | jq -c --argjson files "$files_json" '
    [
      .[]?
      | (.file // "") as $file
      | select($file != "" and (($files | index($file)) != null))
    ] | unique_by(.file)
  '
}

split_rule_warp_conflicts_json() {
  local files_json="$1"
  warp_meta_rules_json | jq -c --argjson files "$files_json" '
    [
      .[]?
      | (.file // "") as $file
      | select($file != "" and (($files | index($file)) != null))
    ] | unique_by(.file)
  '
}

split_rule_has_warp_conflicts() {
  local files_json="$1" conflicts
  conflicts="$(split_rule_warp_conflicts_json "$files_json")" || return 1
  [ "$(echo "$conflicts" | jq 'length')" -gt 0 ]
}

split_rule_clear_all_meta() {
  local meta_json
  meta_json="$(meta_load)"
  meta_json="$(echo "$meta_json" | jq 'del(.warp) | del(.relay)')" || return 1
  meta_save "$meta_json"
}

SPLIT_RULE_BASE_URL="https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set"
SPLIT_RULE_LOOKUP_URL="https://github.com/SagerNet/sing-geosite/tree/rule-set"

split_rule_preset_item() {
  case "${1:-}" in
    1) echo "AI 服务|geosite-category-ai-!cn.srs" ;;
    2) echo "Google|geosite-google.srs" ;;
    3) echo "Netflix|geosite-netflix.srs" ;;
    4) echo "Disney+|geosite-disney.srs" ;;
    5) echo "YouTube|geosite-youtube.srs" ;;
    6) echo "TikTok|geosite-tiktok.srs" ;;
    *) return 1 ;;
  esac
}

split_rule_normalize_file() {
  local raw="${1:-}" name
  name="$(printf '%s' "$raw" | tr -d '[:space:]')"
  [ -n "$name" ] || return 1
  if [[ "$name" == *"://"* ]]; then
    err "请输入规则文件名（如 openai 或 geosite-openai.srs），不要输入完整链接。"
    return 1
  fi
  name="${name##*/}"
  name="${name%.srs}"
  [[ "$name" == geosite-* ]] || name="geosite-${name}"
  if [[ ! "$name" =~ ^geosite-[A-Za-z0-9._!@+-]+$ ]]; then
    err "规则名称格式不对：${raw}"
    return 1
  fi
  echo "${name}.srs"
}

split_rule_validate_remote_file() {
  local file="$1" url
  url="${SPLIT_RULE_BASE_URL}/${file}"
  run_with_spinner "正在验证规则文件 ${file}..." \
    curl_maybe_warp -fsIL --connect-timeout 8 --max-time 15 "$url"
}

split_rule_confirm_relay_to_warp() {
  local files_json="$1" conflicts count
  conflicts="$(split_rule_relay_conflicts_json "$files_json")" || return 1
  count="$(printf '%s\n' "$conflicts" | jq 'length')" || return 1
  [ "$count" -gt 0 ] || return 0

  warn "以下规则当前正在走部分流量中转："
  printf '%s\n' "$conflicts" | jq -r '
    .[]?
    | "  - \(.name // .file) -> 落地 \(.landing_id // "未设置")（\(.file // "")）"
  '
  ask_confirm_yn "是否切换为 WARP 分流？[y/N]: " || return 1
}

split_rule_confirm_warp_to_relay() {
  local files_json="$1" conflicts count
  conflicts="$(split_rule_warp_conflicts_json "$files_json")" || return 1
  count="$(printf '%s\n' "$conflicts" | jq 'length')" || return 1
  [ "$count" -gt 0 ] || return 0

  warn "以下规则当前正在走 WARP 分流："
  printf '%s\n' "$conflicts" | jq -r '
    .[]?
    | "  - \(.name // .file)（\(.file // "")）"
  '
  ask_confirm_yn "是否切换为部分流量中转？[y/N]: " || return 1
}

split_rule_take_over_warp_to_relay() {
  local files_json="$1"
  warp_rule_remove_meta_by_files_json "$files_json"
}

# 预设规则的规范显示名：按 file 反查，未匹配返回空。
# relay/warp 两边的"规则展示"都走它，避免老 meta 里 .name 与新预设名不同步。
split_rule_preset_display_name() {
  case "${1:-}" in
    geosite-category-ai-!cn.srs) echo "AI 服务" ;;
    geosite-google.srs)          echo "Google" ;;
    geosite-netflix.srs)         echo "Netflix" ;;
    geosite-disney.srs)          echo "Disney+" ;;
    geosite-youtube.srs)         echo "YouTube" ;;
    geosite-tiktok.srs)          echo "TikTok" ;;
    *) echo "" ;;
  esac
}

# 分流总览：把 relay 部分流量规则与 WARP 分流规则合并展示，按预设顺序输出"规则名 → 去向"。
# 中转管理菜单与 WARP 分流管理菜单顶部都调它，两边视图一字不差。
split_rule_overview_lines() {
  local relay_rules warp_rules combined count sorted file name dest display arrow padded
  relay_rules="$(relay_meta_rules_json 2>/dev/null)" || relay_rules='[]'
  warp_rules="$(warp_meta_rules_json 2>/dev/null)" || warp_rules='[]'
  [ -n "$relay_rules" ] || relay_rules='[]'
  [ -n "$warp_rules" ] || warp_rules='[]'
  combined="$(jq -nc \
    --argjson relay "$relay_rules" \
    --argjson warp "$warp_rules" '
    ($relay | map({file:(.file // ""), name:(.name // ""), dest:("relay:" + (.landing_id // "未设置"))}))
    + ($warp | map({file:(.file // ""), name:(.name // ""), dest:"warp"}))
    | unique_by(.file)
  ' 2>/dev/null)" || combined='[]'
  count="$(echo "$combined" | jq 'length' 2>/dev/null)" || count=0
  if [ "$count" -eq 0 ]; then
    echo "分流总览：暂无规则"
    return 0
  fi
  echo "分流总览：（共 ${count} 条）"
  sorted="$(echo "$combined" | jq -r '
    def preset_index($file):
      if   $file == "geosite-category-ai-!cn.srs" then 0
      elif $file == "geosite-google.srs"          then 1
      elif $file == "geosite-netflix.srs"         then 2
      elif $file == "geosite-disney.srs"          then 3
      elif $file == "geosite-youtube.srs"         then 4
      elif $file == "geosite-tiktok.srs"          then 5
      else 99 end;
    sort_by(preset_index(.file), .file, .name)
    | .[]
    | (.file // "") + "" + (.name // "") + "" + (.dest // "")
  ' 2>/dev/null)" || return 0
  while IFS=$'\x01' read -r file name dest; do
    [ -z "$file" ] && [ -z "$name" ] && continue
    display="$(split_rule_preset_display_name "$file")"
    [ -n "$display" ] || display="$name"
    [ -n "$display" ] || display="$file"
    case "$dest" in
      warp)    arrow="WARP" ;;
      relay:*) arrow="落地机 ${dest#relay:}" ;;
      *)       arrow="$dest" ;;
    esac
    padded="$(pad_display_text "$display" 22)"
    printf '  %s → %s\n' "$padded" "$arrow"
  done <<< "$sorted"
}
