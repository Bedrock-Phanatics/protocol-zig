package main

import (
	"fmt"
	"sort"
	"strings"
)

// describe renders a node compactly, including constraints, so any wire or
// validation change shows up as a text difference.
func describe(n Node) string {
	var b strings.Builder
	switch n.Kind {
	case "list", "map", "string", "bytes":
		b.WriteString(n.Kind + "<" + n.Prefix + ">")
	case "fixed":
		fmt.Fprintf(&b, "fixed[%d]", n.Len)
	case "bitset":
		fmt.Fprintf(&b, "bitset[%d]", n.Len)
	case "ref", "custom":
		b.WriteString(n.Kind + " " + n.Ref)
	default:
		b.WriteString(n.Kind)
	}
	var bounds []string
	add := func(name string, v any) { bounds = append(bounds, fmt.Sprintf("%s=%v", name, v)) }
	if n.Min != nil {
		add("min", n.Min.String())
	}
	if n.Max != nil {
		add("max", n.Max.String())
	}
	for name, v := range map[string]*uint64{"min_len": n.MinLen, "max_len": n.MaxLen, "min_items": n.MinItems, "max_items": n.MaxItems} {
		if v != nil {
			add(name, *v)
		}
	}
	if n.Pattern != "" {
		add("pattern", n.Pattern)
	}
	if len(n.Allowed) != 0 {
		add("allowed", n.Allowed)
	}
	sort.Strings(bounds)
	if len(bounds) != 0 {
		b.WriteString("{" + strings.Join(bounds, ",") + "}")
	}
	switch n.Kind {
	case "list", "fixed":
		b.WriteString("(" + describe(*n.Element) + ")")
	case "optional":
		b.WriteString("(" + describe(*n.Value) + ")")
	case "map":
		b.WriteString("(" + describe(*n.Key) + " => " + describe(*n.Value) + ")")
	}
	return b.String()
}

type diffWriter struct{ b strings.Builder }

func (d *diffWriter) section(title string, lines []string) {
	if len(lines) == 0 {
		return
	}
	fmt.Fprintf(&d.b, "\n## %s\n\n", title)
	for _, l := range lines {
		d.b.WriteString("- " + l + "\n")
	}
}

func diffFields(owner string, a, b []Field) []string {
	var out []string
	index := func(fields []Field) map[string]int {
		m := map[string]int{}
		for i, f := range fields {
			m[f.Name] = i
		}
		return m
	}
	ai, bi := index(a), index(b)
	var common []string
	for _, f := range a {
		if j, ok := bi[f.Name]; !ok {
			out = append(out, fmt.Sprintf("%s: removed field `%s` %s", owner, f.Name, describe(f.Type)))
		} else {
			common = append(common, f.Name)
			if x, y := describe(f.Type), describe(b[j].Type); x != y {
				out = append(out, fmt.Sprintf("%s.%s: type %s -> %s", owner, f.Name, x, y))
			}
		}
	}
	for _, f := range b {
		if _, ok := ai[f.Name]; !ok {
			out = append(out, fmt.Sprintf("%s: added field `%s` %s at position %d", owner, f.Name, describe(f.Type), bi[f.Name]))
		}
	}
	var order []string
	for _, f := range b {
		if _, ok := ai[f.Name]; ok {
			order = append(order, f.Name)
		}
	}
	if strings.Join(common, ",") != strings.Join(order, ",") {
		out = append(out, fmt.Sprintf("%s: field order %s -> %s", owner, strings.Join(common, ","), strings.Join(order, ",")))
	}
	return out
}

