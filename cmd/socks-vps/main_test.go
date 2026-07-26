package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"socks-vps/internal/config"
	"socks-vps/internal/server"
	"socks-vps/internal/target"
)

func TestHelpDocumentsCommandsAndExitStatus(t *testing.T) {
	var stdout, stderr bytes.Buffer
	code := run([]string{"help"}, strings.NewReader(""), &stdout, &stderr)
	if code != exitOK {
		t.Fatalf("run(help) = %d, want %d", code, exitOK)
	}
	for _, expected := range []string{
		"serve",
		"config-check",
		"config-create",
		"config-port",
		"self-check",
		"64  command usage or configuration failure",
		"78  IPv4 TCP listener address is already in use",
	} {
		if !strings.Contains(stdout.String(), expected) {
			t.Errorf("help does not contain %q", expected)
		}
	}
	if stderr.Len() != 0 {
		t.Fatalf("stderr = %q, want empty", stderr.String())
	}
}

func TestConfigCreateCheckAndPreserve(t *testing.T) {
	directory := t.TempDir()
	configPath := filepath.Join(directory, "config.json")
	credentials := []byte("alice\x00correct horse battery staple\x00")

	var stdout, stderr bytes.Buffer
	code := run(
		[]string{
			"config-create",
			"--port", "1080",
			"--version", "1.0.0",
			"--output", configPath,
		},
		bytes.NewReader(credentials),
		&stdout,
		&stderr,
	)
	if code != exitOK {
		t.Fatalf("config-create code = %d, stderr = %q", code, stderr.String())
	}
	cfg, err := config.Load(configPath)
	if err != nil {
		t.Fatalf("load created config: %v", err)
	}
	if cfg.Listen != config.ListenAddress ||
		cfg.Port != 1080 ||
		cfg.Username != "alice" ||
		cfg.Password != "correct horse battery staple" ||
		cfg.Version != "1.0.0" {
		t.Fatalf("created config = %#v", cfg)
	}

	stdout.Reset()
	stderr.Reset()
	if code := run(
		[]string{"config-check", "--config", configPath},
		strings.NewReader(""),
		&stdout,
		&stderr,
	); code != exitOK {
		t.Fatalf("config-check code = %d, stderr = %q", code, stderr.String())
	}

	updatedPath := filepath.Join(directory, "updated.json")
	stdout.Reset()
	stderr.Reset()
	if code := run(
		[]string{
			"config-create",
			"--preserve", configPath,
			"--version", "1.0.1",
			"--output", updatedPath,
		},
		strings.NewReader(""),
		&stdout,
		&stderr,
	); code != exitOK {
		t.Fatalf("config-create --preserve code = %d, stderr = %q", code, stderr.String())
	}
	updated, err := config.Load(updatedPath)
	if err != nil {
		t.Fatalf("load preserved config: %v", err)
	}
	if updated.Port != cfg.Port ||
		updated.Username != cfg.Username ||
		updated.Password != cfg.Password ||
		updated.Version != "1.0.1" {
		t.Fatalf("preserved config = %#v, original = %#v", updated, cfg)
	}
}

func TestConfigCreateCheckDoesNotWriteCredentials(t *testing.T) {
	var stdout, stderr bytes.Buffer
	code := run(
		[]string{
			"config-create",
			"--check",
			"--port", "1080",
			"--version", "1.0.0",
		},
		bytes.NewReader([]byte("alice\x00very-secret\x00")),
		&stdout,
		&stderr,
	)
	if code != exitOK {
		t.Fatalf("config-create --check code = %d, stderr = %q", code, stderr.String())
	}
	if strings.Contains(stdout.String(), "alice") || strings.Contains(stdout.String(), "very-secret") {
		t.Fatalf("stdout exposed credentials: %q", stdout.String())
	}
}

func TestConfigCreateRejectsMalformedStdinWithoutEchoingIt(t *testing.T) {
	const secret = "do-not-print-this"
	var stdout, stderr bytes.Buffer
	code := run(
		[]string{
			"config-create",
			"--check",
			"--port", "1080",
			"--version", "1.0.0",
		},
		strings.NewReader("alice\x00"+secret+"\n"),
		&stdout,
		&stderr,
	)
	if code != exitConfigError {
		t.Fatalf("config-create malformed stdin code = %d, want %d", code, exitConfigError)
	}
	if strings.Contains(stderr.String(), secret) {
		t.Fatalf("stderr exposed credential: %q", stderr.String())
	}
}

