package main

import (
	"fmt"
	"strings"
)

func coverage(s Schema) (string, error) {
	var b strings.Builder
	counts := map[string]int{}
	var opaque []string
	var problems []string
	ids := map[uint16]bool{}
	var maxID uint16
	for _, p := range s.Packets {
		ids[p.ID] = true
		maxID = max(maxID, p.ID)
		switch strings.Join(p.Directions, ",") {
		case "client":
			counts["client"]++
		case "server":
			counts["server"]++
		default:
			counts["bidirectional"]++
		}
		// A packet whose whole body is one unnamed byte blob would be a
		// catalog entry, not a codec.
		if len(p.Fields) == 1 && p.Fields[0].Type.Kind == "bytes" && (p.Fields[0].Name == "payload" || p.Fields[0].Wire == "") {
			problems = append(problems, fmt.Sprintf("%d %s is an opaque payload", p.ID, p.Name))
		}
		for _, f := range p.Fields {
			if f.Type.Kind == "bytes" {
				opaque = append(opaque, p.Name+"."+f.Name)
			}
		}
	}
	for _, t := range s.Types {
		for _, f := range t.Fields {
			if f.Type.Kind == "bytes" {
				opaque = append(opaque, t.Name+"."+f.Name)
			}
		}
	}
	var gaps []string
	for id := uint16(1); id <= maxID; id++ {
		if !ids[id] {
			gaps = append(gaps, fmt.Sprint(id))
		}
	}
	fmt.Fprintf(&b, "target: Minecraft %s, protocol %d\n", s.Target.MinecraftVersion, s.Target.ProtocolVersion)
	fmt.Fprintf(&b, "known packets: %d\n", len(s.Packets))
	fmt.Fprintf(&b, "semantic codecs: %d\n", len(s.Packets)-len(problems))
	fmt.Fprintf(&b, "known opaque: %d\n", len(problems))
	fmt.Fprintf(&b, "client-to-server: %d, server-to-client: %d, bidirectional: %d\n", counts["client"], counts["server"], counts["bidirectional"])
	fmt.Fprintf(&b, "types: %d\n", len(s.Types))
	fmt.Fprintf(&b, "unassigned IDs below %d: %s\n", maxID, strings.Join(gaps, " "))
	fmt.Fprintf(&b, "byte-buffer fields (opaque by protocol design): %d\n", len(opaque))
	for _, o := range opaque {
		fmt.Fprintf(&b, "  %s\n", o)
	}
	if len(problems) != 0 {
		return b.String(), fmt.Errorf("coverage failed:\n  %s", strings.Join(problems, "\n  "))
	}
	return b.String(), nil
}
