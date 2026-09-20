package main

import (
	"encoding/json"
 "bytes"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"unicode"
)

const (
	baseSchemaPath = "protocol/schema/bedrock-2193.json"
	overlayPath    = "protocol/schema/cloudburst-2193-overlay.json"
)

type manifest struct {
	Packets []packet `json:"packets"`
}

type overlay struct {
	Additions []packet `json:"additions"`
}

type packet struct {
	Name       string   `json:"name"`
	ID         uint16   `json:"id"`
	Directions []string `json:"directions"`
}

func snake(s string) string {
	var b strings.Builder
	for i, r := range s {
		if unicode.IsUpper(r) && i > 0 {
			b.WriteByte('_')
		}
		b.WriteRune(unicode.ToLower(r))
	}
	return strings.ReplaceAll(b.String(), "u_u_i_d", "uuid")
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}

func readJSON(path string, value any) {
	data, err := os.ReadFile(path)
	must(err)
	must(json.Unmarshal(data, value))
}

func loadPackets() []packet {
	var base manifest
	var changes overlay
	readJSON(baseSchemaPath, &base)
	readJSON(overlayPath, &changes)
	packets := append([]packet(nil), base.Packets...)
	for _, addition := range changes.Additions {
		alreadyMerged := false
		for _, existing := range packets {
			if existing.Name == addition.Name && existing.ID == addition.ID {
				if strings.Join(existing.Directions, ",") != strings.Join(addition.Directions, ",") {
					panic(fmt.Errorf("overlay direction conflict for packet %s", addition.Name))
				}
				alreadyMerged = true
				break
			}
		}
		if !alreadyMerged {
			packets = append(packets, addition)
		}
	}

	validName := regexp.MustCompile(`^[A-Za-z][A-Za-z0-9]*$`)
	ids := make(map[uint16]string, len(packets))
	names := make(map[string]uint16, len(packets))
	normalized := make(map[string]string, len(packets))
	for _, p := range packets {
		if p.ID > 1023 {
			panic(fmt.Errorf("packet %s has unsupported 10-bit ID %d", p.Name, p.ID))
		}
		if !validName.MatchString(p.Name) {
			panic(fmt.Errorf("packet name %q is not a Zig identifier", p.Name))
		}
		if previous, ok := ids[p.ID]; ok {
			panic(fmt.Errorf("duplicate packet ID %d: %s and %s", p.ID, previous, p.Name))
		}
		if previous, ok := names[p.Name]; ok {
			panic(fmt.Errorf("duplicate packet name %s at IDs %d and %d", p.Name, previous, p.ID))
		}
		n := snake(p.Name)
		if previous, ok := normalized[n]; ok {
			panic(fmt.Errorf("packet names %s and %s both normalize to %s", previous, p.Name, n))
		}
		if len(p.Directions) == 0 {
			panic(fmt.Errorf("packet %s has no directions", p.Name))
		}
		seenDirection := map[string]bool{}
		for _, direction := range p.Directions {
			if direction != "client" && direction != "server" {
				panic(fmt.Errorf("packet %s has invalid direction %q", p.Name, direction))
			}
			if seenDirection[direction] {
				panic(fmt.Errorf("packet %s repeats direction %q", p.Name, direction))
			}
			seenDirection[direction] = true
		}
		ids[p.ID], names[p.Name], normalized[n] = p.Name, p.ID, p.Name
	}
	sort.Slice(packets, func(i, j int) bool { return packets[i].ID < packets[j].ID })
	return packets
}

func writeAtomic(path, contents string) {
 if len(os.Args) == 2 && os.Args[1] == "--check" {
  actual, err := os.ReadFile(path); must(err)
  if !bytes.Equal(bytes.ReplaceAll(actual, []byte("\r\n"), []byte("\n")), []byte(contents)) { panic("generated output differs: " + path) }
  return
 }

	must(os.MkdirAll(filepath.Dir(path), 0755))
	temporary := path + ".tmp"
	must(os.WriteFile(temporary, []byte(contents), 0644))
	must(os.Rename(temporary, path))
}

func main() {
	packets := loadPackets()

	var semantic strings.Builder
 semantic.WriteString("// Generated current protocol registry. Semantic ordinals are not wire IDs.\npub const PacketKind = enum {\n")
 for _, p := range packets { fmt.Fprintf(&semantic, "    %s,\n", snake(p.Name)) }
 semantic.WriteString("};\npub fn packetKind(id: u10) ?PacketKind {\n    return switch (id) {\n")
 for _, p := range packets { fmt.Fprintf(&semantic, "        %d => .%s,\n", p.ID, snake(p.Name)) }
 semantic.WriteString("        else => null,\n    };\n}\npub fn packetId(kind: PacketKind) ?u10 {\n    return switch (kind) {\n")
 for _, p := range packets { fmt.Fprintf(&semantic, "        .%s => %d,\n", snake(p.Name), p.ID) }
 semantic.WriteString("    };\n}\npub const Direction = enum { client, server, both };\npub fn direction(kind: PacketKind) Direction {\n    return switch (kind) {\n")
 for _, p := range packets { d := "both"; if len(p.Directions)==1 { d=p.Directions[0] }; fmt.Fprintf(&semantic, "        .%s => .%s,\n", snake(p.Name), d) }
 semantic.WriteString("    };\n}\n")
 writeAtomic("src/registry/generated_registry.zig", semantic.String())
 var catalog strings.Builder
	catalog.WriteString("// Generated packet model catalog from the protocol 2193 base schema and overlay.\n")
	var registry strings.Builder
	registry.WriteString("// Generated from the protocol 2193 base schema and overlay.\n")
	registry.WriteString("pub const PacketId = enum(u10) {\n")

	for _, p := range packets {
		n := snake(p.Name)
		catalog.WriteString(fmt.Sprintf("pub const %s = @import(\"generated/%s.zig\").Packet;\n", n, n))
		registry.WriteString(fmt.Sprintf("    %s = %d,\n", n, p.ID))

		module := fmt.Sprintf("// Generated catalog entry for protocol 2193. Wire data is borrowed until a semantic codec is registered.\npub const id: u10 = %d;\npub const directions = %q;\npub const Packet = struct { payload: []const u8 };\n", p.ID, strings.Join(p.Directions, ","))
		writeAtomic(filepath.Join("src", "packets", "generated", n+".zig"), module)
	}
	registry.WriteString("    _,\n};\n")

	writeAtomic("src/packets/generated.zig", catalog.String())
	writeAtomic("src/registry/generated_packet_id.zig", registry.String())
}
