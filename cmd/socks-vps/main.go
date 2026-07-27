package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/netip"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"syscall"
	"time"

	"github.com/go-gost/gosocks5"

	"socks-vps/internal/config"
	"socks-vps/internal/firewall"
	"socks-vps/internal/port"
	"socks-vps/internal/server"
	"socks-vps/internal/target"
)

const (
	exitOK           = 0
	exitRuntimeError = 1
	exitConfigError  = 64
	exitBindConflict = 78

	selfCheckTimeout       = 5 * time.Second
	readinessRetryInterval = 50 * time.Millisecond
)

func main() {
	os.Exit(run(os.Args[1:], os.Stdin, os.Stdout, os.Stderr))
}

func run(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		writeRootUsage(stderr)
		return exitConfigError
	}
	if args[0] == "help" || args[0] == "-h" || args[0] == "--help" {
		writeRootUsage(stdout)
		return exitOK
	}

	var code int
	var err error
	switch args[0] {
	case "serve":
		code, err = serveCommand(args[1:], stderr)
	case "config-check":
		code, err = configCheckCommand(args[1:], stdout, stderr)
	case "config-create":
		code, err = configCreateCommand(args[1:], stdin, stdout, stderr)
	case "config-detail":
		code, err = configDetailCommand(args[1:], stdout, stderr)
	case "config-port":
		code, err = configPortCommand(args[1:], stdout, stderr)
	case "config-ports":
		code, err = configPortsCommand(args[1:], stdout, stderr)
	case "credentials-generate":
		code, err = credentialsGenerateCommand(args[1:], stdout, stderr)
	case "self-check":
		code, err = selfCheckCommand(args[1:], stdout, stderr)
	case "port-check":
		code, err = portCheckCommand(args[1:], stdout, stderr)
	case "port-select":
		code, err = portSelectCommand(args[1:], stdout, stderr)
	case "ipdeny-check":
		code, err = ipdenyCheckCommand(args[1:], stdout, stderr)
	case "firewall-render":
		code, err = firewallRenderCommand(args[1:], stdin, stdout, stderr)
	default:
		writeRootUsage(stderr)
		return reportError(stderr, exitConfigError, fmt.Errorf("unknown command %q", args[0]))
	}
	if err != nil {
		return reportError(stderr, code, err)
	}
	return code
}

func writeRootUsage(writer io.Writer) {
	_, _ = io.WriteString(writer, `Usage: socks-vps <command> [options]

Commands:
  serve          run the IPv4 SOCKS5 service
  config-check   strictly validate an existing configuration
  config-create  validate or write the authoritative configuration
  config-detail  print one NUL-delimited configuration record
  config-port    print the configured IPv4 TCP listener port
  config-ports   print listener ports from a configuration directory
  credentials-generate generate a random NUL-delimited credential pair
  self-check     verify local authentication and target rejection
  port-check     verify that one IPv4 TCP port is available
  port-select    select an available non-reserved IPv4 TCP port
  ipdeny-check   validate the bundled IPv4 CIDR zone
  firewall-render render an owned nftables batch

Exit status:
  0   success
  1   unexpected runtime failure
  64  command usage or configuration failure
  78  IPv4 TCP listener address is already in use
`)
}

func reportError(stderr io.Writer, code int, err error) int {
	_, _ = fmt.Fprintf(stderr, "socks-vps: %v\n", err)
	return code
}

