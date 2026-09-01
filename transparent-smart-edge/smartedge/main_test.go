package main

import (
	"context"
	"crypto/tls"
	"errors"
	"net"
	"testing"
	"time"
)

func TestParseSNIRejectsTruncatedRecordsWithoutPanic(t *testing.T) {
	cases := [][]byte{
		{0x16, 0x03, 0x01, 0x00, 0x00},
		{0x16, 0x03, 0x01, 0x00, 0x01, 0x01},
		{0x16, 0x03, 0x01, 0x00, 0x04, 0x01, 0x00, 0x00, 0x00},
	}
	for _, record := range cases {
		func() {
			defer func() {
				if recovered := recover(); recovered != nil {
					t.Fatalf("parseSNI panicked for %x: %v", record, recovered)
				}
			}()
			if got := parseSNI(record); got != "" {
				t.Fatalf("parseSNI(%x) = %q, want empty", record, got)
			}
		}()
	}
}

func TestParseSNIReadsARealClientHello(t *testing.T) {
	client, server := net.Pipe()
	defer client.Close()
	defer server.Close()
	tlsClient := tls.Client(client, &tls.Config{ServerName: "example.com", InsecureSkipVerify: true})
	go func() { _ = tlsClient.Handshake() }()
	_ = server.SetReadDeadline(time.Now().Add(time.Second))
	buf := make([]byte, readHelloMax)
	n, err := server.Read(buf)
	if err != nil {
		t.Fatal(err)
	}
	if got := parseSNI(buf[:n]); got != "example.com" {
		t.Fatalf("parseSNI(real ClientHello) = %q, want example.com", got)
	}
}

func TestResolveCachesSuccessfulIPv4Lookup(t *testing.T) {
	oldLookup := lookupIPv4
	oldTTL := dnsCacheTTL
	defer func() {
		lookupIPv4 = oldLookup
		dnsCacheTTL = oldTTL
		resolveMu.Lock()
		resolveCache = map[string]dnsCacheEntry{}
		resolveCalls = map[string]*dnsInflight{}
		resolveMu.Unlock()
	}()
	resolveMu.Lock()
	resolveCache = map[string]dnsCacheEntry{}
	resolveCalls = map[string]*dnsInflight{}
	resolveMu.Unlock()
	dnsCacheTTL = time.Minute
	lookups := 0
	lookupIPv4 = func(context.Context, string) ([]net.IP, error) {
		lookups++
		return []net.IP{net.IPv4(192, 0, 2, 10)}, nil
	}
	for i := 0; i < 3; i++ {
		ip, err := resolve("cache.example")
		if err != nil {
			t.Fatal(err)
		}
		if got := ip.String(); got != "192.0.2.10" {
			t.Fatalf("resolve = %s", got)
		}
	}
	if lookups != 1 {
		t.Fatalf("lookups = %d, want 1", lookups)
	}
}

func TestResolveCacheHitIsNotBlockedByAnotherHostnameLookup(t *testing.T) {
	oldLookup := lookupIPv4
	defer func() { lookupIPv4 = oldLookup }()
	resolveMu.Lock()
	resolveCache = map[string]dnsCacheEntry{
		"fast.example": {ip: net.IPv4(192, 0, 2, 20), expires: time.Now().Add(time.Minute)},
	}
	resolveCalls = map[string]*dnsInflight{}
	resolveMu.Unlock()
	started := make(chan struct{})
	release := make(chan struct{})
	lookupIPv4 = func(context.Context, string) ([]net.IP, error) {
		close(started)
		<-release
		return []net.IP{net.IPv4(192, 0, 2, 21)}, nil
	}
	done := make(chan struct{})
	go func() {
		_, _ = resolve("slow.example")
		close(done)
	}()
	<-started
	before := time.Now()
	ip, err := resolve("fast.example")
	if err != nil || ip.String() != "192.0.2.20" {
		t.Fatalf("fast cache hit = %v, %v", ip, err)
	}
	if elapsed := time.Since(before); elapsed > 100*time.Millisecond {
		t.Fatalf("cache hit blocked for %s", elapsed)
	}
	close(release)
	<-done
}

func TestConnectRetryInvalidatesCachedAddressAfterDialFailure(t *testing.T) {
	oldLookup := lookupIPv4
	oldDial := dialTCP
	oldPort := connectPort
	oldProxyHost := proxyHost
	defer func() {
		lookupIPv4 = oldLookup
		dialTCP = oldDial
		connectPort = oldPort
		proxyHost = oldProxyHost
	}()
	proxyHost = ""
	resolveMu.Lock()
	resolveCache = map[string]dnsCacheEntry{}
	resolveCalls = map[string]*dnsInflight{}
	resolveMu.Unlock()
	lookups := 0
	lookupIPv4 = func(context.Context, string) ([]net.IP, error) {
		lookups++
		return []net.IP{net.IPv4(192, 0, 2, byte(30+lookups))}, nil
	}
	dials := 0
	dialTCP = func(string, string, time.Duration) (net.Conn, error) {
		dials++
		if dials == 1 {
			return nil, errors.New("synthetic dial failure")
		}
		client, server := net.Pipe()
		_ = server.Close()
		return client, nil
	}
	conn, ip, err := connectWithRetry("retry.example")
	if err != nil {
		t.Fatal(err)
	}
	_ = conn.Close()
	if lookups != 2 || dials != 2 || ip != "192.0.2.32" {
		t.Fatalf("lookups=%d dials=%d ip=%s", lookups, dials, ip)
	}
}

func TestConnectUsesHTTPProxyAndPreservesBufferedTunnelBytes(t *testing.T) {
	oldDial := dialTCP
	oldProxyHost := proxyHost
	oldProxyPort := proxyPort
	oldConnectPort := connectPort
	defer func() {
		dialTCP = oldDial
		proxyHost = oldProxyHost
		proxyPort = oldProxyPort
		connectPort = oldConnectPort
	}()

	proxyHost = "127.0.0.1"
	proxyPort = 3128
	connectPort = 443
	client, server := net.Pipe()
	dialTCP = func(network, address string, timeout time.Duration) (net.Conn, error) {
		if network != "tcp" || address != "127.0.0.1:3128" {
			t.Fatalf("dial %s %s", network, address)
		}
		return client, nil
	}

	done := make(chan error, 1)
	go func() {
		defer server.Close()
		buf := make([]byte, 4096)
		n, err := server.Read(buf)
		if err != nil {
			done <- err
			return
		}
		request := string(buf[:n])
		if request != "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\nProxy-Connection: keep-alive\r\n\r\n" {
			done <- errors.New("unexpected CONNECT request: " + request)
			return
		}
		_, err = server.Write([]byte("HTTP/1.1 200 Connection established\r\n\r\nTLS"))
		done <- err
	}()

	conn, upstream, err := connectWithRetry("example.com")
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if upstream != "127.0.0.1:3128" {
		t.Fatalf("upstream=%q", upstream)
	}
	got := make([]byte, 3)
	if _, err := conn.Read(got); err != nil {
		t.Fatal(err)
	}
	if string(got) != "TLS" {
		t.Fatalf("buffered bytes=%q", got)
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

func FuzzParseSNINeverPanics(f *testing.F) {
	f.Add([]byte{0x16, 0x03, 0x01, 0x00, 0x00})
	f.Add([]byte{0x16, 0x03, 0x03, 0x00, 0x04, 0x01, 0x00, 0x00, 0x00})
	f.Add([]byte("not tls"))
	f.Fuzz(func(t *testing.T, record []byte) {
		_ = parseSNI(record)
	})
}
