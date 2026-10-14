// route-probe verifies native MTProto before declaring a Telegram route healthy.
package main

import (
	"bufio"
	"bytes"
	"crypto/rand"
	"encoding/binary"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

func probe(proxy, dc string, timeout time.Duration) error {
	conn, err := net.DialTimeout("tcp", proxy, timeout)
	if err != nil {
		return err
	}
	defer conn.Close()
	if err = conn.SetDeadline(time.Now().Add(timeout)); err != nil {
		return err
	}
	target := net.JoinHostPort(dc, "443")
	if _, err = fmt.Fprintf(conn, "CONNECT %s HTTP/1.1\r\nHost: %s\r\n\r\n", target, target); err != nil {
		return err
	}
	reader := bufio.NewReaderSize(conn, 4096)
	response, err := http.ReadResponse(reader, &http.Request{Method: "CONNECT"})
	if err != nil {
		return err
	}
	if response.StatusCode != 200 {
		return fmt.Errorf("CONNECT rejected: %d", response.StatusCode)
	}
	nonce := make([]byte, 16)
	if _, err = rand.Read(nonce); err != nil {
		return err
	}
	request := make([]byte, 42)
	request[0], request[1] = 0xef, 10 // abridged transport + forty-byte envelope
	now := time.Now()
	messageID := uint64(now.Unix())<<32 | uint64(now.Nanosecond())<<32/1_000_000_000
	binary.LittleEndian.PutUint64(request[10:18], messageID&^3)
	binary.LittleEndian.PutUint32(request[18:22], 20)
	binary.LittleEndian.PutUint32(request[22:26], 0xbe7e8ef1) // req_pq_multi
	copy(request[26:], nonce)
	if _, err = conn.Write(request); err != nil {
		return err
	}
	first, err := reader.ReadByte()
	if err != nil {
		return err
	}
	words := int(first)
	if first == 127 {
		length := make([]byte, 3)
		if _, err = io.ReadFull(reader, length); err != nil {
			return err
		}
		words = int(length[0]) | int(length[1])<<8 | int(length[2])<<16
	}
	if words < 10 || words*4 > 4096 {
		return fmt.Errorf("invalid MTProto frame length")
	}
	message := make([]byte, words*4)
	if _, err = io.ReadFull(reader, message); err != nil {
		return err
	}
	if binary.LittleEndian.Uint64(message[:8]) != 0 ||
		binary.LittleEndian.Uint32(message[20:24]) != 0x05162463 ||
		!bytes.Equal(message[24:40], nonce) {
		return fmt.Errorf("missing matching resPQ")
	}
	return nil
}

func main() {
	proxy := flag.String("proxy", "127.0.0.1:3128", "local HTTP CONNECT lane")
	dcs := flag.String("dcs", "149.154.167.51,91.108.56.130", "official DC IPs")
	timeout := flag.Duration("timeout", 3*time.Second, "deadline per DC")
	flag.Parse()
	addresses := strings.Split(*dcs, ",")
	if *timeout <= 0 || *timeout > 10*time.Second || len(addresses) == 0 || len(addresses) > 4 {
		fmt.Fprintln(os.Stderr, "invalid bounded probe settings")
		os.Exit(2)
	}
	start := time.Now()
	errors := make(chan error, len(addresses))
	var workers sync.WaitGroup
	for _, address := range addresses {
		if net.ParseIP(address) == nil {
			fmt.Fprintln(os.Stderr, "DC must be a literal IP")
			os.Exit(2)
		}
		workers.Add(1)
		go func(dc string) { defer workers.Done(); errors <- probe(*proxy, dc, *timeout) }(address)
	}
	workers.Wait()
	close(errors)
	for err := range errors {
		if err != nil {
			fmt.Println("err")
			os.Exit(1)
		}
	}
	fmt.Printf("ok %.3f\n", time.Since(start).Seconds())
}
