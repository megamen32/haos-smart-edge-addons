# Original assignment
Investigate and repair VPN degradation, check live health, and restore daily rooted Android4G endpoint exits. User clarified the failure is at home through SmartDNS and explicitly requested ONE autoheal rather than manual route switching.
Native session: codex01a13c19-2363-7fa2-b21f-c828c2f08877. Root task: /home/roomhacker/apps/vpn-panel/.agents/tasks/20261014-vpn-health.md.
Owned boundary: existing route-health controller, runtime selector projection, native health helper, release packaging/tests/docs in this canonical app repository. Preserve foreign workloads, phone gateway, private transport data and old results.
Acceptance: actual home native Telegram and AI traffic, controlled automatic failover, one route-health process, healthy connection retention, published source/release.
Current plan: .planning/phases/01-automatic-route-recovery/01-PLAN.md; .planning/STATE.md.
Budget: source Go test/build one worker, GOMAXPROCS2/go-p1, GOMEMLIMIT768MiB, expected120s/emergency1200s, generated temp512MiB. Existing inherited CPU4/tasks1536/UID hard bounds remain. Native probe3 lanes with2 DCs each, deadline3s, two sockets per process, no unbounded worker pool. Existing HAOS container budget must be checked before live install; reuse it, no limits raised.
