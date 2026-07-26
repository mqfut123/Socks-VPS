package server

import (
	"bytes"
	"context"
	"crypto/sha256"
	"errors"
	"io"
	"net"
	"net/netip"
	"strconv"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/go-gost/gosocks5"

	"socks-vps/internal/config"
)

type resolverFunc func(context.Context, string, bool) ([]netip.Addr, error)

func (fn resolverFunc) Resolve(ctx context.Context, host string, domain bool) ([]netip.Addr, error) {
	return fn(ctx, host, domain)
}

type dialerFunc func(context.Context, string, string) (net.Conn, error)

func (fn dialerFunc) DialContext(ctx context.Context, network, address string) (net.Conn, error) {
	return fn(ctx, network, address)
}

func testConfig(port int) config.Config {
	return config.Config{
		Schema:   1,
		Listen:   "0.0.0.0",
		Port:     port,
		Username: "alice",
		Password: "correct horse battery staple",
		Version:  "1.0.0",
	}
}

func TestConstantTimeCredentialsEqual(t *testing.T) {
	cfg := testConfig(1080)
	usernameHash := sha256.Sum256([]byte(cfg.Username))
	passwordHash := sha256.Sum256([]byte(cfg.Password))

	tests := []struct {
		name     string
		username string
		password string
		want     bool
	}{
		{name: "both match", username: cfg.Username, password: cfg.Password, want: true},
		{name: "wrong username", username: "mallory", password: cfg.Password},
		{name: "wrong password", username: cfg.Username, password: "wrong"},
		{name: "both wrong", username: "mallory", password: "wrong"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := constantTimeCredentialsEqual(
				test.username,
				test.password,
				usernameHash,
				passwordHash,
			); got != test.want {
				t.Fatalf("constantTimeCredentialsEqual() = %v, want %v", got, test.want)
			}
		})
	}
}

func TestHandleRejectsAuthenticationBeforeResolution(t *testing.T) {
	var resolverCalled bool
	s := New(testConfig(1080), resolverFunc(func(context.Context, string, bool) ([]netip.Addr, error) {
		resolverCalled = true
		return nil, nil
	}))
	client, handlerDone := startHandler(t, s)
	defer client.Close()

	authenticate(t, client, "alice", "wrong", gosocks5.Failure)
	if err := <-handlerDone; !errors.Is(err, gosocks5.ErrAuthFailure) {
		t.Fatalf("handle() error = %v, want auth failure", err)
	}
	if resolverCalled {
		t.Fatal("resolver was called after failed authentication")
	}
}

func TestHandleRequiresUsernamePasswordMethod(t *testing.T) {
	s := New(testConfig(1080), resolverFunc(func(context.Context, string, bool) ([]netip.Addr, error) {
		t.Fatal("resolver must not be called")
		return nil, nil
	}))
	client, handlerDone := startHandler(t, s)
	defer client.Close()

	if _, err := client.Write([]byte{gosocks5.Ver5, 1, gosocks5.MethodNoAuth}); err != nil {
		t.Fatalf("write methods: %v", err)
	}
	response := make([]byte, 2)
	if _, err := io.ReadFull(client, response); err != nil {
		t.Fatalf("read method response: %v", err)
	}
	if response[0] != gosocks5.Ver5 || response[1] != gosocks5.MethodNoAcceptable {
		t.Fatalf("method response = %v, want [5 255]", response)
	}
	if err := <-handlerDone; !errors.Is(err, gosocks5.ErrBadMethod) {
		t.Fatalf("handle() error = %v, want bad method", err)
	}
}

func TestHandleRejectsUnsupportedCommandsAndIPv6(t *testing.T) {
	tests := []struct {
		name      string
		request   *gosocks5.Request
		wantReply uint8
	}{
		{
			name: "BIND",
			request: gosocks5.NewRequest(gosocks5.CmdBind, &gosocks5.Addr{
				Type: gosocks5.AddrIPv4,
				Host: "93.184.216.34",
				Port: 80,
			}),
			wantReply: gosocks5.CmdUnsupported,
		},
		{
			name: "UDP ASSOCIATE",
			request: gosocks5.NewRequest(gosocks5.CmdUdp, &gosocks5.Addr{
				Type: gosocks5.AddrIPv4,
				Host: "93.184.216.34",
				Port: 53,
			}),
			wantReply: gosocks5.CmdUnsupported,
		},
		{
			name: "IPv6 CONNECT",
			request: gosocks5.NewRequest(gosocks5.CmdConnect, &gosocks5.Addr{
				Type: gosocks5.AddrIPv6,
				Host: "2001:db8::1",
				Port: 443,
			}),
			wantReply: gosocks5.AddrUnsupported,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			s := New(testConfig(1080), resolverFunc(func(context.Context, string, bool) ([]netip.Addr, error) {
				t.Fatal("resolver must not be called for a rejected request")
				return nil, nil
			}))
			client, handlerDone := startHandler(t, s)
			defer client.Close()
			authenticate(t, client, "alice", "correct horse battery staple", gosocks5.Succeeded)

			if err := test.request.Write(client); err != nil {
				t.Fatalf("write request: %v", err)
			}
			reply, err := gosocks5.ReadReply(client)
			if err != nil {
				t.Fatalf("read reply: %v", err)
			}
			if reply.Rep != test.wantReply {
				t.Fatalf("reply = %d, want %d", reply.Rep, test.wantReply)
			}
			if err := <-handlerDone; err == nil {
				t.Fatal("handle() returned nil for a rejected request")
			}
		})
	}
}

