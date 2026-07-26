// Package firewall parses the bundled IPdeny IPv4 zone and renders the complete
// nftables batch owned by Socks-VPS. It does not execute nft.
package firewall

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/netip"
	"strings"
)

const (
	TableFamily = "ip"
	TableName   = "socks_vps"
	SetName     = "cn_ipv4"
	ChainName   = "input"

	OwnershipComment = "Socks-VPS managed table"
	setComment       = "Socks-VPS managed CN IPv4 set"
	chainComment     = "Socks-VPS managed input chain"

	minPort = 1024
	maxPort = 65535
)

var (
	ErrEmptyCIDRs      = errors.New("IPv4 CIDR list is empty")
	ErrTableConflict   = errors.New("nftables table ip socks_vps is not owned by Socks-VPS")
	ErrTableNotPresent = errors.New("nftables JSON does not contain table ip socks_vps")
)

// TableState describes the read-only ownership decision made before rendering.
type TableState uint8

const (
	TableAbsent TableState = iota
	TableOwned
	TableForeign
)

// ParseCIDRs strictly parses one canonical IPv4 network prefix per non-empty
// line, preserving source order.
func ParseCIDRs(reader io.Reader) ([]netip.Prefix, error) {
	if reader == nil {
		return nil, fmt.Errorf("parse IPv4 CIDRs: nil reader")
	}

	scanner := bufio.NewScanner(reader)
	var prefixes []netip.Prefix
	lineNumber := 0
	for scanner.Scan() {
		lineNumber++
		line := scanner.Text()
		if line == "" {
			continue
		}
		if strings.TrimSpace(line) != line {
			return nil, fmt.Errorf("parse IPv4 CIDR line %d: surrounding whitespace is not allowed", lineNumber)
		}

		prefix, err := netip.ParsePrefix(line)
		if err != nil {
			return nil, fmt.Errorf("parse IPv4 CIDR line %d %q: %w", lineNumber, line, err)
		}
		if !prefix.Addr().Is4() {
			return nil, fmt.Errorf("parse IPv4 CIDR line %d %q: IPv6 is not allowed", lineNumber, line)
		}
		if prefix != prefix.Masked() {
			return nil, fmt.Errorf("parse IPv4 CIDR line %d %q: host bits must be zero", lineNumber, line)
		}
		prefixes = append(prefixes, prefix)
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("read IPv4 CIDRs: %w", err)
	}
	if len(prefixes) == 0 {
		return nil, ErrEmptyCIDRs
	}
	return prefixes, nil
}

// ClassifyExistingTable verifies the fixed ownership comment from
// `nft --json list table ip socks_vps`. The caller handles the command's
// not-found exit as TableAbsent without passing fabricated JSON here.
func ClassifyExistingTable(reader io.Reader) (TableState, error) {
	if reader == nil {
		return TableForeign, fmt.Errorf("classify existing nftables table: nil reader")
	}

	var document struct {
		Nftables []json.RawMessage `json:"nftables"`
	}
	decoder := json.NewDecoder(reader)
	if err := decoder.Decode(&document); err != nil {
		return TableForeign, fmt.Errorf("decode nftables JSON: %w", err)
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		if err == nil {
			return TableForeign, fmt.Errorf("decode nftables JSON: multiple JSON values")
		}
		return TableForeign, fmt.Errorf("decode nftables JSON trailing data: %w", err)
	}

	for _, raw := range document.Nftables {
		var object struct {
			Table *struct {
				Family  string `json:"family"`
				Name    string `json:"name"`
				Comment string `json:"comment"`
			} `json:"table"`
		}
		if err := json.Unmarshal(raw, &object); err != nil {
			return TableForeign, fmt.Errorf("decode nftables object: %w", err)
		}
		if object.Table == nil ||
			object.Table.Family != TableFamily ||
			object.Table.Name != TableName {
			continue
		}
		if object.Table.Comment == OwnershipComment {
			return TableOwned, nil
		}
		return TableForeign, nil
	}

	return TableForeign, ErrTableNotPresent
}

