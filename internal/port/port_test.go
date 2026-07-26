package port

import (
	"errors"
	"fmt"
	"net"
	"strings"
	"syscall"
	"testing"
)

func TestValidate(t *testing.T) {
	t.Parallel()

	for _, port := range []int{Min, 54321, Max} {
		if err := Validate(port); err != nil {
			t.Fatalf("Validate(%d) returned %v", port, err)
		}
	}
	for _, port := range []int{-1, 0, Min - 1, Max + 1} {
		if err := Validate(port); !errors.Is(err, ErrInvalidPort) {
			t.Fatalf("Validate(%d) error = %v, want ErrInvalidPort", port, err)
		}
	}
}

func TestCheckAvailableUsesRealTCP4Bind(t *testing.T) {
	listener, err := net.ListenTCP("tcp4", &net.TCPAddr{
		IP:   net.IPv4zero,
		Port: 0,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()

	port := listener.Addr().(*net.TCPAddr).Port
	err = CheckAvailable(port)
	if !IsInUse(err) {
		t.Fatalf("CheckAvailable(%d) error = %v, want address in use", port, err)
	}
}

func TestParseReservedPorts(t *testing.T) {
	t.Parallel()

	got, err := ParseReservedPorts("22, 1000-2000,65535\n")
	if err != nil {
		t.Fatal(err)
	}
	for _, port := range []int{22, 1000, 1500, 2000, 65535} {
		if !got.Contains(port) {
			t.Errorf("reserved ports do not contain %d", port)
		}
	}
	for _, port := range []int{21, 23, 999, 2001} {
		if got.Contains(port) {
			t.Errorf("reserved ports unexpectedly contain %d", port)
		}
	}
}

func TestParseReservedPortsRejectsInvalidValues(t *testing.T) {
	t.Parallel()

	for _, value := range []string{
		",",
		"22,",
		"-1",
		"1-",
		"2-1",
		"1-2-3",
		"65536",
		"abc",
	} {
		if _, err := ParseReservedPorts(value); err == nil {
			t.Errorf("ParseReservedPorts(%q) unexpectedly succeeded", value)
		}
	}
}

func TestSelectAvailableSkipsReservedAndOccupiedPorts(t *testing.T) {
	t.Parallel()

	var checked []int
	check := func(port int) error {
		checked = append(checked, port)
		if port == 2002 {
			return fmt.Errorf("listen: %w", syscall.EADDRINUSE)
		}
		return nil
	}

	got, err := SelectAvailable(strings.NewReader("2000-2001"), 2000, check)
	if err != nil {
		t.Fatal(err)
	}
	if got != 2003 {
		t.Fatalf("selected port = %d, want 2003", got)
	}
	if want := []int{2002, 2003}; fmt.Sprint(checked) != fmt.Sprint(want) {
		t.Fatalf("checked ports = %v, want %v", checked, want)
	}
}

func TestSelectAvailableWrapsAtMaximum(t *testing.T) {
	t.Parallel()

	check := func(port int) error {
		if port == Max {
			return syscall.EADDRINUSE
		}
		return nil
	}
	got, err := SelectAvailable(strings.NewReader(""), Max, check)
	if err != nil {
		t.Fatal(err)
	}
	if got != Min {
		t.Fatalf("selected port = %d, want %d", got, Min)
	}
}

func TestSelectAvailableStopsOnNonConflictError(t *testing.T) {
	t.Parallel()

	want := errors.New("bind not permitted")
	_, err := SelectAvailable(strings.NewReader(""), 2000, func(int) error {
		return want
	})
	if !errors.Is(err, want) {
		t.Fatalf("SelectAvailable error = %v, want wrapped %v", err, want)
	}
}

func TestSelectAvailableRejectsInvalidDependencies(t *testing.T) {
	t.Parallel()

	if _, err := SelectAvailable(strings.NewReader(""), Min-1, func(int) error { return nil }); !errors.Is(err, ErrInvalidPort) {
		t.Fatalf("invalid start error = %v, want ErrInvalidPort", err)
	}
	if _, err := SelectAvailable(nil, Min, func(int) error { return nil }); err == nil {
		t.Fatal("nil reserved reader unexpectedly succeeded")
	}
	if _, err := SelectAvailable(strings.NewReader(""), Min, nil); err == nil {
		t.Fatal("nil check function unexpectedly succeeded")
	}
}