func TestHandleRejectsUnknownAddressType(t *testing.T) {
	s := New(testConfig(1080), resolverFunc(func(context.Context, string, bool) ([]netip.Addr, error) {
		t.Fatal("resolver must not be called")
		return nil, nil
	}))
	client, handlerDone := startHandler(t, s)
	defer client.Close()
	authenticate(t, client, "alice", "correct horse battery staple", gosocks5.Succeeded)

	if _, err := client.Write([]byte{gosocks5.Ver5, gosocks5.CmdConnect, 0, 9}); err != nil {
		t.Fatalf("write malformed request: %v", err)
	}
	reply, err := gosocks5.ReadReply(client)
	if err != nil {
		t.Fatalf("read reply: %v", err)
	}
	if reply.Rep != gosocks5.AddrUnsupported {
		t.Fatalf("reply = %d, want %d", reply.Rep, gosocks5.AddrUnsupported)
	}
	if err := <-handlerDone; !errors.Is(err, gosocks5.ErrBadAddrType) {
		t.Fatalf("handle() error = %v, want bad address type", err)
	}
}

func TestHandleRejectsNonzeroRequestReservedByte(t *testing.T) {
	s := New(testConfig(1080), resolverFunc(func(context.Context, string, bool) ([]netip.Addr, error) {
		t.Fatal("resolver must not be called")
		return nil, nil
	}))
	client, handlerDone := startHandler(t, s)
	defer client.Close()
	authenticate(t, client, "alice", "correct horse battery staple", gosocks5.Succeeded)

	request := []byte{
		gosocks5.Ver5,
		gosocks5.CmdConnect,
		1,
		gosocks5.AddrIPv4,
	}
	if _, err := client.Write(request); err != nil {
		t.Fatalf("write malformed request: %v", err)
	}
	reply, err := gosocks5.ReadReply(client)
	if err != nil {
		t.Fatalf("read reply: %v", err)
	}
	if reply.Rep != gosocks5.Failure {
		t.Fatalf("reply = %d, want %d", reply.Rep, gosocks5.Failure)
	}
	if err := <-handlerDone; !errors.Is(err, errNonzeroReservedByte) {
		t.Fatalf("handle() error = %v, want reserved-byte error", err)
	}
}

func TestReadRequestDoesNotConsumePipelinedPayload(t *testing.T) {
	frame := []byte{
		gosocks5.Ver5,
		gosocks5.CmdConnect,
		0,
		gosocks5.AddrIPv4,
		93, 184, 216, 34,
		0, 80,
	}
	const payload = "early application payload"
	reader := bytes.NewBuffer(append(frame, payload...))
	request, err := readRequest(reader)
	if err != nil {
		t.Fatalf("readRequest() error: %v", err)
	}
	if request.Addr.Host != "93.184.216.34" || request.Addr.Port != 80 {
		t.Fatalf("request target = %s, want 93.184.216.34:80", request.Addr)
	}
	if got := reader.String(); got != payload {
		t.Fatalf("remaining payload = %q, want %q", got, payload)
	}
}

