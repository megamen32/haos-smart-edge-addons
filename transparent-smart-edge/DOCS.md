# Transparent Smart Edge

This app combines the VPN Panel SmartDNS resolver, transparent TLS edge, and a
pinned sing-box `1.13.14` binary in one Home Assistant OS container.

The repository and published image contain no transport credentials. Before
switching from staging ports to final ports, place a validated sing-box config
at `/data/singbox.json`. The supplied importer and validator keep that file at
mode `0600` and require the configured VLESS outbound tag.

The default options use staging ports `1053` and `10443`. The active
Bezrabotnyi topology uses DNS port `53`, edge port `443`, router address
`192.168.2.1`, and HAOS address `192.168.2.101`. Do not select final ports until
the old listeners are stopped and `/data/singbox.json` validates.

## LAN proxy lanes

The add-on publishes one HTTP proxy per outbound lane on the LAN side. Each
lane has an enable flag, a port, and an outbound tag:

| Lane | Options | Port | Outbound tag |
| --- | --- | --- | --- |
| World | `lan_world_proxy_*` | 3125 | `world-auto` |
| Finland | `lan_fi_proxy_*` | 3126 | `fi-helsinki` |
| United States | `lan_us_proxy_*` | 3127 | `us-regional` |
| Germany | `lan_de_proxy_*` | 3128 | `de-regional` |
| Russia | `lan_ru_proxy_*` | 3130 | `direct` |

A lane is published only while its `*_proxy_enabled` option is true. The
sing-box internal listener stays on `23128` and is not a LAN lane.

Runtime policy and credentials remain in the app data volume and are included
in app backups; they are never downloaded from GitHub.

