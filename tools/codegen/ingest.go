package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"unicode"
)

// Manifest mirrors the subset of protocolgen's canonical manifest (schema v2)
// that ingest accepts. Unknown node kinds fail closed.
type mManifest struct {
	SchemaVersion int `json:"schema_version"`
	Target        struct {
		MinecraftVersion string `json:"minecraft_version"`
		ProtocolVersion  int    `json:"protocol_version"`
	} `json:"target"`
	Packets []mPacket `json:"packets"`
}

type mPacket struct {
	ID        uint16   `json:"id"`
	Name      string   `json:"name"`
	Direction string   `json:"direction"`
	Fields    []mField `json:"fields"`
}

type mField struct {
	Name     string `json:"name"`
	Encode   mNode  `json:"encode"`
	Decode   *mNode `json:"decode"`
	Symmetry string `json:"symmetry"`
	Reserved bool   `json:"reserved"`
	Ignored  bool   `json:"ignored"`
}

type mNode struct {
	Kind      string `json:"kind"`
	Semantic  string `json:"semantic"`
	TypeID    string `json:"type_id"`
	Primitive *struct {
		Code string `json:"code"`
	} `json:"primitive"`
	Prefix         *mNode     `json:"prefix"`
	Encoding       string     `json:"encoding"`
	Representation string     `json:"representation"`
	Element        *mNode     `json:"element"`
	Length         uint64     `json:"length"`
	Value          *mNode     `json:"value"`
	Fields         []mField   `json:"fields"`
	Key            *mNode     `json:"key"`
	Variants       []mVariant `json:"variants"`
	Control        *mNode     `json:"control"`
	Target         string     `json:"target"`
	Constraints    *struct {
		MinLength     *uint64      `json:"min_length"`
		MaxLength     *uint64      `json:"max_length"`
		MinItems      *uint64      `json:"min_items"`
		MaxItems      *uint64      `json:"max_items"`
		MinProperties *uint64      `json:"min_properties"`
		MaxProperties *uint64      `json:"max_properties"`
		Minimum       *json.Number `json:"minimum"`
		Maximum       *json.Number `json:"maximum"`
		Pattern       string       `json:"pattern"`
	} `json:"constraints"`
}

type mVariant struct {
	Value  int64  `json:"value"`
	Name   string `json:"name"`
	Encode mNode  `json:"encode"`
	Decode *mNode `json:"decode"`
}

type evidence struct {
	Locator string `json:"locator"`
	Summary string `json:"summary"`
}

// Reconciliation holds every reviewed decision layered over the manifest.
// Each decision names the manifest state it was written against, so a changed
// upstream schema stops ingest instead of silently inheriting a stale fix.
type Reconciliation struct {
	SchemaVersion int    `json:"schema_version"`
	Target        Target `json:"target"`
	Manifest      struct {
		Repository string            `json:"repository"`
		Revision   string            `json:"revision"`
		Path       string            `json:"path"`
		Files      map[string]string `json:"files"`
	} `json:"manifest"`
	EvidenceSources []Source `json:"evidence_sources"`
	RemovedPackets  []struct {
		ID       uint16     `json:"id"`
		Name     string     `json:"name"`
		Evidence []evidence `json:"evidence"`
		Reason   string     `json:"reason"`
	} `json:"removed_packets"`
	PacketNames        map[string]string `json:"packet_names"`
	PacketNameEvidence string            `json:"packet_name_evidence"`
	Directions         []struct {
		ID         uint16     `json:"id"`
		Manifest   string     `json:"manifest"`
		Directions []string   `json:"directions"`
		Evidence   []evidence `json:"evidence"`
		Reason     string     `json:"reason"`
	} `json:"directions"`
	// TypeNames maps a normalized type_id to a reviewed Zig type name.
	TypeNames map[string]string `json:"type_names"`
	// VariantNames maps "UnionName.Wire Variant" to a reviewed variant name.
	VariantNames map[string]string `json:"variant_names"`
	// FieldNames maps "TypeOrPacketName.Wire Name" to a reviewed field name.
	FieldNames map[string]string `json:"field_names"`
	// Patterns maps a schema string pattern to "keep" or to the reason it is
	// not enforced (for prose that is not a regular expression).
	Patterns map[string]string `json:"patterns"`
	// Disagreements documents source conflicts resolved in favour of the
	// manifest. Each names the field it covers so a schema change surfaces it.
	Disagreements []struct {
		Target   string     `json:"target"`
		Decision string     `json:"decision"`
		Evidence []evidence `json:"evidence"`
	} `json:"disagreements"`
	// EnumRestrictions reviews every per-site enum subset ("Owner.field").
	// Values narrows a site the manifest leaves open; a site the manifest
	// already narrows must repeat the same values.
	EnumRestrictions map[string]struct {
		Enforce  bool       `json:"enforce"`
		Values   []int64    `json:"values"`
		Reason   string     `json:"reason"`
		Evidence []evidence `json:"evidence"`
	} `json:"enum_restrictions"`
	// Constraints adds reviewed bounds at "Owner.field/step/step" where each
	// step is "value" (optional) or "element" (list or fixed array).
	Constraints map[string]struct {
		MinItems *uint64 `json:"min_items"`
		MaxItems *uint64 `json:"max_items"`
		// DropBounds removes published numeric bounds that describe policy
		// (such as the current protocol number) rather than the wire.
		DropBounds bool       `json:"drop_bounds"`
		Reason     string     `json:"reason"`
		Evidence   []evidence `json:"evidence"`
	} `json:"constraints"`
	// Checks adds reviewed cross-field invariants to a struct.
	Checks map[string][]struct {
		Check
		Reason   string     `json:"reason"`
		Evidence []evidence `json:"evidence"`
	} `json:"checks"`
	// CustomTypes replaces a manifest struct the schema vocabulary cannot
	// express with a hand-written codec. ExpectFields pins the manifest shape.
	CustomTypes map[string]struct {
		Custom       string     `json:"custom"`
		ExpectFields []string   `json:"expect_fields"`
		Reason       string     `json:"reason"`
		Evidence     []evidence `json:"evidence"`
	} `json:"custom_types"`
}

