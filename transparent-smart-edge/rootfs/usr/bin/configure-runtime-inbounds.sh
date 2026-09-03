#!/usr/bin/env bash

set -euo pipefail

source_config="${1:?usage: configure-runtime-inbounds.sh SOURCE DEST TELEGRAM_ENABLED TELEGRAM_PORT TELEGRAM_OUTBOUND LAN_US_ENABLED LAN_US_PORT LAN_US_OUTBOUND LAN_DE_ENABLED LAN_DE_PORT LAN_DE_OUTBOUND}"
destination="${2:?missing destination}"
telegram_enabled="${3:?missing telegram enabled}"
telegram_port="${4:?missing telegram port}"
telegram_outbound="${5:?missing telegram outbound}"
lan_us_enabled="${6:?missing LAN US enabled}"
lan_us_port="${7:?missing LAN US port}"
lan_us_outbound="${8:?missing LAN US outbound}"
lan_de_enabled="${9:?missing LAN DE enabled}"
lan_de_port="${10:?missing LAN DE port}"
lan_de_outbound="${11:?missing LAN DE outbound}"

jq \
  --argjson telegram_enabled "$telegram_enabled" \
  --argjson telegram_port "$telegram_port" \
  --arg telegram_outbound "$telegram_outbound" \
  --argjson lan_us_enabled "$lan_us_enabled" \
  --argjson lan_us_port "$lan_us_port" \
  --arg lan_us_outbound "$lan_us_outbound" \
  --argjson lan_de_enabled "$lan_de_enabled" \
  --argjson lan_de_port "$lan_de_port" \
  --arg lan_de_outbound "$lan_de_outbound" '
  .inbounds = ((.inbounds // []) | map(select(.tag != "telegram-tproxy" and .tag != "lan-us-http" and .tag != "lan-de-http")))
  | .route.rules = ((.route.rules // []) | map(select(
      ((.inbound // []) | index("telegram-tproxy")) == null
      and ((.inbound // []) | index("lan-us-http")) == null
      and ((.inbound // []) | index("lan-de-http")) == null
    )))
  | if $telegram_enabled then
      .inbounds += [{type:"tproxy",tag:"telegram-tproxy",listen:"0.0.0.0",listen_port:$telegram_port}]
      | .route.rules = ([{inbound:["telegram-tproxy"],outbound:$telegram_outbound}] + .route.rules)
    else . end
  | if $lan_us_enabled then
      .inbounds += [{type:"http",tag:"lan-us-http",listen:"0.0.0.0",listen_port:$lan_us_port}]
      | .route.rules = ([{inbound:["lan-us-http"],outbound:$lan_us_outbound}] + .route.rules)
    else . end
  | if $lan_de_enabled then
      .inbounds += [{type:"http",tag:"lan-de-http",listen:"0.0.0.0",listen_port:$lan_de_port}]
      | .route.rules = ([{inbound:["lan-de-http"],outbound:$lan_de_outbound}] + .route.rules)
    else . end
' "$source_config" >"$destination"
