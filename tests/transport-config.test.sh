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
    {"type":"urltest","tag":"us-regional","outbounds":["us-reality","us-cdn"],"url":"https://www.gstatic.com/generate_204","interval":"10s"}
  ]
}
JSON

cat >"$work_dir/sing-box" <<'SH'
#!/bin/sh
[ "$1" = check ] && [ "$2" = -c ]
SH
chmod 0700 "$work_dir/sing-box"

SING_BOX_BIN="$work_dir/sing-box" VALIDATOR_BIN="$validator" \
  bash "$importer" "$work_dir/source.json" de-regional "$work_dir/generated.json" 13128 us-regional

jq -e '
  ([.outbounds[].tag] | sort) == (["de-cdn","de-direct","de-regional","us-cdn","us-reality","us-regional"] | sort)
  and .route.final == "de-regional"
  and ([.outbounds[] | select(.tag == "de-regional" and .type == "urltest" and (.outbounds | length) == 2)] | length) == 1
  and ([.outbounds[] | select(.tag == "us-regional" and .type == "urltest" and (.outbounds | length) == 2)] | length) == 1
' "$work_dir/generated.json" >/dev/null

bash "$runtime_configurer" "$work_dir/generated.json" "$work_dir/runtime.json" true 12555 us-regional true 3127 us-regional

SING_BOX_BIN="$work_dir/sing-box" \
  bash "$validator" "$work_dir/runtime.json" 13128 de-regional us-regional true 3127 us-regional

jq -e '
  ([.inbounds[] | select(.type == "http" and .tag == "lan-us-http" and .listen == "0.0.0.0" and .listen_port == 3127)] | length) == 1
  and ([.route.rules[] | select(.outbound == "us-regional" and ((.inbound // []) | index("lan-us-http")))] | length) == 1
' "$work_dir/runtime.json" >/dev/null

printf 'transport auto-selection contract: PASS\n'
