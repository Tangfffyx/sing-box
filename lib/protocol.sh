#!/usr/bin/env bash

# Protocol module extracted from sb.sh (Stage 2-2)

# ====================================================
# 300 Entry / Relay / Route helpers
# ====================================================
entry_key_prefix_by_type() {
  case "$1" in
    vless-reality) echo "reality" ;;
    anytls) echo "anytls" ;;
    shadowsocks) echo "ss" ;;
    trojan) echo "trojan" ;;
    vmess-ws) echo "vmess-ws" ;;
    vless-ws) echo "vless-ws" ;;
    tuic) echo "tuic" ;;
    *) return 1 ;;
  esac
}

entry_key_from_parts() {
  local proto="$1" port="$2"
  local prefix
  prefix="$(entry_key_prefix_by_type "$proto")" || return 1
  echo "${prefix}-${port}"
}

entry_key_to_protocol_label() {
  case "$1" in
    reality-*) echo "vless-reality" ;;
    anytls-*) echo "anytls" ;;
    ss-*) echo "shadowsocks" ;;
    trojan-*) echo "trojan" ;;
    vmess-ws-*) echo "vmess-ws" ;;
    vless-ws-*) echo "vless-ws" ;;
    tuic-*) echo "tuic" ;;
    *) echo "unknown" ;;
  esac
}

entry_key_to_port() {
  echo "$1" | awk -F- '{print $NF}'
}

protocol_sort_rank() {
  case "$1" in
    vless-reality) echo 10 ;;
    anytls) echo 20 ;;
    shadowsocks) echo 30 ;;
    trojan) echo 40 ;;
    vmess-ws) echo 60 ;;
    vless-ws) echo 70 ;;
    tuic) echo 80 ;;
    *)
      # 预留给未来协议：放在 trojan 与 vmess-ws 之间
      echo 50
      ;;
  esac
}

node_key_base_entry() {
  local node_key="$1"
  if [[ "$node_key" == *"-to-"* ]]; then
    echo "${node_key%%-to-*}"
  else
    echo "$node_key"
  fi
}

node_key_to_protocol_label() {
  local node_key="$1"
  entry_key_to_protocol_label "$(node_key_base_entry "$node_key")"
}

sort_node_keys_preferred() {
  local node proto rank base port
  while IFS= read -r node; do
    [ -n "$node" ] || continue
    base="$(node_key_base_entry "$node")"
    proto="$(entry_key_to_protocol_label "$base")"
    rank="$(protocol_sort_rank "$proto")"
    port="$(entry_key_to_port "$base")"
    [[ "$port" =~ ^[0-9]+$ ]] || port=0
    printf '%s\t%06d\t%s\t%06d\t%s\n' "$rank" "$port" "$proto" "$port" "$node"
  done | sort -t $'\t' -k1,1n -k3,3 -k2,2n -k5,5 | awk -F $'\t' '!seen[$5]++ {print $5}'
}

sort_protocol_inventory_lines() {
  local line entry_key proto port rank
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    IFS=$'\t' read -r entry_key proto port <<< "$line"
    rank="$(protocol_sort_rank "$proto")"
    [[ "$port" =~ ^[0-9]+$ ]] || port=0
    printf '%s\t%06d\t%s\t%s\n' "$rank" "$port" "$proto" "$entry_key"
  done | sort -t $'\t' -k1,1n -k3,3 -k2,2n -k4,4 | awk -F $'\t' '{printf "%s\t%s\t%s\n", $4, $3, ($2+0)}'
}

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

