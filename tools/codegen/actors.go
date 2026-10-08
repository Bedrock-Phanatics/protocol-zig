package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"sort"
)

// Unclassified 64-bit fields fail generation, so new actor IDs can't slip through.
type ActorRefs struct {
	Runtime []string `json:"runtime"`
	Unique  []string `json:"unique"`
	Other   []string `json:"other"`
}

var wideIntegers = map[string]bool{"var_u64": true, "zigzag_i64": true, "u64le": true, "i64le": true, "u64be": true, "i64be": true}

func loadActorRefs(path string) ActorRefs {
	data, err := os.ReadFile(path)
	must(err)
	var a ActorRefs
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	must(decoder.Decode(&a))
	return a
}

func (a ActorRefs) resolve(s Schema) (map[string]string, error) {
	sites := map[string]bool{} // true when the integer sits in a map
	for _, p := range s.Packets {
		for _, f := range p.Fields {
			wideSite(sites, p.Name+"."+f.Name, f.Type, false)
		}
	}
	for _, t := range s.Types {
		for _, f := range t.Fields {
			wideSite(sites, t.Name+"."+f.Name, f.Type, false)
		}
		for _, v := range t.Variants {
			if v.Type != nil {
				wideSite(sites, t.Name+"."+v.Name, *v.Type, false)
			}
		}
	}
	refs := map[string]string{}
	seen := map[string]bool{}
	for _, group := range []struct {
		kind  string
		names []string
	}{{"runtime", a.Runtime}, {"unique", a.Unique}, {"other", a.Other}} {
		for _, name := range group.names {
			inMap, ok := sites[name]
			if !ok {
				return nil, fmt.Errorf("actor-refs.json lists %s, which has no 64-bit integer", name)
			}
			if seen[name] {
				return nil, fmt.Errorf("actor-refs.json lists %s twice", name)
			}
			seen[name] = true
			if group.kind == "other" {
				continue
			}
			if inMap {
				return nil, fmt.Errorf("actor reference %s sits in a map, which the visitor cannot reach", name)
			}
			refs[name] = group.kind
		}
	}
	var missing []string
	for name := range sites {
		if !seen[name] {
			missing = append(missing, name)
		}
	}
	if len(missing) != 0 {
		sort.Strings(missing)
		return nil, fmt.Errorf("unclassified 64-bit fields, add them to actor-refs.json: %v", missing)
	}
	return refs, nil
}

func wideSite(sites map[string]bool, name string, n Node, inMap bool) {
	if wideIntegers[n.Kind] {
		sites[name] = sites[name] || inMap
	}
	if n.Element != nil {
		wideSite(sites, name, *n.Element, inMap)
	}
	if n.Key != nil {
		wideSite(sites, name, *n.Key, true)
	}
	if n.Value != nil {
		wideSite(sites, name, *n.Value, inMap || n.Kind == "map")
	}
}
