// Package config owns the single on-disk Socks-VPS configuration format.
package config

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"unicode/utf8"

	"socks-vps/internal/port"
)

const (
	SchemaVersion = 1
	ListenAddress = "0.0.0.0"
	FileMode      = 0o640
)

// Config is the sole authoritative runtime and installed-version state.
type Config struct {
	Schema   int    `json:"schema"`
	Listen   string `json:"listen"`
	Port     int    `json:"port"`
	Username string `json:"username"`
	Password string `json:"password"`
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

	encoder := json.NewEncoder(temporary)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(value); err != nil {
		_ = temporary.Close()
		return retainedTemporaryError("encode temporary configuration", temporaryPath, err)
	}
	if err := temporary.Chmod(FileMode); err != nil {
		_ = temporary.Close()
		return retainedTemporaryError("set temporary configuration permissions", temporaryPath, err)
	}
	if err := temporary.Sync(); err != nil {
		_ = temporary.Close()
		return retainedTemporaryError("sync temporary configuration", temporaryPath, err)
	}
	if err := temporary.Close(); err != nil {
		return retainedTemporaryError("close temporary configuration", temporaryPath, err)
	}
	if err := os.Rename(temporaryPath, path); err != nil {
		return retainedTemporaryError(
			fmt.Sprintf("install configuration %s", path),
			temporaryPath,
			err,
		)
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

func retainedTemporaryError(action, temporaryPath string, err error) error {
	if modeErr := os.Chmod(temporaryPath, 0o600); modeErr != nil {
		return fmt.Errorf(
			"%s: %w; temporary file retained at %s; restore mode 0600: %v",
			action,
			err,
			temporaryPath,
			modeErr,
		)
	}
	return fmt.Errorf("%s: %w; temporary file retained at %s", action, err, temporaryPath)
}