type overlayNames struct {
	Entries []struct {
		TypeID string `json:"type_id"`
		Name   string `json:"name"`
		Domain string `json:"domain"`
	} `json:"entries"`
	Types []struct {
		TypeID string `json:"type_id"`
		Name   string `json:"name"`
	} `json:"types"`
}

type ingester struct {
	rec       Reconciliation
	names     map[string]string // normalized type_id -> reviewed name
	domains   map[string]string // normalized type_id -> domain
	types     map[string]*TypeDef
	keys      map[string]string // normalized type_id -> type name
	usedNames map[string]string // type name -> key that claimed it
	restrict  map[string]bool   // reviewed enum restriction sites that were applied
	shapes    map[string]string // anonymous type signature -> type name
	reviewed  map[string]bool   // reviewed names that matched a schema site
	errs      []string
}

func readVerified(dir, name, digest string, value any) {
	data, err := os.ReadFile(filepath.Join(dir, name))
	must(err)
	// Digests are of the committed LF bytes; a CRLF checkout hashes the same.
	data = bytes.ReplaceAll(data, []byte("\r\n"), []byte("\n"))
	sum := sha256.Sum256(data)
	if got := "sha256:" + hex.EncodeToString(sum[:]); got != digest {
		panic(fmt.Errorf("%s digest %s does not match the pinned %s", name, got, digest))
	}
	must(json.Unmarshal(data, value))
}

