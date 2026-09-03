#!/usr/bin/env bash

set -euo pipefail

source_config="${1:?usage: configure-runtime-inbounds.sh SOURCE DEST TELEGRAM_ENABLED TELEGRAM_PORT TELEGRAM_OUTBOUND LAN_US_ENABLED LAN_US_PORT LAN_US_OUTBOUND}"
destination="${2:?missing destination}"
telegram_enabled="${3:?missing telegram enabled}"
telegram_port="${4:?missing telegram port}"
telegram_outbound="${5:?missing telegram outbound}"
lan_us_enabled="${6:?missing LAN US enabled}"
lan_us_port="${7:?missing LAN US port}"
lan_us_outbound="${8:?missing LAN US outbound}"

jq \
  --argjson telegram_enabled "$telegram_enabled" \
  --argjson telegram_port "$telegram_port" \
  --arg telegram_outbound "$telegram_outbound" \
  --argjson lan_us_enabled "$lan_us_enabled" \
  --argjson lan_us_port "$lan_us_port" \
  --arg lan_us_outbound "$lan_us_outbound" '
  .inbounds = ((.inbounds // []) | map(select(.tag != "telegram-tproxy" and .tag != "lan-us-http")))
  | .route.rules = ((.route.rules // []) | map(select(
      ((.inbound // []) | index("telegram-tproxy")) == null
      and ((.inbound // []) | index("lan-us-http")) == null
    )))
  | if $telegram_enabled then
      .inbounds += [{type:"tproxy",tag:"telegram-tproxy",listen:"0.0.0.0",listen_port:$telegram_port}]
      | .route.rules = ([{inbound:["telegram-tproxy"],outbound:$telegram_outbound}] + .route.rules)
    else . end
  | if $lan_us_enabled then
      .inbounds += [{type:"http",tag:"lan-us-http",listen:"0.0.0.0",listen_port:$lan_us_port}]
      | .route.rules = ([{inbound:["lan-us-http"],outbound:$lan_us_outbound}] + .route.rules)
    else . end
' "$source_config" >"$destination"

