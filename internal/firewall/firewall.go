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

	tableComment     = "Socks-VPS managed table"
	OwnershipComment = "Socks-VPS managed CN IPv4 set"
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

// ClassifyExistingTable verifies the fixed comment on the cn_ipv4 set from
// `nft --json list table ip socks_vps`. The set comment is the ownership
// marker because nftables versions in supported Linux distributions do not
// consistently include table or chain comments in JSON output. The caller
// handles the command's not-found exit as TableAbsent without fabricating JSON.
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

	tablePresent := false
	ownedSetPresent := false
	for _, raw := range document.Nftables {
		var object struct {
			Table *struct {
				Family string `json:"family"`
				Name   string `json:"name"`
			} `json:"table"`
			Set *struct {
				Family  string `json:"family"`
				Table   string `json:"table"`
				Name    string `json:"name"`
				Comment string `json:"comment"`
			} `json:"set"`
		}
		if err := json.Unmarshal(raw, &object); err != nil {
			return TableForeign, fmt.Errorf("decode nftables object: %w", err)
		}
		if object.Table != nil &&
			object.Table.Family == TableFamily &&
			object.Table.Name == TableName {
			tablePresent = true
		}
		if object.Set != nil &&
			object.Set.Family == TableFamily &&
			object.Set.Table == TableName &&
			object.Set.Name == SetName &&
			object.Set.Comment == OwnershipComment {
			ownedSetPresent = true
		}
	}

	if !tablePresent {
		return TableForeign, ErrTableNotPresent
	}
	if ownedSetPresent {
		return TableOwned, nil
	}
	return TableForeign, nil
}

// Render writes one complete nft -f batch for one blocked listener port.
func Render(writer io.Writer, port int, prefixes []netip.Prefix, state TableState) error {
	return RenderPorts(writer, []int{port}, prefixes, state)
}

// RenderPorts writes one complete nft -f batch for all blocked listener ports.
// TableAbsent creates the table. TableOwned first deletes the owned table and
// then recreates it in the same batch, so nft applies the replacement as one
// transaction. A non-empty port list never modifies a foreign table.
//
// An empty port list requests no CN source blocking. In that state an owned
// table is removed, while absent and foreign tables are left untouched.
func RenderPorts(
	writer io.Writer,
	ports []int,
	prefixes []netip.Prefix,
	state TableState,
) error {
	if len(ports) == 0 {
		switch state {
		case TableAbsent, TableForeign:
			return nil
		case TableOwned:
			return RenderRemove(writer, state)
		default:
			return fmt.Errorf("render nftables batch: invalid table state %d", state)
		}
	}
	if writer == nil {
		return fmt.Errorf("render nftables batch: nil writer")
	}
	seenPorts := make(map[int]struct{}, len(ports))
	for _, port := range ports {
		if port < minPort || port > maxPort {
			return fmt.Errorf(
				"render nftables batch: port must be between %d and %d: %d",
				minPort,
				maxPort,
				port,
			)
		}
		if _, exists := seenPorts[port]; exists {
			return fmt.Errorf("render nftables batch: duplicate port %d", port)
		}
		seenPorts[port] = struct{}{}
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
		tableComment,
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
	if _, err := fmt.Fprintf(writer, "\tcomment %q;\n}\n\n", OwnershipComment); err != nil {
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
		"add rule %s %s %s ip saddr @%s tcp dport ",
		TableFamily,
		TableName,
		ChainName,
		SetName,
	); err != nil {
		return fmt.Errorf("render nftables drop rule: %w", err)
	}
	if len(ports) == 1 {
		if _, err := fmt.Fprint(writer, ports[0]); err != nil {
			return fmt.Errorf("render nftables drop rule port: %w", err)
		}
	} else {
		if _, err := io.WriteString(writer, "{ "); err != nil {
			return fmt.Errorf("render nftables drop rule ports: %w", err)
		}
		for index, port := range ports {
			if index > 0 {
				if _, err := io.WriteString(writer, ", "); err != nil {
					return fmt.Errorf("render nftables drop rule separator: %w", err)
				}
			}
			if _, err := fmt.Fprint(writer, port); err != nil {
				return fmt.Errorf("render nftables drop rule port %d: %w", index, err)
			}
		}
		if _, err := io.WriteString(writer, " }"); err != nil {
			return fmt.Errorf("render nftables drop rule ports: %w", err)
		}
	}
	if _, err := io.WriteString(writer, " counter drop\n"); err != nil {
		return fmt.Errorf("render nftables drop rule closing: %w", err)
	}
	return nil
}

// RenderRemove writes the complete batch for removing the Socks-VPS table.
// Only a table already classified as owned may be deleted. Absent and foreign
// tables are already in the requested state and produce no batch.
func RenderRemove(writer io.Writer, state TableState) error {
	switch state {
	case TableAbsent, TableForeign:
		return nil
	case TableOwned:
		if writer == nil {
			return fmt.Errorf("render nftables removal: nil writer")
		}
		if _, err := fmt.Fprintf(writer, "delete table %s %s\n", TableFamily, TableName); err != nil {
			return fmt.Errorf("render nftables removal: %w", err)
		}
		return nil
	default:
		return fmt.Errorf("render nftables removal: invalid table state %d", state)
	}
}
