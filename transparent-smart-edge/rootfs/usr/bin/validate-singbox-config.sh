#!/usr/bin/env bash

set -euo pipefail

config_path="${1:-/data/singbox.json}"
listen_port="${2:-13128}"
outbound_tag="${3:-de-cdn}"
singbox_bin="${SING_BOX_BIN:-/usr/bin/sing-box}"

if [[ ! -s "$config_path" ]]; then
    printf 'missing sing-box config at %s\n' "$config_path" >&2
    exit 2
fi

if ! jq -e \
    --arg tag "$outbound_tag" \
    --argjson port "$listen_port" \
    '([.inbounds[]? | select(
        .type == "http"
        and .tag == "transparent-edge-http"
        and .listen == "127.0.0.1"
        and .listen_port == $port
      )] | length) == 1
     and ([.outbounds[]? | select(
        .tag == $tag
        and .type == "vless"
        and ((.server | type) == "string" and (.server | length) > 0)
        and ((.server_port | type) == "number" and .server_port > 0 and .server_port <= 65535)
        and ((.uuid | type) == "string" and (.uuid | length) > 0)
        and .tls.enabled == true
        and .tls.utls.enabled == true
        and .transport.type == "ws"
      )] | length) == 1
     and .route.final == $tag' \
    "$config_path" >/dev/null; then
    printf 'sing-box config does not expose the required loopback HTTP to VLESS/TLS/uTLS/WebSocket path\n' >&2
    exit 2
fi

if ! "$singbox_bin" check -c "$config_path" >/dev/null 2>&1; then
    printf 'sing-box 1.13.14 rejected the supplied transport config\n' >&2
    exit 2
fi

printf 'sing-box transport config valid: outbound=%s loopback_port=%s\n' "$outbound_tag" "$listen_port"
