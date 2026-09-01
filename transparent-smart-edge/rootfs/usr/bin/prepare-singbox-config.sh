#!/usr/bin/env bash

set -euo pipefail

source_config="${1:?usage: prepare-singbox-config.sh SOURCE_CONFIG [OUTBOUND_TAG] [DESTINATION] [LOOPBACK_PORT]}"
outbound_tag="${2:-de-cdn}"
destination="${3:-/data/singbox.json}"
listen_port="${4:-13128}"
validator="${VALIDATOR_BIN:-/usr/bin/validate-singbox-config.sh}"

if [[ ! -s "$source_config" ]]; then
    printf 'missing source sing-box config at %s\n' "$source_config" >&2
    exit 2
fi

umask 077
tmp="${destination}.tmp.$$"
cleanup() {
    rm -f "$tmp"
}
trap cleanup EXIT INT TERM

# Extract exactly one already-working outbound. Credentials remain only in the
# source and the mode-0600 destination; neither jq nor this script prints them.
if ! jq -e \
    --arg tag "$outbound_tag" \
    --argjson port "$listen_port" \
    '([.outbounds[]? | select(
        .tag == $tag
        and .type == "vless"
        and .tls.enabled == true
        and .tls.utls.enabled == true
        and .transport.type == "ws"
      )]) as $matches
     | select(($matches | length) == 1)
     | $matches[0] as $outbound
     | {
         log: {level: "info", timestamp: true},
         inbounds: [{
           type: "http",
           tag: "transparent-edge-http",
           listen: "127.0.0.1",
           listen_port: $port
         }],
         outbounds: [$outbound],
         route: {final: $tag}
       }' \
    "$source_config" >"$tmp"; then
    printf 'source config has no unique VLESS/TLS/uTLS/WebSocket outbound tagged %s\n' "$outbound_tag" >&2
    exit 2
fi

chmod 0600 "$tmp"
"$validator" "$tmp" "$listen_port" "$outbound_tag"
mv -f "$tmp" "$destination"
trap - EXIT INT TERM
printf 'sing-box transport installed at %s using outbound %s\n' "$destination" "$outbound_tag"
