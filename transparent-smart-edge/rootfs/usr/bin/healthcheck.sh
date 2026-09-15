#!/usr/bin/env bash

set -euo pipefail

OPTIONS_PATH="${OPTIONS_PATH:-/data/options.json}"

# shellcheck source=/dev/null
source /usr/lib/transparent-smart-edge-options.sh

dns_port="$(option dns_port 1053)"
edge_port="$(option edge_port 10443)"
singbox_port="$(option singbox_internal_port 13128)"
lan_us_enabled="$(option lan_us_proxy_enabled true)"
lan_us_port="$(option lan_us_proxy_port 3127)"
lan_de_enabled="$(option lan_de_proxy_enabled true)"
lan_de_port="$(option lan_de_proxy_port 3128)"
lan_fi_enabled="$(option lan_fi_proxy_enabled true)"
lan_fi_port="$(option lan_fi_proxy_port 3129)"
lan_ru_enabled="$(option lan_ru_proxy_enabled true)"
lan_ru_port="$(option lan_ru_proxy_port 3130)"
require_singbox_config="$(option require_singbox_config false)"
singbox_config=/data/singbox.json
proxy_users_required=false
for proxy_enabled in "$lan_us_enabled" "$lan_de_enabled" "$lan_fi_enabled" "$lan_ru_enabled"; do
    if [[ "$proxy_enabled" == true ]]; then
        proxy_users_required=true
        break
    fi
done

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
    if [[ "$lan_de_enabled" == true ]]; then
        nc -z -w 2 127.0.0.1 "$lan_de_port"
    fi
    if [[ "$lan_fi_enabled" == true ]]; then
        nc -z -w 2 127.0.0.1 "$lan_fi_port"
    fi
    if [[ "$lan_ru_enabled" == true ]]; then
        nc -z -w 2 127.0.0.1 "$lan_ru_port"
    fi
    if [[ "$proxy_users_required" == true ]]; then
        [[ -s /data/proxy-users.json ]] || { printf 'missing required proxy auth file\n' >&2; exit 1; }
        jq -e '(.users | type == "array") and (.users | length > 0) and all(.users[]?; (.username | type == "string" and length > 0) and (.password | type == "string" and length > 0))' /data/proxy-users.json >/dev/null
        jq -e \
          --argjson us "$lan_us_enabled" \
          --argjson de "$lan_de_enabled" \
          --argjson fi "$lan_fi_enabled" \
          --argjson ru "$lan_ru_enabled" '
          def authed($tag): ([.inbounds[]? | select(.tag == $tag and (.users | type == "array") and (.users | length > 0))] | length) == 1;
          (if $us then authed("lan-us-http") else true end)
          and (if $de then authed("lan-de-http") else true end)
          and (if $fi then authed("lan-fi-http") else true end)
          and (if $ru then authed("lan-ru-http") else true end)
        ' /data/singbox-runtime.json >/dev/null
    fi
elif [[ "$require_singbox_config" == true || "$dns_port" == 53 || "$edge_port" == 443 ]]; then
    printf 'sing-box transport is not configured\n' >&2
    exit 1
else
    printf 'staging-no-transport\n'
fi
