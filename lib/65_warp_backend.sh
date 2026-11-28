#!/usr/bin/env bash
# WARP backend discovery, device registration and isolated verification.

warp_wireproxy_configs() {
  local pid arg take cwd path
  while read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    take=0
    while IFS= read -r -d '' arg; do
      if [ "$take" -eq 1 ]; then
        path="$arg"
      else
        case "$arg" in
          -c|--config) take=1; continue ;;
          --config=*|-c=*) path="${arg#*=}" ;;
          *) continue ;;
        esac
      fi
      take=0
      if [[ "$path" != /* ]]; then
        cwd="$(readlink "/proc/$pid/cwd")" || continue
        path="$cwd/$path"
      fi
      [ ! -r "$path" ] || printf '%s\n' "$path"
    done < "/proc/$pid/cmdline"
  done < <(pgrep -x wireproxy 2>/dev/null || true)
  for path in "$WARP_PROXY_FILE" /etc/wireproxy/config /etc/wireproxy/config.conf /etc/wireproxy/wireproxy.conf; do
    [ ! -r "$path" ] || printf '%s\n' "$path"
  done
}

warp_wireproxy_candidates() {
  local file addr user pass host port listeners
  listeners=""
  if has_cmd ss; then listeners="$(ss -nltpH 2>/dev/null)" || listeners=""; fi
  while IFS= read -r file; do
    while IFS=$'\x1f' read -r addr user pass; do
      if [[ "$addr" =~ ^(127\.[0-9]+\.[0-9]+\.[0-9]+|localhost|0\.0\.0\.0|\*|\[::1\]|\[::\]):([0-9]{1,5})$ ]]; then
        host="${BASH_REMATCH[1]}" port="${BASH_REMATCH[2]}"
      else
        continue
      fi
      case "$host" in
        '[::]'|'[::1]') host=::1 ;;
        localhost|0.0.0.0|'*') host=127.0.0.1 ;;
      esac
      [[ "$port" =~ ^[1-9][0-9]*$ ]] && is_valid_port "$port" || continue
      if [ -n "$listeners" ] && ! awk -v addr="$addr" -v port="$port" '
        /"wireproxy"/ && ($4==addr || $4=="*:"port || $4=="0.0.0.0:"port || $4=="[::]:"port ||
          (addr=="localhost:"port && $4=="127.0.0.1:"port)) {found=1}
        END {exit !found}
      ' <<< "$listeners"; then
        continue
      fi
      jq -nc --arg host "$host" --argjson port "$port" --arg user "$user" --arg pass "$pass" '
        {type:"socks",tag:"warp",version:"5",server:$host,server_port:$port,network:"tcp"}
        | if $user != "" or $pass != "" then .+{username:$user,password:$pass} else . end'
    done < <(awk '
      function flush() {
        if (socks && !filtered && addr != "") printf "%s\037%s\037%s\n",addr,user,pass
        addr=user=pass=""; filtered=0
      }
      /^[[:space:]]*\[/ {
        flush()
        socks=(tolower($0) ~ /^[[:space:]]*\[socks5\][[:space:]\r]*$/)
        next
      }
      socks && /^[[:space:]]*[A-Za-z]+[[:space:]]*=/ {
        key=$0; sub(/=.*/, "", key); gsub(/[[:space:]]/, "", key)
        value=$0; sub(/^[^=]*=[[:space:]]*/, "", value); sub(/[[:space:]]*$/, "", value)
        key=tolower(key)
        if (key=="bindaddress") addr=value
        if (key=="username") user=value
        if (key=="password") pass=value
        if (key=="tunneldomains" && value!="") filtered=1
      }
      END {flush()}
    ' "$file")
  done < <(warp_wireproxy_configs | awk '!seen[$0]++')
}

warp_wireproxy_service() {
  local unit
  case "$INIT_SYSTEM" in
    systemd)
      for unit in wireproxy warp-wireproxy; do
        if [ "$(systemctl show -p LoadState --value "$unit.service" 2>/dev/null)" = loaded ]; then
          printf '%s\n' "$unit.service"; return
        fi
      done ;;
    openrc)
      for unit in wireproxy warp-wireproxy; do
        if [ -x "/etc/init.d/$unit" ]; then printf '%s\n' "$unit"; return; fi
      done ;;
  esac
  return 1
}

warp_start_wireproxy() {
  case "$INIT_SYSTEM" in
    systemd) timeout 30 systemctl start "$1" ;;
    openrc) timeout 30 rc-service "$1" start ;;
    *) return 1 ;;
  esac
}

