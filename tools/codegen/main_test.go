package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func mustPanic(t *testing.T, contains string, f func()) {
	t.Helper()
	defer func() {
		r := recover()
		if r == nil {
			t.Fatal("expected rejection")
		}
		if msg := strings.ToLower(strings.TrimSpace(fmtAny(r))); !strings.Contains(msg, strings.ToLower(contains)) {
			t.Fatalf("rejection %q does not mention %q", msg, contains)
		}
	}()
	f()
}

func fmtAny(v any) string {
	if err, ok := v.(error); ok {
		return err.Error()
	}
	if s, ok := v.(string); ok {
		return s
	}
	data, _ := json.Marshal(v)
	return string(data)
}

func tinySchema() Schema {
	u8 := Node{Kind: "u8"}
	return Schema{SchemaVersion: 1, Target: Target{"1.0.0", 1},
		Packets: []Packet{{ID: 1, Name: "Ping", Wire: "PingPacket", Directions: []string{"client"}, Fields: []Field{
			{Name: "mode", Wire: "Mode", Type: Node{Kind: "ref", Ref: "Mode"}},
			{Name: "items", Wire: "Items", Type: Node{Kind: "list", Prefix: "var_u32", Element: &u8}},
		}}},
		Types: []TypeDef{{Name: "Mode", Kind: "enum", Repr: "u8", Values: []Value{{"a", 0}, {"b", 1}}}},
	}
}

func TestValidateRejectsMalformedSchemas(t *testing.T) {
	cases := map[string]func(*Schema){
		"duplicate packet": func(s *Schema) { s.Packets = append(s.Packets, s.Packets[0]) },
		"invalid 10-bit":   func(s *Schema) { s.Packets[0].ID = 1024 },
		"directions":       func(s *Schema) { s.Packets[0].Directions = []string{"server", "client"} },
		"unknown type":     func(s *Schema) { s.Packets[0].Fields[0].Type.Ref = "Missing" },
		"allowed value":    func(s *Schema) { s.Packets[0].Fields[0].Type.Allowed = []int64{7} },
		"prefix":           func(s *Schema) { s.Packets[0].Fields[1].Type.Prefix = "f32le" },
		"pattern":          func(s *Schema) { s.Packets[0].Fields[1].Type = Node{Kind: "string", Prefix: "var_u32", Pattern: "^x$"} },
		"duplicate field":  func(s *Schema) { s.Packets[0].Fields[1].Name = "mode" },
		"invalid enum":     func(s *Schema) { s.Types[0].Values = append(s.Types[0].Values, Value{"c", 256}) },
		"unsupported check": func(s *Schema) {
			s.Types = append(s.Types, TypeDef{Name: "Z", Kind: "struct", Fields: []Field{{Name: "x", Type: Node{Kind: "u8"}}}, Checks: []Check{{Kind: "sum"}}})
		},
	}
	if err := tinySchema().validate(); err != nil {
		t.Fatal(err)
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			s := tinySchema()
			mutate(&s)
			if err := s.validate(); err == nil {
				t.Fatal("accepted an invalid schema")
			}
		})
	}
}

func TestGenerateRejectsUnsatisfiableBounds(t *testing.T) {
	s := tinySchema()
	big := json.Number("300")
	s.Packets[0].Fields[1].Type.Element = &Node{Kind: "u8", Min: &big}
	mustPanic(t, "cannot be satisfied", func() { generate(s) })
}

func TestNaming(t *testing.T) {
	for in, want := range map[string]string{
		"cerealizer<NetworkItemStackDescriptor>::SerializedData":     "NetworkItemStackDescriptor",
		"TextPacketPayload::MessageOnly":                             "TextMessageOnly",
		"SharedTypes::v1_26_0::CameraSplineDefinition":               "CameraSplineDefinition",
		"InventorySource::InventorySourceFlags":                      "InventorySourceFlags",
		"TypedClientNetId<struct ItemStackRequestIdTag, int32_t, 0>": "TypedClientNetId",
	} {
		if got := deriveTypeName(in); got != want {
			t.Errorf("deriveTypeName(%q) = %q, want %q", in, got, want)
		}
	}
	got := variantNames([]string{"DisconnectPacketMessages", "Empty1"}, "disconnect")
	if !reflect.DeepEqual(got, []string{"messages", "empty"}) {
		t.Errorf("variant names %v", got)
	}
	got = variantNames([]string{"Empty0", "ArrowDataPayload", "TextDataPayload"}, "x")
	if !reflect.DeepEqual(got, []string{"empty", "arrow", "text"}) {
		t.Errorf("variant names %v", got)
	}
	if snake("Sender's XUID") != "senders_xuid" || snake("Full container name.") != "full_container_name" || pascal("y-head rotation") != "YHeadRotation" {
		t.Error("identifier normalization changed")
	}
}

func TestDiffReportsWireChanges(t *testing.T) {
	a, b := tinySchema(), tinySchema()
	b.Packets[0].ID = 2
	b.Packets[0].Directions = []string{"client", "server"}
	b.Packets[0].Fields[0], b.Packets[0].Fields[1] = b.Packets[0].Fields[1], b.Packets[0].Fields[0]
	b.Packets[0].Fields[0].Type.Element = &Node{Kind: "u16le"}
	b.Types[0].Values = append(b.Types[0].Values, Value{"c", 2})
	report := diffSchemas(a, b)
	for _, want := range []string{"Ping: 1 -> 2", "[client] -> [client server]", "list<var_u32>(u8) -> list<var_u32>(u16le)", "field order mode,items -> items,mode", "added enum value c=2"} {
		if !strings.Contains(report, want) {
			t.Errorf("diff report lacks %q:\n%s", want, report)
		}
	}
	if !strings.Contains(diffSchemas(a, a), "No wire or validation changes") {
		t.Error("identical schemas reported changes")
	}
}

