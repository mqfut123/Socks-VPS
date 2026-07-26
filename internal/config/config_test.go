package config

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"socks-vps/internal/port"
)

func validConfig() Config {
	return Config{
		Schema:   SchemaVersion,
		Listen:   ListenAddress,
		Port:     23456,
		Username: "proxy-user",
		Password: "correct horse battery staple",
		Version:  "1.0.0",
	}
}

func TestValidate(t *testing.T) {
	t.Parallel()

	if err := Validate(validConfig()); err != nil {
		t.Fatal(err)
	}

	tests := map[string]func(*Config){
		"schema":   func(value *Config) { value.Schema++ },
		"listen":   func(value *Config) { value.Listen = "::" },
		"port":     func(value *Config) { value.Port = port.Min - 1 },
		"username": func(value *Config) { value.Username = "" },
		"password": func(value *Config) { value.Password = strings.Repeat("x", 256) },
		"version":  func(value *Config) { value.Version = "" },
	}
	for name, mutate := range tests {
		name, mutate := name, mutate
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			value := validConfig()
			mutate(&value)
			if err := Validate(value); err == nil {
				t.Fatal("Validate unexpectedly succeeded")
			}
		})
	}
}

func TestValidateCredentialEncodingAndVersionMetadata(t *testing.T) {
	t.Parallel()

	value := validConfig()
	value.Password = string([]byte{0xff})
	if err := Validate(value); err == nil {
		t.Fatal("Validate accepted invalid UTF-8 that JSON cannot round-trip")
	}

	value = validConfig()
	value.Version = "1.0.0+build.20260726"
	if err := Validate(value); err != nil {
		t.Fatalf("Validate rejected version metadata: %v", err)
	}
}

func TestWriteAndLoad(t *testing.T) {
	t.Parallel()

	path := filepath.Join(t.TempDir(), "config.json")
	want := validConfig()
	if err := Write(path, want); err != nil {
		t.Fatal(err)
	}

	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := info.Mode().Perm(); got != FileMode {
		t.Fatalf("permissions = %04o, want %04o", got, FileMode)
	}

	got, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if got != want {
		t.Fatalf("Load = %#v, want %#v", got, want)
	}
}

func TestWriteRetainsTemporaryFileOnInstallFailure(t *testing.T) {
	t.Parallel()

	directory := t.TempDir()
	destinationDirectory := filepath.Join(directory, "occupied")
	if err := os.Mkdir(destinationDirectory, 0o700); err != nil {
		t.Fatal(err)
	}

	err := Write(destinationDirectory, validConfig())
	if err == nil {
		t.Fatal("Write unexpectedly replaced a directory")
	}
	if !strings.Contains(err.Error(), "temporary file retained at") {
		t.Fatalf("Write error does not identify retained temporary file: %v", err)
	}
	retained, globErr := filepath.Glob(filepath.Join(directory, ".config.json.*"))
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

func TestLoadRejectsUnsafePermissions(t *testing.T) {
	t.Parallel()

	path := filepath.Join(t.TempDir(), "config.json")
	if err := Write(path, validConfig()); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := Load(path); err == nil {
		t.Fatal("Load unexpectedly accepted world-readable credentials")
	}
}

func TestLoadRejectsUnknownAndTrailingJSON(t *testing.T) {
	t.Parallel()

	for name, body := range map[string]string{
		"unknown":  `{"schema":1,"listen":"0.0.0.0","port":23456,"username":"u","password":"p","version":"1.0.0","extra":true}`,
		"trailing": `{"schema":1,"listen":"0.0.0.0","port":23456,"username":"u","password":"p","version":"1.0.0"} {}`,
	} {
		name, body := name, body
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			path := filepath.Join(t.TempDir(), "config.json")
			if err := os.WriteFile(path, []byte(body), FileMode); err != nil {
				t.Fatal(err)
			}
			if _, err := Load(path); err == nil {
				t.Fatal("Load unexpectedly succeeded")
			}
		})
	}
}

func TestLoadMissingFile(t *testing.T) {
	t.Parallel()

	_, err := Load(filepath.Join(t.TempDir(), "missing.json"))
	if !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("Load error = %v, want os.ErrNotExist", err)
	}
}
