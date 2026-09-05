// Package server implements the authenticated, IPv4-only SOCKS5 CONNECT
// service used by Socks-VPS.
package server

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"strconv"
	"sync"
	"syscall"
	"time"

	"github.com/go-gost/gosocks5"

	"socks-vps/internal/config"
	"socks-vps/internal/target"
)

const (
	defaultHandshakeTimeout = 10 * time.Second
	defaultConnectTimeout   = 10 * time.Second
)

var ErrAddressInUse = errors.New("SOCKS listener address is already in use")

var errNonzeroReservedByte = errors.New("SOCKS request reserved byte is not zero")

// Resolver resolves one explicit IPv4 address or one domain to already
// approved public IPv4 addresses. A domain lookup is performed by the
// implementation exactly once.
type Resolver interface {
	Resolve(context.Context, string, bool) ([]netip.Addr, error)
}

type contextDialer interface {
	DialContext(context.Context, string, string) (net.Conn, error)
}

// Server owns one IPv4 TCP listener and all accepted client connections.
type Server struct {
	listenAddress string
	usernameHash  [sha256.Size]byte
	passwordHash  [sha256.Size]byte

	resolver         Resolver
	dialer           contextDialer
	handshakeTimeout time.Duration
	connectTimeout   time.Duration

	mu          sync.Mutex
	listener    net.Listener
	connections map[net.Conn]struct{}
	stopping    bool
	handlers    sync.WaitGroup
}

// New constructs a server from a validated configuration.
func New(cfg config.Config, resolver Resolver) *Server {
	return &Server{
		listenAddress:    net.JoinHostPort(cfg.Listen, strconv.Itoa(cfg.Port)),
		usernameHash:     sha256.Sum256([]byte(cfg.Username)),
		passwordHash:     sha256.Sum256([]byte(cfg.Password)),
		resolver:         resolver,
		dialer:           &net.Dialer{},
		handshakeTimeout: defaultHandshakeTimeout,
		connectTimeout:   defaultConnectTimeout,
		connections:      make(map[net.Conn]struct{}),
	}
}

// Serve listens on the configured IPv4 wildcard address until ctx is
// cancelled. Cancellation closes the listener and all active tunnels before
// returning.
func (s *Server) Serve(ctx context.Context) error {
	if s.resolver == nil {
		return errors.New("SOCKS target resolver is nil")
	}

	listener, err := (&net.ListenConfig{}).Listen(ctx, "tcp4", s.listenAddress)
	if err != nil {
		if errors.Is(err, syscall.EADDRINUSE) {
			return fmt.Errorf("%w: %s", ErrAddressInUse, s.listenAddress)
		}
		return fmt.Errorf("listen tcp4 %s: %w", s.listenAddress, err)
	}

	s.mu.Lock()
	if s.stopping {
		s.mu.Unlock()
		_ = listener.Close()
		return nil
	}
	s.listener = listener
	s.mu.Unlock()

	shutdownDone := make(chan struct{})
	go func() {
		select {
		case <-ctx.Done():
			s.shutdown()
		case <-shutdownDone:
		}
	}()
	defer close(shutdownDone)

	for {
		conn, err := listener.Accept()
		if err != nil {
			if ctx.Err() != nil {
				s.shutdown()
				s.handlers.Wait()
				return nil
			}
			s.shutdown()
			s.handlers.Wait()
			return fmt.Errorf("accept SOCKS connection: %w", err)
		}
		if !s.track(conn) {
			_ = conn.Close()
			continue
		}
		s.handlers.Add(1)
		go func() {
			defer s.handlers.Done()
			defer s.untrack(conn)
			defer conn.Close()
			_ = s.handle(ctx, conn)
		}()
	}
}

func (s *Server) track(conn net.Conn) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.stopping {
		return false
	}
	s.connections[conn] = struct{}{}
	return true
}

func (s *Server) untrack(conn net.Conn) {
	s.mu.Lock()
	delete(s.connections, conn)
	s.mu.Unlock()
}

func (s *Server) shutdown() {
	s.mu.Lock()
	if s.stopping {
		s.mu.Unlock()
		return
	}
	s.stopping = true
	listener := s.listener
	connections := make([]net.Conn, 0, len(s.connections))
	for conn := range s.connections {
		connections = append(connections, conn)
	}
	s.mu.Unlock()

	if listener != nil {
		_ = listener.Close()
	}
	for _, conn := range connections {
		_ = conn.Close()
	}
}

