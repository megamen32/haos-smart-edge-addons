#!/usr/bin/env bash

set -euo pipefail

config_path="${1:-/data/singbox.json}"
listen_port="${2:-13128}"
outbound_tag="${3:-de-regional}"
telegram_outbound_tag="${4:-us-regional}"
lan_us_enabled="${5:-false}"
lan_us_port="${6:-3127}"
lan_us_outbound_tag="${7:-us-regional}"
lan_de_enabled="${8:-false}"
lan_de_port="${9:-3128}"
lan_de_outbound_tag="${10:-de-regional}"
singbox_bin="${SING_BOX_BIN:-/usr/bin/sing-box}"

if [[ ! -s "$config_path" ]]; then
    printf 'missing sing-box config at %s\n' "$config_path" >&2
    exit 2
fi

if ! jq -e \
    --arg tag "$outbound_tag" \
    --arg telegram_tag "$telegram_outbound_tag" \
    --argjson port "$listen_port" \
    --argjson lan_us_enabled "$lan_us_enabled" \
    --argjson lan_us_port "$lan_us_port" \
    --arg lan_us_tag "$lan_us_outbound_tag" \
    --argjson lan_de_enabled "$lan_de_enabled" \
    --argjson lan_de_port "$lan_de_port" \
    --arg lan_de_tag "$lan_de_outbound_tag" \
    '. as $root
     | def by_tag($wanted): [$root.outbounds[]? | select(.tag == $wanted)];
     def valid_leaf:
       .type == "vless"
       and ((.server | type) == "string" and (.server | length) > 0)
       and ((.server_port | type) == "number" and .server_port > 0 and .server_port <= 65535)
       and ((.uuid | type) == "string" and (.uuid | length) > 0)
       and .tls.enabled == true
       and .tls.utls.enabled == true
       and ((.transport.type == "ws") or (.transport.type == "httpupgrade") or (.tls.reality.enabled == true));
     def valid_target($wanted):
       by_tag($wanted) as $matches
       | ($matches | length) == 1
       and ($matches[0] as $selected
         | if $selected.type == "urltest" then
             (($selected.outbounds | type) == "array" and ($selected.outbounds | length) > 0)
             and all($selected.outbounds[]; . as $member | (by_tag($member) | length) == 1 and (by_tag($member)[0] | valid_leaf))
           else ($selected | valid_leaf) end);
     ([.inbounds[]? | select(.type == "http" and .tag == "transparent-edge-http" and .listen == "127.0.0.1" and .listen_port == $port)] | length) == 1
     and valid_target($tag)
     and .route.final == $tag
     and (if $telegram_tag == "" then true else valid_target($telegram_tag) end)
     and (if $lan_us_enabled then
            valid_target($lan_us_tag)
            and ([.inbounds[]? | select(.type == "http" and .tag == "lan-us-http" and .listen == "0.0.0.0" and .listen_port == $lan_us_port)] | length) == 1
            and ([.route.rules[]? | select(.outbound == $lan_us_tag and ((.inbound // []) | index("lan-us-http")))] | length) == 1
          else ([.inbounds[]? | select(.tag == "lan-us-http")] | length) == 0 end)
     and (if $lan_de_enabled then
            valid_target($lan_de_tag)
            and ([.inbounds[]? | select(.type == "http" and .tag == "lan-de-http" and .listen == "0.0.0.0" and .listen_port == $lan_de_port)] | length) == 1
            and ([.route.rules[]? | select(.outbound == $lan_de_tag and ((.inbound // []) | index("lan-de-http")))] | length) == 1
          else ([.inbounds[]? | select(.tag == "lan-de-http")] | length) == 0 end)
     and (if ([.inbounds[]? | select(.tag == "telegram-tproxy")] | length) == 0 then true
          else ([.route.rules[]? | select(.outbound == $telegram_tag and ((.inbound // []) | index("telegram-tproxy")))] | length) == 1 end)' \
    "$config_path" >/dev/null; then
    printf 'sing-box config does not expose the required automatic transport groups and Telegram route\n' >&2
    exit 2
fi

if ! "$singbox_bin" check -c "$config_path" >/dev/null 2>&1; then
    printf 'sing-box 1.13.14 rejected the supplied transport config\n' >&2
    exit 2
fi

printf 'sing-box transport config valid: outbound=%s telegram=%s loopback_port=%s\n' "$outbound_tag" "$telegram_outbound_tag" "$listen_port"