// ingest reads the pinned manifest from a protocolgen checkout.
func ingest(checkout, reconciliationPath string) Schema {
	var rec Reconciliation
	data, err := os.ReadFile(reconciliationPath)
	must(err)
	must(json.Unmarshal(data, &rec))
	sourceDir := filepath.Join(checkout, filepath.FromSlash(rec.Manifest.Path))
	var manifest mManifest
	readVerified(sourceDir, "manifest.json", rec.Manifest.Files["manifest.json"], &manifest)
	var naming, layout, domains overlayNames
	readVerified(sourceDir, "naming.json", rec.Manifest.Files["naming.json"], &naming)
	readVerified(sourceDir, "gophertunnel-layout.json", rec.Manifest.Files["gophertunnel-layout.json"], &layout)
	readVerified(sourceDir, "domains.json", rec.Manifest.Files["domains.json"], &domains)
	if manifest.SchemaVersion != 2 || manifest.Target.ProtocolVersion != rec.Target.ProtocolVersion {
		panic(fmt.Errorf("manifest targets protocol %d schema %d, reconciliation targets %d", manifest.Target.ProtocolVersion, manifest.SchemaVersion, rec.Target.ProtocolVersion))
	}
	// Releases can share a protocol number, so the game version must match too.
	if manifest.Target.MinecraftVersion != rec.Target.MinecraftVersion {
		panic(fmt.Errorf("manifest targets Minecraft %s, reconciliation targets %s", manifest.Target.MinecraftVersion, rec.Target.MinecraftVersion))
	}

	g := &ingester{rec: rec, names: map[string]string{}, domains: map[string]string{}, types: map[string]*TypeDef{},
		keys: map[string]string{}, usedNames: map[string]string{}, restrict: map[string]bool{}, shapes: map[string]string{}, reviewed: map[string]bool{}}
	for _, e := range naming.Entries {
		g.names[normalizeTypeID(e.TypeID)] = e.Name
	}
	for _, e := range layout.Types {
		g.names[normalizeTypeID(e.TypeID)] = e.Name
	}
	for id, name := range rec.TypeNames {
		g.names[id] = name
	}
	for _, e := range domains.Entries {
		g.domains[normalizeTypeID(e.TypeID)] = e.Domain
	}

	removed := map[uint16]bool{}
	for _, r := range rec.RemovedPackets {
		removed[r.ID] = true
	}
	overrides := map[uint16]int{}
	for i, d := range rec.Directions {
		overrides[d.ID] = i
	}
	schema := Schema{SchemaVersion: 1, Target: rec.Target}
	schema.Sources = append(schema.Sources, Source{ID: "protocolgen", Repository: rec.Manifest.Repository, Revision: rec.Manifest.Revision,
		Path: rec.Manifest.Path + "/manifest.json", SHA256: rec.Manifest.Files["manifest.json"]})
	schema.Sources = append(schema.Sources, rec.EvidenceSources...)

	seenNames := map[string]bool{}
	for _, mp := range manifest.Packets {
		if removed[mp.ID] {
			panic(fmt.Errorf("removed packet %d is present in the manifest; review the removal", mp.ID))
		}
		name := rec.PacketNames[strconv.Itoa(int(mp.ID))]
		if name == "" {
			panic(fmt.Errorf("packet %d %s has no reviewed name", mp.ID, mp.Name))
		}
		seenNames[strconv.Itoa(int(mp.ID))] = true
		p := Packet{ID: mp.ID, Name: name, Wire: mp.Name}
		switch mp.Direction {
		case "clientbound":
			p.Directions = []string{"server"}
		case "serverbound":
			p.Directions = []string{"client"}
		case "bidirectional":
			p.Directions = []string{"client", "server"}
		default:
			panic(fmt.Errorf("packet %s has direction %q", mp.Name, mp.Direction))
		}
		if i, ok := overrides[mp.ID]; ok {
			o := rec.Directions[i]
			if o.Manifest != mp.Direction {
				panic(fmt.Errorf("direction decision for %d was written against %q but the manifest says %q", mp.ID, o.Manifest, mp.Direction))
			}
			p.Directions = append([]string(nil), o.Directions...)
			delete(overrides, mp.ID)
		}
		p.Fields = append([]Field{}, g.fields(name, snake(name), mp.Fields)...)
		schema.Packets = append(schema.Packets, p)
	}
	for id := range rec.PacketNames {
		if !seenNames[id] {
			panic(fmt.Errorf("reviewed packet name %s has no manifest packet", id))
		}
	}
	for id := range overrides {
		panic(fmt.Errorf("direction decision for %d has no manifest packet", id))
	}
	g.restrictions(&schema)
	g.applyConstraints(&schema)
	g.applyChecks()
	g.checkDisagreements(&schema)
	for id := range rec.CustomTypes {
		if !g.reviewed["custom:"+id] {
			g.errs = append(g.errs, "stale custom type decision "+id)
		}
	}
	for key := range rec.VariantNames {
		if !g.reviewed["variant:"+key] {
			g.errs = append(g.errs, "stale variant name decision "+key)
		}
	}
	for key := range rec.FieldNames {
		if !g.reviewed["field:"+key] {
			g.errs = append(g.errs, "stale field name decision "+key)
		}
	}
	for site := range rec.EnumRestrictions {
		if !g.restrict[site] {
			g.errs = append(g.errs, "stale enum restriction "+site)
		}
	}
	if len(g.errs) != 0 {
		sort.Strings(g.errs)
		panic(fmt.Errorf("ingest failed:\n  %s", strings.Join(g.errs, "\n  ")))
	}
	sort.Slice(schema.Packets, func(i, j int) bool { return schema.Packets[i].ID < schema.Packets[j].ID })
	g.assignOwners(&schema)
	for _, t := range g.types {
		schema.Types = append(schema.Types, *t)
	}
	sort.Slice(schema.Types, func(i, j int) bool { return schema.Types[i].Name < schema.Types[j].Name })
	must(schema.validate())
	return schema
}

func normalizeTypeID(id string) string {
	id = strings.TrimSpace(id)
	id = strings.TrimPrefix(id, "enums/")
	id = strings.TrimPrefix(id, "types/")
	id = strings.TrimSuffix(id, "#")
	id = strings.TrimSuffix(id, ".json")
	return strings.ReplaceAll(id, "__", "::")
}

// fields converts an ordered field list. owner is the Zig name of the type or
// packet holding the fields and is the naming scope for anonymous children.
func (g *ingester) fields(owner, packet string, fields []mField) []Field {
	var result []Field
	used := map[string]bool{}
	for _, f := range fields {
		if f.Reserved || f.Ignored || f.Decode != nil || (f.Symmetry != "" && f.Symmetry != "symmetric") {
			g.errs = append(g.errs, fmt.Sprintf("%s.%s: asymmetric, reserved or ignored fields are unsupported", owner, f.Name))
			continue
		}
		name := g.rec.FieldNames[owner+"."+f.Name]
		if name != "" {
			g.reviewed["field:"+owner+"."+f.Name] = true
		} else {
			name = snake(f.Name)
		}
		if used[name] {
			g.errs = append(g.errs, fmt.Sprintf("%s: field name %q is ambiguous; add a field_names decision", owner, name))
			continue
		}
		used[name] = true
		node := g.node(f.Encode, packet, owner+pascal(name))
		result = append(result, Field{Name: name, Wire: f.Name, Type: node})
	}
	return result
}

func (g *ingester) primitive(n mNode) string {
	if n.Primitive == nil {
		g.errs = append(g.errs, "primitive node without shape")
		return "u8"
	}
	code := n.Primitive.Code
	if code == "nbt_le" {
		if n.Encoding != "network" {
			g.errs = append(g.errs, fmt.Sprintf("NBT encoding %q is unsupported", n.Encoding))
		}
		return "nbt"
	}
	if !isPrimitive(code) {
		g.errs = append(g.errs, fmt.Sprintf("primitive %q is unsupported", code))
		return "u8"
	}
	return code
}

