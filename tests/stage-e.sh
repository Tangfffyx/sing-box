#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
for module in 00_base 01_utils 10_config 20_protocol 30_route 40_relay 42_relay_probe 50_v2ray_api 60_user_db 61_user_manager 70_export 90_protocol_menu; do
  source "lib/$module.sh"
done
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
USER_DB_FILE="$test_dir/db.json"
CONFIG_FILE="$test_dir/config.json"
META_FILE="$test_dir/meta.json"
SB_LOCK_FILE="$test_dir/lock"
user_db_min_template > "$USER_DB_FILE"
cp tests/fixtures/migration-7.0.0/config.json "$CONFIG_FILE"
cp tests/fixtures/migration-7.0.0/meta.json "$META_FILE"
orig="$(config_load)"
before="$(meta_load)"
init_manager_env() { :; }
pause() { :; }
clear() { :; }
protocol_commit_changes() {
  [ "$(jq -Sc . <<< "$1")" = "$(config_load | jq -Sc .)" ] &&
  [ "$(jq -Sc . <<< "$2")" = "$(meta_load | jq -Sc .)" ] || return 1
  printf '%s\n' "$3" > "$CONFIG_FILE"
  printf '%s\n' "$4" > "$META_FILE"
  touch "$test_dir/committed"
}

link="$(build_socks_link '2001:db8::1' 41080 'user@:/%' 'pass@:/%')"
parsed="$(relay_parse_landing_link "$link")"
jq -e '.server == "2001:db8::1" and .port == 41080 and
  .username == "user@:/%" and .password == "pass@:/%"' <<< "$parsed" >/dev/null
for invalid in 'socks5://user:p%00s@a.example:1080' 'socks5://user:%ZZ@a.example:1080' \
    'socks5://user:pass@[2001:db8::1]:65536' 'socks5://user:pass@a.example:1080/abc' \
    'socks5://user:pass@a.example:1080?udp_over_tcp=1' 'socks5://user:pass@2001:db8::1:1080'; do
  if relay_parse_landing_link "$invalid" >/dev/null; then exit 1; fi
done

relay_probe_dns() {
  local credential
  credential="$(jq -r '.password' <<< "$1")"
  [ "$credential" != wrong ] || return 1
  if [ "$2" = tcp ]; then return 0; fi
  case "${probe_scenario:-native}:$3" in
    native:false|uot:true) return 0 ;;
    *) return 1 ;;
  esac
}

# Re-entering the existing auth does not rotate its credential.
unchanged="$(relay_add_full_config "$orig" trojan-18443 "$(relay_known_landing_json "$orig" lab)")"
[ "$(jq -Sc . <<< "$orig")" = "$(jq -Sc . <<< "$unchanged")" ]
wrong_link="$(build_socks_link new.example.net 41081 new-user wrong)"
relay_update_landing_menu <<< $'1\n'"$wrong_link" >/dev/null
[ ! -e "$test_dir/committed" ]
new_link="$(build_socks_link new.example.net 41081 'new@user' 'password@:/%')"
relay_update_landing_menu <<< $'1\n'"$new_link"$'\nno' >/dev/null
[ ! -e "$test_dir/committed" ]
relay_update_landing_menu <<< $'1\n'"$new_link"$'\nyes' >/dev/null
[ -e "$test_dir/committed" ]
jq -e '
  .relay.landings.lab.server == "new.example.net" and .relay.landings.lab.port == 41081
  and .relay.landings.lab.udp_over_tcp == null and (.relay.landings|keys) == ["lab"]
' "$META_FILE" >/dev/null
jq -e --argjson before "$orig" '
  .inbounds == $before.inbounds
  and any(.outbounds[]; .tag == "out-trojan-18443-to-lab" and
    .server == "new.example.net" and .username == "new@user" and .password == "password@:/%")
' "$CONFIG_FILE" >/dev/null
mv "$test_dir/committed" "$test_dir/first"
relay_update_landing_menu <<< $'1\n'"$new_link" >/dev/null
[ ! -e "$test_dir/committed" ]

jq '.relay.landings.other={id:"other",server:"other.example.net",port:1080}
    | .relay.rules=[{name:"test",file:"test.srs",tag:"relay-geosite-test",url:"https://example.net/test.srs",landing_id:"lab"}]' \
  "$META_FILE" > "$test_dir/partial"
mv "$test_dir/partial" "$META_FILE"
probe_scenario=native relay_diagnostics_menu <<< '1' >/dev/null
[ ! -e "$test_dir/committed" ]
probe_scenario=unavailable relay_diagnostics_menu <<< '1' >/dev/null
[ ! -e "$test_dir/committed" ]
probe_scenario=uot relay_diagnostics_menu <<< $'1\nno' >/dev/null
[ ! -e "$test_dir/committed" ]
probe_scenario=uot relay_diagnostics_menu <<< $'1\nyes' >/dev/null
jq -e '.relay.landings.lab.udp_over_tcp and .relay.landings.other.udp_over_tcp == null' "$META_FILE" >/dev/null
jq -e '
  [.outbounds[] | select(.tag == "relay-lab" or .tag == "out-trojan-18443-to-lab") |
      .udp_over_tcp] == [true,true]
' "$CONFIG_FILE" >/dev/null
relay_diagnostics_menu <<< $'1\nr\nyes' >/dev/null
jq -e '.relay.landings.lab.udp_over_tcp == null' "$META_FILE" >/dev/null
jq -e 'all(.outbounds[]; .udp_over_tcp == null)' "$CONFIG_FILE" >/dev/null
echo 'PASS stage E link import, IPv6 and escape handling, update preserves credentials, scoped UDP consent'

# First-time input only requests the two connection fields when a single local entry exists.
jq '.inbounds = [.inbounds[] | select(.tag == "socks-11080")] | .outbounds=[{type:"direct",tag:"direct"}]
    | .route.rules=[]' <<< "$orig" > "$CONFIG_FILE"
printf '{}\n' > "$META_FILE"
relay_add <<< "$new_link"$'\nnew' >/dev/null
jq -e '.relay.landings.new.port == 41081 and (.relay.landings|keys) == ["new"]' "$META_FILE" >/dev/null
jq -e 'any(.inbounds[0].users[]; .username == "socks-11080-to-new")' "$CONFIG_FILE" >/dev/null
echo 'PASS stage E single local entry and minimal first-time input'
