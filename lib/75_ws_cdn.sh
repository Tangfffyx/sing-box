#!/usr/bin/env bash
# Existing-CDN routing and validation. Cloud account changes are outside this module.

WS_CDN_NGINX_DIR="/etc/sing-box-manager/ws-cdn.d"

ws_cdn_hostname() {
  local host="$1"
  [[ "${#host}" -le 253 &&
     "$host" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ &&
     "$host" =~ \.[a-z][a-z0-9-]*$ ]]
}

ws_cdn_port_valid() {
  [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && [ "$1" -le 65535 ]
}

ws_cdn_path_valid() {
  [[ "$1" =~ ^/[A-Za-z0-9._~/-]*$ && "$1" != *//* && "$1/" != */../* && "$1/" != */./* ]]
}

ws_cdn_ws_inbound() {
  local json="$1" tag="$2"
  jq -ec "${JQ_DETECT_PROTOCOL}"'first(.inbounds[]?
    | select(.tag == $tag and ((detect_protocol) == "vmess-ws" or (detect_protocol) == "vless-ws")))' \
    --arg tag "$tag" <<< "$json"
}

ws_cdn_list() {
  protocol_entry_table "$1" | awk -F '\x01' '$2 == "vmess-ws" || $2 == "vless-ws"'
}

ws_cdn_public_peer() {
  local ip="${1,,}"
  if [[ "$ip" =~ ^[23][a-fA-F0-9]{3}: && "$ip" != 2001:db8:* ]]; then return 0; fi
  awk -v ip="$ip" 'BEGIN {
    n=split(ip,a,"."); if (n!=4) exit 1
    for (i=1;i<=4;i++) if (a[i] !~ /^[0-9]+$/ || a[i]>255) exit 1
    exit !(a[1]>0 && a[1]<224 && a[1]!=10 && a[1]!=127 &&
      !(a[1]==169 && a[2]==254) && !(a[1]==172 && a[2]>=16 && a[2]<=31) &&
      !(a[1]==192 && (a[2]==168 || (a[2]==0 && a[3]==2) || (a[2]==0 && a[3]==0))) &&
      !(a[1]==100 && a[2]>=64 && a[2]<=127) && !(a[1]==198 && (a[2]==18 || a[2]==19 || (a[2]==51 && a[3]==100))) &&
      !(a[1]==203 && a[2]==0 && a[3]==113))
  }'
}

# The test harness can provide a local trust root without allowing insecure TLS.
ws_cdn_public_ca() { :; }

ws_cdn_http_upgrade() {
  local leg="$1" host="$2" port="$3" path="$4" origin_addr="${5:-}" origin_port="${6:-}" ca="${7:-}" request_host="${8:-$2}"
  local headers result status peer rc=0
  local -a extra=()
  headers="$(mktemp)" || return 1
  [ -z "$origin_addr" ] || extra+=(--connect-to "$host:$port:$(uri_host "$origin_addr"):$origin_port")
  [ -z "$ca" ] || extra+=(--cacert "$ca")
  result="$(curl --silent --noproxy '*' --http1.1 --connect-timeout 4 --max-time 5 \
    --dump-header "$headers" --output /dev/null --write-out '%{http_code} %{remote_ip}' \
    -H "Host: $request_host" -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
    -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
    "${extra[@]}" "https://$host:$port$path")" || rc=$?
  read -r status peer <<< "$result"
  if { [ "$rc" = 0 ] || [ "$rc" = 28 ]; } && [ "$status" = 101 ] &&
    grep -Eiq '^Sec-WebSocket-Accept:[[:space:]]*s3pPLMBiTxaQ9kYGzzhZRbK\+xOo=' "$headers"; then
    rm -f "$headers"
    printf '%s\n' "$peer"
    return 0
  fi
  rm -f "$headers"
  case "$rc:$status" in
    6:*) warn "$leg DNS 解析失败，请检查域名记录。" ;;
    35:*|51:*|60:*|77:*|*:525|*:526) warn "$leg TLS 握手或证书校验失败，请检查证书名称、HTTPS 回源及 CA。" ;;
    *:404) warn "$leg 返回 404，请核对 WebSocket 路径和站点匹配。" ;;
    *:502|*:503|*:504|*:521|*:522|*:523|*:524) warn "$leg 返回 ${status}，请检查源站地址、HTTPS 回源端口和入站监听。" ;;
    7:*|28:000) warn "$leg 无法连接，请检查端口和防火墙。" ;;
    *) warn "$leg 未完成 WebSocket 升级（HTTP ${status:-未知}）。" ;;
  esac
  return 1
}