func (g *ingester) prefix(n *mNode, where string) string {
	if n == nil || n.Kind != "primitive" {
		g.errs = append(g.errs, where+": missing primitive count prefix")
		return "var_u32"
	}
	code := g.primitive(*n)
	if !countPrefixes[code] {
		g.errs = append(g.errs, fmt.Sprintf("%s: unsupported count prefix %s", where, code))
	}
	return code
}

// node lowers one manifest node. anon names an anonymous struct/union/enum.
func (g *ingester) node(n mNode, packet, anon string) Node {
	var out Node
	c := n.Constraints
	switch n.Kind {
	case "primitive":
		out = Node{Kind: g.primitive(n)}
		if c != nil {
			out.Min, out.Max = c.Minimum, c.Maximum
		}
	case "string":
		if n.Encoding != "utf8" || n.Representation != "text" {
			g.errs = append(g.errs, fmt.Sprintf("%s: string encoding %s/%s", anon, n.Encoding, n.Representation))
		}
		out = Node{Kind: "string", Prefix: g.prefix(n.Prefix, anon)}
		if c != nil {
			out.MinLen, out.MaxLen = c.MinLength, c.MaxLength
			if c.Pattern != "" {
				switch decision := g.rec.Patterns[c.Pattern]; decision {
				case "keep":
					out.Pattern = c.Pattern
				case "":
					g.errs = append(g.errs, fmt.Sprintf("%s: pattern %q needs a reviewed decision", anon, c.Pattern))
				}
			}
		}
	case "bytes":
		out = Node{Kind: "bytes", Prefix: g.prefix(n.Prefix, anon)}
		if c != nil {
			out.MinLen, out.MaxLen = c.MinLength, c.MaxLength
		}
	case "bitset":
		out = Node{Kind: "bitset", Len: n.Length}
	case "array":
		element := g.node(*n.Element, packet, anon+"Item")
		out = Node{Kind: "list", Prefix: g.prefix(n.Prefix, anon), Element: &element}
		if element.Kind == "u8" && element.Min == nil && element.Max == nil && out.Prefix == "var_u32" {
			out = Node{Kind: "bytes", Prefix: "var_u32"}
			if c != nil {
				out.MinLen, out.MaxLen = c.MinItems, c.MaxItems
			}
		} else if c != nil {
			out.MinItems, out.MaxItems = c.MinItems, c.MaxItems
		}
	case "fixed_array":
		element := g.node(*n.Element, packet, anon+"Item")
		if c != nil && ((c.MinItems != nil && *c.MinItems != n.Length) || (c.MaxItems != nil && *c.MaxItems != n.Length)) {
			g.errs = append(g.errs, anon+": fixed array item bounds disagree with its length")
		}
		out = Node{Kind: "fixed", Len: n.Length, Element: &element}
	case "optional":
		value := g.node(*n.Value, packet, anon)
		out = Node{Kind: "optional", Value: &value}
	case "map":
		key := g.node(*n.Key, packet, anon+"Key")
		value := g.node(*n.Value, packet, anon+"Value")
		out = Node{Kind: "map", Prefix: g.prefix(n.Prefix, anon), Key: &key, Value: &value}
		if c != nil {
			out.MinItems, out.MaxItems = c.MinProperties, c.MaxProperties
		}
	case "struct":
		if decision, ok := g.rec.CustomTypes[normalizeTypeID(n.TypeID)]; ok && n.TypeID != "" {
			var got []string
			for _, f := range n.Fields {
				got = append(got, f.Name)
			}
			if strings.Join(got, ",") != strings.Join(decision.ExpectFields, ",") || decision.Reason == "" || len(decision.Evidence) == 0 {
				g.errs = append(g.errs, fmt.Sprintf("custom type decision for %s was written against fields %v, manifest has %v", n.TypeID, decision.ExpectFields, got))
			}
			g.reviewed["custom:"+normalizeTypeID(n.TypeID)] = true
			return Node{Kind: "custom", Ref: decision.Custom}
		}
		if len(n.Fields) == 1 {
			// A single-field wrapper has no framing of its own.
			return g.node(n.Fields[0].Encode, packet, anon)
		}
		name := g.typeName(n, anon)
		fields := g.fields(name, packet, n.Fields)
		out = Node{Kind: "ref", Ref: g.define(TypeDef{Name: name, Kind: "struct", Fields: fields}, n.TypeID).Name}
	case "enum":
		name := g.typeName(n, anon)
		repr := g.primitive(mNode{Primitive: n.Primitive})
		var values []Value
		for _, v := range n.Variants {
			if v.Encode.Kind != "void" || v.Decode != nil {
				g.errs = append(g.errs, name+": enum variant carries a payload")
			}
			values = append(values, Value{Name: snake(v.Name), Value: v.Value})
		}
		values = dedupeValues(values)
		name = g.define(TypeDef{Name: name, Kind: "enum", Repr: repr, Values: values}, n.TypeID).Name
		// Every site records its declared subset; restrictions() drops the
		// ones that match the merged enum once all occurrences are known.
		out = Node{Kind: "ref", Ref: name}
		for _, v := range values {
			out.Allowed = append(out.Allowed, v.Value)
		}
		sort.Slice(out.Allowed, func(i, j int) bool { return out.Allowed[i] < out.Allowed[j] })
	case "union":
		name := g.typeName(n, anon)
		if n.Control == nil || n.Control.Kind != "primitive" {
			g.errs = append(g.errs, name+": union without primitive control")
			return Node{Kind: "u8"}
		}
		t := TypeDef{Name: name, Kind: "union", Repr: g.primitive(*n.Control)}
		wires := make([]string, len(n.Variants))
		for i, v := range n.Variants {
			wires[i] = v.Name
		}
		names := variantNames(wires, packet)
		for i, v := range n.Variants {
			if reviewed := g.rec.VariantNames[name+"."+v.Name]; reviewed != "" {
				names[i] = reviewed
				g.reviewed["variant:"+name+"."+v.Name] = true
			}
		}
		for i, v := range n.Variants {
			if v.Decode != nil {
				g.errs = append(g.errs, name+": asymmetric union variant")
			}
			variant := Variant{Name: names[i], Wire: v.Name, Value: v.Value}
			if v.Encode.Kind != "void" {
				payload := g.node(v.Encode, packet, name+pascal(names[i]))
				variant.Type = &payload
			}
			t.Variants = append(t.Variants, variant)
		}
		out = Node{Kind: "ref", Ref: g.define(t, n.TypeID).Name}
	case "recursive":
		key := normalizeTypeID(n.Target)
		name := g.keys[key]
		if name == "" {
			if name = g.names[key]; name == "" {
				name = deriveTypeName(key)
			}
		}
		out = Node{Kind: "ref", Ref: name}
	default:
		g.errs = append(g.errs, fmt.Sprintf("%s: unsupported node kind %q", anon, n.Kind))
		return Node{Kind: "u8"}
	}
	return out
}

