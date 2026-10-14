package main

import (
	"bufio"
	"encoding/binary"
	"io"
	"net"
	"net/http"
	"testing"
	"time"
)

// Fast unit: distinguish native resPQ from a TCP-only false positive.
// Expected <1s; emergency deadline10s including fixture setup.
func TestNativeProof(t *testing.T) {
	for _, scenario := range []struct {
		name    string
		reply   bool
		corrupt bool
		pass    bool
	}{
		{"valid-native", true, false, true}, {"tcp-only", false, false, false}, {"wrong-nonce", true, true, false},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			listener, err := net.Listen("tcp", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			defer listener.Close()
			done := make(chan struct{})
			go func() {
				defer close(done)
				conn, err := listener.Accept()
				if err != nil {
					return
				}
				defer conn.Close()
				conn.SetDeadline(time.Now().Add(time.Second))
				reader := bufio.NewReader(conn)
				if _, err := http.ReadRequest(reader); err != nil {
					return
				}
				io.WriteString(conn, "HTTP/1.1 200 Connection Established\r\n\r\n")
				request := make([]byte, 42)
				if _, err := io.ReadFull(reader, request); err != nil {
					return
				}
				if !scenario.reply {
					return
				}
				response := make([]byte, 41)
				response[0] = 10
				binary.LittleEndian.PutUint32(response[21:25], 0x05162463)
				copy(response[25:41], request[26:42])
				if scenario.corrupt {
					response[25] ^= 1
				}
				conn.Write(response)
			}()
			err = probe(listener.Addr().String(), "149.154.167.51", time.Second)
			if (err == nil) != scenario.pass {
				t.Fatalf("proof error=%v, want pass=%v", err, scenario.pass)
			}
			<-done
		})
	}
}