ws_cdn_probe_target() { printf '%s\n' 'https://www.cloudflare.com/cdn-cgi/trace'; }

ws_cdn_proxy_client() {
  local inbound="$1" host="$2" port="$3" path="$4" local_port="$5" early="$6" ca="$7"
  jq -ce --arg host "$host" --argjson port "$port" --arg path "$path" --argjson local_port "$local_port" \
    --argjson early "$early" --arg ca "$ca" '
      . as $in | first(.users[]? | select((.uuid // "") != "")) as $user
      | {log:{disabled:true},
         inbounds:[{type:"socks",listen:"127.0.0.1",listen_port:$local_port}],
         outbounds:[{type:$in.type,tag:"probe",server:$host,server_port:$port,uuid:$user.uuid,
           tls:({enabled:true,server_name:$host} | if $ca != "" then .certificate_path=$ca else . end),
           transport:({type:"ws",path:$path,headers:{Host:$host}} | if $early > 0 then
              .+{max_early_data:$early,early_data_header_name:"Sec-WebSocket-Protocol"} else . end)}
           | if $in.type == "vmess" then .+{security:"auto",alter_id:($user.alterId // 0)} else
                if ($user.flow // "") != "" then .flow=$user.flow else . end end]}
  ' <<< "$inbound"
}

ws_cdn_proxy_probe() (
  local inbound="$1" host="$2" port="$3" path="$4" early="$5" ca="$6" temp pid='' proxy_port attempt result target
  umask 077
  temp="$(mktemp -d)" || return 1
  trap 'if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi; rm -rf "$temp"' EXIT
  target="$(ws_cdn_probe_target)" || return 1
  for attempt in 1 2 3; do
    proxy_port=$(( 20000 + RANDOM ))
    ws_cdn_proxy_client "$inbound" "$host" "$port" "$path" "$proxy_port" "$early" "$ca" > "$temp/client.json" || return 1
    sing-box run -c "$temp/client.json" >/dev/null 2>&1 &
    pid=$!
    sleep 0.2
    if kill -0 "$pid" 2>/dev/null; then break; fi
    wait "$pid" 2>/dev/null || true
    pid=''
  done
  [ -n "$pid" ] || return 1
  # Clear the environment's bypass list; the request must use this exact client.
  local -a tls_target=()
  [ -z "$ca" ] || tls_target+=(--cacert "$ca")
  result="$(curl -fsS --noproxy '' --connect-timeout 4 --max-time 8 \
    --socks5-hostname "127.0.0.1:$proxy_port" "${tls_target[@]}" "$target" 2>/dev/null)" || return 1
  kill -0 "$pid" 2>/dev/null && grep -Eq '^ip=[0-9A-Fa-f:.]+$' <<< "$result"
)

ws_cdn_entry_conflict() {
  local meta="$1" config="$2" tag="$3" host="$4" path="$5"
  jq -e --argjson config "$config" --arg tag "$tag" --arg host "$host" --arg path "$path" '
    . as $meta
    | any($config.inbounds[]?; .tag != $tag and .transport.type == "ws" and
         ($meta[.tag] // {}) as $other |
         (($other.public_endpoint.host == $host and .transport.path == $path)
          or any($other.cdn_entries[]?; .host == $host and .path == $path)))
  ' <<< "$meta" >/dev/null
}

ws_cdn_store_entry() {
  local meta="$1" tag="$2" entry="$3"
  jq --arg tag "$tag" --argjson entry "$entry" '
    .[$tag].cdn_entries |= ((. // []) | if any(.[]; .host==$entry.host and .port==$entry.port and .path==$entry.path)
      then map(if .host==$entry.host and .port==$entry.port and .path==$entry.path then $entry else . end)
      else . + [$entry] end)
  ' <<< "$meta"
}

ws_cdn_confirm_operator() {
  local entry="$1" evidence="$2" other="$3"
  [ -f "$evidence" ] && [ -r "$evidence" ] && [ "$other" = true ] || return 1
  jq -ec --argjson entry "$entry" '
    select(type == "object" and (.operator == "电信" or .operator == "移动" or .operator == "联通"))
    | select(.host == $entry.host and .port == $entry.port and
       ((.source // "") | type=="string" and test("^https://[^[:space:]]+$")) and
       ((.provider // "") | type=="string" and length>0) and
       (.edge_ips | type == "array" and index($entry.edge_ip) != null))
    | {operator,provider,source}
  ' "$evidence"
}

ws_cdn_nginx() { nginx "$@"; }

ws_cdn_snippet_path() {
  ws_cdn_hostname "$1" || return 1
  printf '%s/%s.managed.conf\n' "$WS_CDN_NGINX_DIR" "$1"
}

ws_cdn_render_nginx() {
  local meta="$1" config="$2" host="$3" rows path addr port
  rows="$(jq -r --argjson config "$config" --arg host "$host" '
    [to_entries[] | select(.value|type=="object") | .key as $tag | .value.cdn_entries[]?
      | select(.host == $host and .mode == "nginx")
      | . as $entry | first($config.inbounds[]? | select(.tag == $tag)) as $in
      | [$entry.path, ($in.listen // "::"), ($in.listen_port | tostring)]]
      | unique | .[] | join("\u0001")
  ' <<< "$meta")" || return 1
  printf '%s\n' '# Managed by sing-box WS CDN'
  while IFS=$'\x01' read -r path addr port; do
    [ -n "$path" ] || continue
    ws_cdn_path_valid "$path" && ws_cdn_port_valid "$port" || return 1
    case "$addr" in ''|0.0.0.0) addr=127.0.0.1 ;; '::') addr=::1 ;; esac
    [[ "$addr" =~ ^[0-9A-Fa-f:.]+$ ]] || return 1
    printf 'location = %s {\n' "$path"
    printf '    proxy_pass http://%s:%s;\n' "$(uri_host "$addr")" "$port"
    cat <<'NGINX'
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Sec-WebSocket-Protocol $http_sec_websocket_protocol;
    proxy_buffering off;
    proxy_read_timeout 300s;
}
NGINX
  done <<< "$rows"
}

ws_cdn_replace_snippet() {
  local file="$1" tmp
  tmp="$(mktemp "$file.new.XXXXXX")" || return 1
  if ! cat > "$tmp" || ! chmod 0644 "$tmp" || ! mv -f "$tmp" "$file"; then
    rm -f "$tmp"
    return 1
  fi
}

ws_cdn_update_nginx() {
  local host="$1" contents="$2" file dump pending="$USER_DB_FILE.pending"
  file="$(ws_cdn_snippet_path "$host")" || return 1
  if [ -L "$file" ] || { [ -s "$file" ] && [ "$(head -n1 "$file")" != '# Managed by sing-box WS CDN' ]; }; then
    warn "反代片段已有其他内容，请在现有反代中手动维护该路径。"
    return 1
  fi
  mkdir -p "$WS_CDN_NGINX_DIR" || return 1
  if [ -f "$file" ]; then cp -p "$file" "$pending/ws-origin-before" || return 1; fi
  printf '%s\n' "$host" > "$pending/ws-origin-host" || return 1
  ws_cdn_replace_snippet "$file" <<< "$contents" || return 1
  if ! dump="$(ws_cdn_nginx -T 2>/dev/null)"; then
    ws_cdn_nginx -t || true
    warn "Nginx 配置检查失败，请检查重复路径或站点 include。"
    return 1
  fi
  if ! grep -Fxq "# configuration file $file:" <<< "$dump"; then
    warn "Nginx 未加载该片段。请先把此站点的 include 加到 HTTPS server 中。"
    return 1
  fi
  touch "$pending/ws-origin-reload" || return 1
  ws_cdn_nginx -s reload || return 1
  sleep 0.3
}

# Called from the existing manager journal while its lock is held.
ws_cdn_restore_pending() {
  local pending="$1" host file tmp
  [ -f "$pending/ws-origin-host" ] || return 0
  host="$(cat "$pending/ws-origin-host")" || return 1
  file="$(ws_cdn_snippet_path "$host")" || return 1
  if [ -f "$pending/ws-origin-before" ]; then
    tmp="$(mktemp "$file.restore.XXXXXX")" || return 1
    if ! cp -p "$pending/ws-origin-before" "$tmp" || ! mv -f "$tmp" "$file"; then
      rm -f "$tmp"
      return 1
    fi
  else
    rm -f "$file" || return 1
  fi
  if [ -f "$pending/ws-origin-reload" ]; then
    ws_cdn_nginx -t -q && ws_cdn_nginx -s reload || return 1
  fi
}

ws_cdn_verify() {
  local inbound="$1" entry="$2" host port path origin addr origin_port origin_sni origin_ca
  local public_ca peer early=0
  IFS=$'\x01' read -r host port path addr origin_port origin_sni origin_ca < <(
    jq -r '[.host, (.port|tostring), .path, .origin.address, (.origin.port|tostring),
            .origin.sni, (.origin.ca // "")] | join("\u0001")' <<< "$entry"
  )
  ui_echo "正在验证源站 HTTPS 和路径 ${path}（最多 5 秒）。"
  origin="$(ws_cdn_http_upgrade '源站' "$origin_sni" "$origin_port" "$path" \
    "$addr" "$origin_port" "$origin_ca" "$host")" || return 1
  public_ca="$(ws_cdn_public_ca)"
  ui_echo "正在验证公网入口 $host:${port}（最多 5 秒）。"
  peer="$(ws_cdn_http_upgrade '公网入口' "$host" "$port" "$path" '' '' "$public_ca")" || return 1
  if ! ws_cdn_public_peer "$peer" || [ "$peer" = "$origin" ]; then
    warn "公网域名未通过独立地址访问，请检查 DNS 是否已启用 CDN 代理。"
    return 1
  fi
  ui_echo "正在用节点凭据发起代理请求（最多 9 秒）。"
  if ! ws_cdn_proxy_probe "$inbound" "$host" "$port" "$path" 0 "$public_ca"; then
    warn "公网 WebSocket 已升级，但代理请求失败。请核对 CDN 路径到入站的对应关系、UUID 和源站出口。"
    return 1
  fi
  if jq -e '.transport.max_early_data >= 2048 and
    .transport.early_data_header_name == "Sec-WebSocket-Protocol"' <<< "$inbound" >/dev/null; then
    ui_echo "正在验证 Early Data 透传（最多 9 秒）。"
    if ws_cdn_proxy_probe "$inbound" "$host" "$port" "$path" 2048 "$public_ca"; then early=2048; fi
  fi
  jq --arg peer "$peer" --argjson early "$early" --arg checked "$(date -u '+%FT%TZ')" '
    . + {verified:true, edge_ip:$peer, checked_at:$checked, early_data:$early}
  ' <<< "$entry"
}

ws_cdn_validate_entry() {
  local entry="$1" host port path addr origin_port sni ca mode
  IFS=$'\x01' read -r host port path addr origin_port sni mode ca < <(
    jq -r '[.host, (.port|tostring), .path, .origin.address, (.origin.port|tostring),
            .origin.sni, .mode, (.origin.ca // "")] | join("\u0001")' <<< "$entry"
  )
  ws_cdn_hostname "$host" && ws_cdn_port_valid "$port" && ws_cdn_path_valid "$path" &&
    ws_cdn_port_valid "$origin_port" && ws_cdn_hostname "$sni" &&
    [[ "$addr" =~ ^[A-Za-z0-9.:-]+$ && ( "$mode" = nginx || "$mode" = existing ) ]] &&
    { [ -z "$ca" ] || [ -r "$ca" ]; }
}

ws_cdn_finish_attach() {
  local tag="$1" proposed="$2" evidence="$3" inbound="$4" previous_meta="$5" verified other detail
  verified="$(ws_cdn_verify "$inbound" "$proposed")" || return 1
  if [ -n "$evidence" ]; then
    other="$(jq -r --arg tag "$tag" --argjson tested "$verified" '
      any(.[$tag].cdn_entries[]?; .verified == true and .edge_ip != $tested.edge_ip
          and (.host != $tested.host or .port != $tested.port))
    ' <<< "$previous_meta")"
    if detail="$(ws_cdn_confirm_operator "$verified" "$evidence" "$other")"; then
      verified="$(jq --argjson record "$detail" '.operator_evidence=$record' <<< "$verified")" || return 1
    else
      warn "线路记录与实际入口未匹配，按 CDN 自动导出。"
    fi
  else
    # A changed public peer requires fresh evidence for an operator label.
    detail="$(jq -c --arg tag "$tag" --argjson tested "$verified" '
      first(.[$tag].cdn_entries[]? | select(.host==$tested.host and .port==$tested.port
        and .path==$tested.path and .edge_ip==$tested.edge_ip) | .operator_evidence // empty) // null
    ' <<< "$previous_meta")" || return 1
    if [ "$detail" != null ]; then
      verified="$(jq --argjson record "$detail" '.operator_evidence=$record' <<< "$verified")" || return 1
    fi
  fi
  ws_cdn_store_entry "$previous_meta" "$tag" "$verified"
}

ws_cdn_prepare_entry() {
  local tag="$1" requested="$2" inbound="$3" inventory="$4" previous="$5" path host
  path="$(jq -r '.transport.path // empty' <<< "$inbound")"
  requested="$(jq --arg path "$path" '.path=$path | del(.operator_evidence,.verified,.early_data,.edge_ip)' <<< "$requested")" || return 1
  ws_cdn_validate_entry "$requested" || { warn "公网域名、回源设置或现有路径不符合接入要求。"; return 1; }
  host="$(jq -r '.host' <<< "$requested")"
  if ws_cdn_entry_conflict "$previous" "$inventory" "$tag" "$host" "$path"; then
    warn "同一 CDN 域名下，这条 WebSocket 路径已属于另一个节点。"
    return 1
  fi
  # Keep ownership of existing managed paths across retries.
  if jq -e --arg tag "$tag" --arg host "$host" --arg path "$path" '
    any(.[$tag].cdn_entries[]?; .host == $host and .path == $path and .mode == "nginx")
  ' <<< "$previous" >/dev/null; then
    jq '.mode="nginx"' <<< "$requested"
  else
    printf '%s\n' "$requested"
  fi
}

ws_cdn_attach() {
  local tag="$1" requested="$2" evidence="${3:-}" runtime inventory inbound previous proposed final
  if [ "$(jq -r '.mode' <<< "$requested")" = nginx ]; then
    with_manager_lock _ws_cdn_attach_nginx "$tag" "$requested" "$evidence"
    return
  fi
  user_db_exists || { user_db_restore_hint; return 1; }
  runtime="$(config_load)" || return 1
  inventory="$(user_manager_config_for_edit)" || return 1
  inbound="$(ws_cdn_ws_inbound "$runtime" "$tag")" || { warn "该节点未在运行，请先恢复至少一个用户。"; return 1; }
  previous="$(meta_load)" || return 1
  proposed="$(ws_cdn_prepare_entry "$tag" "$requested" "$inbound" "$inventory" "$previous")" || return 1
  if [ "$(jq -r '.mode' <<< "$proposed")" = nginx ]; then
    with_manager_lock _ws_cdn_attach_nginx "$tag" "$proposed" "$evidence"
    return
  fi
  final="$(ws_cdn_finish_attach "$tag" "$proposed" "$evidence" "$inbound" "$previous")" || return 1
  with_manager_lock _ws_cdn_commit_existing "$tag" "$inbound" "$previous" "$final"
}

_ws_cdn_commit_existing() {
  local tag="$1" expected="$2" previous="$3" final="$4" latest latest_inbound runtime
  user_db_exists || { user_db_restore_hint; return 1; }
  latest="$(meta_load)" || return 1
  runtime="$(config_load)" || return 1
  latest_inbound="$(ws_cdn_ws_inbound "$runtime" "$tag")" || return 1
  if [ "$(jq -Sc . <<< "$previous")" != "$(jq -Sc . <<< "$latest")" ] ||
    [ "$(jq -Sc . <<< "$expected")" != "$(jq -Sc . <<< "$latest_inbound")" ]; then
    warn "验证期间节点或入口资料有变化，请重新验证。"
    return 1
  fi
  meta_save "$final" || return 1
  ok "公网代理请求通过，入口已保存。"
}

_ws_cdn_attach_nginx() {
  local tag="$1" requested="$2" evidence="$3"
  local runtime inventory inbound host previous proposed staged snippet final
  user_db_exists || { user_db_restore_hint; return 1; }
  runtime="$(config_load)" || return 1
  inventory="$(user_manager_config_for_edit)" || return 1
  inbound="$(ws_cdn_ws_inbound "$runtime" "$tag")" || { warn "该节点未在运行，请先恢复至少一个用户。"; return 1; }
  previous="$(meta_load)" || return 1
  proposed="$(ws_cdn_prepare_entry "$tag" "$requested" "$inbound" "$inventory" "$previous")" || return 1
  host="$(jq -r '.host' <<< "$proposed")"
  staged="$(ws_cdn_store_entry "$previous" "$tag" "$proposed")" || return 1
  snippet="$(ws_cdn_render_nginx "$staged" "$inventory" "$host")" || return 1
  manager_transaction_begin || return 1
  if ! ws_cdn_update_nginx "$host" "$snippet" ||
     ! final="$(ws_cdn_finish_attach "$tag" "$proposed" "$evidence" "$inbound" "$previous")" ||
     ! meta_save "$final"; then
    manager_recover_pending || return 1
    return 1
  fi
  manager_transaction_end || return 1
  ok "公网代理请求通过，入口已保存。"
}

ws_cdn_detach() {
  with_manager_lock _ws_cdn_detach_body "$@"
}

_ws_cdn_detach_body() {
  local tag="$1" host="$2" port="$3" previous entry next mode inventory snippet
  previous="$(meta_load)" || return 1
  entry="$(jq -ec --arg tag "$tag" --arg host "$host" --argjson port "$port" '
    first(.[$tag].cdn_entries[]? | select(.host==$host and .port==$port))
  ' <<< "$previous")" || return 1
  next="$(jq --arg tag "$tag" --argjson entry "$entry" '
    .[$tag].cdn_entries |= map(select(.host!=$entry.host or .port!=$entry.port))
    | if .[$tag].public_endpoint.host == $entry.host and
        (.[$tag].public_endpoint.port // 443) == $entry.port
      then del(.[$tag].public_endpoint) else . end
  ' <<< "$previous")" || return 1
  mode="$(jq -r '.mode' <<< "$entry")"
  if [ "$mode" = nginx ]; then
    inventory="$(user_manager_config_for_edit)" || return 1
    snippet="$(ws_cdn_render_nginx "$next" "$inventory" "$host")" || return 1
    manager_transaction_begin || return 1
    if ! ws_cdn_update_nginx "$host" "$snippet" || ! meta_save "$next"; then
      manager_recover_pending || return 1
      return 1
    fi
    manager_transaction_end || return 1
  else
    meta_save "$next" || return 1
  fi
  ok "已移除该导出入口。"
}

ws_cdn_detach_menu() {
  local tag="$1" meta host port answer i
  local -a entries=()
  meta="$(meta_load)" || return 1
  mapfile -t entries < <(jq -cr --arg tag "$tag" '.[$tag].cdn_entries[]?' <<< "$meta")
  [ "${#entries[@]}" -gt 0 ] || { warn "此节点还没有已验证的 CDN 入口。"; return 1; }
  for i in "${!entries[@]}"; do
    printf '  %s. %s\n' "$((i+1))" "$(jq -r '"\(.host):\(.port)\(.path)"' <<< "${entries[i]}")"
  done
  read -r -p "选择移除哪条入口（回车返回）: " answer || return 1
  [[ "$answer" =~ ^[1-9][0-9]*$ ]] && [ "$answer" -le "${#entries[@]}" ] || return 1
  read -r host port < <(jq -r '[.host, (.port|tostring)] | join(" ")' <<< "${entries[answer-1]}")
  ask_confirm_yes "确认移除此公网入口？输入 yes 确认: " || return 1
  ws_cdn_detach "$tag" "$host" "$port"
}

ws_cdn_has_managed_entry() {
  jq -e --arg tag "$2" 'any(.[$tag].cdn_entries[]?; .mode == "nginx")' <<< "$1" >/dev/null
}

ws_cdn_menu() {
  local json="$1" meta selected tag proto local_port i host port path mode origin entry answer evidence=''
  local origin_addr=127.0.0.1 origin_port=443 origin_sni origin_ca=''
  local -a rows=()
  mapfile -t rows < <(ws_cdn_list "$json")
  [ "${#rows[@]}" -gt 0 ] || { warn "请先安装 VMess-WS 或 VLESS-WS。"; pause; return 0; }
  print_rect_title "接入已有 CDN"
  say "选择节点。域名须已启用 CDN 代理、WebSocket 和 HTTPS 回源。"
  for i in "${!rows[@]}"; do
    IFS=$'\x01' read -r tag proto local_port <<< "${rows[i]}"
    printf '  %s. %s\n' "$((i+1))" "$tag"
  done
  read -r -p "选择要接入的节点（回车返回）: " selected || return 0
  [[ "$selected" =~ ^[1-9][0-9]*$ ]] && [ "$selected" -le "${#rows[@]}" ] || return 0
  IFS=$'\x01' read -r tag proto local_port <<< "${rows[selected-1]}"
  path="$(ws_cdn_ws_inbound "$json" "$tag" | jq -r '.transport.path // empty')" || return 1
  meta="$(meta_load)" || return 1
  host="$(jq -r --arg tag "$tag" '
    .[$tag].cdn_entries[0].host // .[$tag].public_endpoint.host //
    first(to_entries[] | select(.value|type=="object") | .value.cdn_entries[]? | .host) // ""
  ' <<< "$meta")"
  say "保留当前 WebSocket 路径 $path 和 UUID。新增入口不会覆盖其他已保存的入口。"
  read -r -p "公网域名 [${host:-待填写}]（d 管理已接入入口）: " answer || return 0
  if [ "$answer" = d ]; then ws_cdn_detach_menu "$tag" || true; pause; return 0; fi
  host="$(tr '[:upper:]' '[:lower:]' <<< "${answer:-$host}")"
  [ -n "$host" ] || return 0
  ws_cdn_hostname "$host" || { warn "请输入 CDN 的公网域名，不带协议、端口或路径。"; pause; return 0; }
  entry="$(jq -c --arg host "$host" '
    first(to_entries[] | select(.value|type=="object") | .value.cdn_entries[]? | select(.host == $host)) // {}
  ' <<< "$meta")"
  origin_sni="$host"
  port=443
  mode=existing
  if [ "$entry" != '{}' ]; then
    IFS=$'\x01' read -r port mode origin_addr origin_port origin_sni origin_ca < <(
      jq -r '[.port|tostring] + [.mode,.origin.address,(.origin.port|tostring),.origin.sni,.origin.ca // ""]
             | join("\u0001")' <<< "$entry"
    )
    say "将复用此域名的公网端口和回源设置。"
  fi
  read -r -p "回车验证；n 写入已有 Nginx；c 自定义端口、证书或线路记录: " answer || return 0
  case "$answer" in
    '') ;;
    n|N) mode=nginx ;;
    c|C)
      read -r -p "公网 HTTPS 端口 [$port]: " answer || return 0
      port="${answer:-$port}"
      read -r -p "源站地址 [$origin_addr]: " answer || return 0
      origin_addr="${answer:-$origin_addr}"
      origin_addr="${origin_addr#[}"
      origin_addr="${origin_addr%]}"
      read -r -p "HTTPS 回源端口 [$origin_port]: " answer || return 0
      origin_port="${answer:-$origin_port}"
      read -r -p "源站证书域名 [$origin_sni]: " answer || return 0
      origin_sni="$(tr '[:upper:]' '[:lower:]' <<< "${answer:-$origin_sni}")"
      read -r -p "源站私有 CA 文件（回车沿用现有设置，- 使用系统 CA）: " answer || return 0
      if [ "$answer" = - ]; then origin_ca=''; else origin_ca="${answer:-$origin_ca}"; fi
      read -r -p "供应商独立线路记录 JSON 文件（没有就回车）: " evidence || return 0
      read -r -p "写入已有 Nginx？输入 n，回车沿用当前方式: " answer || return 0
      [ "$answer" != n ] || mode=nginx
      ;;
    *) return 0 ;;
  esac
  if [ "$mode" = nginx ]; then
    has_cmd nginx || { warn "本机未找到 Nginx，可先在现有反代中接好路径，再验证。"; pause; return 0; }
    say "已有 HTTPS server 应先包含以下指令。"
    printf '  include %s/%s.*.conf;\n' "$WS_CDN_NGINX_DIR" "$host"
    read -r -p "已配置 include？按回车继续，q 返回: " answer || return 0
    [ -z "$answer" ] || return 0
  else
    say "确认现有 HTTPS 反代已将 $path 转发到该 WS 入站的端口 ${local_port}。"
  fi
  ws_cdn_port_valid "$port" && ws_cdn_port_valid "$origin_port" || { warn "端口无效。"; return 1; }
  origin="$(jq -nc --arg address "$origin_addr" --argjson port "$origin_port" \
    --arg sni "$origin_sni" --arg ca "$origin_ca" '{address:$address,port:$port,sni:$sni,ca:$ca}')"
  entry="$(jq -nc --arg host "$host" --argjson port "$port" --arg mode "$mode" \
    --argjson origin "$origin" '{host:$host,port:$port,mode:$mode,origin:$origin}')"
  if ws_cdn_attach "$tag" "$entry" "$evidence"; then
    export_configs "__admin__" "$(jq -nc --arg tag "$tag" '[$tag]')" || true
  else
    warn "这次未保存入口。原有节点资料保持可用。"
    pause
  fi
}
