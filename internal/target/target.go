// Package target enforces the IPv4-only public destination boundary.
package target

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/netip"
)

var (
	ErrNotAllowed    = errors.New("target is not an allowed public IPv4 address")
	ErrNoIPv4Address = errors.New("target has no IPv4 address")
)

// IANA IPv4 Special-Purpose Address Space, reviewed against the registry's
// 2025-10-09 snapshot. Every registered special-purpose block is rejected,
// including entries marked Globally Reachable. Multicast is also rejected.
var blockedPrefixes = mustPrefixes(
	"0.0.0.0/8",
	"10.0.0.0/8",
	"100.64.0.0/10",
	"127.0.0.0/8",
	"169.254.0.0/16",
	"172.16.0.0/12",
	"192.0.0.0/24",
	"192.0.2.0/24",
	"192.31.196.0/24",
	"192.52.193.0/24",
	"192.88.99.0/24",
	"192.168.0.0/16",
	"192.175.48.0/24",
	"198.18.0.0/15",
	"198.51.100.0/24",
	"203.0.113.0/24",
	"224.0.0.0/4",
	"240.0.0.0/4",
)

func mustPrefixes(values ...string) []netip.Prefix {
	prefixes := make([]netip.Prefix, 0, len(values))
	for _, value := range values {
		prefixes = append(prefixes, netip.MustParsePrefix(value))
	}
	return prefixes
}

// Resolver performs exactly one A lookup for domain requests and filters the
// resulting addresses before the server dials a numeric IPv4 destination.
type Resolver struct {
	lookupIPv4 func(context.Context, string) ([]netip.Addr, error)
	localIPv4  func() (map[netip.Addr]struct{}, error)
}

// NewResolver uses the host resolver and current interface addresses.
func NewResolver() *Resolver {
	dnsResolver := newIPv4DNSResolver()
	return &Resolver{
		lookupIPv4: func(ctx context.Context, host string) ([]netip.Addr, error) {
			return dnsResolver.LookupNetIP(ctx, "ip4", host)
		},
		localIPv4: currentLocalIPv4,
	}
}

func newIPv4DNSResolver() *net.Resolver {
	dialer := &net.Dialer{}
	return &net.Resolver{
		PreferGo: true,
		Dial: func(ctx context.Context, network, address string) (net.Conn, error) {
			ipv4Network, ipv4Address, err := ipv4DNSAddress(network, address)
			if err != nil {
				return nil, err
			}
			return dialer.DialContext(ctx, ipv4Network, ipv4Address)
		},
	}
}

func ipv4DNSAddress(network, address string) (string, string, error) {
	var ipv4Network string
	switch network {
	case "udp", "udp4":
		ipv4Network = "udp4"
	case "tcp", "tcp4":
		ipv4Network = "tcp4"
	default:
		return "", "", fmt.Errorf("DNS transport %q is not IPv4", network)
	}

	host, port, err := net.SplitHostPort(address)
	if err != nil {
		return "", "", fmt.Errorf("parse DNS server address %q: %w", address, err)
	}
	ip, err := netip.ParseAddr(host)
	if err != nil {
		return "", "", fmt.Errorf("DNS server address %q is not a literal IP: %w", host, err)
	}
	ip = ip.Unmap()
	if !ip.Is4() {
		return "", "", fmt.Errorf("DNS server address %q is not IPv4", host)
	}
	return ipv4Network, net.JoinHostPort(ip.String(), port), nil
}

// Resolve resolves and filters host. domain=false requires a literal IPv4
// address; domain=true performs one IPv4-only lookup.
func (resolver *Resolver) Resolve(
	ctx context.Context,
	host string,
	domain bool,
) ([]netip.Addr, error) {
	if resolver == nil || resolver.lookupIPv4 == nil || resolver.localIPv4 == nil {
		return nil, fmt.Errorf("target resolver is not initialized")
	}
	if host == "" {
		return nil, fmt.Errorf("target host is empty")
	}

	var candidates []netip.Addr
	if domain {
		resolved, err := resolver.lookupIPv4(ctx, host)
		if err != nil {
			return nil, fmt.Errorf("resolve A records for %q: %w", host, err)
		}
		candidates = resolved
	} else {
		address, err := netip.ParseAddr(host)
		if err != nil {
			return nil, fmt.Errorf("parse IPv4 target %q: %w", host, err)
		}
		if !address.Is4() {
			return nil, fmt.Errorf("%w: %s is not IPv4", ErrNotAllowed, host)
		}
		candidates = []netip.Addr{address}
	}
	if len(candidates) == 0 {
		return nil, fmt.Errorf("%w: %q", ErrNoIPv4Address, host)
	}

	local, err := resolver.localIPv4()
	if err != nil {
		return nil, fmt.Errorf("enumerate local IPv4 addresses: %w", err)
	}

	allowed := make([]netip.Addr, 0, len(candidates))
	seen := make(map[netip.Addr]struct{}, len(candidates))
	for _, candidate := range candidates {
		if !candidate.Is4() || !isPublic(candidate) {
			continue
		}
		if _, isLocal := local[candidate]; isLocal {
			continue
		}
		if _, duplicate := seen[candidate]; duplicate {
			continue
		}
		seen[candidate] = struct{}{}
		allowed = append(allowed, candidate)
	}
	if len(allowed) == 0 {
		return nil, fmt.Errorf("%w: %q", ErrNotAllowed, host)
	}
	return allowed, nil
}

func isPublic(address netip.Addr) bool {
	if !address.Is4() {
		return false
	}
	for _, prefix := range blockedPrefixes {
		if prefix.Contains(address) {
			return false
		}
	}
	return true
}

func currentLocalIPv4() (map[netip.Addr]struct{}, error) {
	addresses, err := net.InterfaceAddrs()
	if err != nil {
		return nil, err
	}
	local := make(map[netip.Addr]struct{})
	for _, address := range addresses {
		prefix, err := netip.ParsePrefix(address.String())
		if err != nil {
			continue
		}
		ip := prefix.Addr()
		if ip.Is4() {
			local[ip] = struct{}{}
		}
	}
	return local, nil
}
