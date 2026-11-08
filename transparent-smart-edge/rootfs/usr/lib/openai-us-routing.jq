# US is a preference, not an allowlist. Expand only existing configured
# tunnel groups; actual egress country and OpenAI health determine priority.
# Direct/reject/dangling/cyclic members are never promoted into VPN exits.
def managed_inbound: (.tag // "") | startswith("openai-us-");
def managed_outbound: .tag == "openai-us-route" or .tag == "openai-us-blocked";
. as $source
| $policy[0] as $p
| if $p.schemaVersion != 2 or $p.preferredCountry != "US" or $p.fallback != "healthy-tunnel"
    or ($p.suffixes | type) != "array" or ($p.suffixes | length) == 0
    or ($p.domains | type) != "array"
    or (($p.suffixes + $p.domains) | any(.[]; type != "string" or (test("^[a-z0-9][a-z0-9.-]*[a-z0-9]$") | not)))
    or ($p.probePortBase | type) != "number" or ($p.probePortBase | floor) != $p.probePortBase
    or $p.probePortBase < 18101 or $p.probePortBase > 65000
  then error("invalid canonical OpenAI priority LAN policy") else . end
| def members($tag; $seen):
    if ($tag | type) != "string" then []
    elif ($tag | test("^[A-Za-z0-9_.-]+$") | not)
      or ($tag | startswith("openai-us-")) or ($seen | index($tag)) != null or ($seen | length) > 12
      then []
    else
      [$source.outbounds[]? | select(.tag == $tag)] as $matches
      | if ($matches | length) != 1 then [] else
          $matches[0] as $o
          | if $o.type == "urltest" or $o.type == "selector" then
              if ($o.outbounds | type) != "array" or ($o.outbounds | length) == 0 then []
              else [$o.outbounds[] | members(.; $seen + [$tag])[]] end
            elif (["vless","vmess","trojan","shadowsocks","hysteria2","tuic","wireguard"] | index($o.type)) != null
              then [$tag]
            else [] end
        end
    end;
  ["transparent-edge-http","lan-world-http","lan-us-http","lan-de-http","lan-fi-http","lan-ru-http"] as $lan
| ([$us_tag, $fi_tag, $de_tag, $world_tag] | map(members(.; [])) | add
    | reduce .[] as $member ([]; if index($member) != null then . else . + [$member] end)) as $members
| (if ($members | length) <= 32 then $members else [] end) as $pool
| .outbounds = ((.outbounds // []) | map(select(managed_outbound | not)))
| .inbounds = ((.inbounds // []) | map(select(managed_inbound | not)))
| .route.rules = ((.route.rules // []) | map(select(
    (.outbound != "openai-us-route" and .outbound != "openai-us-blocked")
    and (([.inbound[]? | select(startswith("openai-us-"))] | length) == 0)
    and ((.action == "reject" and .inbound == $lan
      and (.domain_suffix == $p.suffixes or .domain == $p.domains)) | not)
  )))
| . as $clean
| if ($pool | length) > 0 then
    [range(0; ($pool | length) + 1) | $p.probePortBase + .] as $ports
    | if any($clean.inbounds[]?; .listen_port as $port | ($ports | index($port)) != null)
      then error("OpenAI private health port collides with an existing inbound") else . end
    | .outbounds += [
        {type:"http",tag:"openai-us-blocked",server:"127.0.0.1",server_port:$p.probePortBase},
        {type:"selector",tag:"openai-us-route",outbounds:(["openai-us-blocked"] + $pool),
          default:"openai-us-blocked",interrupt_exist_connections:false}
      ]
    | .inbounds += [{type:"http",tag:"openai-us-block-in",listen:"127.0.0.1",listen_port:$p.probePortBase}]
    | .inbounds += [$pool | to_entries[] | {type:"http",tag:("openai-us-probe-" + (.key | tostring)),
        listen:"127.0.0.1",listen_port:($p.probePortBase + 1 + .key)}]
    | .route.rules = (
        [{inbound:["openai-us-block-in"],action:"reject"},
         {inbound:$lan,domain_suffix:$p.suffixes,outbound:"openai-us-route"},
         {inbound:$lan,domain:$p.domains,outbound:"openai-us-route"}]
        + [$pool | to_entries[] | {inbound:["openai-us-probe-" + (.key | tostring)],outbound:.value}]
        + .route.rules)
    | .experimental = ((.experimental // {}) + {clash_api:{external_controller:$clash_api}})
  else
    .route.rules = ([{inbound:$lan,domain_suffix:$p.suffixes,action:"reject"},
      {inbound:$lan,domain:$p.domains,action:"reject"}] + .route.rules)
  end
