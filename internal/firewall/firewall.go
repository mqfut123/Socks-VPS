// Package firewall parses the bundled IPdeny IPv4 zone and renders the complete
// nftables batch owned by Socks-VPS. It does not execute nft.
package firewall

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/netip"
	"strconv"
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
	ErrTableUnhealthy  = errors.New("nftables table ip socks_vps does not provide required CN source blocking")
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

	document, err := decodeNftablesDocument(reader)
	if err != nil {
		return TableForeign, err
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

type nftablesDocument struct {
	Nftables []json.RawMessage `json:"nftables"`
}

func decodeNftablesDocument(reader io.Reader) (nftablesDocument, error) {
	var document nftablesDocument
	decoder := json.NewDecoder(reader)
	if err := decoder.Decode(&document); err != nil {
		return nftablesDocument{}, fmt.Errorf("decode nftables JSON: %w", err)
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		if err == nil {
			return nftablesDocument{}, fmt.Errorf("decode nftables JSON: multiple JSON values")
		}
		return nftablesDocument{}, fmt.Errorf("decode nftables JSON trailing data: %w", err)
	}
	return document, nil
}

// CheckHealth verifies the minimum live nftables state required to block CN
// sources on every supplied listener port. Extra set elements, rules, and
// unrelated objects are allowed.
func CheckHealth(reader io.Reader, blockedPorts []int) error {
	if reader == nil {
		return fmt.Errorf("check nftables table health: nil reader")
	}
	requiredPorts := make(map[int]struct{}, len(blockedPorts))
	for _, port := range blockedPorts {
		if port < minPort || port > maxPort {
			return fmt.Errorf(
				"check nftables table health: port must be between %d and %d: %d",
				minPort,
				maxPort,
				port,
			)
		}
		requiredPorts[port] = struct{}{}
	}
	if len(requiredPorts) == 0 {
		return fmt.Errorf("%w: no listener port requires blocking", ErrTableUnhealthy)
	}

	document, err := decodeNftablesDocument(reader)
	if err != nil {
		return err
	}

	tablePresent := false
	ownedSetPresent := false
	setHasElements := false
	correctInputChain := false
	terminatingRuleBeforeCoverage := false
	acceptRuleBeforeCoverage := false
	coveredPorts := make(map[int]struct{}, len(requiredPorts))
	for _, raw := range document.Nftables {
		var object struct {
			Table *struct {
				Family string `json:"family"`
				Name   string `json:"name"`
			} `json:"table"`
			Set *struct {
				Family  string          `json:"family"`
				Table   string          `json:"table"`
				Name    string          `json:"name"`
				Comment string          `json:"comment"`
				Elem    json.RawMessage `json:"elem"`
			} `json:"set"`
			Element *struct {
				Family string          `json:"family"`
				Table  string          `json:"table"`
				Name   string          `json:"name"`
				Elem   json.RawMessage `json:"elem"`
			} `json:"element"`
			Chain *struct {
				Family string `json:"family"`
				Table  string `json:"table"`
				Name   string `json:"name"`
				Type   string `json:"type"`
				Hook   string `json:"hook"`
				Prio   *int   `json:"prio"`
				Policy string `json:"policy"`
			} `json:"chain"`
			Rule *struct {
				Family string            `json:"family"`
				Table  string            `json:"table"`
				Chain  string            `json:"chain"`
				Expr   []json.RawMessage `json:"expr"`
			} `json:"rule"`
		}
		if err := json.Unmarshal(raw, &object); err != nil {
			return fmt.Errorf("decode nftables object: %w", err)
		}
		if object.Table != nil &&
			object.Table.Family == TableFamily &&
			object.Table.Name == TableName {
			tablePresent = true
		}
		if object.Set != nil &&
			object.Set.Family == TableFamily &&
			object.Set.Table == TableName &&
			object.Set.Name == SetName {
			if object.Set.Comment == OwnershipComment {
				ownedSetPresent = true
			}
			if nftExpressionIsNonEmpty(object.Set.Elem) {
				setHasElements = true
			}
		}
		if object.Element != nil &&
			object.Element.Family == TableFamily &&
			object.Element.Table == TableName &&
			object.Element.Name == SetName &&
			nftExpressionIsNonEmpty(object.Element.Elem) {
			setHasElements = true
		}
		if object.Chain != nil &&
			object.Chain.Family == TableFamily &&
			object.Chain.Table == TableName &&
			object.Chain.Name == ChainName &&
			object.Chain.Type == "filter" &&
			object.Chain.Hook == "input" &&
			object.Chain.Prio != nil &&
			*object.Chain.Prio == -10 &&
			object.Chain.Policy == "accept" {
			correctInputChain = true
		}
		if object.Rule != nil &&
			object.Rule.Family == TableFamily &&
			object.Rule.Table == TableName &&
			object.Rule.Chain == ChainName {
			for port := range matchingDropRulePorts(object.Rule.Expr) {
				coveredPorts[port] = struct{}{}
			}
			if !requiredPortsAreCovered(requiredPorts, coveredPorts) &&
				isUnconditionalTerminatingRule(object.Rule.Expr) {
				terminatingRuleBeforeCoverage = true
			}
			if acceptsUncoveredBlockedTraffic(
				object.Rule.Expr,
				requiredPorts,
				coveredPorts,
			) {
				acceptRuleBeforeCoverage = true
			}
		}
	}

	switch {
	case !tablePresent:
		return fmt.Errorf("%w: table is missing", ErrTableUnhealthy)
	case !ownedSetPresent:
		return fmt.Errorf("%w: ownership marker is missing", ErrTableUnhealthy)
	case !setHasElements:
		return fmt.Errorf("%w: %s set is empty", ErrTableUnhealthy, SetName)
	case !correctInputChain:
		return fmt.Errorf("%w: input filter base chain is missing or incorrect", ErrTableUnhealthy)
	case terminatingRuleBeforeCoverage:
		return fmt.Errorf(
			"%w: an unconditional terminating rule precedes complete port coverage",
			ErrTableUnhealthy,
		)
	case acceptRuleBeforeCoverage:
		return fmt.Errorf(
			"%w: an accept rule permits required CN traffic before complete port coverage",
			ErrTableUnhealthy,
		)
	}
	for port := range requiredPorts {
		if _, covered := coveredPorts[port]; !covered {
			return fmt.Errorf("%w: port %d is not covered by a drop rule", ErrTableUnhealthy, port)
		}
	}
	return nil
}

func requiredPortsAreCovered(required, covered map[int]struct{}) bool {
	for port := range required {
		if _, exists := covered[port]; !exists {
			return false
		}
	}
	return true
}

func nftExpressionIsNonEmpty(raw json.RawMessage) bool {
	if len(raw) == 0 {
		return false
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	var value any
	if err := decoder.Decode(&value); err != nil {
		return false
	}
	switch value := value.(type) {
	case nil:
		return false
	case []any:
		return len(value) > 0
	default:
		return true
	}
}

func matchingDropRulePorts(expressions []json.RawMessage) map[int]struct{} {
	var sourceMatches, portMatches int
	var drop bool
	ports := make(map[int]struct{})
	for _, raw := range expressions {
		var statement map[string]json.RawMessage
		if err := json.Unmarshal(raw, &statement); err != nil || len(statement) != 1 {
			return nil
		}
		if _, exists := statement["drop"]; exists {
			drop = true
			continue
		}
		if _, exists := statement["counter"]; exists {
			continue
		}

		matchRaw, exists := statement["match"]
		if !exists {
			return nil
		}
		var match struct {
			Op    string          `json:"op"`
			Left  json.RawMessage `json:"left"`
			Right json.RawMessage `json:"right"`
		}
		if err := json.Unmarshal(matchRaw, &match); err != nil ||
			(match.Op != "==" && match.Op != "in") {
			return nil
		}
		switch {
		case isPayloadExpression(match.Left, "ip", "saddr") &&
			rawJSONString(match.Right) == "@"+SetName:
			sourceMatches++
		case isPayloadExpression(match.Left, "tcp", "dport"):
			portMatches++
			for port := range nftPortValues(match.Right) {
				ports[port] = struct{}{}
			}
		default:
			return nil
		}
	}
	if sourceMatches != 1 || portMatches != 1 || !drop {
		return nil
	}
	return ports
}

func isUnconditionalTerminatingRule(expressions []json.RawMessage) bool {
	terminates := false
	for _, raw := range expressions {
		var statement map[string]json.RawMessage
		if err := json.Unmarshal(raw, &statement); err != nil || len(statement) != 1 {
			return false
		}
		for name := range statement {
			switch name {
			case "counter", "log", "continue":
			case "accept", "drop", "reject", "return", "queue", "jump", "goto":
				terminates = true
			default:
				return false
			}
		}
	}
	return terminates
}

func acceptsUncoveredBlockedTraffic(
	expressions []json.RawMessage,
	requiredPorts map[int]struct{},
	coveredPorts map[int]struct{},
) bool {
	var accept, sourceMatches, portMatches int
	ports := make(map[int]struct{})
	for _, raw := range expressions {
		var statement map[string]json.RawMessage
		if err := json.Unmarshal(raw, &statement); err != nil || len(statement) != 1 {
			return false
		}
		if _, exists := statement["accept"]; exists {
			accept++
			continue
		}
		if _, exists := statement["counter"]; exists {
			continue
		}
		if _, exists := statement["log"]; exists {
			continue
		}

		matchRaw, exists := statement["match"]
		if !exists {
			return false
		}
		var match struct {
			Op    string          `json:"op"`
			Left  json.RawMessage `json:"left"`
			Right json.RawMessage `json:"right"`
		}
		if err := json.Unmarshal(matchRaw, &match); err != nil ||
			(match.Op != "==" && match.Op != "in") {
			return false
		}
		switch {
		case isPayloadExpression(match.Left, "ip", "saddr") &&
			rawJSONString(match.Right) == "@"+SetName:
			sourceMatches++
		case isPayloadExpression(match.Left, "tcp", "dport"):
			portMatches++
			for port := range nftPortValues(match.Right) {
				ports[port] = struct{}{}
			}
		default:
			return false
		}
	}
	if accept != 1 ||
		sourceMatches > 1 ||
		portMatches > 1 ||
		(sourceMatches == 0 && portMatches == 0) {
		return false
	}
	if portMatches == 0 {
		return !requiredPortsAreCovered(requiredPorts, coveredPorts)
	}
	for port := range ports {
		if _, required := requiredPorts[port]; !required {
			continue
		}
		if _, covered := coveredPorts[port]; !covered {
			return true
		}
	}
	return false
}

func isPayloadExpression(raw json.RawMessage, protocol, field string) bool {
	var expression struct {
		Payload *struct {
			Protocol string `json:"protocol"`
			Field    string `json:"field"`
		} `json:"payload"`
	}
	if err := json.Unmarshal(raw, &expression); err != nil || expression.Payload == nil {
		return false
	}
	return expression.Payload.Protocol == protocol && expression.Payload.Field == field
}

func rawJSONString(raw json.RawMessage) string {
	var value string
	if err := json.Unmarshal(raw, &value); err != nil {
		return ""
	}
	return value
}

func nftPortValues(raw json.RawMessage) map[int]struct{} {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	var value any
	if err := decoder.Decode(&value); err != nil {
		return nil
	}
	ports := make(map[int]struct{})
	collectNFTPorts(value, ports)
	return ports
}

func collectNFTPorts(value any, ports map[int]struct{}) {
	switch value := value.(type) {
	case json.Number:
		port, err := strconv.Atoi(value.String())
		if err == nil && port >= minPort && port <= maxPort {
			ports[port] = struct{}{}
		}
	case []any:
		for _, child := range value {
			collectNFTPorts(child, ports)
		}
	case map[string]any:
		if set, exists := value["set"]; exists {
			collectNFTPorts(set, ports)
		}
		if values, exists := value["range"].([]any); exists && len(values) == 2 {
			first, firstOK := nftPortNumber(values[0])
			last, lastOK := nftPortNumber(values[1])
			if firstOK && lastOK && first <= last {
				for port := first; port <= last; port++ {
					ports[port] = struct{}{}
				}
			}
		}
	}
}

func nftPortNumber(value any) (int, bool) {
	number, ok := value.(json.Number)
	if !ok {
		return 0, false
	}
	port, err := strconv.Atoi(number.String())
	if err != nil || port < minPort || port > maxPort {
		return 0, false
	}
	return port, true
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