func TestHandleResolvesDomainOnceAndDialsApprovedIPv4(t *testing.T) {
	echoAddress, closeEcho := startEchoServer(t)
	defer closeEcho()

	var mu sync.Mutex
	resolveCalls := 0
	var resolvedHost string
	var resolvedDomain bool
	s := New(testConfig(1080), resolverFunc(func(_ context.Context, host string, domain bool) ([]netip.Addr, error) {
		mu.Lock()
		defer mu.Unlock()
		resolveCalls++
		resolvedHost = host
		resolvedDomain = domain
		return []netip.Addr{netip.MustParseAddr("93.184.216.34")}, nil
	}))
	var dialNetwork, dialAddress string
	s.dialer = dialerFunc(func(ctx context.Context, network, address string) (net.Conn, error) {
		dialNetwork = network
		dialAddress = address
		return (&net.Dialer{}).DialContext(ctx, "tcp4", echoAddress)
	})

	client, handlerDone := startHandler(t, s)
	authenticate(t, client, "alice", "correct horse battery staple", gosocks5.Succeeded)
	request := gosocks5.NewRequest(gosocks5.CmdConnect, &gosocks5.Addr{
		Type: gosocks5.AddrDomain,
		Host: "example.com",
		Port: 443,
	})
	if err := request.Write(client); err != nil {
		t.Fatalf("write CONNECT: %v", err)
	}
	reply, err := gosocks5.ReadReply(client)
	if err != nil {
		t.Fatalf("read CONNECT reply: %v", err)
	}
	if reply.Rep != gosocks5.Succeeded {
		t.Fatalf("CONNECT reply = %d, want success", reply.Rep)
	}

	message := []byte("through-the-tunnel")
	if _, err := client.Write(message); err != nil {
		t.Fatalf("write tunnel data: %v", err)
	}
	echoed := make([]byte, len(message))
	if _, err := io.ReadFull(client, echoed); err != nil {
		t.Fatalf("read tunnel data: %v", err)
	}
	if string(echoed) != string(message) {
		t.Fatalf("echoed data = %q, want %q", echoed, message)
	}
	_ = client.Close()
	if err := <-handlerDone; err != nil {
		t.Fatalf("handle() error = %v", err)
	}

	mu.Lock()
	defer mu.Unlock()
	if resolveCalls != 1 || resolvedHost != "example.com" || !resolvedDomain {
		t.Fatalf("resolver calls = %d, host = %q, domain = %v", resolveCalls, resolvedHost, resolvedDomain)
	}
	if dialNetwork != "tcp4" || dialAddress != "93.184.216.34:443" {
		t.Fatalf("dial = %s %s, want tcp4 93.184.216.34:443", dialNetwork, dialAddress)
	}
}

func TestHandleConnectFailureReply(t *testing.T) {
	s := New(testConfig(1080), resolverFunc(func(context.Context, string, bool) ([]netip.Addr, error) {
		return []netip.Addr{netip.MustParseAddr("93.184.216.34")}, nil
	}))
	s.dialer = dialerFunc(func(context.Context, string, string) (net.Conn, error) {
		return nil, syscall.ECONNREFUSED
	})
	client, handlerDone := startHandler(t, s)
	defer client.Close()
	authenticate(t, client, "alice", "correct horse battery staple", gosocks5.Succeeded)
	if err := gosocks5.NewRequest(gosocks5.CmdConnect, &gosocks5.Addr{
		Type: gosocks5.AddrIPv4,
		Host: "93.184.216.34",
		Port: 443,
	}).Write(client); err != nil {
		t.Fatalf("write request: %v", err)
	}
	reply, err := gosocks5.ReadReply(client)
	if err != nil {
		t.Fatalf("read reply: %v", err)
	}
	if reply.Rep != gosocks5.ConnRefused {
		t.Fatalf("reply = %d, want %d", reply.Rep, gosocks5.ConnRefused)
	}
	if err := <-handlerDone; !errors.Is(err, syscall.ECONNREFUSED) {
		t.Fatalf("handle() error = %v, want connection refused", err)
	}
}

func TestHandleBoundsTargetResolution(t *testing.T) {
	s := New(testConfig(1080), resolverFunc(func(
		ctx context.Context,
		_ string,
		_ bool,
	) ([]netip.Addr, error) {
		<-ctx.Done()
		return nil, ctx.Err()
	}))
	s.connectTimeout = 20 * time.Millisecond
	client, handlerDone := startHandler(t, s)
	defer client.Close()
	authenticate(t, client, "alice", "correct horse battery staple", gosocks5.Succeeded)
	if err := gosocks5.NewRequest(gosocks5.CmdConnect, &gosocks5.Addr{
		Type: gosocks5.AddrDomain,
		Host: "slow.example",
		Port: 443,
	}).Write(client); err != nil {
		t.Fatalf("write request: %v", err)
	}
	reply, err := gosocks5.ReadReply(client)
	if err != nil {
		t.Fatalf("read reply: %v", err)
	}
	if reply.Rep != gosocks5.HostUnreachable {
		t.Fatalf("reply = %d, want %d", reply.Rep, gosocks5.HostUnreachable)
	}
	if err := <-handlerDone; !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("handle() error = %v, want deadline exceeded", err)
	}
}

