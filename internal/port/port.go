// Package port validates and selects the IPv4 TCP listener port used by
// Socks-VPS.
package port

import (
	"crypto/rand"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net"
	"os"
	"strconv"
	"strings"
	"syscall"
)

const (
	Min = 1024
	Max = 65535

	ReservedPortsPath = "/proc/sys/net/ipv4/ip_local_reserved_ports"
)

var (
	ErrInvalidPort     = errors.New("port must be between 1024 and 65535")
	ErrNoAvailablePort = errors.New("no available IPv4 TCP port")
)

// CheckFunc checks whether the supplied port can be bound with the same
// tcp4/0.0.0.0 semantics as the service listener.
type CheckFunc func(int) error

// CheckAvailable performs a real IPv4 TCP wildcard bind and immediately
// releases it. A later service bind remains the authoritative result.
func CheckAvailable(port int) error {
	if err := Validate(port); err != nil {
		return err
	}

	listener, err := net.ListenTCP("tcp4", &net.TCPAddr{
		IP:   net.IPv4zero,
		Port: port,
	})
	if err != nil {
		return fmt.Errorf("bind tcp4 0.0.0.0:%d: %w", port, err)
	}
	if err := listener.Close(); err != nil {
		return fmt.Errorf("close tcp4 port probe for %d: %w", port, err)
	}
	return nil
}

// IsInUse reports whether a port check failed because another socket already
// owns the requested bind.
func IsInUse(err error) bool {
	return errors.Is(err, syscall.EADDRINUSE)
}

// Validate applies the public listener port range.
func Validate(port int) error {
	if port < Min || port > Max {
		return fmt.Errorf("%w: %d", ErrInvalidPort, port)
	}
	return nil
}

// Range is an inclusive system-reserved port range.
type Range struct {
	First int
	Last  int
}

// ReservedPorts is the parsed value of Linux ip_local_reserved_ports.
type ReservedPorts []Range

// Contains reports whether port is covered by a reserved range.
func (ports ReservedPorts) Contains(port int) bool {
	for _, reserved := range ports {
		if port >= reserved.First && port <= reserved.Last {
			return true
		}
	}
	return false
}

// ParseReservedPorts parses the Linux ip_local_reserved_ports format.
func ParseReservedPorts(value string) (ReservedPorts, error) {
	value = strings.TrimSpace(value)
	if value == "" {
		return nil, nil
	}

	tokens := strings.Split(value, ",")
	ports := make(ReservedPorts, 0, len(tokens))
	for _, token := range tokens {
		token = strings.TrimSpace(token)
		if token == "" {
			return nil, fmt.Errorf("invalid empty reserved port entry")
		}

		firstText, lastText, isRange := strings.Cut(token, "-")
		first, err := parseKernelPort(firstText)
		if err != nil {
			return nil, fmt.Errorf("invalid reserved port %q: %w", token, err)
		}

		last := first
		if isRange {
			if lastText == "" || strings.Contains(lastText, "-") {
				return nil, fmt.Errorf("invalid reserved port range %q", token)
			}
			last, err = parseKernelPort(lastText)
			if err != nil {
				return nil, fmt.Errorf("invalid reserved port range %q: %w", token, err)
			}
			if first > last {
				return nil, fmt.Errorf("invalid descending reserved port range %q", token)
			}
		}

		ports = append(ports, Range{First: first, Last: last})
	}
	return ports, nil
}

func parseKernelPort(value string) (int, error) {
	if value == "" || strings.TrimSpace(value) != value {
		return 0, fmt.Errorf("invalid port %q", value)
	}
	port, err := strconv.Atoi(value)
	if err != nil {
		return 0, err
	}
	if port < 0 || port > Max {
		return 0, fmt.Errorf("port %d is outside 0-%d", port, Max)
	}
	return port, nil
}

// SelectAvailable checks every listener port once, starting at start and
// wrapping at Max. Reserved ports are never probed. Only EADDRINUSE advances
// to the next candidate; any other bind failure is returned immediately.
func SelectAvailable(reserved io.Reader, start int, check CheckFunc) (int, error) {
	return SelectAvailableExcluding(reserved, start, nil, check)
}

// SelectAvailableExcluding behaves like SelectAvailable and also skips ports
// already assigned to another Socks-VPS instance.
func SelectAvailableExcluding(
	reserved io.Reader,
	start int,
	excluded map[int]struct{},
	check CheckFunc,
) (int, error) {
	if err := Validate(start); err != nil {
		return 0, fmt.Errorf("automatic port start: %w", err)
	}
	if reserved == nil {
		return 0, fmt.Errorf("read system-reserved ports: nil reader")
	}
	if check == nil {
		return 0, fmt.Errorf("check automatic port: nil check function")
	}

	data, err := io.ReadAll(reserved)
	if err != nil {
		return 0, fmt.Errorf("read system-reserved ports: %w", err)
	}
	reservedPorts, err := ParseReservedPorts(string(data))
	if err != nil {
		return 0, fmt.Errorf("parse system-reserved ports: %w", err)
	}

	const candidateCount = Max - Min + 1
	for offset := 0; offset < candidateCount; offset++ {
		candidate := Min + (start-Min+offset)%candidateCount
		if reservedPorts.Contains(candidate) {
			continue
		}
		if _, exists := excluded[candidate]; exists {
			continue
		}

		err := check(candidate)
		switch {
		case err == nil:
			return candidate, nil
		case IsInUse(err):
			continue
		default:
			return 0, fmt.Errorf("check automatic port %d: %w", candidate, err)
		}
	}

	return 0, ErrNoAvailablePort
}

// SelectAutomatic reads Linux's authoritative reserved-port list, chooses a
// random starting point, and performs real tcp4 bind checks.
func SelectAutomatic() (int, error) {
	return SelectAutomaticExcluding(nil)
}

// SelectAutomaticExcluding selects an automatic port while skipping the
// supplied listener ports.
func SelectAutomaticExcluding(excluded map[int]struct{}) (int, error) {
	reserved, err := os.Open(ReservedPortsPath)
	if err != nil {
		return 0, fmt.Errorf("open system-reserved ports %s: %w", ReservedPortsPath, err)
	}
	defer reserved.Close()

	start, err := randomStart()
	if err != nil {
		return 0, err
	}
	return SelectAvailableExcluding(reserved, start, excluded, CheckAvailable)
}

func randomStart() (int, error) {
	const candidateCount = Max - Min + 1
	value, err := rand.Int(rand.Reader, big.NewInt(candidateCount))
	if err != nil {
		return 0, fmt.Errorf("choose automatic port start: %w", err)
	}
	return Min + int(value.Int64()), nil
}
