package target

import (
	"context"
	"errors"
	"net/netip"
	"testing"
)

func testResolver(resolved []netip.Addr, lookupErr error, local ...string) *Resolver {
	localSet := make(map[netip.Addr]struct{}, len(local))
	for _, value := range local {
		localSet[netip.MustParseAddr(value)] = struct{}{}
	}
	return &Resolver{
		lookupIPv4: func(context.Context, string) ([]netip.Addr, error) {
			return resolved, lookupErr
		},
		localIPv4: func() (map[netip.Addr]struct{}, error) {
			return localSet, nil
		},
	}
}

func TestResolveLiteralPublicIPv4(t *testing.T) {
	t.Parallel()

	got, err := testResolver(nil, nil).Resolve(context.Background(), "8.8.8.8", false)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0] != netip.MustParseAddr("8.8.8.8") {
		t.Fatalf("Resolve = %v, want [8.8.8.8]", got)
	}
}

func TestResolveRejectsSpecialAndLocalAddresses(t *testing.T) {
	t.Parallel()

	blocked := []string{
		"0.0.0.1",
		"10.0.0.1",
		"100.64.0.1",
		"127.0.0.1",
		"169.254.169.254",
		"172.16.0.1",
		"192.0.0.8",
		"192.0.0.9",
		"192.0.0.10",
		"192.0.2.1",
		"192.31.196.1",
		"192.52.193.1",
		"192.88.99.1",
		"192.168.0.1",
		"192.175.48.1",
		"198.18.0.1",
		"198.51.100.1",
		"203.0.113.1",
		"224.0.0.1",
		"255.255.255.255",
	}
	for _, address := range blocked {
		address := address
		t.Run(address, func(t *testing.T) {
			t.Parallel()
			if _, err := testResolver(nil, nil).Resolve(context.Background(), address, false); !errors.Is(err, ErrNotAllowed) {
				t.Fatalf("Resolve error = %v, want ErrNotAllowed", err)
			}
		})
	}

	resolver := testResolver(nil, nil, "8.8.8.8")
	if _, err := resolver.Resolve(context.Background(), "8.8.8.8", false); !errors.Is(err, ErrNotAllowed) {
		t.Fatalf("local address error = %v, want ErrNotAllowed", err)
	}
}

func TestIPv4DNSAddressForcesIPv4Transport(t *testing.T) {
	t.Parallel()

	tests := []struct {
		network     string
		address     string
		wantNetwork string
		wantAddress string
	}{
		{
			network:     "udp",
			address:     "8.8.8.8:53",
			wantNetwork: "udp4",
			wantAddress: "8.8.8.8:53",
		},
		{
			network:     "tcp",
			address:     "1.1.1.1:53",
			wantNetwork: "tcp4",
			wantAddress: "1.1.1.1:53",
		},
		{
			network:     "udp4",
			address:     "[::ffff:8.8.4.4]:53",
			wantNetwork: "udp4",
			wantAddress: "8.8.4.4:53",
		},
	}
	for _, test := range tests {
		gotNetwork, gotAddress, err := ipv4DNSAddress(test.network, test.address)
		if err != nil {
			t.Fatalf("ipv4DNSAddress(%q, %q): %v", test.network, test.address, err)
		}
		if gotNetwork != test.wantNetwork || gotAddress != test.wantAddress {
			t.Fatalf(
				"ipv4DNSAddress(%q, %q) = %q, %q; want %q, %q",
				test.network,
				test.address,
				gotNetwork,
				gotAddress,
				test.wantNetwork,
				test.wantAddress,
			)
		}
	}

	for _, test := range []struct {
		network string
		address string
	}{
		{network: "udp6", address: "[2001:4860:4860::8888]:53"},
		{network: "udp", address: "[2001:4860:4860::8888]:53"},
		{network: "udp", address: "resolver.example:53"},
	} {
		if _, _, err := ipv4DNSAddress(test.network, test.address); err == nil {
			t.Fatalf("ipv4DNSAddress(%q, %q) unexpectedly succeeded", test.network, test.address)
		}
	}
}

func TestResolveDomainOnceFiltersAndDeduplicates(t *testing.T) {
	t.Parallel()

	calls := 0
	resolver := testResolver([]netip.Addr{
		netip.MustParseAddr("10.0.0.1"),
		netip.MustParseAddr("8.8.8.8"),
		netip.MustParseAddr("8.8.8.8"),
		netip.MustParseAddr("1.1.1.1"),
	}, nil)
	originalLookup := resolver.lookupIPv4
	resolver.lookupIPv4 = func(ctx context.Context, host string) ([]netip.Addr, error) {
		calls++
		return originalLookup(ctx, host)
	}

	got, err := resolver.Resolve(context.Background(), "example.test", true)
	if err != nil {
		t.Fatal(err)
	}
	if calls != 1 {
		t.Fatalf("lookup calls = %d, want 1", calls)
	}
	want := []netip.Addr{
		netip.MustParseAddr("8.8.8.8"),
		netip.MustParseAddr("1.1.1.1"),
	}
	if len(got) != len(want) {
		t.Fatalf("Resolve = %v, want %v", got, want)
	}
	for index := range want {
		if got[index] != want[index] {
			t.Fatalf("Resolve = %v, want %v", got, want)
		}
	}
}

func TestResolveDomainOnlyBlocked(t *testing.T) {
	t.Parallel()

	resolver := testResolver([]netip.Addr{
		netip.MustParseAddr("127.0.0.1"),
		netip.MustParseAddr("169.254.169.254"),
	}, nil)
	if _, err := resolver.Resolve(context.Background(), "blocked.test", true); !errors.Is(err, ErrNotAllowed) {
		t.Fatalf("Resolve error = %v, want ErrNotAllowed", err)
	}
}

func TestResolveErrors(t *testing.T) {
	t.Parallel()

	lookupErr := errors.New("lookup failed")
	if _, err := testResolver(nil, lookupErr).Resolve(context.Background(), "missing.test", true); !errors.Is(err, lookupErr) {
		t.Fatalf("lookup error = %v, want wrapped %v", err, lookupErr)
	}
	if _, err := testResolver(nil, nil).Resolve(context.Background(), "no-a.test", true); !errors.Is(err, ErrNoIPv4Address) {
		t.Fatalf("empty A result error = %v, want ErrNoIPv4Address", err)
	}
	if _, err := testResolver(nil, nil).Resolve(context.Background(), "2001:db8::1", false); !errors.Is(err, ErrNotAllowed) {
		t.Fatalf("IPv6 error = %v, want ErrNotAllowed", err)
	}
}
