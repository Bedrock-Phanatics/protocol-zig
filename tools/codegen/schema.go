package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"
)

// Schema is the canonical, version-locked wire description the Zig emitter
// consumes. It is produced only by ingest and is reviewed as a checked-in file.
type Schema struct {
	SchemaVersion int       `json:"schema_version"`
	Target        Target    `json:"target"`
	Sources       []Source  `json:"sources"`
	Packets       []Packet  `json:"packets"`
	Types         []TypeDef `json:"types"`
}

type Target struct {
	MinecraftVersion string `json:"minecraft_version"`
	ProtocolVersion  int    `json:"protocol_version"`
}

type Source struct {
	ID         string `json:"id"`
	Repository string `json:"repository"`
	Revision   string `json:"revision"`
	Path       string `json:"path,omitempty"`
	SHA256     string `json:"sha256,omitempty"`
}

type Packet struct {
	ID         uint16   `json:"id"`
	Name       string   `json:"name"`
	Wire       string   `json:"wire"`
	Directions []string `json:"directions"`
	Fields     []Field  `json:"fields"`
}

type Field struct {
	Name string `json:"name"`
	Wire string `json:"wire"`
	Type Node   `json:"type"`
}

type TypeDef struct {
	Name     string    `json:"name"`
	Kind     string    `json:"kind"` // struct, enum, union
	Owner    string    `json:"owner,omitempty"`
	Domain   string    `json:"domain,omitempty"`
	Wire     []string  `json:"wire,omitempty"`
	Fields   []Field   `json:"fields,omitempty"`
	Repr     string    `json:"repr,omitempty"`
	Values   []Value   `json:"values,omitempty"`
	Variants []Variant `json:"variants,omitempty"`
	Checks   []Check   `json:"checks,omitempty"`
}

// Check is a reviewed cross-field invariant. "length_product" requires the
// length of Field to equal the product of the integer Factors times Scale.
type Check struct {
	Kind    string   `json:"kind"`
	Field   string   `json:"field"`
	Factors []string `json:"factors"`
	Scale   uint64   `json:"scale,omitempty"`
}

type Value struct {
	Name  string `json:"name"`
	Value int64  `json:"value"`
}

type Variant struct {
	Name  string `json:"name"`
	Wire  string `json:"wire"`
	Value int64  `json:"value"`
	Type  *Node  `json:"type,omitempty"`
}

// Node is a wire shape. Primitive kinds are the primitive codes themselves.
type Node struct {
	Kind     string       `json:"kind"`
	Prefix   string       `json:"prefix,omitempty"`
	Element  *Node        `json:"element,omitempty"`
	Key      *Node        `json:"key,omitempty"`
	Value    *Node        `json:"value,omitempty"`
	Len      uint64       `json:"len,omitempty"`
	Ref      string       `json:"ref,omitempty"`
	Allowed  []int64      `json:"allowed,omitempty"`
	Min      *json.Number `json:"min,omitempty"`
	Max      *json.Number `json:"max,omitempty"`
	MinLen   *uint64      `json:"min_len,omitempty"`
	MaxLen   *uint64      `json:"max_len,omitempty"`
	MinItems *uint64      `json:"min_items,omitempty"`
	MaxItems *uint64      `json:"max_items,omitempty"`
	Pattern  string       `json:"pattern,omitempty"`
}

type primitiveInfo struct {
	zig   string // Zig value type
	read  string // Reader method
	write string // Writer method
}

