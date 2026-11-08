package main

import (
	"net/http"
	"testing"
)

// The public edge and the LAN resolver are two listeners of the same process.
// Each of them answers with its own edge: the LAN alias for the local
// listener and the public alias for the public one. A single shared profile
// would hand the public alias to the LAN clients and the LAN alias to the
// Internet.
func TestDoHEdgeDependsOnTheListenerProfile(t *testing.T) {
	rt := newRuntime()
	rt.clients["client-1"] = clientCfg{ID: "client-1", Enabled: true}
	rt.proxyDomains["example.com"] = true
	rt.edgeProfiles = map[string]*smartEdge{
		"local":  {Enabled: true, IPv4: "203.0.113.1", TTL: 60},
		"public": {Enabled: true, IPv4: "185.240.120.152", TTL: 60},
	}
	currentConfig = &config{
		BaseDotName:     "dns.bezrabotnyi.com",
		DefaultClientID: "client-1",
		EdgeAuth:        edgeAuth{TTLMs: 120000},
		DoHListen:       listenCfg{Host: "0.0.0.0", Port: 18053, Profile: "local"},
		PublicDoHListen: &listenCfg{Host: "0.0.0.0", Port: 18054, Profile: "public"},
	}

	local := &dohServer{rt: rt}
	public := &dohServer{rt: rt, public: true}

	localRec := dohGet(t, local, "/dns-query/client-1", "dns.bezrabotnyi.com")
	if localRec.Code != http.StatusOK {
		t.Fatalf("local status = %d, want 200: %s", localRec.Code, localRec.Body.String())
	}
	if got := firstA(t, localRec.Body.Bytes()); got != "203.0.113.1" {
		t.Fatalf("local answer = %s, want 203.0.113.1", got)
	}

	publicRec := dohGet(t, public, "/dns-query/client-1", "dns.bezrabotnyi.com")
	if publicRec.Code != http.StatusOK {
		t.Fatalf("public status = %d, want 200: %s", publicRec.Code, publicRec.Body.String())
	}
	if got := firstA(t, publicRec.Body.Bytes()); got != "185.240.120.152" {
		t.Fatalf("public answer = %s, want 185.240.120.152", got)
	}
}

// A public listener without its own configuration still serves the public
// profile: the edge must not fall back to the LAN alias.
func TestDoHPublicProfileFallsBackToPublic(t *testing.T) {
	currentConfig = &config{
		DoHListen: listenCfg{Host: "0.0.0.0", Port: 18053, Profile: "local"},
	}
	public := &dohServer{rt: newRuntime(), public: true}
	if got := public.listenerProfile(); got != "public" {
		t.Fatalf("profile = %q, want public", got)
	}
	local := &dohServer{rt: newRuntime()}
	if got := local.listenerProfile(); got != "local" {
		t.Fatalf("profile = %q, want local", got)
	}
}
