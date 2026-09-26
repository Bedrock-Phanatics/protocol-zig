// Command differential replays tests/corpus through the pinned gophertunnel
// codec, an implementation independent of protocol-zig's schema and generator.
// Every corpus packet must decode from the direction its directory names,
// consume its whole payload and re-encode byte for byte, unless a reviewed
// entry in accepted-divergences.json explains the difference.
//
//	go run . -corpus ../../tests/corpus
package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"github.com/sandertv/gophertunnel/minecraft/protocol"
	"github.com/sandertv/gophertunnel/minecraft/protocol/packet"
)

// Divergence is a reviewed, intentional difference from the oracle.
type Divergence struct {
	Packet    uint32 `json:"packet"`
	Direction string `json:"direction"`
	Kind      string `json:"kind"`
	Evidence  string `json:"evidence"`
	Rationale string `json:"rationale"`
}

type result struct {
	file string
	kind string // "decode", "trailing", "reencode", "unregistered"
	info string
}

func main() {
	corpusDir := flag.String("corpus", "../../tests/corpus", "corpus directory")
	acceptedPath := flag.String("accepted", "accepted-divergences.json", "reviewed divergences")
	dump := flag.String("dump", "", "print gophertunnel's decoding of one corpus file")
	allowUnused := flag.Bool("allow-unused", false, "do not fail when an accepted divergence does not occur (for small corpora)")
	flag.Parse()
	if *dump != "" {
		dumpFile(*dump)
		return
	}

	var accepted []Divergence
	data, err := os.ReadFile(*acceptedPath)
	if err != nil {
		panic(err)
	}
	if err := json.Unmarshal(data, &accepted); err != nil {
		panic(err)
	}
	allowed := map[string]bool{}
	used := map[string]bool{}
	for _, d := range accepted {
		if d.Evidence == "" || d.Rationale == "" {
			panic(fmt.Sprintf("divergence %d/%s lacks evidence or rationale", d.Packet, d.Direction))
		}
		allowed[fmt.Sprintf("%s/%d/%s", d.Direction, d.Packet, d.Kind)] = true
	}

	pools := map[string]packet.Pool{"client": packet.NewClientPool(), "server": packet.NewServerPool()}
	var failures []result
	checked := 0
	err = filepath.WalkDir(*corpusDir, func(path string, entry os.DirEntry, err error) error {
		if err != nil || entry.IsDir() || !strings.HasSuffix(path, ".bin") {
			return err
		}
		rel, _ := filepath.Rel(*corpusDir, path)
		rel = filepath.ToSlash(rel)
		parts := strings.Split(filepath.ToSlash(rel), "/")
		direction := parts[0]
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		checked++
		header, n := binary.Uvarint(data)
		id := uint32(header & 0x3ff)
		payload := data[n:]
		key := func(kind string) string { return fmt.Sprintf("%s/%d/%s", direction, id, kind) }
		fail := func(kind, info string) {
			for _, k := range []string{key(kind), key("layout")} {
				if allowed[k] && (k == key(kind) || kind != "unregistered") {
					used[k] = true
					return
				}
			}
			failures = append(failures, result{rel, kind, info})
		}
		ctor, ok := pools[direction][id]
		if !ok {
			fail("unregistered", "gophertunnel does not accept this ID from the "+direction)
			// The layout is the same from either side, so still compare codecs.
			other := map[string]string{"client": "server", "server": "client"}[direction]
			if ctor, ok = pools[other][id]; !ok {
				return nil
			}
		}
		pk := ctor()
		reader := bytes.NewReader(payload)
		if msg := protect(func() { pk.Marshal(protocol.NewReader(reader, 0, true)) }); msg != "" {
			fail("decode", msg)
			return nil
		}
		if reader.Len() != 0 {
			fail("trailing", strconv.Itoa(reader.Len())+" unread bytes")
			return nil
		}
		var out bytes.Buffer
		if msg := protect(func() { pk.Marshal(protocol.NewWriter(&out, 0)) }); msg != "" {
			fail("reencode", "encode panicked: "+msg)
			return nil
		}
		if got := out.Bytes(); !bytes.Equal(got, payload) {
			at := 0
			for at < len(got) && at < len(payload) && got[at] == payload[at] {
				at++
			}
			from := max(at-16, 0)
			fail("reencode", fmt.Sprintf("first difference at byte %d of %d: oracle %x... corpus %x...", at, len(payload),
				got[from:min(at+16, len(got))], payload[from:min(at+16, len(payload))]))
		}
		return nil
	})
	if err != nil {
		panic(err)
	}
	for k := range allowed {
		if !used[k] && !*allowUnused {
			failures = append(failures, result{k, "stale", "accepted divergence no longer occurs"})
		}
	}
	sort.Slice(failures, func(i, j int) bool { return failures[i].file < failures[j].file })
	for _, f := range failures {
		fmt.Printf("%-12s %s: %s\n", f.kind, f.file, f.info)
	}
	fmt.Printf("differential: %d corpus packets, %d unexplained differences\n", checked, len(failures))
	if len(failures) != 0 || checked == 0 {
		os.Exit(1)
	}
}

func protect(f func()) (msg string) {
	defer func() {
		if r := recover(); r != nil {
			msg = fmt.Sprint(r)
		}
	}()
	f()
	return ""
}

func dumpFile(path string) {
	data, err := os.ReadFile(path)
	if err != nil {
		panic(err)
	}
	header, n := binary.Uvarint(data)
	direction := "client"
	if strings.Contains(filepath.ToSlash(path), "/server/") {
		direction = "server"
	}
	pools := map[string]packet.Pool{"client": packet.NewClientPool(), "server": packet.NewServerPool()}
	ctor, ok := pools[direction][uint32(header&0x3ff)]
	if !ok {
		ctor = pools[map[string]string{"client": "server", "server": "client"}[direction]][uint32(header&0x3ff)]
	}
	pk := ctor()
	reader := bytes.NewReader(data[n:])
	msg := protect(func() { pk.Marshal(protocol.NewReader(reader, 0, true)) })
	fmt.Printf("payload %x\nerror %q, %d unread\n%+v\n", data[n:], msg, reader.Len(), pk)
}