var primitives = map[string]primitiveInfo{
	"bool":       {"bool", "readBool", "writeBool"},
	"u8":         {"u8", "readU8", "writeU8"},
	"i8":         {"i8", "readI8", "writeI8"},
	"u16le":      {"u16", "readU16", "writeU16"},
	"i16le":      {"i16", "readI16", "writeI16"},
	"u32le":      {"u32", "readU32", "writeU32"},
	"i32le":      {"i32", "readI32", "writeI32"},
	"u64le":      {"u64", "readU64", "writeU64"},
	"i64le":      {"i64", "readI64", "writeI64"},
	"u16be":      {"u16", "readU16Be", "writeU16Be"},
	"i16be":      {"i16", "readI16Be", "writeI16Be"},
	"u32be":      {"u32", "readU32Be", "writeU32Be"},
	"i32be":      {"i32", "readI32Be", "writeI32Be"},
	"u64be":      {"u64", "readU64Be", "writeU64Be"},
	"i64be":      {"i64", "readI64Be", "writeI64Be"},
	"f32le":      {"f32", "readF32", "writeF32"},
	"f64le":      {"f64", "readF64", "writeF64"},
	"var_u32":    {"u32", "readVarU32", "writeVarU32"},
	"var_u64":    {"u64", "readVarU64", "writeVarU64"},
	"zigzag_i32": {"i32", "readVarI32", "writeVarI32"},
	"zigzag_i64": {"i64", "readVarI64", "writeVarI64"},
	"uuid":       {"[16]u8", "readUuid", "writeUuid"},
	"nbt":        {"[]const u8", "readNbt", "writeNbt"},
}

// customTypes are hand-written codecs in src/custom for shapes the schema
// vocabulary cannot express. Each is introduced by a reviewed decision.
var customTypes = map[string]bool{"RecipeIngredient": true}

// countPrefixes are the element-count encodings the runtime reads
// (codec.CountPrefix). Strings and byte arrays always use var_u32.
var countPrefixes = map[string]bool{"var_u32": true, "u32le": true}

func isPrimitive(kind string) bool { _, ok := primitives[kind]; return ok }

func loadSchema(path string) Schema {
	data, err := os.ReadFile(path)
	must(err)
	var s Schema
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	decoder.UseNumber()
	must(decoder.Decode(&s))
	must(s.validate())
	return s
}

func (s Schema) encode() string {
	var buffer bytes.Buffer
	encoder := json.NewEncoder(&buffer)
	encoder.SetEscapeHTML(false)
	encoder.SetIndent("", "  ")
	must(encoder.Encode(s))
	return buffer.String()
}

func (s Schema) typeMap() map[string]*TypeDef {
	types := make(map[string]*TypeDef, len(s.Types))
	for i := range s.Types {
		types[s.Types[i].Name] = &s.Types[i]
	}
	return types
}

