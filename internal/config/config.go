// Package config owns the on-disk Socks-VPS configuration format.
package config

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"unicode/utf8"

	"socks-vps/internal/port"
)

const (
	SchemaVersion = 1
	ListenAddress = "0.0.0.0"
	FileMode      = 0o640
)

// Config is the authoritative runtime and installed-version state for one
// SOCKS listener.
type Config struct {
	Schema   int    `json:"schema"`
	Listen   string `json:"listen"`
	Port     int    `json:"port"`
	Username string `json:"username"`
	Password string `json:"password"`
	AllowCN  bool   `json:"allow_cn,omitempty"`
	Version  string `json:"version"`
}

// Validate checks the public configuration contract before it reaches a
// listener, credentials comparison, or firewall write.
func Validate(value Config) error {
	if value.Schema != SchemaVersion {
		return fmt.Errorf("unsupported configuration schema %d", value.Schema)
	}
	if value.Listen != ListenAddress {
		return fmt.Errorf("listen address must be %s", ListenAddress)
	}
	if err := port.Validate(value.Port); err != nil {
		return fmt.Errorf("invalid listener port: %w", err)
	}
	if err := validateCredential("username", value.Username); err != nil {
		return err
	}
	if err := validateCredential("password", value.Password); err != nil {
		return err
	}
	if value.Version == "" {
		return fmt.Errorf("version must not be empty")
	}
	return nil
}

func validateCredential(name, value string) error {
	length := len([]byte(value))
	if length == 0 || length > 255 {
		return fmt.Errorf("%s must contain 1-255 bytes", name)
	}
	if !utf8.ValidString(value) {
		return fmt.Errorf("%s must be valid UTF-8", name)
	}
	return nil
}

// Load reads, strictly decodes, validates, and permission-checks a
// configuration file.
func Load(path string) (Config, error) {
	file, err := os.Open(path)
	if err != nil {
		return Config{}, fmt.Errorf("open configuration %s: %w", path, err)
	}
	defer file.Close()

	info, err := file.Stat()
	if err != nil {
		return Config{}, fmt.Errorf("stat configuration %s: %w", path, err)
	}
	if !info.Mode().IsRegular() {
		return Config{}, fmt.Errorf("configuration %s is not a regular file", path)
	}
	if permissions := info.Mode().Perm(); permissions != FileMode {
		return Config{}, fmt.Errorf(
			"configuration %s permissions are %04o, want %04o",
			path,
			permissions,
			FileMode,
		)
	}

	value, err := decode(file)
	if err != nil {
		return Config{}, fmt.Errorf("decode configuration %s: %w", path, err)
	}
	return value, nil
}

// LoadDirectory reads every direct *.json child in lexical filename order.
// Each file keeps the same strict validation and permission contract as Load.
func LoadDirectory(path string) ([]Config, error) {
	entries, err := os.ReadDir(path)
	if err != nil {
		return nil, fmt.Errorf("read configuration directory %s: %w", path, err)
	}

	var names []string
	for _, entry := range entries {
		if strings.HasSuffix(entry.Name(), ".json") {
			names = append(names, entry.Name())
		}
	}
	sort.Strings(names)
	if len(names) == 0 {
		return nil, fmt.Errorf("configuration directory %s contains no *.json files", path)
	}

	values := make([]Config, 0, len(names))
	ports := make(map[int]string, len(names))
	for _, name := range names {
		configPath := filepath.Join(path, name)
		value, err := Load(configPath)
		if err != nil {
			return nil, err
		}
		if previous, exists := ports[value.Port]; exists {
			return nil, fmt.Errorf(
				"configuration port %d is duplicated in %s and %s",
				value.Port,
				previous,
				name,
			)
		}
		ports[value.Port] = name
		values = append(values, value)
	}
	return values, nil
}

func decode(reader io.Reader) (Config, error) {
	decoder := json.NewDecoder(reader)
	decoder.DisallowUnknownFields()

	var value Config
	if err := decoder.Decode(&value); err != nil {
		return Config{}, err
	}
	var trailing any
	err := decoder.Decode(&trailing)
	if !errors.Is(err, io.EOF) {
		if err == nil {
			return Config{}, fmt.Errorf("multiple JSON values are not allowed")
		}
		return Config{}, fmt.Errorf("trailing JSON data: %w", err)
	}
	if err := Validate(value); err != nil {
		return Config{}, err
	}
	return value, nil
}

// Write validates value and atomically writes path with the credential file
// mode. Callers create and own the destination directory.
func Write(path string, value Config) error {
	if err := Validate(value); err != nil {
		return err
	}

	directory := filepath.Dir(path)
	temporary, err := os.CreateTemp(directory, ".config.json.*")
	if err != nil {
		return fmt.Errorf("create temporary configuration in %s: %w", directory, err)
	}
	temporaryPath := temporary.Name()
	defer func() {
		_ = os.Remove(temporaryPath)
	}()

	encoder := json.NewEncoder(temporary)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(value); err != nil {
		_ = temporary.Close()
		return fmt.Errorf("encode temporary configuration: %w", err)
	}
	if err := temporary.Chmod(FileMode); err != nil {
		_ = temporary.Close()
		return fmt.Errorf("set temporary configuration permissions: %w", err)
	}
	if err := temporary.Sync(); err != nil {
		_ = temporary.Close()
		return fmt.Errorf("sync temporary configuration: %w", err)
	}
	if err := temporary.Close(); err != nil {
		return fmt.Errorf("close temporary configuration: %w", err)
	}
	if err := os.Rename(temporaryPath, path); err != nil {
		return fmt.Errorf("install configuration %s: %w", path, err)
	}

	directoryHandle, err := os.Open(directory)
	if err != nil {
		return fmt.Errorf("open configuration directory %s: %w", directory, err)
	}
	defer directoryHandle.Close()
	if err := directoryHandle.Sync(); err != nil {
		return fmt.Errorf("sync configuration directory %s: %w", directory, err)
	}
	return nil
}