func TestConfigCheckInvalidConfigUsesConfigExitStatus(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	if err := os.WriteFile(path, []byte(`{"schema":1}`), 0o640); err != nil {
		t.Fatalf("write invalid config: %v", err)
	}
	var stdout, stderr bytes.Buffer
	code := run(
		[]string{"config-check", "--config", path},
		strings.NewReader(""),
		&stdout,
		&stderr,
	)
	if code != exitConfigError {
		t.Fatalf("config-check code = %d, want %d; stderr = %q", code, exitConfigError, stderr.String())
	}
}

func TestConfigPort(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	if err := config.Write(path, validConfig(23456)); err != nil {
		t.Fatalf("write config: %v", err)
	}

	var stdout, stderr bytes.Buffer
	code := run(
		[]string{"config-port", "--config", path},
		strings.NewReader(""),
		&stdout,
		&stderr,
	)
	if code != exitOK {
		t.Fatalf("config-port code = %d, stderr = %q", code, stderr.String())
	}
	if got, want := stdout.String(), "23456\n"; got != want {
		t.Fatalf("config-port stdout = %q, want %q", got, want)
	}
	if strings.Contains(stdout.String(), "alice") ||
		strings.Contains(stdout.String(), "correct horse battery staple") {
		t.Fatalf("config-port exposed credentials: %q", stdout.String())
	}
}

func TestConfigPortRejectsMissingExtraAndInvalidConfig(t *testing.T) {
	invalidPath := filepath.Join(t.TempDir(), "config.json")
	if err := os.WriteFile(invalidPath, []byte(`{"schema":1}`), 0o640); err != nil {
		t.Fatalf("write invalid config: %v", err)
	}
	unsafePath := filepath.Join(t.TempDir(), "config.json")
	if err := config.Write(unsafePath, validConfig(23456)); err != nil {
		t.Fatalf("write unsafe-permission config: %v", err)
	}
	if err := os.Chmod(unsafePath, 0o644); err != nil {
		t.Fatalf("set unsafe config permissions: %v", err)
	}

	tests := [][]string{
		{"config-port"},
		{"config-port", "--config", invalidPath},
		{"config-port", "--config", unsafePath},
		{"config-port", "--config", invalidPath, "extra"},
	}
	for _, args := range tests {
		var stdout, stderr bytes.Buffer
		if code := run(args, strings.NewReader(""), &stdout, &stderr); code != exitConfigError {
			t.Fatalf("run(%v) = %d, want %d; stderr = %q", args, code, exitConfigError, stderr.String())
		}
		if stdout.Len() != 0 {
			t.Fatalf("run(%v) stdout = %q, want empty", args, stdout.String())
		}
	}
}

func TestServeBindConflictUsesDedicatedExitStatus(t *testing.T) {
	listener, err := net.Listen("tcp4", "0.0.0.0:0")
	if err != nil {
		t.Fatalf("reserve listener: %v", err)
	}
	defer listener.Close()
	port := listener.Addr().(*net.TCPAddr).Port
	path := filepath.Join(t.TempDir(), "config.json")
	if err := config.Write(path, validConfig(port)); err != nil {
		t.Fatalf("write config: %v", err)
	}

	var stdout, stderr bytes.Buffer
	code := run(
		[]string{"serve", "--config", path},
		strings.NewReader(""),
		&stdout,
		&stderr,
	)
	if code != exitBindConflict {
		t.Fatalf("serve code = %d, want %d; stderr = %q", code, exitBindConflict, stderr.String())
	}
}

func TestPortCheckSupportsLiteralAndConfig(t *testing.T) {
	listener, err := net.Listen("tcp4", "0.0.0.0:0")
	if err != nil {
		t.Fatalf("reserve listener: %v", err)
	}
	defer listener.Close()
	portNumber := listener.Addr().(*net.TCPAddr).Port

	path := filepath.Join(t.TempDir(), "config.json")
	if err := config.Write(path, validConfig(portNumber)); err != nil {
		t.Fatalf("write config: %v", err)
	}
	for _, args := range [][]string{
		{"port-check", "--port", strconv.Itoa(portNumber)},
		{"port-check", "--config", path},
	} {
		var stdout, stderr bytes.Buffer
		if code := run(args, strings.NewReader(""), &stdout, &stderr); code != exitBindConflict {
			t.Fatalf("run(%v) = %d, want %d; stderr = %q", args, code, exitBindConflict, stderr.String())
		}
	}

	var stdout, stderr bytes.Buffer
	if code := run(
		[]string{"port-check", "--port", "80"},
		strings.NewReader(""),
		&stdout,
		&stderr,
	); code != exitConfigError {
		t.Fatalf("invalid port code = %d, want %d", code, exitConfigError)
	}
}