func dedupeValues(values []Value) []Value {
	var out []Value
	seen, numbers := map[string]bool{}, map[int64]bool{}
	for _, v := range values {
		if numbers[v.Value] {
			continue // later aliases of a value keep the first declared name
		}
		name := v.Name
		for i := 2; seen[name]; i++ {
			name = fmt.Sprintf("%s_%d", v.Name, i)
		}
		seen[name], numbers[v.Value] = true, true
		out = append(out, Value{Name: name, Value: v.Value})
	}
	return out
}

func (g *ingester) typeName(n mNode, anon string) string {
	if n.TypeID == "" {
		return anon
	}
	key := normalizeTypeID(n.TypeID)
	if name := g.keys[key]; name != "" {
		return name
	}
	name := g.names[key]
	if name == "" {
		name = deriveTypeName(key)
	}
	return name
}

// define registers a named type, merging wire-identical repeats. Constraint
// annotations may differ between occurrences; the merged type keeps only the
// bounds every occurrence publishes, so no site rejects values its own
// schema allows. Enum value sets are unioned.
func (g *ingester) define(t TypeDef, typeID string) *TypeDef {
	key := "anon:" + t.Name
	if typeID != "" {
		key = normalizeTypeID(typeID)
		t.Wire = []string{key}
	} else if t.Kind == "union" {
		// Identical anonymous shapes (the same inline union repeated per
		// field, or copied between packets) share one definition.
		shape, err := json.Marshal(TypeDef{Kind: t.Kind, Fields: t.Fields, Repr: t.Repr, Values: t.Values, Variants: t.Variants})
		must(err)
		if name, ok := g.shapes[string(shape)]; ok {
			return g.types[name]
		}
		if name := g.rec.TypeNames[key]; name != "" {
			t.Name = name
		}
		g.shapes[string(shape)] = t.Name
	}
	if claimed, ok := g.usedNames[t.Name]; ok && claimed != key {
		g.errs = append(g.errs, fmt.Sprintf("type name %s is claimed by %q and %q; add a type_names decision", t.Name, claimed, key))
		return g.types[t.Name]
	}
	g.usedNames[t.Name] = key
	g.keys[key] = t.Name
	existing := g.types[t.Name]
	if existing == nil {
		g.types[t.Name] = &t
		return &t
	}
	switch t.Kind {
	case "enum":
		if existing.Kind != "enum" || existing.Repr != t.Repr {
			g.errs = append(g.errs, t.Name+": enum occurrences disagree on representation")
			return existing
		}
		existing.Values = dedupeValues(append(existing.Values, t.Values...))
		sort.Slice(existing.Values, func(i, j int) bool { return existing.Values[i].Value < existing.Values[j].Value })
	case "struct":
		if !sameFields(existing.Fields, t.Fields) {
			g.errs = append(g.errs, t.Name+": struct occurrences differ on the wire")
			return existing
		}
		for i := range existing.Fields {
			intersect(&existing.Fields[i].Type, t.Fields[i].Type)
		}
	case "union":
		if existing.Kind != "union" || existing.Repr != t.Repr || len(existing.Variants) != len(t.Variants) {
			g.errs = append(g.errs, t.Name+": union occurrences differ on the wire")
			return existing
		}
		for i := range existing.Variants {
			a, b := existing.Variants[i], t.Variants[i]
			if a.Value != b.Value || a.Name != b.Name || (a.Type == nil) != (b.Type == nil) || (a.Type != nil && !sameShape(*a.Type, *b.Type)) {
				g.errs = append(g.errs, t.Name+": union occurrences differ on the wire")
				return existing
			}
			if a.Type != nil {
				intersect(existing.Variants[i].Type, *b.Type)
			}
		}
	}
	return existing
}