warp_probe_config() {
  local backend="$1" port="$2" token="$3"
  jq -nc --argjson w "$backend" --argjson port "$port" --arg token "$token" '
    {log:{disabled:true},inbounds:[{type:"socks",listen:"127.0.0.1",listen_port:$port,
      users:[{username:"warp-probe",password:$token}]}],route:{final:"warp"}}
    | if $w.type=="wireguard" then
        .endpoints=[$w] | .dns={servers:[{type:"local",tag:"sb-warp-resolver"}]}
      else .outbounds=[$w] end'
}

warp_probe_backend() (
  local backend="$1" dir pid='' port token attempt result
  umask 077
  dir="$(mktemp -d)" || return 1
  trap 'if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi; rm -rf "$dir"' EXIT
  token="$RANDOM$RANDOM$RANDOM$RANDOM"
  for attempt in 1 2 3; do
    port=$((20000+RANDOM))
    warp_probe_config "$backend" "$port" "$token" > "$dir/config.json" || return 1
    sing-box run -c "$dir/config.json" > "$dir/core.log" 2>&1 &
    pid=$!
    sleep 0.25
    if kill -0 "$pid" 2>/dev/null; then break; fi
    wait "$pid" 2>/dev/null || true
    pid=''
  done
  [ -n "$pid" ] || return 1
  result="$(curl -q -fsS --connect-timeout 4 --max-time 18 --noproxy '' --proxy-user "warp-probe:$token" \
    --socks5-hostname "127.0.0.1:$port" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)" || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  tr -d '\r' <<< "$result" | grep -Ex 'warp=(on|plus)' >/dev/null
)

warp_profile_endpoint() {
  awk -F= '
    /^[[:space:]]*\[/ { section=$0; gsub(/[[:space:]\[\]]/,"",section); next }
    NF>1 {
      k=$1; gsub(/[[:space:]]/,"",k)
      v=$0; sub(/^[^=]*=[[:space:]]*/,"",v); sub(/[[:space:]]*$/,"",v)
      if (section=="Interface" && k=="Address") address=address (address==""?"":",") v
      if (section=="Interface" && k=="PrivateKey") private=v
      if (section=="Interface" && k=="MTU") mtu=v
      if (section=="Peer" && k=="Endpoint") endpoint=v
      if (section=="Peer" && k=="PublicKey") public=v
      if (section=="Peer" && k=="AllowedIPs") allowed=allowed (allowed==""?"":",") v
    }
    END {
      print address; print private; print mtu; print endpoint; print public; print allowed
    }
  ' "$1" | jq -Rsec '
    split("\n") as $v | ($v[3]|capture("^(?<host>.+):(?<port>[0-9]+)$")) as $peer
    | def csv: split(",") | map(gsub("[[:space:]]";"") | select(length>0));
      {type:"wireguard",tag:"warp",system:false,domain_resolver:{server:"sb-warp-resolver",strategy:"prefer_ipv4"},
       address:($v[0]|csv),private_key:$v[1],mtu:($v[2]|if .=="" then 1280 else tonumber end),
       peers:[{address:($peer.host|ltrimstr("[")|rtrimstr("]")),port:($peer.port|tonumber),
           public_key:$v[4],allowed_ips:($v[5]|csv)}]}
    | select((.address|length)>0 and (.private_key|length)>0 and
      (.peers[0] | (.public_key|length)>0 and (.allowed_ips|length)>0))'
}

warp_check_core() (
  local dir key sample
  umask 077
  dir="$(mktemp -d)" || return 1
  trap 'rm -rf "$dir"' EXIT
  key='EAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEA='
  sample="$(jq -nc --arg k "$key" '{type:"wireguard",tag:"warp",system:false,address:["192.0.2.2/32"],
    private_key:$k,peers:[{address:"192.0.2.1",port:51820,public_key:$k,allowed_ips:["0.0.0.0/0"]}]}')" || return 1
  warp_probe_config "$sample" 23456 check-only > "$dir/check.json" || return 1
  sing-box check -c "$dir/check.json" >/dev/null 2>&1
)

warp_download_wgcf() (
  local dir="$1" version=2.2.30 arch asset digest temp
  case "$(uname -m)" in
    x86_64) arch=amd64; digest=fc443008fe29a6f0b05b45d27436b7ce89e87a6836718597ccb39e41da418304 ;;
    aarch64|arm64) arch=arm64; digest=761f1d35157feb7c527cd8b13fbe428b47a9786af207a73e380630609c3d1f40 ;;
    i386|i486|i586|i686) arch=386; digest=0019c8c83efb4a1cde5aa70b830febb45edd5b9541ec232310e936938f18fad6 ;;
    armv7*) arch=armv7; digest=e7b2db8265295866d4e4f49163c23771e7b4e289d5e74d04cdacea291fd9c500 ;;
    armv6*) arch=armv6; digest=6fbe74e05c4117f1f089f94c0be166f82725e4a887d6f0d00c69502f0f53bb91 ;;
    s390x) arch=s390x; digest=1b43b91625f8cb98057ae36c2777f31e9203e69e0c26628620ba4da2a50f07fa ;;
    *) err "wgcf 暂不支持此 CPU 架构。"; return 1 ;;
  esac
  if [ -x "$dir/wgcf" ] && printf '%s  %s\n' "$digest" "$dir/wgcf" | sha256sum -c - >/dev/null 2>&1; then return 0; fi
  asset="wgcf_${version}_linux_${arch}"
  temp="$(mktemp "$dir/.wgcf.XXXXXX")" || return 1
  trap 'rm -f "$temp"' EXIT
  curl -q -fsSL --proto '=https' --connect-timeout 8 --max-time 45 \
    "https://github.com/ViRb3/wgcf/releases/download/v$version/$asset" -o "$temp" || return 1
  printf '%s  %s\n' "$digest" "$temp" | sha256sum -c - >/dev/null || return 1
  chmod 700 "$temp" && mv -f "$temp" "$dir/wgcf"
)

