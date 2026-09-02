# Transparent Smart Edge add-on

This local HAOS add-on runs the existing VPN Panel `smartdns-go` resolver,
Smart Edge, and a pinned statically linked sing-box `1.13.14` together.
SmartDNS selects configured domains and synthesizes the router LAN address;
the TCP edge reads TLS SNI and opens an HTTP `CONNECT` tunnel through the
add-on's loopback-only sing-box listener.

`/data/config.json` is the durable, panel-rendered SmartDNS policy. On first
boot only, a direct-only safe default is created there. Each start writes
listener/proxy overrides to `/data/runtime-config.json` without modifying the
durable policy.

The transport is intentionally not bundled: `/data/singbox.json` must contain
the real VLESS/TLS/uTLS/WebSocket outbound. To import the already-working
the existing DE and US `urltest` groups from a server-44 config without
printing their credentials:

```bash
/usr/bin/prepare-singbox-config.sh /data/server44-source.json de-regional /data/singbox.json 13128 us-regional
```

The importer writes mode `0600` and runs `sing-box check` before replacing the
destination. With the default staging ports, an absent file produces an
explicit `staging-no-transport` health state while DNS/edge listeners remain
testable. `require_singbox_config: true`, DNS port `53`, or edge port `443`
turns absence into a startup/health failure.

The shipped options use staging ports `1053` and `10443`. The default
`edge_ipv4` remains `192.168.2.1`, so clients keep connecting to the router.
After AdGuard and
Nginx Proxy Manager release their listeners, change `dns_port` to `53` and
`edge_port` to `443`. The router can then keep advertising `192.168.2.1` for
DNS and statically forward DNS/TCP edge traffic to `192.168.2.101`.
