#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
for module in 00_base 01_utils 10_config 20_protocol 30_route 35_split_rule_conflict 40_relay 50_v2ray_api 60_user_db 61_user_manager 64_warp 65_warp_backend 90_protocol_menu; do
  source "lib/$module.sh"
done
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
CONFIG_FILE="$tmp/config.json"
META_FILE="$tmp/meta.json"
USER_DB_FILE="$tmp/users.json"
SB_LOCK_FILE="$tmp/lock"
WARP_PROXY_FILE="$tmp/wireproxy.conf"
cp tests/fixtures/migration-7.0.0/config.json "$CONFIG_FILE"
cp tests/fixtures/migration-7.0.0/meta.json "$META_FILE"
user_db_min_template > "$USER_DB_FILE"
cat > "$WARP_PROXY_FILE" <<'CONF'
[http]
BindAddress = 127.0.0.1:8844
[Socks5]
BindAddress = [::1]:43210
Username = local
Password = p=a:ss
[Socks5]
BindAddress = 127.0.0.1:24442
TunnelDomains = ^www\.cloudflare\.com$
CONF

warp_wireproxy_configs() { printf '%s\n' "$WARP_PROXY_FILE"; }
ss() { printf '%s\n' 'LISTEN 0 16 [::1]:43210 [::]:* users:(("wireproxy",pid=10,fd=7))'; }
socks="$(warp_wireproxy_candidates)"
jq -e '.server=="::1" and .server_port==43210 and .network=="tcp"
  and .username=="local" and .password=="p=a:ss"' <<< "$socks" >/dev/null
unset -f ss
pause() { :; }
clear() { :; }
warp_require_singbox() { :; }
warp_validate_download() {
  printf '%s\n' "$1" >> "$tmp/downloads"
  [ "${fail_download:-0}" -eq 0 ]
}
warp_wireproxy_service() { return 1; }
warp_probe_backend() {
  printf '%s\n' "$(jq -r .type <<< "$1")" >> "$tmp/probes"
  [ "${fail_probe:-0}" -eq 0 ]
}
warp_check_core() { touch "$tmp/core-checked"; }
split_rule_confirm_relay_to_warp() { [ "${allow_takeover:-1}" -eq 1 ]; }
user_manager_config_for_edit() { config_load; }
singbox_service_active() { return 0; }

# Use the production config+meta writer and service-restart rollback.
user_manager_apply_changes() {
  _CONFIG_SKIP_USAGE_SYNC=1 config_and_meta_apply "$2" "$3"
}
sing-box() { :; }

# Keep configuration application isolated, while exercising its real rollback.
reload_or_restart_singbox_safe() {
  printf '%s\n' restart >> "$tmp/restarts"
  if [ -f "$tmp/fail-restart" ]; then rm "$tmp/fail-restart"; return 1; fi
}

relay_j="$(relay_meta_json_from_meta "$(meta_load)")"
landing="$(relay_known_landing_json "$(config_load)" lab)"
relay_j="$(relay_rule_add_meta_to_json "$relay_j" Google geosite-google.srs "$landing")"
relay_j="$(relay_rule_add_meta_to_json "$relay_j" Other geosite-example.srs "$landing")"
relay_meta_replace_in_meta_json "$(meta_load)" "$relay_j" > "$tmp/before-meta"
cp "$tmp/before-meta" "$META_FILE"
relay_project_partial_state_with_meta "$(config_load)" "$(meta_load)" > "$tmp/before-config"
cp "$tmp/before-config" "$CONFIG_FILE"

allow_takeover=0
if warp_add_preset_rules 2; then exit 1; fi
[ ! -e "$tmp/downloads" ]
cmp "$META_FILE" "$tmp/before-meta"
allow_takeover=1
fail_download=1
if warp_add_preset_rules 2; then exit 1; fi
[ ! -e "$tmp/probes" ]
fail_download=0
fail_probe=1
if warp_add_preset_rules 2; then exit 1; fi
cmp "$META_FILE" "$tmp/before-meta"
cmp "$CONFIG_FILE" "$tmp/before-config"
[ ! -e "$tmp/core-checked" ]
fail_probe=0
touch "$tmp/fail-restart"
if warp_add_preset_rules 2; then exit 1; fi
[ ! -e "$tmp/fail-restart" ]
cmp "$META_FILE" "$tmp/before-meta"
cmp "$CONFIG_FILE" "$tmp/before-config"

