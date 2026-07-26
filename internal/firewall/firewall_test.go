package firewall

import (
	"bytes"
	"crypto/md5"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/netip"
	"os"
	"strings"
	"testing"
)

func TestParseCIDRsPreservesOrder(t *testing.T) {
	t.Parallel()

	got, err := ParseCIDRs(strings.NewReader("1.0.2.0/23\n1.0.1.0/24\n"))
	if err != nil {
		t.Fatal(err)
	}
	want := []netip.Prefix{
		netip.MustParsePrefix("1.0.2.0/23"),
		netip.MustParsePrefix("1.0.1.0/24"),
	}
	if len(got) != len(want) {
		t.Fatalf("prefix count = %d, want %d", len(got), len(want))
	}
	for index := range want {
		if got[index] != want[index] {
			t.Errorf("prefix %d = %s, want %s", index, got[index], want[index])
		}
	}
}

func TestParseCIDRsRejectsInvalidInput(t *testing.T) {
	t.Parallel()

	tests := map[string]string{
		"empty":            "",
		"whitespace":       "1.0.1.0/24 \n",
		"not a prefix":     "1.0.1.1\n",
		"IPv6":             "2001:db8::/32\n",
		"IPv4 mapped IPv6": "::ffff:1.0.1.0/120\n",
		"host bits":        "1.0.1.1/24\n",
		"comment":          "# comment\n",
	}
	for name, input := range tests {
		name, input := name, input
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			if _, err := ParseCIDRs(strings.NewReader(input)); err == nil {
				t.Fatal("ParseCIDRs unexpectedly succeeded")
			}
		})
	}
}

func TestBundledIPdenyIntegrity(t *testing.T) {
	var source struct {
		UpstreamMD5 string `json:"upstream_md5"`
		SHA256      string `json:"sha256"`
		LineCount   int    `json:"line_count"`
	}
	sourceFile, err := os.Open("../../assets/ipdeny/SOURCE.json")
	if err != nil {
		t.Fatal(err)
	}
	if err := json.NewDecoder(sourceFile).Decode(&source); err != nil {
		_ = sourceFile.Close()
		t.Fatal(err)
	}
	if err := sourceFile.Close(); err != nil {
		t.Fatal(err)
	}

	zone, err := os.ReadFile("../../assets/ipdeny/cn-aggregated.zone")
	if err != nil {
		t.Fatal(err)
	}
	prefixes, err := ParseCIDRs(bytes.NewReader(zone))
	if err != nil {
		t.Fatal(err)
	}
	if len(prefixes) != source.LineCount {
		t.Fatalf("prefix count = %d, SOURCE.json line_count = %d", len(prefixes), source.LineCount)
	}
	gotSHA256 := sha256.Sum256(zone)
	if got := hex.EncodeToString(gotSHA256[:]); got != source.SHA256 {
		t.Fatalf("zone SHA-256 = %s, SOURCE.json = %s", got, source.SHA256)
	}
	gotMD5 := md5.Sum(zone)
	md5Text := hex.EncodeToString(gotMD5[:])
	if md5Text != source.UpstreamMD5 {
		t.Fatalf("zone MD5 = %s, SOURCE.json = %s", md5Text, source.UpstreamMD5)
	}

	upstream, err := os.ReadFile("../../assets/ipdeny/MD5SUM.upstream")
	if err != nil {
		t.Fatal(err)
	}
	var upstreamCN string
	for _, line := range strings.Split(string(upstream), "\n") {
		fields := strings.Fields(line)
		if len(fields) == 2 && fields[1] == "cn-aggregated.zone" {
			if upstreamCN != "" {
				t.Fatal("MD5SUM.upstream contains multiple cn-aggregated.zone entries")
			}
			upstreamCN = fields[0]
		}
	}
	if upstreamCN == "" {
		t.Fatal("MD5SUM.upstream has no cn-aggregated.zone entry")
	}
	if upstreamCN != source.UpstreamMD5 || upstreamCN != md5Text {
		t.Fatalf(
			"upstream CN MD5 = %s, SOURCE.json = %s, zone = %s",
			upstreamCN,
			source.UpstreamMD5,
			md5Text,
		)
	}

	copyrights, err := os.ReadFile("../../assets/ipdeny/Copyrights.txt")
	if err != nil {
		t.Fatal(err)
	}
	if len(strings.TrimSpace(string(copyrights))) == 0 {
		t.Fatal("Copyrights.txt is empty")
	}
}

