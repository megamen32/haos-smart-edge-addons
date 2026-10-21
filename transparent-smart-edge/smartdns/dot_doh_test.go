package main

import (
	"bytes"
	"encoding/base64"
	"encoding/binary"
	"net/http"
	"net/http/httptest"
	"testing"
)

// RFC 7858 carries the DNS message as-is over TLS. The listener used to
// require a length-prefixed frame, which closed the connection for every
// standard DoT client.
func TestNextDoTFrameAcceptsPlainDNSMessage(t *testing.T) {
	query := dnsAQuery("example.com", 0x1234)
	frame, rest, framed, needMore, ok := nextDoTFrame(query)
	if !ok {
		t.Fatal("plain DoT message rejected")
	}
	if needMore {
		t.Fatal("plain DoT message reported as incomplete")
	}
	if framed {
		t.Fatal("plain DoT message reported as length-prefixed")
	}
	if !bytes.Equal(frame, query) {
		t.Fatalf("frame = %d bytes, want the whole query (%d)", len(frame), len(query))
	}
	if len(rest) != 0 {
		t.Fatalf("rest = %d bytes, want 0", len(rest))
	}
}

func TestNextDoTFrameAcceptsLengthPrefixedFrame(t *testing.T) {
	query := dnsAQuery("example.com", 0x1234)
	framed := make([]byte, 2+len(query))
	binary.BigEndian.PutUint16(framed[0:2], uint16(len(query)))
	copy(framed[2:], query)

	frame, rest, isFramed, needMore, ok := nextDoTFrame(framed)
	if !ok {
		t.Fatal("length-prefixed frame rejected")
	}
	if needMore {
		t.Fatal("complete frame reported as incomplete")
	}
	if !isFramed {
		t.Fatal("length-prefixed frame not detected")
	}
	if !bytes.Equal(frame, query) {
		t.Fatal("frame payload does not match the query")
	}
	if len(rest) != 0 {
		t.Fatalf("rest = %d bytes, want 0", len(rest))
	}
}

func TestNextDoTFrameSplitsPipelinedQueries(t *testing.T) {
	first := dnsAQuery("example.com", 0x1111)
	second := dnsAQuery("example.org", 0x2222)
	stream := append(append([]byte{}, first...), second...)

	frame, rest, framed, needMore, ok := nextDoTFrame(stream)
	if !ok || needMore {
		t.Fatalf("pipelined query rejected: ok=%v needMore=%v", ok, needMore)
	}
	if framed {
		t.Fatal("pipelined plain query reported as length-prefixed")
	}
	if !bytes.Equal(frame, first) {
		t.Fatal("first pipelined query does not match")
	}
	frame, _, _, needMore, ok = nextDoTFrame(rest)
	if !ok || needMore {
		t.Fatalf("second pipelined query rejected: ok=%v needMore=%v", ok, needMore)
	}
	if !bytes.Equal(frame, second) {
		t.Fatal("second pipelined query does not match")
	}
}

func TestNextDoTFrameNeedsMoreBytesForPartialMessage(t *testing.T) {
	query := dnsAQuery("example.com", 0x1234)
	_, _, _, needMore, ok := nextDoTFrame(query[:10])
	if !ok {
		t.Fatal("partial message rejected")
	}
	if !needMore {
		t.Fatal("partial message did not request more bytes")
	}
}

func TestNextDoTFrameRejectsGarbage(t *testing.T) {
	garbage := make([]byte, 32)
	for i := range garbage {
		garbage[i] = 0xff
	}
	_, _, _, needMore, ok := nextDoTFrame(garbage)
	if ok {
		t.Fatal("garbage accepted as a DNS frame")
	}
	if needMore {
		t.Fatal("garbage should not ask for more bytes")
	}
}

