// Loopback-only HTTP CONNECT relay for WSLC registry traffic.
// ClientHello is inspected for SNI and replayed byte-for-byte. TLS is never
// terminated; no certificates or private keys are generated.
package main

import (
	"bufio"
	"bytes"
	"crypto/tls"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

var errPeekComplete = errors.New("ClientHello inspected")

func normalizeProxy(value string) (string, error) {
	value = strings.TrimSpace(value)
	if value == "" {
		return "", errors.New("-proxy is required; supply http://host:port or host:port")
	}
	if !strings.Contains(value, "://") {
		value = "http://" + value
	}
	u, err := url.Parse(value)
	if err != nil {
		return "", err
	}
	if u.Scheme != "http" || u.Hostname() == "" || u.User != nil || (u.Path != "" && u.Path != "/") || u.RawQuery != "" || u.Fragment != "" {
		return "", errors.New("expected an HTTP CONNECT proxy without credentials, path, query, or fragment")
	}
	port := u.Port()
	if port == "" {
		port = "80"
	}
	number, err := strconv.Atoi(port)
	if err != nil || number < 1 || number > 65535 {
		return "", errors.New("invalid proxy TCP port")
	}
	return net.JoinHostPort(strings.ToLower(u.Hostname()), strconv.Itoa(number)), nil
}

type recordingConn struct {
	net.Conn
	buffer bytes.Buffer
}

func (c *recordingConn) Read(b []byte) (int, error) {
	if c.buffer.Len() >= 256*1024 {
		return 0, errors.New("request preface too large")
	}
	n, err := c.Conn.Read(b)
	c.buffer.Write(b[:n])
	return n, err
}

// Discard alerts caused by the intentional inspection callback error.
func (c *recordingConn) Write(b []byte) (int, error) { return len(b), nil }

func inspect(client net.Conn, isTLS bool) (string, []byte, error) {
	client.SetReadDeadline(time.Now().Add(15 * time.Second))
	defer client.SetReadDeadline(time.Time{})
	recorder := &recordingConn{Conn: client}
	var host string
	if isTLS {
		server := tls.Server(recorder, &tls.Config{GetConfigForClient: func(hello *tls.ClientHelloInfo) (*tls.Config, error) {
			host = hello.ServerName
			return nil, errPeekComplete
		}})
		err := server.Handshake()
		if !errors.Is(err, errPeekComplete) {
			return "", nil, fmt.Errorf("TLS preface: %w", err)
		}
	} else {
		req, err := http.ReadRequest(bufio.NewReader(recorder))
		if err != nil {
			return "", nil, err
		}
		host = req.Host
		if parsed, _, e := net.SplitHostPort(host); e == nil {
			host = parsed
		}
	}
	if host == "" || bytes.ContainsAny([]byte(host), "\r\n /\\") {
		return "", nil, errors.New("missing or invalid destination hostname")
	}
	port := "80"
	if isTLS {
		port = "443"
	}
	return net.JoinHostPort(host, port), recorder.buffer.Bytes(), nil
}

func tunnel(client net.Conn, proxy string, isTLS bool) {
	defer client.Close()
	target, preface, err := inspect(client, isTLS)
	if err != nil {
		log.Printf("preface: %v", err)
		return
	}
	dialer := net.Dialer{Timeout: 10 * time.Second, KeepAlive: 30 * time.Second}
	upstream, err := dialer.Dial("tcp", proxy)
	if err != nil {
		log.Printf("proxy connection: %v", err)
		return
	}
	defer upstream.Close()
	upstream.SetDeadline(time.Now().Add(15 * time.Second))
	req := &http.Request{Method: "CONNECT", URL: &url.URL{Opaque: target}, Host: target, Header: make(http.Header)}
	if err = req.Write(upstream); err != nil {
		log.Printf("CONNECT write: %v", err)
		return
	}
	reader := bufio.NewReader(upstream)
	resp, err := http.ReadResponse(reader, req)
	if err != nil {
		log.Printf("CONNECT response: %v", err)
		return
	}
	if resp.StatusCode != 200 {
		log.Printf("CONNECT %s rejected: %s", target, resp.Status)
		return
	}
	upstream.SetDeadline(time.Time{})
	if _, err = io.Copy(upstream, bytes.NewReader(preface)); err != nil {
		return
	}
	log.Printf("CONNECT %s via %s", target, proxy)
	done := make(chan struct{}, 2)
	go func() { io.Copy(upstream, client); done <- struct{}{} }()
	go func() { io.Copy(client, reader); done <- struct{}{} }()
	<-done
	client.Close()
	upstream.Close()
	<-done
}

func main() {
	proxyFlag := flag.String("proxy", "", "HTTP CONNECT upstream: http://host:port or host:port (required)")
	tlsPort := flag.Int("tls-port", 0, "loopback HTTPS redirect port; 0 selects a free port")
	httpPort := flag.Int("http-port", 0, "loopback HTTP redirect port; 0 selects a free port")
	state := flag.String("state", ".", "PID and log directory")
	flag.Parse()
	proxy, err := normalizeProxy(*proxyFlag)
	if err != nil {
		log.Fatal(err)
	}
	if err := os.MkdirAll(*state, 0700); err != nil {
		log.Fatal(err)
	}
	output, err := os.OpenFile(filepath.Join(*state, "redirect.log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		log.Fatal(err)
	}
	defer output.Close()
	log.SetOutput(output)
	type listenerEndpoint struct {
		listener net.Listener
		tls      bool
	}
	var endpoints []listenerEndpoint
	ports := []struct {
		requested int
		tls       bool
	}{{*tlsPort, true}, {*httpPort, false}}
	actualTLS, actualHTTP := 0, 0
	for _, entry := range ports {
		v4, e := net.Listen("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(entry.requested)))
		if e != nil {
			log.Fatal(e)
		}
		port := v4.Addr().(*net.TCPAddr).Port
		v6, e := net.Listen("tcp", net.JoinHostPort("::1", strconv.Itoa(port)))
		if e != nil {
			log.Fatal(e)
		}
		endpoints = append(endpoints, listenerEndpoint{v4, entry.tls}, listenerEndpoint{v6, entry.tls})
		if entry.tls {
			actualTLS = port
		} else {
			actualHTTP = port
		}
	}
	metadata, err := json.Marshal(struct {
		PID      int    `json:"pid"`
		TLSPort  int    `json:"tlsPort"`
		HTTPPort int    `json:"httpPort"`
		Proxy    string `json:"proxy"`
	}{os.Getpid(), actualTLS, actualHTTP, proxy})
	if err != nil {
		log.Fatal(err)
	}
	readyPath := filepath.Join(*state, "relay.json")
	if err = os.WriteFile(readyPath+".tmp", metadata, 0600); err != nil {
		log.Fatal(err)
	}
	if err = os.Rename(readyPath+".tmp", readyPath); err != nil {
		log.Fatal(err)
	}
	if err = os.WriteFile(filepath.Join(*state, "redirect.pid"), []byte(strconv.Itoa(os.Getpid())), 0600); err != nil {
		log.Fatal(err)
	}
	log.Printf("ready pid=%d upstream=%s tls=%d http=%d", os.Getpid(), proxy, actualTLS, actualHTTP)
	for _, ep := range endpoints {
		go func(endpoint listenerEndpoint) {
			for {
				c, e := endpoint.listener.Accept()
				if e != nil {
					log.Fatal(e)
				}
				go tunnel(c, proxy, endpoint.tls)
			}
		}(ep)
	}
	select {}
}
