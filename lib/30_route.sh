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

HY2_HOP_DEFAULT_START=30000
HY2_HOP_DEFAULT_END=40000

hy2_hop_range_valid() {
  local start="$1" end="$2" listen_port="$3"
  [[ "$start" =~ ^[0-9]+$ ]] && [[ "$end" =~ ^[0-9]+$ ]] && [[ "$listen_port" =~ ^[0-9]+$ ]] || return 1
  [ "$start" -ge 1024 ] && [ "$end" -le 65535 ] && [ "$end" -gt "$start" ] || return 1
  # 范围不能包含监听端口
  { [ "$listen_port" -lt "$start" ] || [ "$listen_port" -gt "$end" ]; } || return 1
  return 0
}

# 解析 "30000-40000" 为 _HOP_START/_HOP_END，格式不对返回 1。
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

# 持久化重定向规则：只用已装好的工具保存，不自动装包；
# 保存不了返回 1，由调用方明确提醒用户手动保存，不悄悄跳过。
hy2_hop_persist() {
  if has_cmd netfilter-persistent; then
    netfilter-persistent save >/dev/null 2>&1 && return 0
  fi
  if has_cmd iptables-save && [ -d /etc/iptables ]; then
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || return 1
    if has_cmd ip6tables-save; then ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true; fi
    return 0
  fi
  if [ "$PKG_MANAGER" = "apk" ] && has_cmd iptables-save; then
    # Alpine OpenRC 的 iptables 服务从 /etc/iptables/rules-save 恢复
    mkdir -p /etc/iptables 2>/dev/null || return 1
    iptables-save > /etc/iptables/rules-save 2>/dev/null
    return $?
  fi
  return 1
}

# 应用端口跳跃重定向（先查后加，重装不重复）。持久化失败只警告，不回滚已生效的规则。
hy2_hop_apply() {
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
  if ! hy2_hop_persist; then
    warn "端口跳跃规则已生效，但持久化失败：重启后规则会丢失。请手动保存，例如 Debian/Ubuntu：apt install -y iptables-persistent && netfilter-persistent save。"
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
    warn "本机只有 nft 可用，跳跃规则需手动删除：nft delete rule ip nat prerouting udp dport ${start}-${end} redirect to :${port}（按 handle 删除更稳妥）。"
  fi
  hy2_hop_persist || warn "端口跳跃规则已删除，但持久化更新失败，重启后旧规则可能恢复，请手动保存。"
  return 0
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
  if ! echo "$normalized" | jq -e '.outbounds[]? | select((.tag // "") == "warp")' >/dev/null 2>&1; then
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
      | select(. != "" and node_part(.) == $entry)] | unique
  ')" || return 1
  relay_pairs_json="$(relay_list_table "$normalized" | jq -Rsc --argjson config "$normalized" '
    [$config.outbounds[]?.tag] as $tags
    | [split("\n")[] | select(length > 0) | split("\u0001")
       | select(.[1] != "" and .[2] != "") | {u:.[1],o:.[2]}
       | select(.o as $o | ($tags|index($o)) != null)] | sort_by(.o,.u) | unique_by(.u)
  ')" || return 1

  preserved_rules_json="$(
    echo "$normalized" | jq -c '
      [ .route.rules[]? | select(.auth_user? == null and .inbound? == null and . != {action:"reject"}) ]
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
