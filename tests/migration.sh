#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source lib/10_config.sh
source lib/30_route.sh
c='{"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"},{"type":"socks","tag":"proxy","server":"127.0.0.1","server_port":1080},{"type":"block","tag":"reject"}],"route":{"final":"reject","rules":[{"port":25,"outbound":"reject"}],"rule_set":[{"type":"remote","tag":"direct-rules","url":"https://example.com/rules.json","download_detour":"direct"},{"type":"remote","tag":"proxy-rules","url":"https://example.com/rules.json","download_detour":"proxy"}]}}'
out=$(config_normalize "$c")
echo "$out" | jq -e '.route.rules == [{port:25,action:"reject"},{action:"reject"}] and .route.final == null and ([.outbounds[].type]|index("block")) == null and .route.rule_set[0].http_client == {version:2} and .route.rule_set[1].http_client.detour == "proxy" and ([.route.rule_set[]|has("download_detour")]|any|not)' >/dev/null
[ "$(echo "$out"|jq -Sc .)" = "$(config_normalize "$out"|jq -Sc .)" ]
custom=$(echo "$c"|jq '.outbounds[0].bind_interface="eth0"')
config_normalize "$custom"|jq -e '.route.rule_set[0].http_client.detour == "direct"' >/dev/null
custom=$(echo "$c"|jq '.route.rule_set[0].http_client={version:1,headers:{"X-Test":"kept"}}')
config_normalize "$custom"|jq -e '.route.rule_set[0].http_client.headers["X-Test"] == "kept"' >/dev/null
config_port_in_use_by_layer '{"inbounds":[{"type":"shadowsocks","listen_port":443}]}' 443 udp
config_port_in_use_by_layer '{"inbounds":[{"type":"shadowsocks","listen_port":443}]}' 443 tcp
! config_port_in_use_by_layer '{"inbounds":[{"type":"shadowsocks","network":"tcp","listen_port":443}]}' 443 udp
! config_port_in_use_by_layer '{"inbounds":[{"type":"tuic","tag":"excluded","listen_port":443}]}' 443 udp excluded
printf 'PASS 1.14 migration, custom download settings, idempotence and TCP/UDP conflicts\n'
