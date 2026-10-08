#!/usr/bin/env bash

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="$repo_dir/.test-tmp/transport-config"
importer="$repo_dir/transparent-smart-edge/rootfs/usr/bin/prepare-singbox-config.sh"
validator="$repo_dir/transparent-smart-edge/rootfs/usr/bin/validate-singbox-config.sh"
runtime_configurer="$repo_dir/transparent-smart-edge/rootfs/usr/bin/configure-runtime-inbounds.sh"

rm -rf "$work_dir"
mkdir -p "$work_dir"
trap 'rm -rf "$work_dir"' EXIT INT TERM

cat >"$work_dir/source.json" <<'JSON'
{
  "outbounds": [
    {"type":"direct","tag":"direct"},
    {"type":"vless","tag":"de-direct","server":"de.example","server_port":443,"uuid":"de-direct-uuid","tls":{"enabled":true,"utls":{"enabled":true},"reality":{"enabled":true,"public_key":"key","short_id":"id"}}},
    {"type":"vless","tag":"de-cdn","server":"de-cdn.example","server_port":443,"uuid":"de-cdn-uuid","tls":{"enabled":true,"utls":{"enabled":true}},"transport":{"type":"ws","path":"/de"}},
    {"type":"urltest","tag":"de-regional","outbounds":["de-direct","de-cdn"],"url":"https://www.gstatic.com/generate_204","interval":"10s"},
    {"type":"vless","tag":"us-reality","server":"us.example","server_port":443,"uuid":"us-reality-uuid","tls":{"enabled":true,"utls":{"enabled":true},"reality":{"enabled":true,"public_key":"key","short_id":"id"}}},
    {"type":"vless","tag":"us-cdn","server":"us-cdn.example","server_port":443,"uuid":"us-cdn-uuid","tls":{"enabled":true,"utls":{"enabled":true}},"transport":{"type":"ws","path":"/us"}},
    {"type":"urltest","tag":"us-regional","outbounds":["us-reality","us-cdn"],"url":"https://www.gstatic.com/generate_204","interval":"10s"},
    {"type":"vless","tag":"fi-helsinki","server":"fi.example","server_port":443,"uuid":"fi-uuid","flow":"xtls-rprx-vision","tls":{"enabled":true,"server_name":"www.google.com","utls":{"enabled":true,"fingerprint":"chrome"},"reality":{"enabled":true,"public_key":"key","short_id":"id"}}}
  ]
}
JSON

cat >"$work_dir/sing-box" <<'SH'
#!/bin/sh
[ "$1" = check ] && [ "$2" = -c ]
SH
chmod 0700 "$work_dir/sing-box"

SING_BOX_BIN="$work_dir/sing-box" VALIDATOR_BIN="$validator" \
  bash "$importer" "$work_dir/source.json" de-regional "$work_dir/generated.json" 23128 us-regional

jq -e '
  ([.outbounds[].tag] | sort) == (["de-cdn","de-direct","de-regional","us-cdn","us-reality","us-regional"] | sort)
  and .route.final == "de-regional"
  and ([.outbounds[] | select(.tag == "de-regional" and .type == "urltest" and (.outbounds | length) == 2)] | length) == 1
  and ([.outbounds[] | select(.tag == "us-regional" and .type == "urltest" and (.outbounds | length) == 2)] | length) == 1
' "$work_dir/generated.json" >/dev/null

# The importer bootstraps only the primary and Telegram groups; the panel
# renders the full source with every regional outbound. Add the Finland leaf
# from the source fixture so the runtime stage exercises the fi lane too.
jq --slurpfile src "$work_dir/source.json" \
  '.outbounds += ([$src[0].outbounds[] | select(.tag == "fi-helsinki" or .tag == "direct")])' \
  "$work_dir/generated.json" >"$work_dir/generated-full.json"
mv "$work_dir/generated-full.json" "$work_dir/generated.json"

printf '%s\n' '{"users":[{"username":"test-user","password":"test-password"}]}' >"$work_dir/proxy-users.json"

bash "$runtime_configurer" "$work_dir/generated.json" "$work_dir/runtime.json" true 12555 us-regional true 3127 us-regional true 3128 de-regional true 3129 fi-helsinki true 3130 direct "$work_dir/proxy-users.json" true

SING_BOX_BIN="$work_dir/sing-box" \
  bash "$validator" "$work_dir/runtime.json" 23128 de-regional us-regional true 3127 us-regional true 3128 de-regional true 3129 fi-helsinki true 3130 direct true