func TestNextDoTFrameAcceptsEDNSQuery(t *testing.T) {
	query := dnsAQuery("example.com", 0x1234)
	// An EDNS0 OPT record in the additional section.
	opt := make([]byte, 11)
	opt[0] = 0
	binary.BigEndian.PutUint16(opt[1:3], 41) // OPT
	binary.BigEndian.PutUint16(opt[3:5], 4096)
	binary.BigEndian.PutUint32(opt[5:9], 0)
	binary.BigEndian.PutUint16(opt[9:11], 0)
	query = append(query, opt...)
	binary.BigEndian.PutUint16(query[10:12], 1) // arcount

	frame, rest, framed, needMore, ok := nextDoTFrame(query)
	if !ok || needMore {
		t.Fatalf("EDNS query rejected: ok=%v needMore=%v", ok, needMore)
	}
	if framed {
		t.Fatal("EDNS query reported as length-prefixed")
	}
	if !bytes.Equal(frame, query) {
		t.Fatal("EDNS frame does not match the query")
	}
	if len(rest) != 0 {
		t.Fatalf("rest = %d bytes, want 0", len(rest))
	}
}

func dohTestRuntime(t *testing.T, clientID, answer string) *runtime {
	t.Helper()
	rt := newRuntime()
	rt.staticA = map[string][]string{"example.com": {answer}}
	rt.clients[clientID] = clientCfg{ID: clientID, Enabled: true}
	currentConfig = &config{
		BaseDotName:     "dns.bezrabotnyi.com",
		DefaultClientID: clientID,
		EdgeAuth:        edgeAuth{TTLMs: 120000},
	}
	return rt
}

func dohGet(t *testing.T, handler *dohServer, target, host string) *httptest.ResponseRecorder {
	t.Helper()
	query := dnsAQuery("example.com", 0x4321)
	encoded := base64.RawURLEncoding.EncodeToString(query)
	req := httptest.NewRequest(http.MethodGet, target+"?dns="+encoded, nil)
	req.Host = host
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	return rec
}

// The host form carries the client identity in the host name, the same way
// the DoT listener reads it from SNI.
func TestDoHHostFormTakesClientFromHostHeader(t *testing.T) {
	rt := dohTestRuntime(t, "client-1", "203.0.113.9")
	handler := &dohServer{rt: rt}

	rec := dohGet(t, handler, "/dns-query", "client-1.dns.bezrabotnyi.com")
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", rec.Code, rec.Body.String())
	}
	if got := firstA(t, rec.Body.Bytes()); got != "203.0.113.9" {
		t.Fatalf("answer = %s, want 203.0.113.9", got)
	}
}

func TestDoHBaseHostUsesDefaultClient(t *testing.T) {
	rt := dohTestRuntime(t, "default-client", "203.0.113.10")
	handler := &dohServer{rt: rt}

	rec := dohGet(t, handler, "/dns-query", "dns.bezrabotnyi.com")
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", rec.Code, rec.Body.String())
	}
	if got := firstA(t, rec.Body.Bytes()); got != "203.0.113.10" {
		t.Fatalf("answer = %s, want 203.0.113.10", got)
	}
}

func TestDoHPathFormStillResolvesTheClient(t *testing.T) {
	rt := dohTestRuntime(t, "client-1", "203.0.113.11")
	handler := &dohServer{rt: rt}

	rec := dohGet(t, handler, "/dns-query/client-1", "dns.bezrabotnyi.com")
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", rec.Code, rec.Body.String())
	}
	if got := firstA(t, rec.Body.Bytes()); got != "203.0.113.11" {
		t.Fatalf("answer = %s, want 203.0.113.11", got)
	}
}

func TestDoHRefusesForeignHost(t *testing.T) {
	rt := dohTestRuntime(t, "client-1", "203.0.113.12")
	handler := &dohServer{rt: rt}

	rec := dohGet(t, handler, "/dns-query", "evil.example.com")
	if rec.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403: %s", rec.Code, rec.Body.String())
	}
}

func TestDoHRefusesUnknownClientHost(t *testing.T) {
	rt := dohTestRuntime(t, "client-1", "203.0.113.13")
	handler := &dohServer{rt: rt}

	rec := dohGet(t, handler, "/dns-query", "someone-else.dns.bezrabotnyi.com")
	if rec.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403: %s", rec.Code, rec.Body.String())
	}
}