// validate rejects every construct the emitter cannot represent exactly, so
// a schema that passes validation always generates complete codecs.
func (s Schema) validate() error {
	if s.SchemaVersion != 1 {
		return fmt.Errorf("unsupported schema version %d", s.SchemaVersion)
	}
	types := map[string]*TypeDef{}
	for i := range s.Types {
		t := &s.Types[i]
		if !isPascal(t.Name) {
			return fmt.Errorf("type name %q is not PascalCase", t.Name)
		}
		if types[t.Name] != nil {
			return fmt.Errorf("duplicate type %s", t.Name)
		}
		types[t.Name] = t
	}
	if !sort.SliceIsSorted(s.Types, func(i, j int) bool { return s.Types[i].Name < s.Types[j].Name }) {
		return fmt.Errorf("types are not sorted")
	}
	ids, names := map[uint16]bool{}, map[string]bool{}
	for i, p := range s.Packets {
		if i > 0 && s.Packets[i-1].ID >= p.ID {
			return fmt.Errorf("packets are not sorted by ID at %s", p.Name)
		}
		if p.ID == 0 || p.ID > 1023 {
			return fmt.Errorf("packet %s has invalid 10-bit ID %d", p.Name, p.ID)
		}
		if ids[p.ID] || names[p.Name] {
			return fmt.Errorf("duplicate packet %s (%d)", p.Name, p.ID)
		}
		ids[p.ID], names[p.Name] = true, true
		if !isPascal(p.Name) {
			return fmt.Errorf("packet name %q is not PascalCase", p.Name)
		}
		if len(p.Directions) == 0 || len(p.Directions) > 2 || !sort.StringsAreSorted(p.Directions) {
			return fmt.Errorf("packet %s has invalid directions %v", p.Name, p.Directions)
		}
		for j, d := range p.Directions {
			if (d != "client" && d != "server") || (j > 0 && p.Directions[j-1] == d) {
				return fmt.Errorf("packet %s has invalid direction %q", p.Name, d)
			}
		}
		if err := validateFields(p.Name, p.Fields, types); err != nil {
			return err
		}
	}
	for _, t := range s.Types {
		if t.Owner != "" && !names[t.Owner] {
			return fmt.Errorf("type %s has unknown owner %s", t.Name, t.Owner)
		}
		switch t.Kind {
		case "struct":
			if err := validateFields(t.Name, t.Fields, types); err != nil {
				return err
			}
			if err := validateChecks(t); err != nil {
				return err
			}
		case "enum":
			if !isInteger(t.Repr) || len(t.Values) == 0 {
				return fmt.Errorf("enum %s has invalid representation", t.Name)
			}
			if err := validateValues(t.Name, t.Values, t.Repr); err != nil {
				return err
			}
		case "union":
			if !isInteger(t.Repr) || len(t.Variants) == 0 {
				return fmt.Errorf("union %s has invalid tag", t.Name)
			}
			seen := map[string]bool{}
			values := map[int64]bool{}
			for _, v := range t.Variants {
				if !isSnake(v.Name) || seen[v.Name] || values[v.Value] {
					return fmt.Errorf("union %s has invalid or duplicate variant %q", t.Name, v.Name)
				}
				if !fits(v.Value, t.Repr) {
					return fmt.Errorf("union %s variant %s does not fit %s", t.Name, v.Name, t.Repr)
				}
				seen[v.Name], values[v.Value] = true, true
				if v.Type != nil {
					if err := validateNode(t.Name+"."+v.Name, *v.Type, types); err != nil {
						return err
					}
				}
			}
		default:
			return fmt.Errorf("type %s has invalid kind %q", t.Name, t.Kind)
		}
	}
	return nil
}

func validateChecks(t TypeDef) error {
	kinds := map[string]string{}
	for _, f := range t.Fields {
		kinds[f.Name] = f.Type.Kind
	}
	for _, c := range t.Checks {
		if c.Kind != "length_product" || len(c.Factors) == 0 {
			return fmt.Errorf("%s has unsupported check %q", t.Name, c.Kind)
		}
		if k := kinds[c.Field]; k != "list" && k != "bytes" && k != "string" {
			return fmt.Errorf("%s check field %q is not a sequence", t.Name, c.Field)
		}
		for _, factor := range c.Factors {
			if !isInteger(kinds[factor]) {
				return fmt.Errorf("%s check factor %q is not an integer field", t.Name, factor)
			}
		}
	}
	return nil
}

func validateValues(owner string, values []Value, repr string) error {
	seen := map[string]bool{}
	numbers := map[int64]bool{}
	for _, v := range values {
		if !isSnake(v.Name) || seen[v.Name] || numbers[v.Value] || !fits(v.Value, repr) {
			return fmt.Errorf("enum %s has invalid value %s=%d", owner, v.Name, v.Value)
		}
		seen[v.Name], numbers[v.Value] = true, true
	}
	return nil
}

func validateFields(owner string, fields []Field, types map[string]*TypeDef) error {
	seen := map[string]bool{}
	for _, f := range fields {
		if !isSnake(f.Name) || seen[f.Name] {
			return fmt.Errorf("%s has invalid or duplicate field %q", owner, f.Name)
		}
		seen[f.Name] = true
		if err := validateNode(owner+"."+f.Name, f.Type, types); err != nil {
			return err
		}
	}
	return nil
}