func diffSchemas(a, b Schema) string {
	d := &diffWriter{}
	fmt.Fprintf(&d.b, "# Protocol schema changes: %s (%d) -> %s (%d)\n", a.Target.MinecraftVersion, a.Target.ProtocolVersion, b.Target.MinecraftVersion, b.Target.ProtocolVersion)

	byName := func(s Schema) map[string]Packet {
		m := map[string]Packet{}
		for _, p := range s.Packets {
			m[p.Name] = p
		}
		return m
	}
	pa, pb := byName(a), byName(b)
	var added, removed, ids, directions, fields []string
	for _, p := range a.Packets {
		q, ok := pb[p.Name]
		if !ok {
			removed = append(removed, fmt.Sprintf("%d %s", p.ID, p.Name))
			continue
		}
		if p.ID != q.ID {
			ids = append(ids, fmt.Sprintf("%s: %d -> %d", p.Name, p.ID, q.ID))
		}
		if strings.Join(p.Directions, ",") != strings.Join(q.Directions, ",") {
			directions = append(directions, fmt.Sprintf("%s: %v -> %v", p.Name, p.Directions, q.Directions))
		}
		fields = append(fields, diffFields(p.Name, p.Fields, q.Fields)...)
	}
	for _, p := range b.Packets {
		if _, ok := pa[p.Name]; !ok {
			added = append(added, fmt.Sprintf("%d %s (%s)", p.ID, p.Name, strings.Join(p.Directions, ",")))
		}
	}
	d.section("Packets added", added)
	d.section("Packets removed", removed)
	d.section("Packet IDs changed", ids)
	d.section("Packet directions changed", directions)
	d.section("Packet fields changed", fields)

	ta, tb := a.typeMap(), b.typeMap()
	var typesAdded, typesRemoved, typeChanges []string
	for _, t := range a.Types {
		u, ok := tb[t.Name]
		if !ok {
			typesRemoved = append(typesRemoved, t.Kind+" "+t.Name)
			continue
		}
		if t.Kind != u.Kind || t.Repr != u.Repr {
			typeChanges = append(typeChanges, fmt.Sprintf("%s: %s %s -> %s %s", t.Name, t.Kind, t.Repr, u.Kind, u.Repr))
			continue
		}
		typeChanges = append(typeChanges, diffFields(t.Name, t.Fields, u.Fields)...)
		typeChanges = append(typeChanges, diffValues(t.Name, t.Values, u.Values)...)
		typeChanges = append(typeChanges, diffVariants(t.Name, t.Variants, u.Variants)...)
		if fmt.Sprint(t.Checks) != fmt.Sprint(u.Checks) {
			typeChanges = append(typeChanges, fmt.Sprintf("%s: checks %v -> %v", t.Name, t.Checks, u.Checks))
		}
	}
	for _, t := range b.Types {
		if _, ok := ta[t.Name]; !ok {
			typesAdded = append(typesAdded, t.Kind+" "+t.Name)
		}
	}
	d.section("Types added", typesAdded)
	d.section("Types removed", typesRemoved)
	d.section("Type changes", typeChanges)
	if !strings.Contains(d.b.String(), "\n## ") {
		d.b.WriteString("\nNo wire or validation changes.\n")
	}
	return d.b.String()
}

func diffValues(owner string, a, b []Value) []string {
	var out []string
	am, bm := map[int64]string{}, map[int64]string{}
	for _, v := range a {
		am[v.Value] = v.Name
	}
	for _, v := range b {
		bm[v.Value] = v.Name
	}
	for _, v := range a {
		if name, ok := bm[v.Value]; !ok {
			out = append(out, fmt.Sprintf("%s: removed enum value %s=%d", owner, v.Name, v.Value))
		} else if name != v.Name {
			out = append(out, fmt.Sprintf("%s: enum value %d renamed %s -> %s", owner, v.Value, v.Name, name))
		}
	}
	for _, v := range b {
		if _, ok := am[v.Value]; !ok {
			out = append(out, fmt.Sprintf("%s: added enum value %s=%d", owner, v.Name, v.Value))
		}
	}
	return out
}

func diffVariants(owner string, a, b []Variant) []string {
	var out []string
	payload := func(v Variant) string {
		if v.Type == nil {
			return "void"
		}
		return describe(*v.Type)
	}
	bm := map[int64]Variant{}
	for _, v := range b {
		bm[v.Value] = v
	}
	am := map[int64]bool{}
	for _, v := range a {
		am[v.Value] = true
		w, ok := bm[v.Value]
		switch {
		case !ok:
			out = append(out, fmt.Sprintf("%s: removed variant %d %s", owner, v.Value, v.Name))
		case payload(v) != payload(w) || v.Name != w.Name:
			out = append(out, fmt.Sprintf("%s: variant %d %s %s -> %s %s", owner, v.Value, v.Name, payload(v), w.Name, payload(w)))
		}
	}
	for _, v := range b {
		if !am[v.Value] {
			out = append(out, fmt.Sprintf("%s: added variant %d %s %s", owner, v.Value, v.Name, payload(v)))
		}
	}
	return out
}
