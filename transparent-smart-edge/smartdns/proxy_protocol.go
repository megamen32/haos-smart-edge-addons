package main

// The public DNS edge sits behind an SNI router that forwards the real client
// address with the PROXY protocol. Without it the resolver would only see the
// router, and the edge authorization of a client would be granted to the
// wrong address.
//
// Both wire versions are accepted: the binary version 2 that HAProxy sends
// and the text version 1 that other forwarders use. A connection without a
// PROXY header keeps the address of the peer, so the same listener works
// behind a direct connection.

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"strings"
	"time"
)

var proxyV2Signature = []byte{0x0d, 0x0a, 0x0d, 0x0a, 0x00, 0x0d, 0x0a, 0x51, 0x55, 0x49, 0x54, 0x0a}

const (
	proxyV2VersionCommand = 0x21 // version 2, PROXY command
	proxyV2TCPOverIPv4    = 0x11
	proxyV2TCPOverIPv6    = 0x21
)

// proxyHeaderTimeout bounds the wait for the PROXY header, so a client that
// opens a connection and stays silent cannot hold a goroutine forever.
const proxyHeaderTimeout = 10 * time.Second

// proxyConn reports the address of the real client instead of the address of
// the hop that forwarded the connection.
type proxyConn struct {
	net.Conn
	reader *bufio.Reader
	source net.Addr
}

func (c *proxyConn) Read(p []byte) (int, error) { return c.reader.Read(p) }

func (c *proxyConn) RemoteAddr() net.Addr { return c.source }

// proxyProtocolListener reads the PROXY header of every accepted connection
// and replaces the reported address with the address of the real client.
type proxyProtocolListener struct {
	net.Listener
}

func (l *proxyProtocolListener) Accept() (net.Conn, error) {
	conn, err := l.Listener.Accept()
	if err != nil {
		return nil, err
	}
	parsed, err := parseProxyHeader(conn)
	if err != nil {
		conn.Close()
		return nil, err
	}
	return parsed, nil
}

// parseProxyHeader returns the connection with the address of the real
// client. A connection without a PROXY header keeps the address of the peer.
func parseProxyHeader(conn net.Conn) (net.Conn, error) {
	reader := bufio.NewReader(conn)
	_ = conn.SetReadDeadline(time.Now().Add(proxyHeaderTimeout))
	source, ok, err := readProxyV2(reader)
	if err != nil {
		return nil, err
	}
	if !ok {
		source, ok, err = readProxyV1(reader)
		if err != nil {
			return nil, err
		}
	}
	_ = conn.SetReadDeadline(time.Time{})
	if !ok {
		source = conn.RemoteAddr()
	}
	return &proxyConn{Conn: conn, reader: reader, source: source}, nil
}

// readProxyV2 reads the binary version of the PROXY protocol. The signature
// is twelve bytes, so a connection that is not a PROXY header is left
// untouched.
func readProxyV2(reader *bufio.Reader) (net.Addr, bool, error) {
	head, err := reader.Peek(len(proxyV2Signature))
	if err != nil || !bytes.Equal(head, proxyV2Signature) {
		return nil, false, nil
	}
	// The header has to be consumed before the address block is read.
	header := make([]byte, 16)
	if _, err := io.ReadFull(reader, header); err != nil {
		return nil, false, errors.New("proxy protocol: truncated header")
	}
	versionCommand := header[12]
	familyProtocol := header[13]
	length := int(binary.BigEndian.Uint16(header[14:16]))
	body := make([]byte, length)
	if _, err := io.ReadFull(reader, body); err != nil {
		return nil, false, errors.New("proxy protocol: truncated header")
	}
	if versionCommand != proxyV2VersionCommand {
		return nil, false, nil
	}
	switch familyProtocol {
	case proxyV2TCPOverIPv4:
		if len(body) < 12 {
			return nil, false, errors.New("proxy protocol: short address")
		}
		return &net.TCPAddr{IP: net.IP(body[0:4])}, true, nil
	case proxyV2TCPOverIPv6:
		if len(body) < 36 {
			return nil, false, errors.New("proxy protocol: short address")
		}
		return &net.TCPAddr{IP: net.IP(body[0:16])}, true, nil
	}
	return nil, false, nil
}

// readProxyV1 reads the text version of the PROXY protocol.
func readProxyV1(reader *bufio.Reader) (net.Addr, bool, error) {
	prefix, err := reader.Peek(6)
	if err != nil || string(prefix) != "PROXY " {
		return nil, false, nil
	}
	line, err := reader.ReadString('\n')
	if err != nil {
		return nil, false, errors.New("proxy protocol: truncated header")
	}
	fields := strings.Fields(strings.TrimSpace(line))
	if len(fields) < 3 || (fields[1] != "TCP4" && fields[1] != "TCP6") {
		return nil, false, errors.New("proxy protocol: unsupported header")
	}
	ip := net.ParseIP(fields[2])
	if ip == nil {
		return nil, false, errors.New("proxy protocol: bad address")
	}
	return &net.TCPAddr{IP: ip}, true, nil
}