func (s *Server) handle(ctx context.Context, client net.Conn) error {
	if err := setPhaseDeadline(client, s.handshakeTimeout); err != nil {
		return err
	}
	methods, err := gosocks5.ReadMethods(client)
	if err != nil {
		return fmt.Errorf("read SOCKS methods: %w", err)
	}
	if !containsMethod(methods, gosocks5.MethodUserPass) {
		if err := gosocks5.WriteMethod(gosocks5.MethodNoAcceptable, client); err != nil {
			return fmt.Errorf("write SOCKS method rejection: %w", err)
		}
		return gosocks5.ErrBadMethod
	}
	if err := gosocks5.WriteMethod(gosocks5.MethodUserPass, client); err != nil {
		return fmt.Errorf("write SOCKS authentication method: %w", err)
	}

	if err := setPhaseDeadline(client, s.handshakeTimeout); err != nil {
		return err
	}
	credentials, err := gosocks5.ReadUserPassRequest(client)
	if err != nil {
		return fmt.Errorf("read SOCKS username/password request: %w", err)
	}
	valid := constantTimeCredentialsEqual(
		credentials.Username,
		credentials.Password,
		s.usernameHash,
		s.passwordHash,
	)
	status := byte(gosocks5.Failure)
	if valid {
		status = gosocks5.Succeeded
	}
	if err := gosocks5.NewUserPassResponse(gosocks5.UserPassVer, status).Write(client); err != nil {
		return fmt.Errorf("write SOCKS username/password response: %w", err)
	}
	if !valid {
		return gosocks5.ErrAuthFailure
	}

	if err := setPhaseDeadline(client, s.handshakeTimeout); err != nil {
		return err
	}
	request, err := readRequest(client)
	if err != nil {
		switch {
		case errors.Is(err, gosocks5.ErrBadAddrType):
			_ = writeReply(client, gosocks5.AddrUnsupported, nil)
		case errors.Is(err, errNonzeroReservedByte):
			_ = writeReply(client, gosocks5.Failure, nil)
		}
		return fmt.Errorf("read SOCKS request: %w", err)
	}
	if request.Cmd != gosocks5.CmdConnect {
		if err := writeReply(client, gosocks5.CmdUnsupported, nil); err != nil {
			return err
		}
		return fmt.Errorf("SOCKS command %d is not supported", request.Cmd)
	}
	if request.Addr == nil {
		if err := writeReply(client, gosocks5.AddrUnsupported, nil); err != nil {
			return err
		}
		return errors.New("SOCKS request has no target address")
	}
	if request.Addr.Type == gosocks5.AddrIPv6 {
		if err := writeReply(client, gosocks5.AddrUnsupported, nil); err != nil {
			return err
		}
		return errors.New("SOCKS IPv6 targets are not supported")
	}

	isDomain := request.Addr.Type == gosocks5.AddrDomain
	if !isDomain && request.Addr.Type != gosocks5.AddrIPv4 {
		if err := writeReply(client, gosocks5.AddrUnsupported, nil); err != nil {
			return err
		}
		return fmt.Errorf("SOCKS address type %d is not supported", request.Addr.Type)
	}
	if err := client.SetDeadline(time.Time{}); err != nil {
		return fmt.Errorf("clear SOCKS request deadline: %w", err)
	}

	targetContext, cancelTarget := context.WithTimeout(ctx, s.connectTimeout)
	defer cancelTarget()
	ips, err := s.resolver.Resolve(targetContext, request.Addr.Host, isDomain)
	if err != nil {
		reply := uint8(gosocks5.HostUnreachable)
		if errors.Is(err, target.ErrNotAllowed) {
			reply = gosocks5.NotAllowed
		}
		if writeErr := writeReply(client, reply, nil); writeErr != nil {
			return writeErr
		}
		return fmt.Errorf("resolve SOCKS target: %w", err)
	}

	targetConn, err := s.dialApproved(targetContext, ips, request.Addr.Port)
	if err != nil {
		if writeErr := writeReply(client, replyForDialError(err), nil); writeErr != nil {
			return writeErr
		}
		return err
	}
	if !s.track(targetConn) {
		_ = targetConn.Close()
		return ctx.Err()
	}
	defer s.untrack(targetConn)
	defer targetConn.Close()

	if err := writeReply(client, gosocks5.Succeeded, ipv4BoundAddress(targetConn.LocalAddr())); err != nil {
		return err
	}
	if err := client.SetDeadline(time.Time{}); err != nil {
		return fmt.Errorf("clear SOCKS client deadline: %w", err)
	}

	relay(client, targetConn)
	return nil
}