protocol_entry_inventory() {
  local json="$1"
  echo "$json" | jq -r '
    .inbounds[]?
    | (
        if .type == "vless" and (.tls.reality.enabled // false) then "vless-reality"
        elif .type == "anytls" then "anytls"
        elif .type == "shadowsocks" then "shadowsocks"
        elif .type == "trojan" then "trojan"
        elif .type == "vmess" and ((.transport.type // "") == "ws") then "vmess-ws"
        elif .type == "vless" and ((.transport.type // "") == "ws") then "vless-ws"
        elif .type == "tuic" then "tuic"
        else ""
        end
      ) as $proto
    | select($proto != "")
    | [(.tag // ""), $proto, ((.listen_port // 0) | tostring)]
    | @tsv
  '
}

protocol_entry_inventory_ext() {
  local json="$1"
  echo "$json" | jq -r '
    .inbounds
    | to_entries[]?
    | .key as $idx
    | .value as $ib
    | (
        if $ib.type == "vless" and ($ib.tls.reality.enabled // false) then "vless-reality"
        elif $ib.type == "anytls" then "anytls"
        elif $ib.type == "shadowsocks" then "shadowsocks"
        elif $ib.type == "trojan" then "trojan"
        elif $ib.type == "vmess" and (($ib.transport.type // "") == "ws") then "vmess-ws"
        elif $ib.type == "vless" and (($ib.transport.type // "") == "ws") then "vless-ws"
        elif $ib.type == "tuic" then "tuic"
        else ""
        end
      ) as $proto
    | select($proto != "")
    | [$idx, ($ib.tag // ""), $proto, (($ib.listen_port // 0) | tostring)]
    | @tsv
  '
}

inbound_protocol_name() {
  local inbound="$1"
  echo "$inbound" | jq -r '
    if .type == "vless" and (.tls.reality.enabled // false) then "vless-reality"
    elif .type == "anytls" then "anytls"
    elif .type == "shadowsocks" then "shadowsocks"
    elif .type == "trojan" then "trojan"
    elif .type == "vmess" and ((.transport.type // "") == "ws") then "vmess-ws"
    elif .type == "vless" and ((.transport.type // "") == "ws") then "vless-ws"
    elif .type == "tuic" then "tuic"
    else ""
    end
  '
}

# --------------------------------------------------
# remove_relays_by_user_names
# 作用：
#   删除指定 relay user
#   更新相关 route.rules
#   不直接删除 outbound，由 route_rebuild 最终清理
# --------------------------------------------------
remove_relays_by_user_names(){
  local json="$1" users_json="$2"
  local updated_json

  updated_json="$(
    echo "$json" | jq --argjson users "$users_json" '
      def auth_users_array:
        if (.auth_user? == null) then []
        elif ((.auth_user | type) == "array") then .auth_user
        else [ .auth_user ]
        end;

      .inbounds |= map(
        if .users? then
          .users |= map(select(((.name // "") as $n | ($users | index($n))) == null))
        else . end
      )
      | .route.rules |= map(
          if (.auth_user? == null) then .
          else
            (auth_users_array | map(select(($users | index(.)) == null))) as $remain
            | if ($remain | length) == 0 then empty
              elif ($remain | length) == 1 then .auth_user = $remain[0]
              else .auth_user = $remain
              end
          end
        )
    '
  )" || return 1

  route_rebuild "$updated_json" || return 1
}

# --------------------------------------------------
# route_rebuild
# 作用：
#   根据当前 inbounds/users 重建托管 route 规则
#   自动生成 direct 规则
#   自动生成 relay 规则
#   清理无引用的 relay outbound
# 注意：
#   不会修改非托管 route
# --------------------------------------------------
route_rebuild(){
  local json="$1"
  local normalized core_users_json relay_pairs_json preserved_rules_json

  normalized="$(config_normalize "$json")" || return 1

  core_users_json="$({
    while IFS=$'	' read -r entry user_name; do
      [ -n "$user_name" ] || continue
      if [ "$(user_node_part "$user_name")" = "$entry" ]; then
        echo "$user_name"
      fi
    done < <(echo "$normalized" | jq -r '.inbounds[]? | .tag as $entry | (.users // [])[]? | [$entry, (.name // "")] | @tsv')
  } | awk 'NF' | sort -u | jq -R . | jq -s '.')" || return 1

  relay_pairs_json="$({
    while IFS=$'	' read -r entry relay_user out_tag; do
      [ -z "${relay_user:-}" ] && continue
      [ -z "${out_tag:-}" ] && continue
      if echo "$normalized" | jq -e --arg ot "$out_tag" '.outbounds[]? | select((.tag // "") == $ot)' >/dev/null 2>&1; then
        jq -n --arg u "$relay_user" --arg o "$out_tag" '{u:$u,o:$o}'
      fi
    done < <(relay_list_table "$normalized")
  } | jq -s 'sort_by(.o, .u) | unique_by(.u)')" || return 1

  preserved_rules_json="$(
    echo "$normalized" | jq -c '
      [ .route.rules[]? | select(.auth_user? == null) ]
    '
  )" || return 1

  echo "$normalized" | jq --argjson core "$core_users_json" --argjson relay "$relay_pairs_json" --argjson kept "$preserved_rules_json" '
    .route.rules = (
      ($kept // [])
      + (if ($core | length) > 0 then [{auth_user:($core | unique | sort),outbound:"direct"}] else [] end)
      + (($relay // []) | group_by(.o) | map({auth_user:(map(.u) | unique | sort), outbound:.[0].o}))
    )
    | .route.rules |= unique_by((.outbound // "") + "|" + (((.auth_user // []) | if type == "array" then . else [.] end | sort) | join(",")))
    | . as $root
    | .outbounds |= map(
        (.tag // "") as $tag
        | select(
            (
              ($tag != "direct")
              and (($tag | startswith("out-")) or ($tag | startswith("to-")))
              and (([$root.route.rules[]? | .outbound // empty] | index($tag)) == null)
            ) | not
          )
      )
    | .route.final = "reject"
  ' || return 1
}
protocol_transport_layer() {

  case "$1" in
    tuic) echo "udp" ;;
    *) echo "tcp" ;;
  esac
}

config_port_in_use_by_layer() {
  local json="$1" port="$2" layer="$3" exclude_tag="${4:-}"
  if [ "$layer" = "udp" ]; then
    echo "$json" | jq -e --arg p "$port" --arg ex "$exclude_tag" '
      .inbounds[]?
      | select((.listen_port? // empty | tostring) == $p)
      | select(.type=="tuic")
      | select(($ex == "") or ((.tag // "") != $ex))
    ' >/dev/null 2>&1
  else
    echo "$json" | jq -e --arg p "$port" --arg ex "$exclude_tag" '
      .inbounds[]?
      | select((.listen_port? // empty | tostring) == $p)
      | select(.type!="tuic")
      | select(($ex == "") or ((.tag // "") != $ex))
    ' >/dev/null 2>&1
  fi
}

port_conflict_for_protocol() {
  local json="$1" proto="$2" port="$3" exclude_tag="${4:-}"
  local layer
  layer="$(protocol_transport_layer "$proto")"
  config_port_in_use_by_layer "$json" "$port" "$layer" "$exclude_tag"
}

find_inbound_by_entry_key() {
  local json="$1" entry_key="$2"
  echo "$json" | jq -c --arg ek "$entry_key" '.inbounds[]? | select(.tag==$ek)' | head -n1
}

# ====================================================
# 400 Protocol builders / removers
# ====================================================
protocol_status_summary() {
  local json="$1"
  local all_lines proto label ports
  all_lines="$(protocol_entry_inventory "$json")"

  for proto in vless-reality anytls shadowsocks trojan vmess-ws vless-ws tuic; do
    label="$proto"
    ports="$(printf '%s
' "$all_lines" | awk -F '	' -v p="$proto" 'NF >= 3 && $2 == p { print $3 }' | sort -n | uniq | paste -sd'|' -)"

    if [ -n "$ports" ]; then
      printf '%s	%s	%s
' "$label" "已安装" "$ports"
    else
      printf '%s	%s	%s
' "$label" "未安装" ""
    fi
  done
}

protocol_entry_table() {
  local json="$1"
  protocol_entry_inventory "$json" | sort_protocol_inventory_lines
}

show_managed_relay_lines() {
  local json="$1"
  local found=0
  local seen=""
  local relay_node
  while IFS=$'	' read -r entry relay_user out_tag; do
    [ -z "${relay_user:-}" ] && continue
    relay_node="$(user_node_part "$relay_user")"
    [ -n "$relay_node" ] || continue
    if printf '%s
' "$seen" | grep -Fxq "$relay_node"; then
      continue
    fi
    seen="${seen}${relay_node}"$'
'
    found=1
    echo -e "  - ${G}${relay_node}${NC}"
  done < <(relay_list_table "$json")
  [ $found -eq 1 ]
}

build_vless_reality_inbound() {
  local port="$1" sni="$2" priv="$3" sid="$4"
  local entry_key uuid sid_json
  entry_key="$(entry_key_from_parts vless-reality "$port")"
  uuid="$(sing-box generate uuid)"
  if [ -n "$sid" ]; then
    sid_json="[\"$sid\"]"
  else
    sid_json='[]'
  fi
  jq -n --arg tag "$entry_key" --arg uuid "$uuid" --arg sni "$sni" --arg priv "$priv" --argjson sid "$sid_json" --argjson port "$port" '
    {
      "type":"vless",
      "tag":$tag,
      "listen":"::",
      "listen_port":$port,
      "users":[{"name":$tag,"uuid":$uuid,"flow":"xtls-rprx-vision"}],
      "tls":{
        "enabled":true,
        "server_name":$sni,
        "reality":{
          "enabled":true,
          "handshake":{"server":$sni,"server_port":443},
          "private_key":$priv,
          "short_id":$sid
        }
      }
    }
  '
}

ensure_self_signed_cert() {
  local cn="$1" crt_path="$2" key_path="$3"
  mkdir -p "$(dirname "$crt_path")"
  openssl req -x509 -newkey ec:<(openssl ecparam -name prime256v1) \
    -keyout "$key_path" -out "$crt_path" -days 36500 -nodes -subj "/CN=${cn}" >/dev/null 2>&1
}

build_anytls_inbound() {
  local port="$1" sni="$2"
  local entry_key pass crt key
  entry_key="$(entry_key_from_parts anytls "$port")"
  pass="$(openssl rand -base64 16)"
  crt="/etc/sing-box/anytls-${port}.crt"
  key="/etc/sing-box/anytls-${port}.key"
  ensure_self_signed_cert "$sni" "$crt" "$key"
  jq -n --arg tag "$entry_key" --arg pass "$pass" --arg sni "$sni" --arg crt "$crt" --arg key "$key" --argjson port "$port" '
    {
      "type":"anytls",
      "tag":$tag,
      "listen":"::",
      "listen_port":$port,
      "users":[{"name":$tag,"password":$pass}],
      "padding_scheme":[],
      "tls":{
        "enabled":true,
        "server_name":$sni,
        "certificate_path":$crt,
        "key_path":$key,
        "alpn":["h2","http/1.1"]
      }
    }
  '
}

ss2022_normalize_password_pair() {
  local raw="$1"
  local sp up
  if [ -z "$raw" ]; then
    sp="$(openssl rand -base64 16)"
    up="$(openssl rand -base64 16)"
    echo "${sp}:${up}"
    return 0
  fi
  sp="${raw%%:*}"
  up=""
  [[ "$raw" == *:* ]] && up="${raw#*:}"
  if ! echo "$sp" | base64 -d >/dev/null 2>&1; then sp="$(openssl rand -base64 16)"; fi
  if [ -n "$up" ] && ! echo "$up" | base64 -d >/dev/null 2>&1; then up="$(openssl rand -base64 16)"; fi
  if [ -n "$up" ]; then echo "${sp}:${up}"; else echo "$sp"; fi
}

build_ss_inbound() {
  local port="$1"
  local entry_key server_p user_p
  entry_key="$(entry_key_from_parts shadowsocks "$port")"
  server_p="$(openssl rand -base64 16)"
  user_p="$(openssl rand -base64 16)"
  jq -n --arg tag "$entry_key" --arg sp "$server_p" --arg up "$user_p" --argjson port "$port" '
    {
      "type":"shadowsocks",
      "tag":$tag,
      "listen":"::",
      "listen_port":$port,
      "method":"2022-blake3-aes-128-gcm",
      "password":$sp,
      "users":[{"name":$tag,"password":$up}]
    }
  '
}

build_trojan_inbound() {
  local port="$1" sni="$2"
  local entry_key pass crt key
  entry_key="$(entry_key_from_parts trojan "$port")"
  pass="$(openssl rand -base64 16)"
  crt="/etc/sing-box/trojan-${port}.crt"
  key="/etc/sing-box/trojan-${port}.key"
  ensure_self_signed_cert "$sni" "$crt" "$key"
  jq -n --arg tag "$entry_key" --arg pass "$pass" --arg sni "$sni" --arg crt "$crt" --arg key "$key" --argjson port "$port" '
    {
      "type":"trojan",
      "tag":$tag,
      "listen":"::",
      "listen_port":$port,
      "users":[{"name":$tag,"password":$pass}],
      "tls":{
        "enabled":true,
        "server_name":$sni,
        "certificate_path":$crt,
        "key_path":$key
      }
    }
  '
}

build_vmess_ws_inbound() {
  local port="$1" listen="$2" path="$3"
  local entry_key uuid
  entry_key="$(entry_key_from_parts vmess-ws "$port")"
  uuid="$(sing-box generate uuid)"
  jq -n --arg tag "$entry_key" --arg uuid "$uuid" --arg listen "$listen" --arg path "$path" --argjson port "$port" '
    {
      "type":"vmess",
      "tag":$tag,
      "listen":$listen,
      "listen_port":$port,
      "users":[{"name":$tag,"uuid":$uuid,"alterId":0}],
      "transport":{"type":"ws","path":$path,"max_early_data":2048,"early_data_header_name":"Sec-WebSocket-Protocol"}
    }
  '
}

build_vless_ws_inbound() {
  local port="$1" listen="$2" path="$3"
  local entry_key uuid
  entry_key="$(entry_key_from_parts vless-ws "$port")"
  uuid="$(sing-box generate uuid)"
  jq -n --arg tag "$entry_key" --arg uuid "$uuid" --arg listen "$listen" --arg path "$path" --argjson port "$port" '
    {
      "type":"vless",
      "tag":$tag,
      "listen":$listen,
      "listen_port":$port,
      "users":[{"name":$tag,"uuid":$uuid}],
      "transport":{"type":"ws","path":$path,"max_early_data":2048,"early_data_header_name":"Sec-WebSocket-Protocol"}
    }
  '
}

build_tuic_inbound() {
  local port="$1" sni="$2"
  local entry_key uuid pass crt key
  entry_key="$(entry_key_from_parts tuic "$port")"
  uuid="$(sing-box generate uuid)"
  pass="$(openssl rand -base64 12)"
  crt="/etc/sing-box/tuic-${port}.crt"
  key="/etc/sing-box/tuic-${port}.key"
  ensure_self_signed_cert "$sni" "$crt" "$key"
  jq -n --arg tag "$entry_key" --arg uuid "$uuid" --arg pass "$pass" --arg sni "$sni" --arg crt "$crt" --arg key "$key" --argjson port "$port" '
    {
      "type":"tuic",
      "tag":$tag,
      "listen":"::",
      "listen_port":$port,
      "users":[{"name":$tag,"uuid":$uuid,"password":$pass}],
      "tls":{"enabled":true,"server_name":$sni,"alpn":["h3"],"certificate_path":$crt,"key_path":$key},
      "congestion_control":"bbr"
    }
  '
}

cleanup_inbound_generated_cert_files() {
  local json="$1" entry_key="$2"
  local crt key
  crt="$(echo "$json" | jq -r --arg ek "$entry_key" '.inbounds[]? | select((.tag // "") == $ek) | .tls.certificate_path // empty' | head -n1)"
  key="$(echo "$json" | jq -r --arg ek "$entry_key" '.inbounds[]? | select((.tag // "") == $ek) | .tls.key_path // empty' | head -n1)"
  if [ -n "$crt" ] && [[ "$crt" == /etc/sing-box/* ]]; then
    rm -f "$crt" >/dev/null 2>&1 || true
  fi
  if [ -n "$key" ] && [[ "$key" == /etc/sing-box/* ]]; then
    rm -f "$key" >/dev/null 2>&1 || true
  fi
}

# --------------------------------------------------
# remove_inbound_by_entry_key
# 作用：
#   删除指定 entry_key 对应的 inbound
#   同时清理该 inbound 关联的 users 和 route 规则
#   最终由 route_rebuild 统一收口
# --------------------------------------------------
remove_inbound_by_entry_key(){
  local json="$1" entry_key="$2"
  local inbound_users_json related_outbounds_json updated_json

  inbound_users_json="$(
    echo "$json" | jq -c --arg ek "$entry_key" '
      [
        .inbounds[]?
        | select(.tag == $ek)
        | (.users // [])[]?
        | .name // empty
        | select(. != "")
      ]
    '
  )" || return 1

  related_outbounds_json="$(
    echo "$json" | jq -c --argjson users "$inbound_users_json" '
      def auth_users_array:
        if (.auth_user? == null) then []
        elif ((.auth_user | type) == "array") then .auth_user
        else [ .auth_user ]
        end;

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
    '
  )" || return 1

  updated_json="$(
    echo "$json" | jq --arg ek "$entry_key" --argjson users "$inbound_users_json" '
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
    '
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
    echo "$json" | jq -c --arg ek "$entry_key" '
      def node_part($s):
        if ($s | contains("@")) then ($s | split("@")[0]) else $s end;
      [
        .inbounds[]?
        | select(.tag == $ek)
        | (.users // [])[]?
        | .name // empty
        | select(. != "" and (node_part(.) != $ek))
      ]
    '
  )"

  remove_relays_by_user_names "$json" "$relay_users_json"
}