func TestClassifyExistingTable(t *testing.T) {
	t.Parallel()

	owned := `{
		"nftables": [
			{"metainfo": {"json_schema_version": 1}},
			{"table": {"family": "ip", "name": "socks_vps", "handle": 7}},
			{"set": {
				"family": "ip",
				"table": "socks_vps",
				"name": "cn_ipv4",
				"comment": "Socks-VPS managed CN IPv4 set"
			}}
		]
	}`
	state, err := ClassifyExistingTable(strings.NewReader(owned))
	if err != nil {
		t.Fatal(err)
	}
	if state != TableOwned {
		t.Fatalf("state = %v, want TableOwned", state)
	}

	foreign := `{
		"nftables": [
			{"table": {
				"family": "ip",
				"name": "socks_vps",
				"comment": "Socks-VPS managed table"
			}},
			{"set": {
				"family": "ip",
				"table": "socks_vps",
				"name": "cn_ipv4",
				"comment": "someone else"
			}}
		]
	}`
	state, err = ClassifyExistingTable(strings.NewReader(foreign))
	if err != nil {
		t.Fatal(err)
	}
	if state != TableForeign {
		t.Fatalf("state = %v, want TableForeign", state)
	}
}

func TestClassifyExistingTableRejectsInvalidOrWrongListing(t *testing.T) {
	t.Parallel()

	if _, err := ClassifyExistingTable(strings.NewReader(`not json`)); err == nil {
		t.Fatal("invalid JSON unexpectedly succeeded")
	}
	wrong := `{"nftables":[{"table":{"family":"inet","name":"socks_vps","comment":"Socks-VPS managed table"}}]}`
	if _, err := ClassifyExistingTable(strings.NewReader(wrong)); !errors.Is(err, ErrTableNotPresent) {
		t.Fatalf("wrong listing error = %v, want ErrTableNotPresent", err)
	}
}

func TestClassifyExistingTableRequiresExactSetMarker(t *testing.T) {
	t.Parallel()

	for name, set := range map[string]string{
		"wrong family": `{
			"family": "inet",
			"table": "socks_vps",
			"name": "cn_ipv4",
			"comment": "Socks-VPS managed CN IPv4 set"
		}`,
		"wrong table": `{
			"family": "ip",
			"table": "other",
			"name": "cn_ipv4",
			"comment": "Socks-VPS managed CN IPv4 set"
		}`,
		"wrong name": `{
			"family": "ip",
			"table": "socks_vps",
			"name": "other",
			"comment": "Socks-VPS managed CN IPv4 set"
		}`,
	} {
		t.Run(name, func(t *testing.T) {
			document := `{
				"nftables": [
					{"table": {"family": "ip", "name": "socks_vps"}},
					{"set": ` + set + `}
				]
			}`
			state, err := ClassifyExistingTable(strings.NewReader(document))
			if err != nil {
				t.Fatal(err)
			}
			if state != TableForeign {
				t.Fatalf("state = %v, want TableForeign", state)
			}
		})
	}
}