warp_wgcf_profile() (
  local dir="$1" account="$1/wgcf-account.toml" profile="$1/wgcf-profile.conf" tmp
  umask 077
  if [ -s "$profile" ]; then return 0; fi
  warp_download_wgcf "$dir" || { err "wgcf 下载或校验失败。"; return 1; }
  if [ ! -s "$account" ]; then
    if ! timeout 40 "$dir/wgcf" --config "$account" register --accept-tos >/dev/null 2>&1; then
      [ -s "$account" ] || { err "WARP 注册失败，请检查网络后重试。"; return 1; }
    fi
  fi
  tmp="$(mktemp "$dir/.profile.XXXXXX")" || return 1
  trap 'rm -f "$tmp"' EXIT
  if ! timeout 40 "$dir/wgcf" --config "$account" generate --profile "$tmp" >/dev/null 2>&1; then
    err "获取 WARP 连接资料失败，下次会复用已注册设备。"
    return 1
  fi
  warp_profile_endpoint "$tmp" >/dev/null || { err "WARP 连接资料无法读取。"; return 1; }
  mv -f "$tmp" "$profile"
)

warp_find_verified_wireproxy() {
  local outvar="$1" item
  while IFS= read -r item; do
    if run_with_spinner "验证 WireProxy 的 WARP 出口" warp_probe_backend "$item"; then
      printf -v "$outvar" '%s' "$item"
      return 0
    fi
  done < <(warp_wireproxy_candidates)
  return 1
}

warp_prepare_backend() {
  local outvar="$1" candidate unit dir
  if warp_find_verified_wireproxy candidate; then
    printf -v "$outvar" '%s' "$candidate"
    return 0
  fi
  unit="$(warp_wireproxy_service)" || unit=''
  if [ -n "$unit" ]; then
    local running=0
    case "$INIT_SYSTEM" in
      systemd) systemctl is-active --quiet "$unit" && running=1 ;;
      openrc) rc-service "$unit" status >/dev/null 2>&1 && running=1 ;;
    esac
    if [ "$running" -eq 0 ]; then
      ask_confirm_yes "WireProxy 已停止。启动它？输入 yes 确认: " || return 1
      run_with_spinner "启动 WireProxy" warp_start_wireproxy "$unit" || return 1
      if warp_find_verified_wireproxy candidate; then
        printf -v "$outvar" '%s' "$candidate"
        return 0
      fi
    fi
  fi
  if [ -n "$unit" ] || pgrep -x wireproxy >/dev/null 2>&1 || [ -n "$(warp_wireproxy_configs)" ]; then
    err "WireProxy 未通过 WARP 验证。请检查 SOCKS5 地址、认证和隧道后重试。"
    return 1
  fi
  if ! warp_check_core; then
    err "当前 sing-box 不支持用户态 WireGuard，请先更新内核。"
    return 1
  fi
  dir="$(dirname "$META_FILE")/warp"
  if [ ! -s "$dir/wgcf-account.toml" ] && [ ! -s "$dir/wgcf-profile.conf" ]; then
    ui_echo "首次会用 wgcf 注册。Cloudflare 条款 https://www.cloudflare.com/application/terms/"
    ask_confirm_yes "同意条款并继续？输入 yes 确认: " || return 1
  fi
  (umask 077; mkdir -p "$dir" && chmod 700 "$dir") || return 1
  run_with_spinner "准备 WARP 连接资料" with_manager_lock warp_wgcf_profile "$dir" || return 1
  candidate="$(warp_profile_endpoint "$dir/wgcf-profile.conf")" || return 1
  if ! run_with_spinner "验证 WARP 隧道" warp_probe_backend "$candidate"; then
    err "未能通过 WARP 访问 Cloudflare，已保留注册资料，可稍后重试。"
    return 1
  fi
  printf -v "$outvar" '%s' "$candidate"
}