warp_add_preset_rules 2
jq -e 'any(.outbounds[]; .tag=="warp" and .server=="::1" and .server_port==43210)
  and any(.route.rules[]; .outbound=="warp" and (.auth_user|length)>0)
  and any(.route.rules[]; .outbound=="relay-lab")' "$CONFIG_FILE" >/dev/null
jq -e '[.relay.rules[].file] == ["geosite-example.srs"] and [.warp.rules[].file] == ["geosite-google.srs"]' "$META_FILE" >/dev/null
restarts="$(wc -l < "$tmp/restarts")"
downloads="$(wc -l < "$tmp/downloads")"
warp_add_preset_rules 2
[ "$(wc -l < "$tmp/restarts")" = "$restarts" ]
[ "$(wc -l < "$tmp/downloads")" = "$downloads" ]
[ ! -e "$tmp/core-checked" ]
fail_probe=1
warp_rules_delete_menu <<< 1
jq -e 'all(.outbounds[]; .tag!="warp") and all(.route.rules[]; .outbound!="warp")
  and any(.route.rules[]; .outbound=="relay-lab")
  and all(.route.rule_set[]; .tag!="relay-geosite-google")' "$CONFIG_FILE" >/dev/null
jq -e '.warp.mode=="off" and .warp.rules==[]' "$META_FILE" >/dev/null
test -s "$WARP_PROXY_FILE"
printf '%s\n' 'PASS stage G IPv6 authenticated WireProxy discovery, takeover, failed probe/download, rollback, idempotence and cancellation'

cat > "$tmp/wgcf-profile.conf" <<'CONF'
[Interface]
PrivateKey = EAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEA=
Address = 192.0.2.2/32
Address = 2001:db8::1/128
[Peer]
PublicKey = EAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEA=
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = engage.cloudflareclient.com:2408
CONF
endpoint="$(warp_profile_endpoint "$tmp/wgcf-profile.conf")"
jq -e '.system==false and (.address|length)==2 and
  .peers[0].address=="engage.cloudflareclient.com" and .peers[0].port==2408' <<< "$endpoint" >/dev/null
rules='[{"tag":"relay-geosite-google","file":"geosite-google.srs","url":"https://example.invalid/rules.srs"}]'
next="$(jq --argjson rules "$rules" '.warp={rules:$rules,mode:"rules"}' "$META_FILE")"
projected="$(warp_config_project_json "$(config_load)" "$rules" "$endpoint")"
route_rebuild "$projected" "$next" | jq -e '
  any(.endpoints[]; .tag=="warp" and .type=="wireguard")
  and any(.route.rules[]; .outbound=="warp")
  and any(.dns.servers[]; .tag=="sb-warp-resolver")' >/dev/null
printf '%s\n' 'PASS stage G WireGuard profile parsing, endpoint projection and route rebuild'

warp_wireproxy_configs() { :; }
pgrep() { return 1; }
ask_confirm_yes() {
  printf '%s\n' consent >> "$tmp/consent"
  return 0
}
# Simulate wgcf writing a successful registration and failing its final lookup.
warp_download_wgcf() {
  cat > "$1/wgcf" <<'WGCF'
#!/usr/bin/env bash
account="$2"
case "$3" in
  register)
    printf '%s\n' fake-account > "$account"
    printf '%s\n' register >> "${G_FIXTURE_DIR}/register"
    exit 1 ;;
  generate)
    cp "${G_FIXTURE_DIR}/wgcf-profile.conf" "$5" ;;
esac
WGCF
  chmod 700 "$1/wgcf"
}
export G_FIXTURE_DIR="$tmp"
fail_probe=1
if warp_add_preset_rules 5; then exit 1; fi
test -s "$tmp/warp/wgcf-account.toml"
test -s "$tmp/warp/wgcf-profile.conf"
jq -e '.warp.mode=="off"' "$META_FILE" >/dev/null
fail_probe=0
warp_add_preset_rules 5
[ "$(cat "$tmp/register")" = register ]
[ "$(cat "$tmp/consent")" = consent ]
jq -e 'any(.endpoints[]; .tag=="warp" and .system==false)' "$CONFIG_FILE" >/dev/null
warp_rules_delete_menu <<< 1
jq -e '(.endpoints // [] | all(.tag!="warp"))
  and (.dns.servers // [] | all(.tag!="sb-warp-resolver"))
  and (.route.rules|all(.outbound!="warp"))' "$CONFIG_FILE" >/dev/null
test -s "$tmp/warp/wgcf-account.toml"
printf '%s\n' 'PASS stage G consent, persisted registration, handshake retry and managed endpoint cancellation'