jq -e '
  ([.inbounds[] | select(.type == "http" and .tag == "lan-us-http" and .listen == "0.0.0.0" and .listen_port == 3127 and ((.users // []) | length) == 0)] | length) == 1
  and ([.route.rules[] | select(.outbound == "us-regional" and ((.inbound // []) | index("lan-us-http")))] | length) == 1
  and ([.inbounds[] | select(.type == "http" and .tag == "wan-us-http" and .listen_port == 13127 and (.users | length) == 1)] | length) == 1
  and ([.route.rules[] | select(.outbound == "us-regional" and ((.inbound // []) | index("wan-us-http")))] | length) == 1
  and ([.inbounds[] | select(.type == "http" and .tag == "lan-de-http" and .listen == "0.0.0.0" and .listen_port == 3128 and ((.users // []) | length) == 0)] | length) == 1
  and ([.route.rules[] | select(.outbound == "de-regional" and ((.inbound // []) | index("lan-de-http")))] | length) == 1
  and ([.inbounds[] | select(.type == "http" and .tag == "wan-de-http" and .listen_port == 13128 and (.users | length) == 1)] | length) == 1
  and ([.route.rules[] | select(.outbound == "de-regional" and ((.inbound // []) | index("wan-de-http")))] | length) == 1
  and ([.inbounds[] | select(.type == "http" and .tag == "lan-fi-http" and .listen == "0.0.0.0" and .listen_port == 3129 and ((.users // []) | length) == 0)] | length) == 1
  and ([.route.rules[] | select(.outbound == "fi-helsinki" and ((.inbound // []) | index("lan-fi-http")))] | length) == 1
  and ([.inbounds[] | select(.type == "http" and .tag == "wan-fi-http" and .listen_port == 13129 and (.users | length) == 1)] | length) == 1
  and ([.route.rules[] | select(.outbound == "fi-helsinki" and ((.inbound // []) | index("wan-fi-http")))] | length) == 1
  and ([.inbounds[] | select(.type == "http" and .tag == "lan-ru-http" and .listen == "0.0.0.0" and .listen_port == 3130 and ((.users // []) | length) == 0)] | length) == 1
  and ([.route.rules[] | select(.outbound == "direct" and ((.inbound // []) | index("lan-ru-http")))] | length) == 1
  and ([.inbounds[] | select(.type == "http" and .tag == "wan-ru-http" and .listen_port == 13130 and (.users | length) == 1)] | length) == 1
  and ([.route.rules[] | select(.outbound == "direct" and ((.inbound // []) | index("wan-ru-http")))] | length) == 1
' "$work_dir/runtime.json" >/dev/null


jq -e '
  (.outbounds[] | select(.tag == "ai-route")) as $sel
  | $sel.type == "selector"
  and ($sel.outbounds == ["fi-helsinki","de-regional","us-regional"])
  and ($sel.default == "fi-helsinki")
  and (.experimental.clash_api.external_controller == "127.0.0.1:9095")
  and ((([.outbounds[].tag] as $tags | [$sel.outbounds[] | select(. as $m | ($tags | index($m)) == null)] | length)) == 0)
' "$work_dir/runtime.json" >/dev/null

jq -e '
  (.route.rules | to_entries | map(select(.value.outbound == "ai-route")) | first | .key) as $ai
  | (.route.rules | to_entries | map(select(((.value.inbound // []) | index("lan-ru-http")) or ((.value.inbound // []) | index("wan-ru-http")))) | map(.key) | max) as $lane_max
  | (.route.rules | to_entries | map(select((.value.inbound // []) | index("telegram-tproxy"))) | first | .key) as $tg
  | $ai > $lane_max and $ai < $tg
' "$work_dir/runtime.json" >/dev/null

jq -e '([.route.rules[] | select(.outbound == "ai-route" and ((.domain_suffix // []) | index("openai.com")) and ((.domain_suffix // []) | index("anthropic.com")))] | length) == 1' "$work_dir/runtime.json" >/dev/null

bash "$runtime_configurer" "$work_dir/generated.json" "$work_dir/runtime-noai.json" true 12555 us-regional true 3127 us-regional true 3128 de-regional true 3129 fi-helsinki true 3130 direct "$work_dir/proxy-users.json" false

jq -e '
  ([.outbounds[] | select(.tag == "ai-route")] | length) == 0
  and ((.experimental.clash_api // null) == null)
  and ([.route.rules[] | select(.outbound == "ai-route")] | length) == 0
' "$work_dir/runtime-noai.json" >/dev/null

printf 'transport auto-selection contract: PASS (ai-route selector, clash api, rule order, disabled path)\n'
