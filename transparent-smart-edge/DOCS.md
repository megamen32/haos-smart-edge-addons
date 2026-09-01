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

Runtime policy and credentials remain in the app data volume and are included
in app backups; they are never downloaded from GitHub.