func sameFields(a, b []Field) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i].Name != b[i].Name || !sameShape(a[i].Type, b[i].Type) {
			return false
		}
	}
	return true
}

// sameShape compares wire layout, ignoring validation annotations.
func sameShape(a, b Node) bool {
	strip := func(n Node) Node {
		n.Min, n.Max, n.MinLen, n.MaxLen, n.MinItems, n.MaxItems, n.Pattern, n.Allowed = nil, nil, nil, nil, nil, nil, "", nil
		n.Element, n.Key, n.Value = nil, nil, nil
		return n
	}
	if !reflect.DeepEqual(strip(a), strip(b)) {
		return false
	}
	for _, pair := range [][2]*Node{{a.Element, b.Element}, {a.Key, b.Key}, {a.Value, b.Value}} {
		if (pair[0] == nil) != (pair[1] == nil) || (pair[0] != nil && !sameShape(*pair[0], *pair[1])) {
			return false
		}
	}
	return true
}

func intersect(a *Node, b Node) {
	a.Min = looser(a.Min, b.Min, true)
	a.Max = looser(a.Max, b.Max, false)
	a.MinLen = looserCount(a.MinLen, b.MinLen, true)
	a.MaxLen = looserCount(a.MaxLen, b.MaxLen, false)
	a.MinItems = looserCount(a.MinItems, b.MinItems, true)
	a.MaxItems = looserCount(a.MaxItems, b.MaxItems, false)
	if a.Pattern != b.Pattern {
		a.Pattern = ""
	}
	if !reflect.DeepEqual(a.Allowed, b.Allowed) {
		a.Allowed = mergeAllowed(a.Allowed, b.Allowed)
	}
	for _, pair := range [][2]*Node{{a.Element, b.Element}, {a.Key, b.Key}, {a.Value, b.Value}} {
		if pair[0] != nil && pair[1] != nil {
			intersect(pair[0], *pair[1])
		}
	}
}

func mergeAllowed(a, b []int64) []int64 {
	if len(a) == 0 || len(b) == 0 {
		return nil
	}
	set := map[int64]bool{}
	for _, v := range append(append([]int64(nil), a...), b...) {
		set[v] = true
	}
	var out []int64
	for v := range set {
		out = append(out, v)
	}
	sort.Slice(out, func(i, j int) bool { return out[i] < out[j] })
	return out
}

func looser(a, b *json.Number, minimum bool) *json.Number {
	if a == nil || b == nil {
		return nil
	}
	x, err1 := strconv.ParseFloat(a.String(), 64)
	y, err2 := strconv.ParseFloat(b.String(), 64)
	must(err1)
	must(err2)
	if (minimum && y < x) || (!minimum && y > x) {
		return b
	}
	return a
}

func looserCount(a, b *uint64, minimum bool) *uint64 {
	if a == nil || b == nil {
		return nil
	}
	if (minimum && *b < *a) || (!minimum && *b > *a) {
		return b
	}
	return a
}

// assignOwners places each type used by exactly one packet in that packet's
// file; shared types go to their reviewed domain file.
func (g *ingester) assignOwners(s *Schema) {
	users := map[string]map[string]bool{}
	var visit func(packet string, n Node, seen map[string]bool)
	visit = func(packet string, n Node, seen map[string]bool) {
		for _, child := range []*Node{n.Element, n.Key, n.Value} {
			if child != nil {
				visit(packet, *child, seen)
			}
		}
		if n.Kind != "ref" || seen[n.Ref] {
			return
		}
		seen[n.Ref] = true
		if users[n.Ref] == nil {
			users[n.Ref] = map[string]bool{}
		}
		users[n.Ref][packet] = true
		t := g.types[n.Ref]
		for _, f := range t.Fields {
			visit(packet, f.Type, seen)
		}
		for _, v := range t.Variants {
			if v.Type != nil {
				visit(packet, *v.Type, seen)
			}
		}
	}
	for _, p := range s.Packets {
		seen := map[string]bool{}
		for _, f := range p.Fields {
			visit(p.Name, f.Type, seen)
		}
	}
	for name, t := range g.types {
		if len(users[name]) == 1 {
			for packet := range users[name] {
				t.Owner = packet
			}
			continue
		}
		domain := ""
		for _, w := range t.Wire {
			if d := g.domains[w]; d != "" {
				domain = d
			}
		}
		if domain == "" {
			domain = "misc"
		}
		t.Domain = domain
	}
}

var versionNamespace = regexp.MustCompile(`^v\d+(_\d+)*$`)
var emptyVariant = regexp.MustCompile(`^Empty\d+$`)

