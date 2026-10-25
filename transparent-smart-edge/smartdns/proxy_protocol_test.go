package main

import (
	"encoding/binary"
	"io"
	"net"
	"testing"
)

func proxyV2Header(source, destination net.IP) []byte {
	header := make([]byte, 16+12)
	copy(header[:12], proxyV2Signature)
	header[12] = proxyV2VersionCommand
	header[13] = proxyV2TCPOverIPv4
	binary.BigEndian.PutUint16(header[14:16], 12)
	copy(header[16:20], source.To4())
	copy(header[20:24], destination.To4())
	binary.BigEndian.PutUint16(header[24:26], 443)
	binary.BigEndian.PutUint16(header[26:28], 8449)
	return header
}

func remoteHost(t *testing.T, conn net.Conn) string {
	t.Helper()
	host, _, err := net.SplitHostPort(conn.RemoteAddr().String())
	if err != nil {
		t.Fatalf("remote address %q: %v", conn.RemoteAddr(), err)
	}
	return host
}

func TestProxyProtocolV2ReportsTheRealClient(t *testing.T) {
	client, server := net.Pipe()
	defer client.Close()
	defer server.Close()

	go func() {
		header := proxyV2Header(net.ParseIP("203.0.113.9"), net.ParseIP("192.168.2.100"))
		_, _ = client.Write(append(header, []byte("GET /dns-query HTTP/1.1\r\n\r\n")...))
	}()

	parsed, err := parseProxyHeader(server)
	if err != nil {
		t.Fatalf("parse proxy header: %v", err)
	}
	if host := remoteHost(t, parsed); host != "203.0.113.9" {
		t.Fatalf("client address = %q, want 203.0.113.9", host)
	}
	// The request behind the header must still reach the server untouched.
	head := make([]byte, 4)
	if _, err := io.ReadFull(parsed, head); err != nil {
		t.Fatalf("read payload: %v", err)
	}
	if string(head) != "GET " {
		t.Fatalf("payload = %q, want the request behind the header", string(head))
	}
}

func TestProxyProtocolV1ReportsTheRealClient(t *testing.T) {
	client, server := net.Pipe()
	defer client.Close()
	defer server.Close()

	go func() {
		_, _ = client.Write([]byte("PROXY TCP4 198.51.100.7 192.168.2.100 443 8449\r\nGET /dns-query HTTP/1.1\r\n\r\n"))
	}()

	parsed, err := parseProxyHeader(server)
	if err != nil {
		t.Fatalf("parse proxy header: %v", err)
	}
	if host := remoteHost(t, parsed); host != "198.51.100.7" {
		t.Fatalf("client address = %q, want 198.51.100.7", host)
	}
}

func TestConnectionWithoutProxyHeaderKeepsThePeerAddress(t *testing.T) {
	client, server := net.Pipe()
	defer client.Close()
	defer server.Close()

	go func() {
		_, _ = client.Write([]byte("GET /dns-query HTTP/1.1\r\n\r\n"))
	}()

	parsed, err := parseProxyHeader(server)
	if err != nil {
		t.Fatalf("parse proxy header: %v", err)
	}
	// The peer address of the pipe is unknown, but it must not be replaced by
	// a zero address.
	if parsed.RemoteAddr() == nil {
		t.Fatal("remote address is nil")
	}
	head := make([]byte, 4)
	if _, err := io.ReadFull(parsed, head); err != nil {
		t.Fatalf("read payload: %v", err)
	}
	if string(head) != "GET " {
		t.Fatalf("payload = %q, want the request itself", string(head))
	}
}

func TestBrokenProxyHeaderIsRejected(t *testing.T) {
	client, server := net.Pipe()
	defer client.Close()
	defer server.Close()

	go func() {
		_, _ = client.Write([]byte("PROXY TCP4 not-an-address 192.168.2.100 443 8449\r\n"))
	}()

	if _, err := parseProxyHeader(server); err == nil {
		t.Fatal("a broken PROXY header must be rejected")
	}
}