func serveCommand(args []string, stderr io.Writer) (int, error) {
	flags := newFlagSet("serve", stderr)
	configPath := flags.String("config", "", "path to config.json")
	configDirectory := flags.String("config-dir", "", "directory containing *.json configurations")
	if err := flags.Parse(args); err != nil {
		return flagExitCode(err), flagError(err)
	}
	if err := requireNoPositionals(flags); err != nil {
		return exitConfigError, err
	}
	configs, err := loadConfigs("serve", *configPath, *configDirectory)
	if err != nil {
		return exitConfigError, err
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := serveAll(ctx, configs); err != nil {
		if errors.Is(err, server.ErrAddressInUse) {
			return exitBindConflict, err
		}
		return exitRuntimeError, err
	}
	return exitOK, nil
}

type serveResult struct {
	port int
	err  error
}

func serveAll(parent context.Context, configs []config.Config) error {
	if len(configs) == 0 {
		return errors.New("serve requires at least one configuration")
	}

	ctx, cancel := context.WithCancel(parent)
	defer cancel()
	results := make(chan serveResult, len(configs))
	for _, cfg := range configs {
		cfg := cfg
		go func() {
			err := server.New(cfg, target.NewResolver()).Serve(ctx)
			if err != nil {
				err = fmt.Errorf("serve port %d: %w", cfg.Port, err)
			}
			results <- serveResult{port: cfg.Port, err: err}
		}()
	}

	first := <-results
	if parent.Err() == nil {
		cancel()
		for remaining := len(configs) - 1; remaining > 0; remaining-- {
			<-results
		}
		if first.err != nil {
			return first.err
		}
		return fmt.Errorf("SOCKS listener on port %d stopped unexpectedly", first.port)
	}

	cancel()
	for remaining := len(configs) - 1; remaining > 0; remaining-- {
		<-results
	}
	return nil
}

func loadConfigs(command, configPath, configDirectory string) ([]config.Config, error) {
	if (configPath == "") == (configDirectory == "") {
		return nil, fmt.Errorf("%s requires exactly one of --config or --config-dir", command)
	}
	if configPath != "" {
		cfg, err := config.Load(configPath)
		if err != nil {
			return nil, err
		}
		return []config.Config{cfg}, nil
	}
	return config.LoadDirectory(configDirectory)
}

func configCheckCommand(args []string, stdout, stderr io.Writer) (int, error) {
	flags := newFlagSet("config-check", stderr)
	configPath := flags.String("config", "", "path to config.json")
	configDirectory := flags.String("config-dir", "", "directory containing *.json configurations")
	if err := flags.Parse(args); err != nil {
		return flagExitCode(err), flagError(err)
	}
	if err := requireNoPositionals(flags); err != nil {
		return exitConfigError, err
	}
	if _, err := loadConfigs("config-check", *configPath, *configDirectory); err != nil {
		return exitConfigError, err
	}
	_, _ = io.WriteString(stdout, "configuration valid\n")
	return exitOK, nil
}

func configCreateCommand(args []string, stdin io.Reader, stdout, stderr io.Writer) (int, error) {
	flags := newFlagSet("config-create", stderr)
	portNumber := flags.Int("port", 0, "IPv4 TCP listener port")
	version := flags.String("version", "", "installed version")
	output := flags.String("output", "", "destination config.json")
	preserve := flags.String("preserve", "", "existing config.json to preserve")
	checkOnly := flags.Bool("check", false, "validate stdin and options without writing")
	allowCN := flags.Bool("allow-cn", false, "allow clients whose source IP is in the CN zone")
	if err := flags.Parse(args); err != nil {
		return flagExitCode(err), flagError(err)
	}
	if err := requireNoPositionals(flags); err != nil {
		return exitConfigError, err
	}
	if *version == "" {
		return exitConfigError, errors.New("config-create requires --version")
	}
	allowCNSet := false
	flags.Visit(func(option *flag.Flag) {
		if option.Name == "allow-cn" {
			allowCNSet = true
		}
	})

	var cfg config.Config
	if *preserve != "" {
		if *checkOnly || *portNumber != 0 || allowCNSet {
			return exitConfigError, errors.New(
				"--preserve cannot be combined with --check, --port, or --allow-cn",
			)
		}
		if *output == "" {
			return exitConfigError, errors.New("config-create --preserve requires --output")
		}
		loaded, err := config.Load(*preserve)
		if err != nil {
			return exitConfigError, err
		}
		loaded.Version = *version
		cfg = loaded
	} else {
		if *portNumber == 0 {
			return exitConfigError, errors.New("config-create requires --port")
		}
		if *checkOnly {
			if *output != "" {
				return exitConfigError, errors.New("config-create --check cannot be combined with --output")
			}
		} else if *output == "" {
			return exitConfigError, errors.New("config-create requires --output unless --check is used")
		}

		username, password, err := readCredentialPair(stdin)
		if err != nil {
			return exitConfigError, err
		}
		cfg = config.Config{
			Schema:   config.SchemaVersion,
			Listen:   config.ListenAddress,
			Port:     *portNumber,
			Username: username,
			Password: password,
			AllowCN:  *allowCN,
			Version:  *version,
		}
	}
	if err := config.Validate(cfg); err != nil {
		return exitConfigError, err
	}
	if *checkOnly {
		_, _ = io.WriteString(stdout, "configuration input valid\n")
		return exitOK, nil
	}
	if err := config.Write(*output, cfg); err != nil {
		return exitRuntimeError, err
	}
	_, _ = io.WriteString(stdout, "configuration written\n")
	return exitOK, nil
}

func configDetailCommand(args []string, stdout, stderr io.Writer) (int, error) {
	flags := newFlagSet("config-detail", stderr)
	configPath := flags.String("config", "", "path to config.json")
	if err := flags.Parse(args); err != nil {
		return flagExitCode(err), flagError(err)
	}
	if err := requireNoPositionals(flags); err != nil {
		return exitConfigError, err
	}
	if *configPath == "" {
		return exitConfigError, errors.New("config-detail requires --config")
	}
	cfg, err := config.Load(*configPath)
	if err != nil {
		return exitConfigError, err
	}
	if bytes.IndexByte([]byte(cfg.Username), 0) >= 0 ||
		bytes.IndexByte([]byte(cfg.Password), 0) >= 0 {
		return exitConfigError, errors.New(
			"config-detail cannot encode credentials containing NUL bytes",
		)
	}
	fields := []string{
		strconv.Itoa(cfg.Port),
		cfg.Username,
		cfg.Password,
		strconv.FormatBool(cfg.AllowCN),
	}
	for _, field := range fields {
		if _, err := io.WriteString(stdout, field); err != nil {
			return exitRuntimeError, fmt.Errorf("write configuration detail: %w", err)
		}
		if _, err := stdout.Write([]byte{0}); err != nil {
			return exitRuntimeError, fmt.Errorf("write configuration detail delimiter: %w", err)
		}
	}
	return exitOK, nil
}

func configPortCommand(args []string, stdout, stderr io.Writer) (int, error) {
	flags := newFlagSet("config-port", stderr)
	configPath := flags.String("config", "", "path to config.json")
	if err := flags.Parse(args); err != nil {
		return flagExitCode(err), flagError(err)
	}
	if err := requireNoPositionals(flags); err != nil {
		return exitConfigError, err
	}
	if *configPath == "" {
		return exitConfigError, errors.New("config-port requires --config")
	}
	cfg, err := config.Load(*configPath)
	if err != nil {
		return exitConfigError, err
	}
	_, _ = fmt.Fprintln(stdout, cfg.Port)
	return exitOK, nil
}

func configPortsCommand(args []string, stdout, stderr io.Writer) (int, error) {
	flags := newFlagSet("config-ports", stderr)
	configDirectory := flags.String("config-dir", "", "directory containing *.json configurations")
	blockedCNOnly := flags.Bool("blocked-cn-only", false, "print only ports that block CN sources")
	if err := flags.Parse(args); err != nil {
		return flagExitCode(err), flagError(err)
	}
	if err := requireNoPositionals(flags); err != nil {
		return exitConfigError, err
	}
	if *configDirectory == "" {
		return exitConfigError, errors.New("config-ports requires --config-dir")
	}
	configs, err := config.LoadDirectory(*configDirectory)
	if err != nil {
		return exitConfigError, err
	}
	for _, cfg := range configs {
		if *blockedCNOnly && cfg.AllowCN {
			continue
		}
		if _, err := fmt.Fprintln(stdout, cfg.Port); err != nil {
			return exitRuntimeError, fmt.Errorf("write configuration port: %w", err)
		}
	}
	return exitOK, nil
}

func credentialsGenerateCommand(args []string, stdout, stderr io.Writer) (int, error) {
	flags := newFlagSet("credentials-generate", stderr)
	if err := flags.Parse(args); err != nil {
		return flagExitCode(err), flagError(err)
	}
	if err := requireNoPositionals(flags); err != nil {
		return exitConfigError, err
	}
	username, err := generateCredential()
	if err != nil {
		return exitRuntimeError, err
	}
	password, err := generateCredential()
	if err != nil {
		return exitRuntimeError, err
	}
	for _, value := range []string{username, password} {
		if _, err := io.WriteString(stdout, value); err != nil {
			return exitRuntimeError, fmt.Errorf("write generated credentials: %w", err)
		}
		if _, err := stdout.Write([]byte{0}); err != nil {
			return exitRuntimeError, fmt.Errorf("write generated credentials delimiter: %w", err)
		}
	}
	return exitOK, nil
}

func generateCredential() (string, error) {
	const randomBytes = 15
	data := make([]byte, randomBytes)
	if _, err := io.ReadFull(rand.Reader, data); err != nil {
		return "", fmt.Errorf("generate random credential: %w", err)
	}
	return base64.RawURLEncoding.EncodeToString(data), nil
}

func readCredentialPair(reader io.Reader) (string, string, error) {
	const maximumEncodedLength = 255 + 1 + 255 + 1
	data, err := io.ReadAll(io.LimitReader(reader, maximumEncodedLength+1))
	if err != nil {
		return "", "", fmt.Errorf("read credentials from stdin: %w", err)
	}
	if len(data) > maximumEncodedLength ||
		len(data) == 0 ||
		data[len(data)-1] != 0 ||
		bytes.Count(data, []byte{0}) != 2 {
		return "", "", errors.New(
			"credentials stdin must be exactly username NUL password NUL with no trailing data",
		)
	}
	parts := bytes.Split(data, []byte{0})
	if len(parts) != 3 || len(parts[2]) != 0 {
		return "", "", errors.New(
			"credentials stdin must be exactly username NUL password NUL with no trailing data",
		)
	}
	return string(parts[0]), string(parts[1]), nil
}

func selfCheckCommand(args []string, stdout, stderr io.Writer) (int, error) {
	flags := newFlagSet("self-check", stderr)
	configPath := flags.String("config", "", "path to config.json")
	configDirectory := flags.String("config-dir", "", "directory containing *.json configurations")
	if err := flags.Parse(args); err != nil {
		return flagExitCode(err), flagError(err)
	}
	if err := requireNoPositionals(flags); err != nil {
		return exitConfigError, err
	}
	configs, err := loadConfigs("self-check", *configPath, *configDirectory)
	if err != nil {
		return exitConfigError, err
	}
	for _, cfg := range configs {
		if err := selfCheck(cfg); err != nil {
			return exitRuntimeError, fmt.Errorf("self-check port %d: %w", cfg.Port, err)
		}
	}
	_, _ = io.WriteString(stdout, "self-check passed\n")
	return exitOK, nil
}

func selfCheck(cfg config.Config) error {
	ctx, cancel := context.WithTimeout(context.Background(), selfCheckTimeout)
	defer cancel()

	address := net.JoinHostPort("127.0.0.1", strconv.Itoa(cfg.Port))
	conn, err := dialUntilReady(ctx, &net.Dialer{}, address)
	if err != nil {
		return fmt.Errorf("connect to local SOCKS listener %s: %w", address, err)
	}
	defer conn.Close()
	if deadline, ok := ctx.Deadline(); ok {
		if err := conn.SetDeadline(deadline); err != nil {
			return fmt.Errorf("set self-check deadline: %w", err)
		}
	}

	if _, err := conn.Write([]byte{gosocks5.Ver5, 1, gosocks5.MethodUserPass}); err != nil {
		return fmt.Errorf("write self-check methods: %w", err)
	}
	var method [2]byte
	if _, err := io.ReadFull(conn, method[:]); err != nil {
		return fmt.Errorf("read self-check method: %w", err)
	}
	if method != [2]byte{gosocks5.Ver5, gosocks5.MethodUserPass} {
		return fmt.Errorf("SOCKS listener selected unexpected authentication method %d", method[1])
	}
	if err := gosocks5.NewUserPassRequest(
		gosocks5.UserPassVer,
		cfg.Username,
		cfg.Password,
	).Write(conn); err != nil {
		return fmt.Errorf("write self-check credentials: %w", err)
	}
	authentication, err := gosocks5.ReadUserPassResponse(conn)
	if err != nil {
		return fmt.Errorf("read self-check authentication response: %w", err)
	}
	if authentication.Status != gosocks5.Succeeded {
		return errors.New("SOCKS listener rejected configured credentials")
	}

	request := gosocks5.NewRequest(gosocks5.CmdConnect, &gosocks5.Addr{
		Type: gosocks5.AddrIPv4,
		Host: "127.0.0.1",
		Port: 1,
	})
	if err := request.Write(conn); err != nil {
		return fmt.Errorf("write self-check blocked target: %w", err)
	}
	reply, err := gosocks5.ReadReply(conn)
	if err != nil {
		return fmt.Errorf("read self-check blocked-target reply: %w", err)
	}
	if reply.Rep != gosocks5.NotAllowed {
		return fmt.Errorf("blocked loopback target returned SOCKS reply %d, want %d", reply.Rep, gosocks5.NotAllowed)
	}
	return nil
}

type localDialer interface {
	DialContext(context.Context, string, string) (net.Conn, error)
}

func dialUntilReady(ctx context.Context, dialer localDialer, address string) (net.Conn, error) {
	for {
		conn, err := dialer.DialContext(ctx, "tcp4", address)
		if err == nil {
			return conn, nil
		}
		if !errors.Is(err, syscall.ECONNREFUSED) {
			return nil, err
		}

		timer := time.NewTimer(readinessRetryInterval)
		select {
		case <-ctx.Done():
			timer.Stop()
			return nil, fmt.Errorf("%w after local connection refusal", ctx.Err())
		case <-timer.C:
		}
	}
}

func portCheckCommand(args []string, stdout, stderr io.Writer) (int, error) {
	flags := newFlagSet("port-check", stderr)
	portNumber := flags.Int("port", 0, "IPv4 TCP listener port")
	configPath := flags.String("config", "", "read the port from config.json")
	if err := flags.Parse(args); err != nil {
		return flagExitCode(err), flagError(err)
	}
	if err := requireNoPositionals(flags); err != nil {
		return exitConfigError, err
	}
	if (*portNumber == 0) == (*configPath == "") {
		return exitConfigError, errors.New("port-check requires exactly one of --port or --config")
	}
	if *configPath != "" {
		cfg, err := config.Load(*configPath)
		if err != nil {
			return exitConfigError, err
		}
		*portNumber = cfg.Port
	}
	if err := port.Validate(*portNumber); err != nil {
		return exitConfigError, err
	}
	if err := port.CheckAvailable(*portNumber); err != nil {
		if port.IsInUse(err) {
			return exitBindConflict, err
		}
		return exitRuntimeError, err
	}
	_, _ = fmt.Fprintf(stdout, "port %d is available\n", *portNumber)
	return exitOK, nil
}

func portSelectCommand(args []string, stdout, stderr io.Writer) (int, error) {
	flags := newFlagSet("port-select", stderr)
	if err := flags.Parse(args); err != nil {
		return flagExitCode(err), flagError(err)
	}
	if err := requireNoPositionals(flags); err != nil {
		return exitConfigError, err
	}
	selected, err := port.SelectAutomatic()
	if err != nil {
		return exitRuntimeError, err
	}
	_, _ = fmt.Fprintln(stdout, selected)
	return exitOK, nil
}

func ipdenyCheckCommand(args []string, stdout, stderr io.Writer) (int, error) {
	flags := newFlagSet("ipdeny-check", stderr)
	zonePath := flags.String("zone", "", "path to the IPdeny IPv4 zone")
	if err := flags.Parse(args); err != nil {
		return flagExitCode(err), flagError(err)
	}
	if err := requireNoPositionals(flags); err != nil {
		return exitConfigError, err
	}
	if *zonePath == "" {
		return exitConfigError, errors.New("ipdeny-check requires --zone")
	}
	zone, err := os.Open(*zonePath)
	if err != nil {
		return exitRuntimeError, fmt.Errorf("open IPdeny zone %s: %w", *zonePath, err)
	}
	defer zone.Close()
	prefixes, err := firewall.ParseCIDRs(zone)
	if err != nil {
		return exitConfigError, err
	}
	_, _ = fmt.Fprintf(stdout, "%d IPv4 CIDRs valid\n", len(prefixes))
	return exitOK, nil
}

func firewallRenderCommand(args []string, stdin io.Reader, stdout, stderr io.Writer) (int, error) {
	flags := newFlagSet("firewall-render", stderr)
	configPath := flags.String("config", "", "path to config.json")
	configDirectory := flags.String("config-dir", "", "directory containing *.json configurations")
	portNumber := flags.Int("port", 0, "IPv4 TCP listener port")
	allowCN := flags.Bool("allow-cn", false, "allow CN sources when --port is used")
	zonePath := flags.String("zone", "", "path to the IPdeny IPv4 zone")
	outputPath := flags.String("output", "", "destination nftables batch")
	existingPath := flags.String(
		"existing-table-json",
		"",
		"path to nft --json list table ip socks_vps output",
	)
	remove := flags.Bool("remove", false, "render removal of an owned table")
	if err := flags.Parse(args); err != nil {
		return flagExitCode(err), flagError(err)
	}
	if err := requireNoPositionals(flags); err != nil {
		return exitConfigError, err
	}
	allowCNSet := false
	flags.Visit(func(option *flag.Flag) {
		if option.Name == "allow-cn" {
			allowCNSet = true
		}
	})
	if *outputPath == "" {
		return exitConfigError, errors.New("firewall-render requires --output")
	}

	state, err := existingTableState(*existingPath, *remove, stdin)
	if err != nil {
		return exitRuntimeError, err
	}
	if *remove {
		if *configPath != "" ||
			*configDirectory != "" ||
			*portNumber != 0 ||
			allowCNSet ||
			*zonePath != "" {
			return exitConfigError, errors.New(
				"firewall-render --remove cannot be combined with --config, --config-dir, --port, --allow-cn, or --zone",
			)
		}
		if err := renderOutput(*outputPath, stdout, func(writer io.Writer) error {
			return firewall.RenderRemove(writer, state)
		}); err != nil {
			return exitRuntimeError, err
		}
		if *outputPath != "-" {
			_, _ = io.WriteString(stdout, "firewall removal batch written\n")
		}
		return exitOK, nil
	}

	inputCount := 0
	if *configPath != "" {
		inputCount++
	}
	if *configDirectory != "" {
		inputCount++
	}
	if *portNumber != 0 {
		inputCount++
	}
	if inputCount != 1 {
		return exitConfigError, errors.New(
			"firewall-render requires exactly one of --config, --config-dir, or --port",
		)
	}
	if allowCNSet && *portNumber == 0 {
		return exitConfigError, errors.New(
			"firewall-render --allow-cn is only valid with --port",
		)
	}

	var blockedPorts []int
	if *configPath != "" {
		cfg, err := config.Load(*configPath)
		if err != nil {
			return exitConfigError, err
		}
		if !cfg.AllowCN {
			blockedPorts = append(blockedPorts, cfg.Port)
		}
	} else if *configDirectory != "" {
		configs, err := config.LoadDirectory(*configDirectory)
		if err != nil {
			return exitConfigError, err
		}
		for _, cfg := range configs {
			if !cfg.AllowCN {
				blockedPorts = append(blockedPorts, cfg.Port)
			}
		}
	} else {
		if err := port.Validate(*portNumber); err != nil {
			return exitConfigError, err
		}
		if !*allowCN {
			blockedPorts = append(blockedPorts, *portNumber)
		}
	}

	var prefixes []netip.Prefix
	if len(blockedPorts) > 0 {
		if *zonePath == "" {
			return exitConfigError, errors.New(
				"firewall-render requires --zone when one or more ports block CN sources",
			)
		}
		zone, err := os.Open(*zonePath)
		if err != nil {
			return exitRuntimeError, fmt.Errorf("open IPdeny zone %s: %w", *zonePath, err)
		}
		var parseErr error
		prefixes, parseErr = firewall.ParseCIDRs(zone)
		closeErr := zone.Close()
		if parseErr != nil {
			return exitConfigError, parseErr
		}
		if closeErr != nil {
			return exitRuntimeError, fmt.Errorf("close IPdeny zone %s: %w", *zonePath, closeErr)
		}
	}
	if err := renderOutput(*outputPath, stdout, func(writer io.Writer) error {
		return firewall.RenderPorts(writer, blockedPorts, prefixes, state)
	}); err != nil {
		return exitRuntimeError, err
	}
	if *outputPath != "-" {
		_, _ = io.WriteString(stdout, "firewall batch written\n")
	}
	return exitOK, nil
}

func existingTableState(
	path string,
	required bool,
	stdin io.Reader,
) (firewall.TableState, error) {
	if path == "" {
		if required {
			return firewall.TableForeign, errors.New(
				"firewall-render --remove requires --existing-table-json",
			)
		}
		return firewall.TableAbsent, nil
	}
	if path == "-" {
		state, err := firewall.ClassifyExistingTable(stdin)
		if err != nil {
			return firewall.TableForeign, err
		}
		return state, nil
	}
	document, err := os.Open(path)
	if err != nil {
		return firewall.TableForeign, fmt.Errorf("open existing nftables table JSON %s: %w", path, err)
	}
	defer document.Close()
	state, err := firewall.ClassifyExistingTable(document)
	if err != nil {
		return firewall.TableForeign, err
	}
	return state, nil
}

func renderOutput(path string, stdout io.Writer, render func(io.Writer) error) error {
	if path == "-" {
		return render(stdout)
	}
	return writeFileAtomically(path, 0o600, render)
}

func writeFileAtomically(path string, mode os.FileMode, render func(io.Writer) error) error {
	if path == "" {
		return errors.New("output path is empty")
	}
	if render == nil {
		return errors.New("output renderer is nil")
	}

	directory := filepath.Dir(path)
	temporary, err := os.CreateTemp(directory, "."+filepath.Base(path)+".*")
	if err != nil {
		return fmt.Errorf("create temporary output in %s: %w", directory, err)
	}
	temporaryPath := temporary.Name()
	defer func() {
		_ = os.Remove(temporaryPath)
	}()

	if err := temporary.Chmod(mode); err != nil {
		_ = temporary.Close()
		return fmt.Errorf("set temporary output permissions: %w", err)
	}
	if err := render(temporary); err != nil {
		_ = temporary.Close()
		return fmt.Errorf("render temporary output: %w", err)
	}
	if err := temporary.Sync(); err != nil {
		_ = temporary.Close()
		return fmt.Errorf("sync temporary output: %w", err)
	}
	if err := temporary.Close(); err != nil {
		return fmt.Errorf("close temporary output: %w", err)
	}
	if err := os.Rename(temporaryPath, path); err != nil {
		return fmt.Errorf("install output %s: %w", path, err)
	}
	directoryHandle, err := os.Open(directory)
	if err != nil {
		return fmt.Errorf("open output directory %s: %w", directory, err)
	}
	defer directoryHandle.Close()
	if err := directoryHandle.Sync(); err != nil {
		return fmt.Errorf("sync output directory %s: %w", directory, err)
	}
	return nil
}

func newFlagSet(name string, stderr io.Writer) *flag.FlagSet {
	flags := flag.NewFlagSet(name, flag.ContinueOnError)
	flags.SetOutput(stderr)
	return flags
}

func requireNoPositionals(flags *flag.FlagSet) error {
	if flags.NArg() != 0 {
		return fmt.Errorf("%s does not accept positional arguments", flags.Name())
	}
	return nil
}

func flagExitCode(err error) int {
	if errors.Is(err, flag.ErrHelp) {
		return exitOK
	}
	return exitConfigError
}

func flagError(err error) error {
	if errors.Is(err, flag.ErrHelp) {
		return nil
	}
	return err
}