func validateNode(path string, n Node, types map[string]*TypeDef) error {
	fail := func(format string, args ...any) error {
		return fmt.Errorf("%s: %s", path, fmt.Sprintf(format, args...))
	}
	if n.Min != nil || n.Max != nil {
		if !isInteger(n.Kind) && n.Kind != "f32le" && n.Kind != "f64le" {
			return fail("numeric bounds on %s", n.Kind)
		}
	}
	if (n.MinLen != nil || n.MaxLen != nil) && n.Kind != "string" && n.Kind != "bytes" {
		return fail("length bounds on %s", n.Kind)
	}
	if (n.MinItems != nil || n.MaxItems != nil) && n.Kind != "list" && n.Kind != "map" {
		return fail("item bounds on %s", n.Kind)
	}
	if n.Pattern != "" {
		if n.Kind != "string" {
			return fail("pattern on %s", n.Kind)
		}
		if _, ok := patternMatchers[n.Pattern]; !ok {
			return fail("unsupported pattern %q", n.Pattern)
		}
	}
	if len(n.Allowed) != 0 && n.Kind != "ref" {
		return fail("allowed values on %s", n.Kind)
	}
	switch n.Kind {
	case "string", "bytes":
		if n.Prefix != "var_u32" {
			return fail("invalid length prefix %q", n.Prefix)
		}
	case "bitset":
		if n.Len == 0 || n.Len > 256 {
			return fail("invalid bitset length %d", n.Len)
		}
	case "list":
		if !countPrefixes[n.Prefix] || n.Element == nil {
			return fail("invalid list")
		}
		return validateNode(path+"[]", *n.Element, types)
	case "map":
		if !countPrefixes[n.Prefix] || n.Key == nil || n.Value == nil {
			return fail("invalid map")
		}
		if err := validateNode(path+".key", *n.Key, types); err != nil {
			return err
		}
		return validateNode(path+".value", *n.Value, types)
	case "fixed":
		if n.Len == 0 || n.Len > 4096 || n.Element == nil {
			return fail("invalid fixed array")
		}
		return validateNode(path+"[]", *n.Element, types)
	case "optional":
		if n.Value == nil {
			return fail("optional has no value")
		}
		return validateNode(path+"?", *n.Value, types)
	case "custom":
		if !customTypes[n.Ref] {
			return fail("unknown custom type %q", n.Ref)
		}
	case "ref":
		t := types[n.Ref]
		if t == nil {
			return fail("unknown type %q", n.Ref)
		}
		for _, value := range n.Allowed {
			if t.Kind != "enum" {
				return fail("allowed values on non-enum %s", n.Ref)
			}
			found := false
			for _, v := range t.Values {
				found = found || v.Value == value
			}
			if !found {
				return fail("allowed value %d is not declared by %s", value, n.Ref)
			}
		}
	default:
		if !isPrimitive(n.Kind) {
			return fail("unknown kind %q", n.Kind)
		}
		if n.Prefix != "" || n.Element != nil || n.Key != nil || n.Value != nil || n.Ref != "" {
			return fail("primitive %s has structural attributes", n.Kind)
		}
	}
	return nil
}

func isInteger(kind string) bool {
	switch kind {
	case "u8", "i8", "u16le", "i16le", "u32le", "i32le", "u64le", "i64le", "u16be", "i16be", "u32be", "i32be", "u64be", "i64be",
		"var_u32", "var_u64", "zigzag_i32", "zigzag_i64":
		return true
	}
	return false
}

func fits(value int64, kind string) bool {
	info := primitives[kind]
	signed := strings.HasPrefix(info.zig, "i")
	bits := map[string]uint{"u8": 8, "i8": 8, "u16": 16, "i16": 16, "u32": 32, "i32": 32, "u64": 64, "i64": 64}[info.zig]
	if bits == 0 {
		return false
	}
	if signed {
		return bits == 64 || (value >= -(int64(1)<<(bits-1)) && value < int64(1)<<(bits-1))
	}
	return value >= 0 && (bits == 64 || value < int64(1)<<bits)
}

func isPascal(s string) bool {
	if s == "" || s[0] < 'A' || s[0] > 'Z' {
		return false
	}
	for _, r := range s {
		if !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9') {
			return false
		}
	}
	return true
}

func isSnake(s string) bool {
	if s == "" || s[0] < 'a' || s[0] > 'z' || strings.HasSuffix(s, "_") || strings.Contains(s, "__") {
		return false
	}
	for _, r := range s {
		if !(r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '_') {
			return false
		}
	}
	return true
}
