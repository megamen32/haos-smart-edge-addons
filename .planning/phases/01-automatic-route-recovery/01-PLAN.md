---
phase: 01-automatic-route-recovery
plan: 01
type: execute
wave: 1
depends_on: []
autonomous: true
requirements: [HEAL-01, HEAL-02, HEAL-03]
---

<objective>Extend the existing HAOS route-health controller to verify native Telegram and heal its selector, without manual pins or restarting a healthy stack for an upstream outage.</objective>
<tasks>
<task type="auto"><name>Native probe and controller</name><action>Add a bounded req_pq_multi/resPQ helper; project Telegram selector and extend existing loop, preserve connections and healthy lanes.</action><verify>Focused unit/integration scenarios catch TCP-only false health, automatic failure recovery and all-upstream-failure restart loops.</verify><done>One controller makes measured route decisions.</done></task>
<task type="auto"><name>Deliver and prove home recovery</name><action>Publish owned main changes and image; preserve private runtime data; validate and install on active Store app; perform controlled route failure and native home/AI canaries.</action><verify>Real home native responses and AI HTTPS/stream stay usable; selected bad route changes automatically; one controller PID.</verify><done>Requested automatic consumer recovery is demonstrated and daily phone results are retained by vpn-panel.</done></task>
</tasks>