func TestCheckDoesNotOverwriteStaleOutput(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "output.zig")
	stale := filepath.Join(dir, "removed.zig")
	must(os.WriteFile(path, []byte("stale"), 0o644))
	must(os.WriteFile(stale, []byte("old"), 0o644))
	if code := sync(map[string]string{path: "fresh"}, []string{dir}, true); code == 0 {
		t.Fatal("check accepted drift")
	}
	if data, _ := os.ReadFile(path); string(data) != "stale" {
		t.Fatal("check changed output")
	}
	if code := sync(map[string]string{path: "fresh"}, []string{dir}, false); code != 0 {
		t.Fatal("write failed")
	}
	if _, err := os.Stat(stale); !os.IsNotExist(err) {
		t.Fatal("stale generated file was kept")
	}
	if code := sync(map[string]string{path: "fresh"}, []string{dir}, true); code != 0 {
		t.Fatal("check rejected fresh output")
	}
}

func TestCheckedInSchemaGeneratesDeterministically(t *testing.T) {
	s := loadSchema(filepath.Join("..", "..", "protocol", "schema", "bedrock-"+protocolVersion+".json"))
	if !reflect.DeepEqual(generate(s), generate(s)) {
		t.Fatal("generation is not deterministic")
	}
	hints := loadHints(filepath.Join("..", "..", "protocol", "schema", "sample-hints-"+protocolVersion+".json"))
	if !reflect.DeepEqual(corpus(s, hints, 1, 2), corpus(s, hints, 1, 2)) {
		t.Fatal("corpus is not deterministic")
	}
	if report, err := coverage(s); err != nil || !strings.Contains(report, "known opaque: 0") {
		t.Fatalf("coverage: %v\n%s", err, report)
	}
}

// writeSource writes a minimal protocolgen output directory and returns the
// reconciliation that pins it.
func writeSource(t *testing.T, manifest string) (string, Reconciliation) {
	dir := t.TempDir()
	files := map[string]string{"manifest.json": manifest, "naming.json": `{"entries":[]}`, "gophertunnel-layout.json": `{"types":[]}`, "domains.json": `{"entries":[]}`}
	var rec Reconciliation
	rec.Target = Target{"1.0.0", 1}
	rec.Manifest.Files = map[string]string{}
	for name, data := range files {
		must(os.WriteFile(filepath.Join(dir, name), []byte(data), 0o644))
		sum := sha256.Sum256([]byte(data))
		rec.Manifest.Files[name] = "sha256:" + hex.EncodeToString(sum[:])
	}
	rec.PacketNames = map[string]string{"1": "Ping"}
	return dir, rec
}

func runIngest(t *testing.T, dir string, rec Reconciliation) Schema {
	path := filepath.Join(t.TempDir(), "reconciliation.json")
	data, err := json.Marshal(rec)
	must(err)
	must(os.WriteFile(path, data, 0o644))
	return ingest(dir, path)
}

const tinyManifest = `{"schema_version":2,"target":{"minecraft_version":"1.0.0","protocol_version":1},"packets":[
 {"id":1,"name":"PingPacket","direction":"serverbound","fields":[
  {"name":"Mode","encode":{"kind":"enum","type_id":"enums/Mode","primitive":{"code":"u8"},"variants":[{"value":0,"name":"a","encode":{"kind":"void"}},{"value":1,"name":"b","encode":{"kind":"void"}}]},"symmetry":"symmetric"},
  {"name":"Wrapped","encode":{"kind":"struct","type_id":"Wrapper","fields":[{"name":"Inner","encode":{"kind":"primitive","primitive":{"code":"var_u64"}},"symmetry":"symmetric"}]},"symmetry":"symmetric"}]}]}`

func TestIngestFailsClosed(t *testing.T) {
	dir, rec := writeSource(t, tinyManifest)
	s := runIngest(t, dir, rec)
	if len(s.Packets) != 1 || s.Packets[0].Fields[1].Type.Kind != "var_u64" {
		t.Fatalf("single-field wrappers must flatten: %+v", s.Packets)
	}
	if s.Packets[0].Directions[0] != "client" {
		t.Fatal("serverbound must map to client")
	}

	tampered := rec
	tampered.Manifest.Files = map[string]string{}
	for k, v := range rec.Manifest.Files {
		tampered.Manifest.Files[k] = v
	}
	tampered.Manifest.Files["manifest.json"] = "sha256:00"
	mustPanic(t, "digest", func() { runIngest(t, dir, tampered) })

	stale := rec
	stale.Directions = append(stale.Directions, struct {
		ID         uint16     `json:"id"`
		Manifest   string     `json:"manifest"`
		Directions []string   `json:"directions"`
		Evidence   []evidence `json:"evidence"`
		Reason     string     `json:"reason"`
	}{ID: 1, Manifest: "clientbound", Directions: []string{"client", "server"}})
	mustPanic(t, "written against", func() { runIngest(t, dir, stale) })

	unnamed := rec
	unnamed.PacketNames = map[string]string{}
	mustPanic(t, "no reviewed name", func() { runIngest(t, dir, unnamed) })

	extra := rec
	extra.FieldNames = map[string]string{"Ping.Missing": "x"}
	mustPanic(t, "stale field name", func() { runIngest(t, dir, extra) })
}
