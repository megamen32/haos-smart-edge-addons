# Bezrabotnyi HAOS Apps

Home Assistant app repository for the transparent SmartDNS and sing-box edge
used by the Bezrabotnyi network.

[![Add app repository to Home Assistant](https://my.home-assistant.io/badges/supervisor_add_addon_repository.svg)](https://my.home-assistant.io/redirect/supervisor_add_addon_repository/?repository_url=https%3A%2F%2Fgithub.com%2Fmegamen32%2Fhaos-smart-edge-addons)

Manual repository URL:

```text
https://github.com/megamen32/haos-smart-edge-addons
```

## Apps

### Transparent Smart Edge

Runs SmartDNS, a transparent TLS edge, and a pinned sing-box transport in one
Supervisor-managed container. Runtime transport credentials are not stored in
this repository or its container image.

Images are built automatically on every push to `main` with the official Home
Assistant builder actions and published to GitHub Container Registry.