func TestServeReportsAddressInUse(t *testing.T) {
	listener, err := net.Listen("tcp4", "0.0.0.0:0")
	if err != nil {
		t.Fatalf("reserve port: %v", err)
	}
	defer listener.Close()
	port := listener.Addr().(*net.TCPAddr).Port

	s := New(testConfig(port), resolverFunc(func(context.Context, string, bool) ([]netip.Addr, error) {
		return nil, nil
	}))
	if err := s.Serve(context.Background()); !errors.Is(err, ErrAddressInUse) {
		t.Fatalf("Serve() error = %v, want address in use", err)
	}
}

func TestServeStopsOnContextCancellation(t *testing.T) {
	port := availablePort(t)
	s := New(testConfig(port), resolverFunc(func(context.Context, string, bool) ([]netip.Addr, error) {
		return nil, nil
	}))
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		done <- s.Serve(ctx)
	}()

	address := net.JoinHostPort("127.0.0.1", strconv.Itoa(port))
	var conn net.Conn
	var dialErr error
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		conn, dialErr = net.DialTimeout("tcp4", address, 20*time.Millisecond)
		if dialErr == nil {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	if conn == nil {
		cancel()
		t.Fatalf("server did not start listening on %s", address)
	}
	cancel()
	_ = conn.Close()

	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("Serve() error = %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("Serve() did not stop after cancellation")
	}
}

func TestHandshakeDeadline(t *testing.T) {
	s := New(testConfig(1080), resolverFunc(func(context.Context, string, bool) ([]netip.Addr, error) {
		return nil, nil
	}))
	s.handshakeTimeout = 20 * time.Millisecond
	client, serverConn := net.Pipe()
	defer client.Close()
	done := make(chan error, 1)
	go func() {
		done <- s.handle(context.Background(), serverConn)
		_ = serverConn.Close()
	}()

	select {
	case err := <-done:
		var networkError net.Error
		if !errors.As(err, &networkError) || !networkError.Timeout() {
			t.Fatalf("handle() error = %v, want timeout", err)
		}
	case <-time.After(time.Second):
		t.Fatal("handle() did not enforce handshake deadline")
	}
}

func TestReplyForDialError(t *testing.T) {
	tests := []struct {
		err  error
		want uint8
	}{
		{err: syscall.ENETUNREACH, want: gosocks5.NetUnreachable},
		{err: syscall.EHOSTUNREACH, want: gosocks5.HostUnreachable},
		{err: syscall.ECONNREFUSED, want: gosocks5.ConnRefused},
		{err: errors.New("other"), want: gosocks5.Failure},
	}
	for _, test := range tests {
		if got := replyForDialError(test.err); got != test.want {
			t.Errorf("replyForDialError(%v) = %d, want %d", test.err, got, test.want)
		}
	}
}

func startHandler(t *testing.T, s *Server) (net.Conn, <-chan error) {
	t.Helper()
	client, serverConn := net.Pipe()
	done := make(chan error, 1)
	go func() {
		done <- s.handle(context.Background(), serverConn)
		_ = serverConn.Close()
	}()
	return client, done
}

func authenticate(t *testing.T, conn net.Conn, username, password string, wantStatus byte) {
	t.Helper()
	if _, err := conn.Write([]byte{gosocks5.Ver5, 1, gosocks5.MethodUserPass}); err != nil {
		t.Fatalf("write methods: %v", err)
	}
	method := make([]byte, 2)
	if _, err := io.ReadFull(conn, method); err != nil {
		t.Fatalf("read selected method: %v", err)
	}
	if method[0] != gosocks5.Ver5 || method[1] != gosocks5.MethodUserPass {
		t.Fatalf("selected method = %v, want [5 2]", method)
	}
	if err := gosocks5.NewUserPassRequest(gosocks5.UserPassVer, username, password).Write(conn); err != nil {
		t.Fatalf("write username/password: %v", err)
	}
	response, err := gosocks5.ReadUserPassResponse(conn)
	if err != nil {
		t.Fatalf("read username/password response: %v", err)
	}
	if response.Status != wantStatus {
		t.Fatalf("authentication status = %d, want %d", response.Status, wantStatus)
	}
}

func startEchoServer(t *testing.T) (string, func()) {
	t.Helper()
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen for echo server: %v", err)
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		_, _ = io.Copy(conn, conn)
	}()
	return listener.Addr().String(), func() {
		_ = listener.Close()
		<-done
	}
}

func availablePort(t *testing.T) int {
	t.Helper()
	listener, err := net.Listen("tcp4", "0.0.0.0:0")
	if err != nil {
		t.Fatalf("find available port: %v", err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	if err := listener.Close(); err != nil {
		t.Fatalf("release available port: %v", err)
	}
	return port
}