// words splits an identifier or phrase into lower-case words.
func words(s string) []string {
	var out []string
	var cur []rune
	flush := func() {
		if len(cur) > 0 {
			out = append(out, strings.ToLower(string(cur)))
			cur = nil
		}
	}
	runes := []rune(s)
	for i, r := range runes {
		switch {
		case r == '\'':
		case !unicode.IsLetter(r) && !unicode.IsDigit(r):
			flush()
		case unicode.IsUpper(r) && len(cur) > 0 && (unicode.IsLower(cur[len(cur)-1]) || unicode.IsDigit(cur[len(cur)-1]) ||
			(i+1 < len(runes) && unicode.IsLower(runes[i+1]) && unicode.IsUpper(cur[len(cur)-1]))):
			flush()
			cur = append(cur, r)
		default:
			cur = append(cur, r)
		}
	}
	flush()
	return out
}

func snake(s string) string { return strings.Join(words(s), "_") }

func pascal(s string) string {
	var b strings.Builder
	for _, w := range words(s) {
		b.WriteString(strings.ToUpper(w[:1]) + w[1:])
	}
	return b.String()
}

func deriveTypeName(key string) string {
	key = strings.ReplaceAll(key, "struct ", "")
	if i := strings.IndexByte(key, '<'); i >= 0 {
		depth, end := 0, i
		for j := i; j < len(key); j++ {
			if key[j] == '<' {
				depth++
			} else if key[j] == '>' {
				if depth--; depth == 0 {
					end = j
					break
				}
			}
		}
		base, argument, rest := key[:i], key[i+1:end], key[end+1:]
		// cerealizer<T>::SerializedData is the wire form of T itself; other
		// template arguments are C++ tags without wire meaning.
		if strings.HasSuffix(base, "cerealizer") && rest == "::SerializedData" {
			return deriveTypeName(argument)
		}
		key = base + rest
	}
	var parts []string
	for _, part := range strings.Split(key, "::") {
		// Versioned and shared namespaces are C++ organisation, not identity.
		if part != "SharedTypes" && !versionNamespace.MatchString(part) {
			parts = append(parts, part)
		}
	}
	name := pascal(parts[len(parts)-1])
	if len(parts) > 1 {
		parent := pascal(parts[len(parts)-2])
		for _, suffix := range []string{"PacketPayload", "PacketData", "Packet", "Payload"} {
			if trimmed := strings.TrimSuffix(parent, suffix); trimmed != "" {
				parent = trimmed
			}
		}
		if !strings.HasPrefix(name, parent) {
			name = parent + name
		}
	}
	return name
}

// variantNames derives union variant names from the manifest's C++ names,
// dropping namespace qualifiers and words every variant shares.
func variantNames(wires []string, packet string) []string {
	scaffold := append(words(packet), "packet")
	split := make([][]string, len(wires))
	for i, w := range wires {
		parts := strings.Split(w, "::")
		split[i] = words(parts[len(parts)-1])
		// A variant named after its packet ("DisconnectPacketMessages") keeps
		// only the part that distinguishes it.
		if len(split[i]) > len(scaffold) && strings.Join(split[i][:len(scaffold)], "_") == strings.Join(scaffold, "_") {
			split[i] = split[i][len(scaffold):]
		}
		if emptyVariant.MatchString(w) {
			// protocolgen numbers void variants; the number is the tag, not a name.
			split[i] = []string{"empty"}
		}
		if len(split[i]) == 0 {
			split[i] = []string{"variant"}
		}
	}
	trimmed := func(prefix, suffix int) ([]string, bool) {
		out := make([]string, len(split))
		seen := map[string]bool{}
		for i, w := range split {
			if len(w) == 1 && w[0] == "empty" {
				out[i] = "empty"
				if seen["empty"] {
					return nil, false
				}
				seen["empty"] = true
				continue
			}
			if prefix+suffix >= len(w) {
				return nil, false
			}
			out[i] = strings.Join(w[prefix:len(w)-suffix], "_")
			if seen[out[i]] {
				return nil, false
			}
			seen[out[i]] = true
		}
		return out, true
	}
	shared := func(fromEnd bool, skip int) int {
		n := 0
		for {
			var word string
			first := true
			for _, w := range split {
				if len(w) == 1 && w[0] == "empty" {
					continue // a void variant does not share its siblings' words
				}
				idx := n
				if fromEnd {
					idx = len(w) - 1 - n
				}
				if idx < 0 || idx >= len(w) || (fromEnd && idx < skip) {
					return n
				}
				if first {
					word, first = w[idx], false
				} else if w[idx] != word {
					return n
				}
			}
			if first {
				return n
			}
			n++
		}
	}
	prefix, suffix := 0, 0
	if len(wires) > 1 {
		prefix = shared(false, 0)
		suffix = shared(true, prefix)
	}
	for ; prefix >= 0; prefix-- {
		for s := suffix; s >= 0; s-- {
			if out, ok := trimmed(prefix, s); ok {
				return fixDigits(out)
			}
		}
	}
	out, _ := trimmed(0, 0)
	if out == nil {
		out = make([]string, len(wires))
		for i := range wires {
			out[i] = fmt.Sprintf("variant%d", i)
		}
	}
	return fixDigits(out)
}