// Render writes one complete nft -f batch. TableAbsent creates the table.
// TableOwned first deletes the owned table and then recreates it in the same
// batch, so nft applies the replacement as one transaction. Foreign tables are
// never modified.
func Render(writer io.Writer, port int, prefixes []netip.Prefix, state TableState) error {
	if writer == nil {
		return fmt.Errorf("render nftables batch: nil writer")
	}
	if port < minPort || port > maxPort {
		return fmt.Errorf("render nftables batch: port must be between %d and %d: %d", minPort, maxPort, port)
	}
	if len(prefixes) == 0 {
		return ErrEmptyCIDRs
	}
	for index, prefix := range prefixes {
		if !prefix.IsValid() || !prefix.Addr().Is4() || prefix != prefix.Masked() {
			return fmt.Errorf("render nftables batch: invalid canonical IPv4 CIDR at index %d: %v", index, prefix)
		}
	}

	switch state {
	case TableAbsent:
	case TableOwned:
		if _, err := fmt.Fprintf(writer, "delete table %s %s\n\n", TableFamily, TableName); err != nil {
			return fmt.Errorf("render nftables replacement: %w", err)
		}
	case TableForeign:
		return ErrTableConflict
	default:
		return fmt.Errorf("render nftables batch: invalid table state %d", state)
	}

	if _, err := fmt.Fprintf(
		writer,
		"create table %s %s { comment %q; }\n\n",
		TableFamily,
		TableName,
		OwnershipComment,
	); err != nil {
		return fmt.Errorf("render nftables table: %w", err)
	}
	if _, err := fmt.Fprintf(writer, "add set %s %s %s {\n", TableFamily, TableName, SetName); err != nil {
		return fmt.Errorf("render nftables set: %w", err)
	}
	if _, err := io.WriteString(writer, "\ttype ipv4_addr;\n\tflags interval;\n"); err != nil {
		return fmt.Errorf("render nftables set type: %w", err)
	}
	if _, err := io.WriteString(writer, "\telements = {\n"); err != nil {
		return fmt.Errorf("render nftables set elements: %w", err)
	}
	for index, prefix := range prefixes {
		suffix := ","
		if index == len(prefixes)-1 {
			suffix = ""
		}
		if _, err := fmt.Fprintf(writer, "\t\t%s%s\n", prefix, suffix); err != nil {
			return fmt.Errorf("render nftables set element %d: %w", index, err)
		}
	}
	if _, err := io.WriteString(writer, "\t};\n"); err != nil {
		return fmt.Errorf("render nftables set closing: %w", err)
	}
	if _, err := fmt.Fprintf(writer, "\tcomment %q;\n}\n\n", setComment); err != nil {
		return fmt.Errorf("render nftables set comment: %w", err)
	}

	if _, err := fmt.Fprintf(
		writer,
		"add chain %s %s %s { type filter hook input priority -10; comment %q; }\n",
		TableFamily,
		TableName,
		ChainName,
		chainComment,
	); err != nil {
		return fmt.Errorf("render nftables chain: %w", err)
	}
	if _, err := fmt.Fprintf(
		writer,
		"add rule %s %s %s ip saddr @%s tcp dport %d counter drop\n",
		TableFamily,
		TableName,
		ChainName,
		SetName,
		port,
	); err != nil {
		return fmt.Errorf("render nftables drop rule: %w", err)
	}
	return nil
}

// RenderRemove writes the complete batch for removing the Socks-VPS table.
// Only a table already classified as owned may be deleted. An absent table is
// already in the requested state and produces no batch.
func RenderRemove(writer io.Writer, state TableState) error {
	switch state {
	case TableAbsent:
		return nil
	case TableOwned:
		if writer == nil {
			return fmt.Errorf("render nftables removal: nil writer")
		}
		if _, err := fmt.Fprintf(writer, "delete table %s %s\n", TableFamily, TableName); err != nil {
			return fmt.Errorf("render nftables removal: %w", err)
		}
		return nil
	case TableForeign:
		return ErrTableConflict
	default:
		return fmt.Errorf("render nftables removal: invalid table state %d", state)
	}
}