func TestIPdenyCheckUsesFirewallParser(t *testing.T) {
	sourceFile, err := os.Open("../../assets/ipdeny/SOURCE.json")
	if err != nil {
		t.Fatal(err)
	}
	var source struct {
		LineCount int `json:"line_count"`
	}
	if err := json.NewDecoder(sourceFile).Decode(&source); err != nil {
		_ = sourceFile.Close()
		t.Fatal(err)
	}
	if err := sourceFile.Close(); err != nil {
		t.Fatal(err)
	}

	var stdout, stderr bytes.Buffer
	code := run(
		[]string{"ipdeny-check", "--zone", "../../assets/ipdeny/cn-aggregated.zone"},
		strings.NewReader(""),
		&stdout,
		&stderr,
	)
	if code != exitOK {
		t.Fatalf("ipdeny-check code = %d, stderr = %q", code, stderr.String())
	}
	want := fmt.Sprintf("%d IPv4 CIDRs valid\n", source.LineCount)
	if got := stdout.String(); got != want {
		t.Fatalf("ipdeny-check stdout = %q, want %q", got, want)
	}
}

func TestFirewallRenderApplyAndRemove(t *testing.T) {
	directory := t.TempDir()
	configPath := filepath.Join(directory, "config.json")
	if err := config.Write(configPath, validConfig(23456)); err != nil {
		t.Fatalf("write config: %v", err)
	}
	zonePath := filepath.Join(directory, "zone")
	if err := os.WriteFile(zonePath, []byte("1.0.1.0/24\n"), 0o600); err != nil {
		t.Fatalf("write zone: %v", err)
	}
	outputPath := filepath.Join(directory, "firewall.nft")

	var stdout, stderr bytes.Buffer
	code := run(
		[]string{
			"firewall-render",
			"--config", configPath,
			"--zone", zonePath,
			"--output", outputPath,
		},
		strings.NewReader(""),
		&stdout,
		&stderr,
	)
	if code != exitOK {
		t.Fatalf("firewall-render code = %d, stderr = %q", code, stderr.String())
	}
	batch, err := os.ReadFile(outputPath)
	if err != nil {
		t.Fatalf("read firewall batch: %v", err)
	}
	if !strings.Contains(string(batch), "tcp dport 23456 counter drop") {
		t.Fatalf("firewall batch does not contain configured port:\n%s", batch)
	}

	existingPath := filepath.Join(directory, "existing.json")
	existing := `{"nftables":[{"table":{"family":"ip","name":"socks_vps","comment":"Socks-VPS managed table"}}]}`
	if err := os.WriteFile(existingPath, []byte(existing), 0o600); err != nil {
		t.Fatalf("write existing table JSON: %v", err)
	}
	stdout.Reset()
	stderr.Reset()
	code = run(
		[]string{
			"firewall-render",
			"--remove",
			"--existing-table-json", existingPath,
			"--output", outputPath,
		},
		strings.NewReader(""),
		&stdout,
		&stderr,
	)
	if code != exitOK {
		t.Fatalf("firewall-render --remove code = %d, stderr = %q", code, stderr.String())
	}
	batch, err = os.ReadFile(outputPath)
	if err != nil {
		t.Fatalf("read removal batch: %v", err)
	}
	if got, want := string(batch), "delete table ip socks_vps\n"; got != want {
		t.Fatalf("removal batch = %q, want %q", got, want)
	}

	stdout.Reset()
	stderr.Reset()
	code = run(
		[]string{
			"firewall-render",
			"--port", "23457",
			"--zone", zonePath,
			"--existing-table-json", "-",
			"--output", "-",
		},
		strings.NewReader(existing),
		&stdout,
		&stderr,
	)
	if code != exitOK {
		t.Fatalf("firewall-render stdin/stdout code = %d, stderr = %q", code, stderr.String())
	}
	if !strings.HasPrefix(stdout.String(), "delete table ip socks_vps\n") ||
		!strings.Contains(stdout.String(), "tcp dport 23457 counter drop") {
		t.Fatalf("stdout replacement batch is incomplete:\n%s", stdout.String())
	}
	if strings.Contains(stdout.String(), "batch written") {
		t.Fatalf("stdout batch contains status text:\n%s", stdout.String())
	}
}