func TestRenderInitialBatch(t *testing.T) {
	t.Parallel()

	prefixes := []netip.Prefix{
		netip.MustParsePrefix("1.0.1.0/24"),
		netip.MustParsePrefix("1.0.2.0/23"),
	}
	var output bytes.Buffer
	if err := Render(&output, 23456, prefixes, TableAbsent); err != nil {
		t.Fatal(err)
	}

	got := output.String()
	for _, required := range []string{
		`create table ip socks_vps { comment "Socks-VPS managed table"; }`,
		"add set ip socks_vps cn_ipv4 {",
		"type ipv4_addr;",
		"flags interval;",
		"1.0.1.0/24,",
		"1.0.2.0/23",
		`add chain ip socks_vps input { type filter hook input priority -10; comment "Socks-VPS managed input chain"; }`,
		"add rule ip socks_vps input ip saddr @cn_ipv4 tcp dport 23456 counter drop",
	} {
		if !strings.Contains(got, required) {
			t.Errorf("rendered batch does not contain %q:\n%s", required, got)
		}
	}
	if strings.Contains(got, "delete table") {
		t.Fatalf("initial batch unexpectedly deletes a table:\n%s", got)
	}
	if strings.Contains(got, "\n\t\taccept") {
		t.Fatalf("batch unexpectedly adds an accept rule:\n%s", got)
	}
	if strings.Contains(got, "policy accept") {
		t.Fatalf("batch unexpectedly sets an explicit accept policy:\n%s", got)
	}
}

func TestRenderOwnedReplacementIsOneBatch(t *testing.T) {
	t.Parallel()

	var output bytes.Buffer
	err := Render(
		&output,
		1024,
		[]netip.Prefix{netip.MustParsePrefix("1.0.1.0/24")},
		TableOwned,
	)
	if err != nil {
		t.Fatal(err)
	}
	got := output.String()
	if !strings.HasPrefix(got, "delete table ip socks_vps\n\ncreate table ip socks_vps {") {
		t.Fatalf("replacement batch = %q", got)
	}
	if strings.Contains(got, "flush ruleset") || strings.Contains(got, "flush table") {
		t.Fatalf("replacement batch contains a forbidden flush:\n%s", got)
	}
}

func TestRenderRejectsForeignTableAndInvalidData(t *testing.T) {
	t.Parallel()

	valid := []netip.Prefix{netip.MustParsePrefix("1.0.1.0/24")}
	if err := Render(&bytes.Buffer{}, 12345, valid, TableForeign); !errors.Is(err, ErrTableConflict) {
		t.Fatalf("foreign table error = %v, want ErrTableConflict", err)
	}
	if err := Render(&bytes.Buffer{}, 1023, valid, TableAbsent); err == nil {
		t.Fatal("port below range unexpectedly succeeded")
	}
	if err := Render(&bytes.Buffer{}, 12345, nil, TableAbsent); !errors.Is(err, ErrEmptyCIDRs) {
		t.Fatalf("empty CIDRs error = %v, want ErrEmptyCIDRs", err)
	}
	nonCanonical := []netip.Prefix{netip.MustParsePrefix("1.0.1.1/24")}
	if err := Render(&bytes.Buffer{}, 12345, nonCanonical, TableAbsent); err == nil {
		t.Fatal("non-canonical CIDR unexpectedly succeeded")
	}
}

func TestRenderRemove(t *testing.T) {
	t.Parallel()

	var output bytes.Buffer
	if err := RenderRemove(&output, TableOwned); err != nil {
		t.Fatal(err)
	}
	if got, want := output.String(), "delete table ip socks_vps\n"; got != want {
		t.Fatalf("removal batch = %q, want %q", got, want)
	}

	output.Reset()
	if err := RenderRemove(&output, TableAbsent); err != nil {
		t.Fatal(err)
	}
	if output.Len() != 0 {
		t.Fatalf("absent table removal wrote %q", output.String())
	}

	if err := RenderRemove(&bytes.Buffer{}, TableForeign); !errors.Is(err, ErrTableConflict) {
		t.Fatalf("foreign table error = %v, want ErrTableConflict", err)
	}
	if err := RenderRemove(&bytes.Buffer{}, TableState(99)); err == nil {
		t.Fatal("invalid table state unexpectedly succeeded")
	}
}
