#!/usr/bin/env bash

set -euo pipefail

OPTIONS_PATH="${OPTIONS_PATH:-/data/options.json}"
CONFIG_PATH=/data/config.json
RUNTIME_CONFIG_PATH=/data/runtime-config.json
DEFAULT_CONFIG_PATH=/etc/transparent-smart-edge/config.default.json
SINGBOX_CONFIG_PATH=/data/singbox.json
SINGBOX_RUNTIME_PATH=/data/singbox-runtime.json

option() {
    local key="$1"
    local fallback="$2"
    local value=""
    if [[ -s "$OPTIONS_PATH" ]]; then
        value="$(jq -er --arg key "$key" '.[$key] // empty' "$OPTIONS_PATH" 2>/dev/null || true)"
    fi
    if [[ -n "$value" ]]; then
        printf '%s' "$value"
    else
        printf '%s' "$fallback"
    fi
}

require_port() {
    local name="$1"
    local value="$2"
    if [[ ! "$value" =~ ^[0-9]+$ ]] || (( value < 1 || value > 65535 )); then
        printf 'invalid %s: %s\n' "$name" "$value" >&2
        exit 2
    fi
}

DNS_LISTEN_HOST="$(option dns_listen_host 0.0.0.0)"
DNS_PORT="$(option dns_port 1053)"
DOH_PORT="$(option doh_port 18053)"
EDGE_LISTEN_HOST="$(option edge_listen_host 0.0.0.0)"
EDGE_PORT="$(option edge_port 10443)"
EDGE_IPV4="$(option edge_ipv4 192.168.2.1)"
SINGBOX_INTERNAL_PORT="$(option singbox_internal_port 13128)"
SINGBOX_OUTBOUND_TAG="$(option singbox_outbound_tag de-cdn)"
REQUIRE_SINGBOX_CONFIG="$(option require_singbox_config false)"
TELEGRAM_TPROXY_ENABLED="$(option telegram_tproxy_enabled false)"
TELEGRAM_TPROXY_PORT="$(option telegram_tproxy_port 12555)"

require_port dns_port "$DNS_PORT"
require_port doh_port "$DOH_PORT"
require_port edge_port "$EDGE_PORT"
require_port singbox_internal_port "$SINGBOX_INTERNAL_PORT"
require_port telegram_tproxy_port "$TELEGRAM_TPROXY_PORT"

if ! /usr/bin/sing-box version 2>/dev/null | grep -Fq 'sing-box version 1.13.14'; then
    printf 'bundled sing-box is not version 1.13.14\n' >&2
    exit 2
fi

singbox_enabled=0
if [[ -s "$SINGBOX_CONFIG_PATH" ]]; then
    jq --argjson enabled "$([[ "$TELEGRAM_TPROXY_ENABLED" == true ]] && echo true || echo false)" --argjson port "$TELEGRAM_TPROXY_PORT" '
      if $enabled then .inbounds += [{type:"tproxy",tag:"telegram-tproxy",listen:"0.0.0.0",listen_port:$port}] else . end' \
      "$SINGBOX_CONFIG_PATH" >"$SINGBOX_RUNTIME_PATH.tmp"
    chmod 0600 "$SINGBOX_RUNTIME_PATH.tmp"
    mv -f "$SINGBOX_RUNTIME_PATH.tmp" "$SINGBOX_RUNTIME_PATH"
    /usr/bin/validate-singbox-config.sh "$SINGBOX_RUNTIME_PATH" "$SINGBOX_INTERNAL_PORT" "$SINGBOX_OUTBOUND_TAG"
    singbox_enabled=1
elif [[ "$REQUIRE_SINGBOX_CONFIG" == true || "$DNS_PORT" == 53 || "$EDGE_PORT" == 443 ]]; then
    printf 'missing %s; refusing final-port startup without a validated transport\n' "$SINGBOX_CONFIG_PATH" >&2
    exit 2
else
    printf 'staging mode: %s is absent; DNS/TCP listeners will start without transport readiness\n' "$SINGBOX_CONFIG_PATH" >&2
fi

if [[ ! -s "$CONFIG_PATH" ]]; then
    install -m 0600 "$DEFAULT_CONFIG_PATH" "$CONFIG_PATH"
fi

# Keep the panel-rendered policy durable in /data/config.json. Listener and
# HAOS-local transport details are projected into a separate runtime file so
# restarts and staging-to-final port changes never rewrite the policy source.
jq \
    --arg dns_host "$DNS_LISTEN_HOST" \
    --argjson dns_port "$DNS_PORT" \
    --argjson doh_port "$DOH_PORT" \
    --arg edge_ipv4 "$EDGE_IPV4" \
    --argjson proxy_port "$SINGBOX_INTERNAL_PORT" \
    '.udpListen = {host: $dns_host, port: $dns_port, profile: "local"}
     | .dohListen = {host: "127.0.0.1", port: $doh_port, profile: "local"}
     | del(.dotListen, .tls, .publicDnsListen, .sync)
     | .httpProxy = {host: "127.0.0.1", port: $proxy_port, timeoutMs: 5000}
     | .edgeProfiles = (.edgeProfiles // {})
     | .edgeProfiles.local = {enabled: true, ipv4: $edge_ipv4, ttl: 60}' \
    "$CONFIG_PATH" >"$RUNTIME_CONFIG_PATH.tmp"
chmod 0600 "$RUNTIME_CONFIG_PATH.tmp"
mv -f "$RUNTIME_CONFIG_PATH.tmp" "$RUNTIME_CONFIG_PATH"

export SMART_DNS_CONFIG="$RUNTIME_CONFIG_PATH"
export LISTEN_HOST="$EDGE_LISTEN_HOST"
export LISTEN_PORT="$EDGE_PORT"
export CONNECT_PORT=443
export PROXY_HOST=127.0.0.1
export PROXY_PORT="$SINGBOX_INTERNAL_PORT"

/usr/bin/smartdns &
smartdns_pid="$!"
singbox_pid=""
if [[ "$singbox_enabled" == 1 ]]; then
    /usr/bin/sing-box run -c "$SINGBOX_RUNTIME_PATH" &
    singbox_pid="$!"
fi
/usr/bin/smart-edge &
smart_edge_pid="$!"

cleanup() {
    local pids=("$smartdns_pid" "$smart_edge_pid")
    if [[ -n "$singbox_pid" ]]; then
        pids+=("$singbox_pid")
    fi
    kill "${pids[@]}" 2>/dev/null || true
    wait "${pids[@]}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

if [[ "$TELEGRAM_TPROXY_ENABLED" == true ]]; then
    /usr/bin/telegram-tproxy-policy.sh "$TELEGRAM_TPROXY_PORT" --apply
fi

ready=0
for _ in $(seq 1 50); do
    if ! kill -0 "$smartdns_pid" 2>/dev/null || ! kill -0 "$smart_edge_pid" 2>/dev/null; then
        break
    fi
    if [[ -n "$singbox_pid" ]] && ! kill -0 "$singbox_pid" 2>/dev/null; then
        break
    fi
    if /usr/bin/healthcheck.sh; then
        ready=1
        break
    fi
    sleep 0.1
done

if [[ "$ready" != 1 ]]; then
    printf 'transparent Smart Edge listeners did not become ready\n' >&2
    exit 1
fi

set +e
child_pids=("$smartdns_pid" "$smart_edge_pid")
if [[ -n "$singbox_pid" ]]; then
    child_pids+=("$singbox_pid")
fi
wait -n "${child_pids[@]}"
status="$?"
set -e
printf 'transparent Smart Edge child exited with status %s\n' "$status" >&2
exit "$status"