func TestAtomicOutputRetainsTemporaryFileOnRenderFailure(t *testing.T) {
	directory := t.TempDir()
	outputPath := filepath.Join(directory, "result")
	renderError := errors.New("render failed")

	err := writeFileAtomically(outputPath, 0o600, func(io.Writer) error {
		return renderError
	})
	if !errors.Is(err, renderError) {
		t.Fatalf("writeFileAtomically() error = %v, want render error", err)
	}
	if !strings.Contains(err.Error(), "temporary file retained at") {
		t.Fatalf("error does not identify retained temporary file: %v", err)
	}
	retained, globErr := filepath.Glob(filepath.Join(directory, ".result.*"))
	if globErr != nil {
		t.Fatal(globErr)
	}
	if len(retained) != 1 {
		t.Fatalf("retained temporary files = %v, want one", retained)
	}
	info, statErr := os.Stat(retained[0])
	if statErr != nil {
		t.Fatal(statErr)
	}
	if got := info.Mode().Perm(); got != 0o600 {
		t.Fatalf("retained permissions = %04o, want 0600", got)
	}
}

func TestSelfCheckUsesOnlyLocalBlockedTarget(t *testing.T) {
	port := availableCommandPort(t)
	cfg := validConfig(port)
	path := filepath.Join(t.TempDir(), "config.json")
	if err := config.Write(path, cfg); err != nil {
		t.Fatalf("write config: %v", err)
	}

	// The self-check's 127.0.0.1 target must receive the policy rejection
	// reply without any public network request.
	service := server.New(cfg, blockedResolver{})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	serviceDone := make(chan error, 1)
	go func() {
		serviceDone <- service.Serve(ctx)
	}()
	waitForListener(t, port)

	var stdout, stderr bytes.Buffer
	code := run(
		[]string{"self-check", "--config", path},
		strings.NewReader(""),
		&stdout,
		&stderr,
	)
	cancel()
	select {
	case err := <-serviceDone:
		if err != nil {
			t.Fatalf("service Serve() error: %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("service did not stop")
	}
	if code != exitOK {
		t.Fatalf("self-check code = %d, stderr = %q", code, stderr.String())
	}
}

func TestDialUntilReadyRetriesOnlyConnectionRefused(t *testing.T) {
	successClient, successServer := net.Pipe()
	defer successServer.Close()
	dialer := &sequenceLocalDialer{
		results: []dialResult{
			{err: syscall.ECONNREFUSED},
			{err: syscall.ECONNREFUSED},
			{conn: successClient},
		},
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	conn, err := dialUntilReady(ctx, dialer, "127.0.0.1:1080")
	if err != nil {
		t.Fatalf("dialUntilReady() error: %v", err)
	}
	_ = conn.Close()
	if dialer.calls != 3 {
		t.Fatalf("dial calls = %d, want 3", dialer.calls)
	}

	dialer = &sequenceLocalDialer{results: []dialResult{{err: syscall.EACCES}}}
	if _, err := dialUntilReady(ctx, dialer, "127.0.0.1:1080"); !errors.Is(err, syscall.EACCES) {
		t.Fatalf("non-readiness error = %v, want EACCES", err)
	}
	if dialer.calls != 1 {
		t.Fatalf("non-readiness dial calls = %d, want 1", dialer.calls)
	}
}

type dialResult struct {
	conn net.Conn
	err  error
}

type sequenceLocalDialer struct {
	results []dialResult
	calls   int
}

func (dialer *sequenceLocalDialer) DialContext(
	context.Context,
	string,
	string,
) (net.Conn, error) {
	result := dialer.results[dialer.calls]
	dialer.calls++
	return result.conn, result.err
}

type blockedResolver struct{}

func (blockedResolver) Resolve(
	context.Context,
	string,
	bool,
) ([]netip.Addr, error) {
	return nil, target.ErrNotAllowed
}

func validConfig(port int) config.Config {
	return config.Config{
		Schema:   config.SchemaVersion,
		Listen:   config.ListenAddress,
		Port:     port,
		Username: "alice",
		Password: "correct horse battery staple",
		Version:  "1.0.0",
	}
}

func availableCommandPort(t *testing.T) int {
	t.Helper()
	listener, err := net.Listen("tcp4", "0.0.0.0:0")
	if err != nil {
		t.Fatalf("find available port: %v", err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	if err := listener.Close(); err != nil {
		t.Fatalf("close temporary listener: %v", err)
	}
	return port
}

func waitForListener(t *testing.T, port int) {
	t.Helper()
	address := net.JoinHostPort("127.0.0.1", strconv.Itoa(port))
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		conn, err := net.DialTimeout("tcp4", address, 20*time.Millisecond)
		if err == nil {
			_ = conn.Close()
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("listener %s did not start", address)
}
