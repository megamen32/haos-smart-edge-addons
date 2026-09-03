#!/usr/bin/env bash

set -euo pipefail

OPTIONS_PATH="${OPTIONS_PATH:-/data/options.json}"

option() {
    local key="$1"
    local fallback="$2"
    local value=""
    if [[ -s "$OPTIONS_PATH" ]]; then
        value="$(jq -er --arg key "$key" '.[$key] // empty' "$OPTIONS_PATH" 2>/dev/null || true)"
    fi
    [[ -n "$value" ]] && printf '%s' "$value" || printf '%s' "$fallback"
}

dns_port="$(option dns_port 1053)"
edge_port="$(option edge_port 10443)"
singbox_port="$(option singbox_internal_port 13128)"
lan_us_enabled="$(option lan_us_proxy_enabled true)"
lan_us_port="$(option lan_us_proxy_port 3127)"
require_singbox_config="$(option require_singbox_config false)"
singbox_config=/data/singbox.json

# SmartDNS serves both UDP and TCP on the configured LAN DNS port. The TCP
# probes below are connection-only, so they prove listener ownership without
# making upstream internet health part of the container health decision.
nc -z -w 2 127.0.0.1 "$dns_port"
nc -z -w 2 127.0.0.1 "$edge_port"

if [[ -s "$singbox_config" ]]; then
    nc -z -w 2 127.0.0.1 "$singbox_port"
    if [[ "$lan_us_enabled" == true ]]; then
        nc -z -w 2 127.0.0.1 "$lan_us_port"
    fi
elif [[ "$require_singbox_config" == true || "$dns_port" == 53 || "$edge_port" == 443 ]]; then
    printf 'sing-box transport is not configured\n' >&2
    exit 1
else
    printf 'staging-no-transport\n'
fi