func readRequest(reader io.Reader) (*gosocks5.Request, error) {
	var header [4]byte
	if _, err := io.ReadFull(reader, header[:]); err != nil {
		return nil, err
	}
	if header[0] != gosocks5.Ver5 {
		return nil, gosocks5.ErrBadVersion
	}
	if header[2] != 0 {
		return nil, errNonzeroReservedByte
	}

	length := 0
	switch header[3] {
	case gosocks5.AddrIPv4:
		length = 10
	case gosocks5.AddrIPv6:
		length = 22
	case gosocks5.AddrDomain:
		var domainLength [1]byte
		if _, err := io.ReadFull(reader, domainLength[:]); err != nil {
			return nil, err
		}
		length = 7 + int(domainLength[0])
		frame := make([]byte, length)
		copy(frame, header[:])
		frame[4] = domainLength[0]
		if _, err := io.ReadFull(reader, frame[5:]); err != nil {
			return nil, err
		}
		return gosocks5.ReadRequest(bytes.NewReader(frame))
	default:
		return nil, gosocks5.ErrBadAddrType
	}
	frame := make([]byte, length)
	copy(frame, header[:])
	if _, err := io.ReadFull(reader, frame[len(header):]); err != nil {
		return nil, err
	}
	return gosocks5.ReadRequest(bytes.NewReader(frame))
}

func containsMethod(methods []uint8, wanted uint8) bool {
	for _, method := range methods {
		if method == wanted {
			return true
		}
	}
	return false
}

func constantTimeCredentialsEqual(
	username string,
	password string,
	expectedUsername [sha256.Size]byte,
	expectedPassword [sha256.Size]byte,
) bool {
	usernameHash := sha256.Sum256([]byte(username))
	passwordHash := sha256.Sum256([]byte(password))
	usernameMatches := subtle.ConstantTimeCompare(usernameHash[:], expectedUsername[:])
	passwordMatches := subtle.ConstantTimeCompare(passwordHash[:], expectedPassword[:])
	return usernameMatches&passwordMatches == 1
}

func setPhaseDeadline(conn net.Conn, timeout time.Duration) error {
	if err := conn.SetDeadline(time.Now().Add(timeout)); err != nil {
		return fmt.Errorf("set SOCKS handshake deadline: %w", err)
	}
	return nil
}

func (s *Server) dialApproved(ctx context.Context, ips []netip.Addr, port uint16) (net.Conn, error) {
	if len(ips) == 0 {
		return nil, target.ErrNotAllowed
	}
	connectContext, cancel := context.WithTimeout(ctx, s.connectTimeout)
	defer cancel()
	deadline, _ := connectContext.Deadline()

	var lastErr error
	for index, ip := range ips {
		address := net.JoinHostPort(ip.String(), strconv.Itoa(int(port)))
		// Share the remaining total budget among the remaining approved
		// addresses, with net.Dialer's two-second minimum per attempt.
		// The parent context still caps the total resolution/dial time.
		attemptTimeout := time.Until(deadline) / time.Duration(len(ips)-index)
		if attemptTimeout < 2*time.Second {
			attemptTimeout = 2 * time.Second
		}
		attemptContext, cancelAttempt := context.WithTimeout(connectContext, attemptTimeout)
		conn, err := s.dialer.DialContext(attemptContext, "tcp4", address)
		cancelAttempt()
		if err == nil {
			return conn, nil
		}
		lastErr = err
		if connectContext.Err() != nil {
			break
		}
	}
	if lastErr == nil {
		lastErr = errors.New("resolver returned no IPv4 target")
	}
	return nil, fmt.Errorf("connect to approved IPv4 target: %w", lastErr)
}

func writeReply(conn net.Conn, reply uint8, address *gosocks5.Addr) error {
	if err := gosocks5.NewReply(reply, address).Write(conn); err != nil {
		return fmt.Errorf("write SOCKS reply %d: %w", reply, err)
	}
	return nil
}

func replyForDialError(err error) uint8 {
	switch {
	case errors.Is(err, syscall.ENETUNREACH):
		return gosocks5.NetUnreachable
	case errors.Is(err, syscall.EHOSTUNREACH):
		return gosocks5.HostUnreachable
	case errors.Is(err, syscall.ECONNREFUSED):
		return gosocks5.ConnRefused
	default:
		return gosocks5.Failure
	}
}

func ipv4BoundAddress(address net.Addr) *gosocks5.Addr {
	tcpAddress, ok := address.(*net.TCPAddr)
	if !ok {
		return nil
	}
	ip := tcpAddress.IP.To4()
	if ip == nil {
		return nil
	}
	return &gosocks5.Addr{
		Type: gosocks5.AddrIPv4,
		Host: ip.String(),
		Port: uint16(tcpAddress.Port),
	}
}

func relay(client, targetConn net.Conn) {
	done := make(chan struct{}, 2)
	copyHalf := func(destination, source net.Conn) {
		if _, err := io.Copy(destination, source); err != nil {
			// A failed direction cannot carry a later response. Close both
			// sockets so the other copy does not wait on an idle peer.
			_ = destination.Close()
			_ = source.Close()
		} else if writer, ok := destination.(interface{ CloseWrite() error }); ok {
			_ = writer.CloseWrite()
		}
		done <- struct{}{}
	}

	go copyHalf(targetConn, client)
	go copyHalf(client, targetConn)
	<-done
	<-done
}