func fixDigits(names []string) []string {
	for i, n := range names {
		if n[0] >= '0' && n[0] <= '9' {
			names[i] = "v" + n
		}
	}
	return names
}

// restrictions keeps an enum site's declared subset only when it is narrower
// than the merged enum. Such subsets tie an enum to a union discriminant, so
// each one must be reviewed before it is enforced.
func (g *ingester) restrictions(s *Schema) {
	var visit func(site string, n *Node)
	visit = func(site string, n *Node) {
		for _, child := range []*Node{n.Element, n.Key, n.Value} {
			if child != nil {
				visit(site, child)
			}
		}
		t := g.types[n.Ref]
		if n.Kind != "ref" || t == nil || t.Kind != "enum" {
			return
		}
		declared := n.Allowed
		narrower := len(declared) != 0 && len(declared) < len(t.Values)
		n.Allowed = nil
		decision, ok := g.rec.EnumRestrictions[site]
		if !ok {
			if narrower {
				g.errs = append(g.errs, fmt.Sprintf("%s restricts %s to %v; review it in enum_restrictions", site, t.Name, declared))
			}
			return
		}
		g.restrict[site] = true
		values := decision.Values
		if values == nil {
			values = declared
		} else if narrower && fmt.Sprint(values) != fmt.Sprint(declared) {
			g.errs = append(g.errs, fmt.Sprintf("%s: reviewed values %v disagree with the manifest subset %v", site, values, declared))
		}
		if decision.Reason == "" || (!narrower && (len(decision.Evidence) == 0 || decision.Values == nil)) {
			g.errs = append(g.errs, site+": enum restriction needs a reason, and values with evidence where the manifest has none")
		}
		for _, v := range values {
			found := false
			for _, declared := range t.Values {
				found = found || declared.Value == v
			}
			if !found {
				g.errs = append(g.errs, fmt.Sprintf("%s: value %d is not declared by %s", site, v, t.Name))
			}
		}
		if decision.Enforce {
			n.Allowed = values
		}
	}
	g.eachSite(s, visit)
}

// eachSite visits every field and union payload node with its "Owner.name" site.
func (g *ingester) eachSite(s *Schema, visit func(site string, n *Node)) {
	for i := range s.Packets {
		for j := range s.Packets[i].Fields {
			visit(s.Packets[i].Name+"."+s.Packets[i].Fields[j].Name, &s.Packets[i].Fields[j].Type)
		}
	}
	names := make([]string, 0, len(g.types))
	for name := range g.types {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		t := g.types[name]
		for j := range t.Fields {
			visit(name+"."+t.Fields[j].Name, &t.Fields[j].Type)
		}
		for j := range t.Variants {
			if t.Variants[j].Type != nil {
				visit(name+"."+t.Variants[j].Name, t.Variants[j].Type)
			}
		}
	}
}

func (g *ingester) applyConstraints(s *Schema) {
	targets := map[string]*Node{}
	g.eachSite(s, func(site string, n *Node) { targets[site] = n })
	for path, c := range g.rec.Constraints {
		steps := strings.Split(path, "/")
		n := targets[steps[0]]
		for _, step := range steps[1:] {
			switch {
			case n == nil:
			case step == "value" && n.Kind == "optional":
				n = n.Value
			case step == "element" && (n.Kind == "list" || n.Kind == "fixed"):
				n = n.Element
			default:
				n = nil
			}
		}
		if n != nil && c.DropBounds && c.Reason != "" && len(c.Evidence) != 0 {
			if n.Min == nil && n.Max == nil {
				g.errs = append(g.errs, "constraint decision "+path+" drops bounds the manifest no longer publishes")
			}
			n.Min, n.Max = nil, nil
			continue
		}
		if n == nil || (n.Kind != "list" && n.Kind != "map") || c.Reason == "" || len(c.Evidence) == 0 {
			g.errs = append(g.errs, "constraint decision "+path+" does not name a list or lacks evidence")
			continue
		}
		if c.MinItems != nil {
			n.MinItems = c.MinItems
		}
		if c.MaxItems != nil {
			n.MaxItems = c.MaxItems
		}
	}
}

func (g *ingester) applyChecks() {
	for owner, checks := range g.rec.Checks {
		t := g.types[owner]
		if t == nil || t.Kind != "struct" {
			g.errs = append(g.errs, "check decision names unknown struct "+owner)
			continue
		}
		for _, c := range checks {
			if c.Reason == "" || len(c.Evidence) == 0 {
				g.errs = append(g.errs, "check decision for "+owner+" lacks evidence")
			}
			t.Checks = append(t.Checks, c.Check)
		}
	}
}

func (g *ingester) checkDisagreements(s *Schema) {
	for _, d := range g.rec.Disagreements {
		owner, field, _ := strings.Cut(d.Target, ".")
		found := false
		for _, p := range s.Packets {
			for _, f := range p.Fields {
				found = found || (p.Name == owner && f.Name == field)
			}
		}
		if t := g.types[owner]; t != nil {
			for _, f := range t.Fields {
				found = found || f.Name == field
			}
		}
		if !found || d.Decision == "" || len(d.Evidence) == 0 {
			g.errs = append(g.errs, "disagreement record "+d.Target+" is stale or incomplete")
		}
	}
}
