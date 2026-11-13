package main

import (
	"bufio"
	"bytes"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestNormalizeProxy(t *testing.T) {
	for _, tc := range []struct{ input, want string }{
		{"127.0.0.1:10808", "127.0.0.1:10808"},
		{"http://LOCALHOST:7890/", "localhost:7890"},
		{"http://proxy.example", "proxy.example:80"},
		{"http://[::1]:8080", "[::1]:8080"},
	} {
		t.Run(tc.input, func(t *testing.T) {
			got, err := normalizeProxy(tc.input)
			if err != nil || got != tc.want {
				t.Fatalf("normalizeProxy = %q, %v; want %q", got, err, tc.want)
			}
		})
	}
	for _, value := range []string{"", "socks5://127.0.0.1:1080", "https://proxy.example:443", "http://user:pass@proxy.example:80", "http://proxy.example:0", "http://proxy.example:70000", "http://proxy.example/path", "http://proxy.example?x=1", "http://proxy.example#fragment"} {
		t.Run("reject/"+value, func(t *testing.T) {
			if _, err := normalizeProxy(value); err == nil {
				t.Fatal("invalid proxy was accepted")
			}
		})
	}
}

func TestInspectHTTPPreservesOriginalBytes(t *testing.T) {
	client, server := net.Pipe()
	defer client.Close()
	defer server.Close()
	original := []byte("POST /v2/check HTTP/1.1\r\nHost: registry.example\r\nContent-Length: 4\r\nX-Custom: untouched\r\n\r\ndata")
	written := make(chan error, 1)
	go func() { _, err := client.Write(original); written <- err }()
	target, preface, err := inspect(server, false)
	if err != nil {
		t.Fatal(err)
	}
	if target != "registry.example:80" {
		t.Fatalf("unexpected target %q", target)
	}
	if !bytes.Equal(preface, original) {
		t.Fatalf("HTTP preface changed: %q", preface)
	}
	if err := <-written; err != nil {
		t.Fatal(err)
	}
}

// This local fake proxy forwards CONNECT to a test TLS server. No public
// registries, certificates, credentials, or internet connection are used.
func startConnectProxy(t *testing.T, backend string) (string, <-chan string) {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	targets := make(chan string, 1)
	go func() {
		client, err := listener.Accept()
		if err != nil {
			return
		}
		defer client.Close()
		client.SetDeadline(time.Now().Add(10 * time.Second))
		reader := bufio.NewReader(client)
		req, err := http.ReadRequest(reader)
		if err != nil || req.Method != "CONNECT" {
			targets <- "invalid CONNECT"
			return
		}
		targets <- req.Host
		upstream, err := net.DialTimeout("tcp", backend, 5*time.Second)
		if err != nil {
			return
		}
		defer upstream.Close()
		upstream.SetDeadline(time.Now().Add(10 * time.Second))
		if _, err = io.WriteString(client, "HTTP/1.1 200 Connection Established\r\n\r\n"); err != nil {
			return
		}
		done := make(chan struct{}, 2)
		go func() { io.Copy(upstream, reader); done <- struct{}{} }()
		go func() { io.Copy(client, upstream); done <- struct{}{} }()
		<-done
		client.Close()
		upstream.Close()
		<-done
	}()
	return listener.Addr().String(), targets
}

func startTestRelay(t *testing.T, proxy string) (string, <-chan struct{}) {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	done := make(chan struct{})
	go func() {
		defer close(done)
		client, err := listener.Accept()
		if err != nil {
			return
		}
		tunnel(client, proxy, true)
	}()
	return listener.Addr().String(), done
}

func TestTLSForwardingPreservesCertificateValidation(t *testing.T) {
	payload := strings.Repeat("registry response bytes\n", 4096)
	backend := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, payload) }))
	backend.Config.ErrorLog = log.New(io.Discard, "", 0)
	backend.StartTLS()
	defer backend.Close()
	serverName := backend.Certificate().DNSNames[0]
	for _, trusted := range []bool{true, false} {
		name := "trusted"
		if !trusted {
			name = "untrusted"
		}
		t.Run(name, func(t *testing.T) {
			proxy, targets := startConnectProxy(t, backend.Listener.Addr().String())
			relay, done := startTestRelay(t, proxy)
			roots := x509.NewCertPool()
			if trusted {
				roots.AddCert(backend.Certificate())
			}
			client, err := tls.DialWithDialer(&net.Dialer{Timeout: 5 * time.Second}, "tcp", relay, &tls.Config{ServerName: serverName, RootCAs: roots})
			if !trusted {
				if client != nil {
					client.Close()
				}
				var certificateError *tls.CertificateVerificationError
				if !errors.As(err, &certificateError) {
					t.Fatalf("want certificate verification failure, got %v", err)
				}
			} else {
				if err != nil {
					t.Fatal(err)
				}
				client.SetDeadline(time.Now().Add(5 * time.Second))
				if _, err = io.WriteString(client, "GET /v2/ HTTP/1.1\r\nHost: "+serverName+"\r\nConnection: close\r\n\r\n"); err != nil {
					t.Fatal(err)
				}
				response, err := http.ReadResponse(bufio.NewReader(client), &http.Request{Method: "GET"})
				if err != nil {
					t.Fatal(err)
				}
				body, err := io.ReadAll(response.Body)
				response.Body.Close()
				client.Close()
				if err != nil || string(body) != payload {
					t.Fatalf("payload was not forwarded intact: bytes=%d error=%v", len(body), err)
				}
			}
			select {
			case target := <-targets:
				if target != net.JoinHostPort(serverName, "443") {
					t.Fatalf("wrong CONNECT target %q", target)
				}
			case <-time.After(5 * time.Second):
				t.Fatal("proxy did not receive CONNECT")
			}
			select {
			case <-done:
			case <-time.After(5 * time.Second):
				t.Fatal("relay did not close after client completion")
			}
		})
	}
}
