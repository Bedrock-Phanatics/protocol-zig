// Command differential replays the packet corpus through the pinned
// gophertunnel codec, an implementation independent of protocol-zig's schema
// and generator. Every packet must decode from the side that sent it, consume
// its whole payload and re-encode byte for byte, unless a reviewed entry in
// accepted-divergences.json explains the difference.
//
//	go run . -corpus ../../tests/corpus-2193.txt
//	go run . -dump "server 11 0b..."   # show gophertunnel's decoding of one line
package main

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"

	"github.com/sandertv/gophertunnel/minecraft/protocol"
	"github.com/sandertv/gophertunnel/minecraft/protocol/packet"
)

// Divergence is a reviewed, intentional difference from the oracle. Kind is
// "unregistered", "reencode", or "layout" (any decode, trailing-byte or
// re-encode difference caused by a documented wire conflict).
type Divergence struct {
	Packet    uint32 `json:"packet"`
	Direction string `json:"direction"`
	Kind      string `json:"kind"`
	Evidence  string `json:"evidence"`
	Rationale string `json:"rationale"`
}

type sample struct {
	line      int
	direction string
	id        uint32
	payload   []byte
}

var pools = map[string]packet.Pool{"client": packet.NewClientPool(), "server": packet.NewServerPool()}
var otherSide = map[string]string{"client": "server", "server": "client"}

func main() {
	corpusPath := flag.String("corpus", "../../tests/corpus-2193.txt", "corpus file")
	acceptedPath := flag.String("accepted", "accepted-divergences.json", "reviewed divergences")
	dump := flag.String("dump", "", "print gophertunnel's decoding of one corpus line")
	allowUnused := flag.Bool("allow-unused", false, "do not fail when an accepted divergence does not occur (for small corpora)")
	flag.Parse()

	if *dump != "" {
		s, err := parse(*dump, 0)
		must(err)
		dumpSample(s)
		return
	}
	samples := readCorpus(*corpusPath)
	accepted := readAccepted(*acceptedPath)
	used := map[string]bool{}
	var failures []string
	for _, s := range samples {
		for _, f := range check(s) {
			key := fmt.Sprintf("%s/%d/%s", s.direction, s.id, f.kind)
			layout := fmt.Sprintf("%s/%d/layout", s.direction, s.id)
			switch {
			case accepted[key]:
				used[key] = true
			case f.kind != "unregistered" && accepted[layout]:
				used[layout] = true
			default:
				failures = append(failures, fmt.Sprintf("%-12s line %d (%s %d): %s", f.kind, s.line, s.direction, s.id, f.info))
			}
		}
	}
	if !*allowUnused {
		for key := range accepted {
			if !used[key] {
				failures = append(failures, "stale        "+key+": accepted divergence no longer occurs")
			}
		}
	}
	sort.Strings(failures)
	for _, f := range failures {
		fmt.Println(f)
	}
	fmt.Printf("differential: %d corpus packets, %d unexplained differences\n", len(samples), len(failures))
	if len(failures) != 0 || len(samples) == 0 {
		os.Exit(1)
	}
}

type finding struct{ kind, info string }

func check(s sample) []finding {
	var out []finding
	ctor, ok := pools[s.direction][s.id]
	if !ok {
		out = append(out, finding{"unregistered", "gophertunnel does not accept this ID from the " + s.direction})
		// The layout is the same from either side, so still compare codecs.
		if ctor, ok = pools[otherSide[s.direction]][s.id]; !ok {
			return out
		}
	}
	pk := ctor()
	reader := bytes.NewReader(s.payload)
	if msg := protect(func() { pk.Marshal(protocol.NewReader(reader, 0, true)) }); msg != "" {
		return append(out, finding{"decode", msg})
	}
	if reader.Len() != 0 {
		return append(out, finding{"trailing", strconv.Itoa(reader.Len()) + " unread bytes"})
	}
	var encoded bytes.Buffer
	if msg := protect(func() { pk.Marshal(protocol.NewWriter(&encoded, 0)) }); msg != "" {
		return append(out, finding{"reencode", "encode panicked: " + msg})
	}
	if got := encoded.Bytes(); !bytes.Equal(got, s.payload) {
		at := 0
		for at < len(got) && at < len(s.payload) && got[at] == s.payload[at] {
			at++
		}
		from := max(at-16, 0)
		out = append(out, finding{"reencode", fmt.Sprintf("first difference at byte %d of %d: oracle %x... corpus %x...",
			at, len(s.payload), got[from:min(at+16, len(got))], s.payload[from:min(at+16, len(s.payload))])})
	}
	return out
}

func parse(line string, number int) (sample, error) {
	fields := strings.Fields(line)
	if len(fields) != 3 || (fields[0] != "client" && fields[0] != "server") {
		return sample{}, fmt.Errorf("line %d: want \"<client|server> <id> <hex>\"", number)
	}
	data, err := hex.DecodeString(fields[2])
	if err != nil {
		return sample{}, fmt.Errorf("line %d: %w", number, err)
	}
	header, n := binary.Uvarint(data)
	if n <= 0 {
		return sample{}, fmt.Errorf("line %d: bad packet header", number)
	}
	return sample{line: number, direction: fields[0], id: uint32(header & 0x3ff), payload: data[n:]}, nil
}

func readCorpus(path string) []sample {
	file, err := os.Open(path)
	must(err)
	defer file.Close()
	var samples []sample
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 1<<20), 64<<20)
	for number := 1; scanner.Scan(); number++ {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		s, err := parse(line, number)
		must(err)
		samples = append(samples, s)
	}
	must(scanner.Err())
	return samples
}

func readAccepted(path string) map[string]bool {
	data, err := os.ReadFile(path)
	must(err)
	var entries []Divergence
	must(json.Unmarshal(data, &entries))
	accepted := map[string]bool{}
	for _, d := range entries {
		if d.Evidence == "" || d.Rationale == "" {
			must(fmt.Errorf("divergence %d/%s lacks evidence or rationale", d.Packet, d.Direction))
		}
		accepted[fmt.Sprintf("%s/%d/%s", d.Direction, d.Packet, d.Kind)] = true
	}
	return accepted
}

func dumpSample(s sample) {
	ctor, ok := pools[s.direction][s.id]
	if !ok {
		ctor = pools[otherSide[s.direction]][s.id]
	}
	pk := ctor()
	reader := bytes.NewReader(s.payload)
	msg := protect(func() { pk.Marshal(protocol.NewReader(reader, 0, true)) })
	fmt.Printf("payload %x\nerror %q, %d unread\n%+v\n", s.payload, msg, reader.Len(), pk)
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

func must(err error) {
	if err != nil {
		panic(err)
	}
}
