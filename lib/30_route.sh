#!/usr/bin/env bash
# ============================================================
# 模块: 30_route.sh
# 职责: 路由重建、协议清单、端口冲突检测、inbound/relay 删除
# 依赖: 00_base.sh (JQ_SHARED), 10_config.sh, 20_protocol.sh
# ============================================================

# ---------- 中转命名约定 ----------

relay_user_name() {
  local entry_key="$1" land="$2"
  echo "${entry_key}-to-${land}"
}

relay_outbound_tag() {
  local entry_key="$1" land="$2"
  echo "to-${land}"
}

relay_user_to_outbound() {
  if [[ "$1" =~ -to-(.+)$ ]]; then echo "to-${BASH_REMATCH[1]}"; else echo "out-$1"; fi
}

# ---------- 协议清单（使用共享 jq 模板） ----------

protocol_entry_inventory() {
  local json="$1"
  echo "$json" | jq -r "${JQ_DETECT_PROTOCOL}"'
    .inbounds[]?
    | (detect_protocol) as $proto
    | select($proto != "")
    | [(.tag // ""), $proto, ((.listen_port // 0) | tostring)]
    | join("\u0001")
  '
}

protocol_entry_inventory_ext() {
  local json="$1"
  echo "$json" | jq -r "${JQ_DETECT_PROTOCOL}"'
    .inbounds
    | to_entries[]?
    | .key as $idx
    | .value as $ib
    | ($ib | detect_protocol) as $proto
    | select($proto != "")
    | [$idx, ($ib.tag // ""), $proto, (($ib.listen_port // 0) | tostring)]
    | join("\u0001")
  '
}

inbound_protocol_name() {
  local inbound="$1"
  echo "$inbound" | jq -r "${JQ_DETECT_PROTOCOL}"'detect_protocol'
}

# ---------- 端口冲突检测（使用注册表） ----------

protocol_transport_layer() {
  local proto="$1"
  echo "${PROTO_TRANSPORT[$proto]:-tcp}"
}

config_port_in_use_by_layer() {
  local json="$1" port="$2" layer="$3" exclude_tag="${4:-}"
  echo "$json" | jq -e --arg p "$port" --arg ex "$exclude_tag" --arg layer "$layer" '
    .inbounds[]?
    | select((.listen_port? // empty | tostring) == $p)
    | select(($ex == "") or ((.tag // "") != $ex))
    | (if .type == "tuic" or .type == "hysteria2" or .type == "hysteria" then ["udp"]
       elif .type == "shadowsocks" then
         if (.network // "") == "" then ["tcp","udp"]
         elif (.network|type) == "array" then .network else (.network|split(",")) end
       else ["tcp"] end) as $layers
    | select(($layers | index($layer)) != null)
  ' >/dev/null 2>&1
}

port_conflict_for_protocol() {
  local json="$1" proto="$2" port="$3" exclude_tag="${4:-}"
  local layer
  layer="$(protocol_transport_layer "$proto")"
  local transport
  for transport in $layer; do
    if config_port_in_use_by_layer "$json" "$port" "$transport" "$exclude_tag"; then return 0; fi
  done
  return 1
}

# ====================================================
# Hysteria2 端口跳跃
# sing-box 只监听一个 UDP 端口；跳跃靠防火墙把一段 UDP 端口重定向到监听端口。
# 跳跃范围存在 meta.json（config.json 没有这个字段），按 entry_key 记，如 hy2-443。
# ====================================================

HY2_HOP_DEFAULT_START=42310
HY2_HOP_DEFAULT_END=45545

hy2_hop_range_valid() {
  local start="$1" end="$2" listen_port="$3"
  [[ "$start" =~ ^[0-9]+$ ]] && [[ "$end" =~ ^[0-9]+$ ]] && [[ "$listen_port" =~ ^[0-9]+$ ]] || return 1
  [ "$start" -ge 1024 ] && [ "$end" -le 65535 ] && [ "$end" -gt "$start" ] || return 1
  # 范围不能包含监听端口
  { [ "$listen_port" -lt "$start" ] || [ "$listen_port" -gt "$end" ]; } || return 1
  return 0
}

# 解析 "42310-45545" 为 _HOP_START/_HOP_END，格式不对返回 1。
hy2_parse_hop_range() {
  local range="${1:-}"
  [[ "$range" =~ ^([0-9]+)-([0-9]+)$ ]] || return 1
  _HOP_START="${BASH_REMATCH[1]}"
  _HOP_END="${BASH_REMATCH[2]}"
}

hy2_hop_range_from_meta() {
  local meta_json="${1:-}" tag="$2"
  [ -n "$meta_json" ] || meta_json='{}'
  echo "$meta_json" | jq -r --arg t "$tag" '
    (.[$t].hop_start // null) as $s | (.[$t].hop_end // null) as $e
    | if ($s != null and $e != null) then "\($s)-\($e)" else "" end'
}

hy2_hop_range_set_in_meta() {
  local meta_json="${1:-}" tag="$2" start="$3" end="$4"
  [ -n "$meta_json" ] || meta_json='{}'
  echo "$meta_json" | jq --arg t "$tag" --argjson s "$start" --argjson e "$end" \
    '.[$t] = ((.[$t] // {}) + {hop_start:$s, hop_end:$e})'
}

hy2_hop_range_del_from_meta() {
  local meta_json="${1:-}" tag="$2"
  [ -n "$meta_json" ] || meta_json='{}'
  echo "$meta_json" | jq --arg t "$tag" '
    del(.[$t].hop_start, .[$t].hop_end)
    | if (.[$t] // null) == {} then del(.[$t]) else . end'
}

# 指定的范围是否已被其它 hy2 节点占用（排除自己，用于重装换范围时判断）。
hy2_hop_range_in_use_by_meta() {
  local meta_json="${1:-}" start="$2" end="$3" exclude_tag="${4:-}"
  [ -n "$meta_json" ] || meta_json='{}'
  echo "$meta_json" | jq -e --argjson s "$start" --argjson e "$end" --arg ex "$exclude_tag" '
    [ to_entries[]
      | select((.key | startswith("hy2-")) and .key != $ex)
      | (.value.hop_start // null) as $hs | (.value.hop_end // null) as $he
      | select($hs != null and $he != null)
      | select(($s <= $he) and ($e >= $hs)) ] | length > 0' >/dev/null 2>&1
}

hy2_hop_rule_present() {
  local table_cmd="$1" start="$2" end="$3" port="$4"
  "$table_cmd" -t nat -C PREROUTING -p udp --dport "${start}:${end}" -j REDIRECT --to-port "$port" 2>/dev/null
}

# 仅在没有 iptables 时的 nft 兜底（有 iptables 的系统走 iptables-nft 即可）。
hy2_hop_apply_nft() {
  local start="$1" end="$2" port="$3"
  if nft list ruleset 2>/dev/null | grep -Fq "udp dport ${start}-${end} redirect to :${port}"; then return 0; fi
  nft add table ip nat 2>/dev/null || true
  nft add chain ip nat prerouting '{ type nat hook prerouting priority 0; }' 2>/dev/null || true
  nft add rule ip nat prerouting udp dport "${start}-${end}" redirect to ":${port}" || return 1
}

# 最近一次 hy2_hop_persist 失败的原因（成功时为空），供调用方在警告里具体说明。
_HY2_PERSIST_FAIL=""

# 持久化重定向规则：只用已装好的工具保存，不自动装包（不装 iptables-persistent）；
# 保存不了返回 1，并把原因记在 _HY2_PERSIST_FAIL 里，由调用方明确提醒用户手动保存，不悄悄跳过。
# 注意：只写 /etc/iptables/rules.v4 并不能保证开机自动恢复（没装 iptables-persistent
# 的系统开机时没人读这个文件）；开机恢复靠下面的 hy2_hop_restore_* 服务/cron。
hy2_hop_persist() {
  _HY2_PERSIST_FAIL=""
  if has_cmd netfilter-persistent; then
    if netfilter-persistent save >/dev/null 2>&1; then return 0; fi
    _HY2_PERSIST_FAIL="netfilter-persistent save 执行失败"
  else
    _HY2_PERSIST_FAIL="未安装 iptables-persistent（没有 netfilter-persistent 命令）"
  fi
  if [ "$PKG_MANAGER" = "apk" ] && has_cmd iptables-save; then
    # Alpine OpenRC 的 iptables 服务从 /etc/iptables/rules-save 恢复
    if mkdir -p /etc/iptables 2>/dev/null && iptables-save > /etc/iptables/rules-save 2>/dev/null; then
      return 0
    fi
    _HY2_PERSIST_FAIL="iptables-save 写入 /etc/iptables/rules-save 失败"
    return 1
  fi
  if has_cmd iptables-save; then
    # 新装系统常没有 /etc/iptables 目录：自己建目录再保存，不装任何包。
    if mkdir -p /etc/iptables 2>/dev/null && iptables-save > /etc/iptables/rules.v4 2>/dev/null; then
      if has_cmd ip6tables-save; then ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true; fi
      return 0
    fi
    _HY2_PERSIST_FAIL="无法创建 /etc/iptables 或 iptables-save 执行失败"
    return 1
  fi
  _HY2_PERSIST_FAIL="本机没有 iptables-save 可用"
  return 1
}

# 只加规则（先查后加，不持久化），供 hy2_hop_apply 与开机恢复共用。
_hy2_hop_add_rule() {
  local start="$1" end="$2" port="$3"
  local applied=0
  if has_cmd iptables; then
    if ! hy2_hop_rule_present iptables "$start" "$end" "$port"; then
      iptables -t nat -A PREROUTING -p udp --dport "${start}:${end}" -j REDIRECT --to-port "$port" || return 1
    fi
    applied=1
  fi
  if has_cmd ip6tables; then
    if ! hy2_hop_rule_present ip6tables "$start" "$end" "$port"; then
      ip6tables -t nat -A PREROUTING -p udp --dport "${start}:${end}" -j REDIRECT --to-port "$port" || return 1
    fi
    applied=1
  fi
  if [ "$applied" -eq 0 ]; then
    if has_cmd nft; then
      hy2_hop_apply_nft "$start" "$end" "$port" || return 1
    else
      err "未找到 iptables/ip6tables/nft，无法设置端口跳跃重定向。"
      return 1
    fi
  fi
  return 0
}

# 验证规则确实在防火墙里（安装后立即核对，不只信“执行成功”）。
# 有 iptables 就要求 v4 规则在，有 ip6tables 就要求 v6 规则也在；只有 nft 时查 ruleset。
hy2_hop_rule_verified() {
  local start="$1" end="$2" port="$3"
  if has_cmd iptables || has_cmd ip6tables; then
    if has_cmd iptables && ! hy2_hop_rule_present iptables "$start" "$end" "$port"; then return 1; fi
    if has_cmd ip6tables && ! hy2_hop_rule_present ip6tables "$start" "$end" "$port"; then return 1; fi
    return 0
  fi
  if has_cmd nft; then
    nft list ruleset 2>/dev/null | grep -Fq "udp dport ${start}-${end} redirect to :${port}"
    return $?
  fi
  return 1
}

# 应用端口跳跃重定向（先查后加，重装不重复）。持久化失败只警告，不回滚已生效的规则；
# 持久化失败时尽量装好开机自恢复服务，重启后规则能自动补回。
hy2_hop_apply() {
  local start="$1" end="$2" port="$3"
  _hy2_hop_add_rule "$start" "$end" "$port" || return 1
  if ! hy2_hop_persist; then
    if hy2_hop_restore_sync 2>/dev/null; then
      warn "端口跳跃规则已生效，但持久化保存失败（${_HY2_PERSIST_FAIL}）。已安装开机自恢复服务，重启后会自动补回规则；也可手动保存，例如 Debian/Ubuntu：apt install -y iptables-persistent && netfilter-persistent save。"
    else
      warn "端口跳跃规则已生效，但持久化失败（${_HY2_PERSIST_FAIL}），且开机自恢复服务未能安装：重启后规则会丢失。请手动保存，例如 Debian/Ubuntu：apt install -y iptables-persistent && netfilter-persistent save。"
    fi
  fi
  return 0
}

# 删除端口跳跃重定向（规则不存在也不报错）。调用前请先确认没有其它 hy2 节点还在用这个范围。
hy2_hop_remove() {
  local start="$1" end="$2" port="$3"
  if has_cmd iptables; then
    iptables -t nat -D PREROUTING -p udp --dport "${start}:${end}" -j REDIRECT --to-port "$port" 2>/dev/null || true
  fi
  if has_cmd ip6tables; then
    ip6tables -t nat -D PREROUTING -p udp --dport "${start}:${end}" -j REDIRECT --to-port "$port" 2>/dev/null || true
  fi
  if ! has_cmd iptables && ! has_cmd ip6tables && has_cmd nft; then
    local fam handle
    for fam in ip ip6; do
      while IFS= read -r handle; do
        [ -n "$handle" ] && nft delete rule "$fam" nat prerouting handle "$handle" 2>/dev/null || true
      done < <(nft -a list chain "$fam" nat prerouting 2>/dev/null \
        | awk -v pat="udp dport ${start}-${end} redirect to :${port}" 'index($0, pat) && /# handle [0-9]+/ { print $NF }')
    done
  fi
  hy2_hop_persist >/dev/null 2>&1 || true
  return 0
}

# 彻底卸载时调用：按 meta 清理全部端口跳跃防火墙规则与开机自恢复服务。
hy2_hop_remove_all_from_meta() {
  local meta_json _tag _start _end _port
  meta_json="$(meta_load 2>/dev/null)" || meta_json='{}'
  [ -n "$meta_json" ] || meta_json='{}'
  while IFS=' ' read -r _tag _start _end; do
    [ -n "$_tag" ] || continue
    _port="$(entry_key_to_port "$_tag")"
    [ -n "$_port" ] || continue
    hy2_hop_remove "$_start" "$_end" "$_port" 2>/dev/null || true
  done < <(printf '%s\n' "$meta_json" | jq -r '
    to_entries[]
    | select(.key | startswith("hy2-"))
    | select(.value.hop_start != null and .value.hop_end != null)
    | "\(.key) \(.value.hop_start) \(.value.hop_end)"
  ' 2>/dev/null)
  hy2_hop_restore_remove >/dev/null 2>&1 || true
}

# ====================================================
# Hysteria2 端口跳跃：开机自恢复（方案 B，不装 iptables-persistent）
# 原理：规则只在内存里，重启会丢。服务/cron 在开机时读 meta.json，
# 把每个 hy2 节点存的跳跃范围重新加回防火墙。服务由脚本自己建、
# 卸载时自己拆，不动系统包。
# ====================================================

HY2_HOP_RESTORE_SERVICE="/etc/systemd/system/sing-box-hy2-hop-restore.service"
HY2_HOP_RESTORE_CRON_MARK="sing-box-hy2-hop-restore"

# meta 里是否还有任何 hy2 节点的跳跃范围。
hy2_hop_has_any_range() {
  local meta_json="${1:-}"
  [ -n "$meta_json" ] || meta_json='{}'
  echo "$meta_json" | jq -e '
    [ to_entries[]
      | select(.key | startswith("hy2-"))
      | select(.value.hop_start != null and .value.hop_end != null) ] | length > 0' >/dev/null 2>&1
}

# 开机恢复入口（sb.sh --restore-hy2-hops 调用）：按 meta 把所有跳跃规则补回来。
# 不调持久化——恢复本身就是持久化的手段；失败返回 1 供 systemd/cron 日志查看。
hy2_hop_restore_all() {
  local meta_json
  meta_json="$(meta_load 2>/dev/null)" || meta_json='{}'
  [ -n "$meta_json" ] || meta_json='{}'
  local _ok=0 _tag _start _end _port
  while IFS=' ' read -r _tag _start _end; do
    [ -n "$_tag" ] || continue
    _port="$(entry_key_to_port "$_tag")"
    if ! hy2_hop_range_valid "$_start" "$_end" "$_port" 2>/dev/null; then
      warn "开机恢复跳过无效的跳跃范围：${_tag} ${_start}-${_end}。"
      _ok=1
      continue
    fi
    if ! _hy2_hop_add_rule "$_start" "$_end" "$_port"; then
      warn "开机恢复跳跃规则失败：${_tag} UDP ${_start}-${_end} -> ${_port}。"
      _ok=1
    fi
  done <<EOF
$(echo "$meta_json" | jq -r 'to_entries[] | select(.key | startswith("hy2-")) | select(.value.hop_start != null and .value.hop_end != null) | "\(.key) \(.value.hop_start) \(.value.hop_end)"' 2>/dev/null)
EOF
  return $_ok
}

_hy2_hop_restore_service_installed() {
  [ -f "$HY2_HOP_RESTORE_SERVICE" ] && grep -Fq -- "--restore-hy2-hops" "$HY2_HOP_RESTORE_SERVICE" 2>/dev/null
}

_hy2_hop_restore_cron_installed() {
  has_cmd crontab || return 1
  crontab -l 2>/dev/null | grep -Fq "$HY2_HOP_RESTORE_CRON_MARK"
}

# 装开机恢复：优先 systemd oneshot 服务；没有 systemd 时退到 @reboot cron；
# 两者都没有则返回 1，由调用方提醒用户手动处理。
hy2_hop_restore_install() {
  if _hy2_hop_restore_service_installed || _hy2_hop_restore_cron_installed; then return 0; fi
  if has_cmd systemctl && [ -d /run/systemd/system ]; then
    mkdir -p /etc/systemd/system || return 1
    cat > "$HY2_HOP_RESTORE_SERVICE" <<EOF
[Unit]
Description=Restore Hysteria2 port hopping iptables rules
After=network.target
[Service]
Type=oneshot
ExecStart=/bin/bash ${SB_TARGET_SCRIPT} --restore-hy2-hops
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable sing-box-hy2-hop-restore.service >/dev/null 2>&1 || return 1
    _hy2_hop_restore_service_installed
    return $?
  fi
  if has_cmd crontab; then
    local tmp
    tmp="$(mktemp)" || return 1
    crontab -l 2>/dev/null | grep -v "$HY2_HOP_RESTORE_CRON_MARK" > "$tmp" || true
    echo "@reboot /bin/bash ${SB_TARGET_SCRIPT} --restore-hy2-hops >/dev/null 2>&1 # ${HY2_HOP_RESTORE_CRON_MARK}" >> "$tmp"
    crontab "$tmp" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
    _hy2_hop_restore_cron_installed
    return $?
  fi
  return 1
}

# 拆开机恢复（服务和 cron 都清，只在没有跳跃范围剩下时调用）。
hy2_hop_restore_remove() {
  if [ -f "$HY2_HOP_RESTORE_SERVICE" ]; then
    systemctl disable --now sing-box-hy2-hop-restore.service >/dev/null 2>&1 || true
    rm -f "$HY2_HOP_RESTORE_SERVICE" || true
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
  if has_cmd crontab; then
    local tmp
    tmp="$(mktemp)" || return 0
    crontab -l 2>/dev/null | grep -v "$HY2_HOP_RESTORE_CRON_MARK" > "$tmp" || true
    if [ -s "$tmp" ]; then
      crontab "$tmp" || true
    else
      crontab -r 2>/dev/null || true
    fi
    rm -f "$tmp"
  fi
  return 0
}

# 按 meta 现状同步开机恢复：还有跳跃范围就确保装好，一个不剩就拆掉。
hy2_hop_restore_sync() {
  local meta_json
  meta_json="$(meta_load 2>/dev/null)" || meta_json='{}'
  [ -n "$meta_json" ] || meta_json='{}'
  if hy2_hop_has_any_range "$meta_json"; then
    hy2_hop_restore_install
  else
    hy2_hop_restore_remove
  fi
}

find_inbound_by_entry_key() {
  local json="$1" entry_key="$2"
  echo "$json" | jq -c --arg ek "$entry_key" '.inbounds[]? | select(.tag==$ek)' | head -n1
}

# ---------- 辅助：列出所有节点 key ----------

list_all_node_keys() {
  local json="$1"
  {
    echo "$json" | jq -r '.inbounds[]?.tag // empty'
    echo "$json" | jq -r '
      .inbounds[]?
      | (.users // [])[]?
      | (.name // .username // empty)
    ' | while IFS= read -r n; do
      [ -n "$n" ] || continue
      np="$(user_node_part "$n")"
      if [[ "$np" == *"-to-"* ]]; then
        echo "$np"
      fi
    done
  } | awk 'NF' | LC_ALL=C sort -u | sort_node_keys_by_protocol
}

# ====================================================
# 路由重建（核心函数，使用共享 jq 模板去重）
# ====================================================

route_rebuild(){
  local json="$1"
  local meta_json="${2:-}"
  local normalized core_auth_users_json relay_pairs_json preserved_rules_json
  local warp_mode="off" warp_tags_json='[]'
  local warp_available_tags_json='[]'
  local relay_rule_groups_json='[]'
  local relay_available_groups_json='[]'

  normalized="$(config_normalize "$json")" || return 1

  [ -n "$meta_json" ] || meta_json="$(meta_load)"

  if echo "$meta_json" | jq -e . >/dev/null 2>&1; then
    warp_mode="$(echo "$meta_json" | jq -r 'if (.warp.mode // "off") == "rules" then "rules" else "off" end' 2>/dev/null || echo "off")"
    warp_tags_json="$(echo "$meta_json" | jq -c '
      [
        .warp.rules[]?
        | (.file // "") as $file
        | select($file != "")
        | "relay-" + (($file | sub("\\.srs$"; "")) | gsub("[^A-Za-z0-9_-]"; "-"))
      ] | unique
    ' 2>/dev/null || echo '[]')"
  fi
  if ! echo "$normalized" | jq -e '(.outbounds[]?, .endpoints[]?) | select(.tag == "warp")' >/dev/null 2>&1; then
    warp_mode="off"
    warp_tags_json='[]'
  fi
  if [ "$warp_mode" = "rules" ]; then
    warp_available_tags_json="$(
      echo "$normalized" | jq -c --argjson wanted "$warp_tags_json" '
        [
          .route.rule_set[]?
          | (.tag // empty) as $tag
          | select(($wanted | index($tag)) != null)
          | $tag
        ] | unique
      '
    )" || warp_available_tags_json='[]'
  else
    warp_available_tags_json='[]'
  fi

  if echo "$meta_json" | jq -e . >/dev/null 2>&1; then
    relay_rule_groups_json="$(echo "$meta_json" | jq -c '
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
      | [
          ($relay.rules // [])[]?
          | (.landing_id // ($legacy_landing.id // "default")) as $landing_id
          | select(($landing_id != "") and (($landings[$landing_id] // null) != null))
          | (.tag // empty) as $tag
          | select($tag != "")
          | {tag:$tag, out:("relay-" + $landing_id)}
        ]
    ' 2>/dev/null || echo '[]')"
  fi
  relay_available_groups_json="$(
    echo "$normalized" | jq -c --argjson wanted "$relay_rule_groups_json" '
      def uniq:
        reduce .[] as $x ([]; if index($x) then . else . + [$x] end);
      ([.route.rule_set[]?.tag // empty] | uniq) as $available_rules
      | ([.outbounds[]?.tag // empty] | uniq) as $available_outbounds
      | [
          ($wanted // [])[]
          | . as $wanted_rule
          | select(($available_rules | index($wanted_rule.tag)) != null)
          | select(($available_outbounds | index($wanted_rule.out)) != null)
        ]
      | group_by(.out)
      | map({o:.[0].out, tags:([.[].tag] | uniq | sort)})
    '
  )" || relay_available_groups_json='[]'

  core_auth_users_json="$(echo "$normalized" | jq -c "${JQ_NODE_PART}"'
    [.inbounds[]? | .tag as $entry | .users[]? | (.name // .username // "")
      | select(. != "" and (node_part(.) | contains("-to-") | not))] | unique
  ')" || return 1
  relay_pairs_json="$(relay_list_table "$normalized" | jq -Rsc --argjson config "$normalized" '
    [$config.outbounds[]?.tag] as $tags
    | [split("\n")[] | select(length > 0) | split("\u0001")
       | select(.[1] != "" and .[2] != "") | {u:.[1],o:.[2]}
       | select(.o as $o | ($tags|index($o)) != null)] | sort_by(.o,.u) | unique_by(.u)
  ')" || return 1

  preserved_rules_json="$(
    echo "$normalized" | jq -c '
      [ .route.rules[]? | select(. != {action:"reject"})
        | select(.auth_user? == null or .inbound? != null or
            ((keys - ["auth_user","rule_set","outbound","action"]) | length > 0) or
            ((.action // "route") != "route") or
            ((.outbound // "") | test("^(direct$|warp$|out-|to-|relay-)") | not)) ]
    '
  )" || return 1

  echo "$normalized" | jq \
    --argjson core_auth "$core_auth_users_json" \
    --argjson relay "$relay_pairs_json" \
    --argjson kept "$preserved_rules_json" \
    --argjson relay_rule_groups "$relay_available_groups_json" \
    --argjson warp_tags "$warp_available_tags_json" '
    .route.rules = (
      ($kept // [])
      + (($relay // []) | group_by(.o) | map({auth_user:(map(.u) | unique | sort), outbound:.[0].o}))
      + (if ($core_auth | length) > 0 then (($relay_rule_groups // []) | map(select((.tags // []) | length > 0) | {auth_user:($core_auth | unique | sort),rule_set:(.tags | unique | sort),outbound:.o})) else [] end)
      + (if (($core_auth | length) > 0 and ($warp_tags | length) > 0) then [{auth_user:($core_auth | unique | sort),rule_set:$warp_tags,outbound:"warp"}] else [] end)
      + (if ($core_auth | length) > 0 then [{auth_user:($core_auth | unique | sort),outbound:"direct"}] else [] end)
    )
    # 保留规则的完整条件和顺序；生成的用户列表已在上面 unique。
    # 不可用 outbound/auth_user/rule_set 三字段对用户规则做全局去重。
    | . as $root
    | .outbounds |= map(
        (.tag // "") as $tag
        | select(
            (
              ($tag != "direct")
              and (($tag | startswith("out-")) or ($tag | startswith("to-")) or ($tag | startswith("relay-")))
              and (([$root.route.rules[]? | .outbound // empty] | index($tag)) == null)
            ) | not
          )
      )
    | if (.route.rule_set? == null) then .
      else
        (($warp_tags // []) + (($relay_rule_groups // []) | map(.tags[]?))) as $active_split_rule_tags
        | .route.rule_set = (
            ((.route.rule_set // []) | if type == "array" then . else [.] end)
            | map(
                (.tag // "") as $tag
                | select(
                    (
                      ((($tag | startswith("warp-geosite-")) or ($tag | startswith("relay-geosite-")))
                        and (($active_split_rule_tags | index($tag)) == null))
                    ) | not
                  )
              )
          )
      end
    | .route.rules += [{action:"reject"}]
    | del(.route.final)
  ' || return 1
}

# ====================================================
# 删除操作（使用共享 jq 模板去重）
# ====================================================

remove_relays_by_user_names(){
  local json="$1" users_json="$2"
  local updated_json

  updated_json="$(
    echo "$json" | jq "${JQ_AUTH_USERS}"'
      .inbounds |= map(
        if .users? then
          .users |= map(select(((.name // .username // "") as $n | ($users | index($n))) == null))
        else . end
      )
      | .route.rules |= map(
          if (.auth_user? == null) then .
          else
            (auth_users_array | [.[] | . as $u | select(($users | index($u)) == null)]) as $remain
            | if ($remain | length) == 0 then empty
              elif ($remain | length) == 1 then .auth_user = $remain[0]
              else .auth_user = $remain
              end
          end
        )
    ' --argjson users "$users_json"
  )" || return 1

  route_rebuild "$updated_json" || return 1
}

remove_inbound_by_entry_key(){
  local json="$1" entry_key="$2"
  local inbound_users_json related_outbounds_json updated_json

  inbound_users_json="$(
    echo "$json" | jq -c --arg ek "$entry_key" '
      [
        .inbounds[]?
        | select(.tag == $ek)
        | (.users // [])[]?
        | (.name // .username // empty)
        | select(. != "")
      ]
    '
  )" || return 1

  related_outbounds_json="$(
    echo "$json" | jq -c "${JQ_AUTH_USERS}"'
      (
        [
          .route.rules[]?
          | select((auth_users_array | any(. as $u | (($users | index($u)) != null))))
          | .outbound // empty
          | select(. != "" and . != "direct")
        ]
        + [
            ($users // [])[] as $u
            | (["out-" + $u] + (if ($u | contains("-to-")) then ["out-to-" + (($u | capture(".*-to-(?<land>.+)$").land)), "to-" + (($u | capture(".*-to-(?<land>.+)$").land))] else [] end))[] as $cand
            | .outbounds[]?
            | .tag // empty
            | select(. == $cand)
          ]
      ) | unique
    ' --argjson users "$inbound_users_json"
  )" || return 1

  updated_json="$(
    echo "$json" | jq "${JQ_AUTH_USERS}"'
      .inbounds |= map(select((.tag // "") != $ek))
      | .route.rules |= map(
          select(
            (
              .auth_user? as $au
              | if $au == null then true
                else
                  (
                    if ($au | type) == "array" then $au else [ $au ] end
                  ) as $arr
                  | any($arr[]; . as $u | (($users | index($u)) != null)) | not
                end
            )
          )
        )
    ' --arg ek "$entry_key" --argjson users "$inbound_users_json"
  )" || return 1

  echo "$updated_json" | jq --argjson outs "$related_outbounds_json" '
    . as $root
    | .outbounds |= map(
        (.tag // "") as $tag
        | select(
            (
              (($outs | index($tag)) != null)
              and (([$root.route.rules[]? | .outbound // empty] | index($tag)) == null)
            ) | not
          )
      )
  ' || return 1
}

remove_relays_for_entry_key() {
  local json="$1" entry_key="$2"
  local relay_users_json

  relay_users_json="$(
    echo "$json" | jq -c "${JQ_NODE_PART}"'
      [
        .inbounds[]?
        | select(.tag == $ek)
        | (.users // [])[]?
        | (.name // .username // empty)
        | select(. != "" and (node_part(.) | contains("-to-")))
      ]
    ' --arg ek "$entry_key"
  )"

  remove_relays_by_user_names "$json" "$relay_users_json"
}
