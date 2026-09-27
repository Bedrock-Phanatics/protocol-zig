// Command codegen turns a pinned protocolgen manifest into the canonical
// protocol-zig schema and generates Zig codecs from that schema.
//
//	codegen ingest   -manifest DIR [-root DIR]   refresh protocol/schema/bedrock.json
//	codegen generate [-check] [-root DIR]         write or verify src/generated
//	codegen corpus   [-check] [-samples N] [-out F] write or verify tests/corpus.txt
//	codegen coverage                              report semantic coverage
//	codegen diff     OLD.json NEW.json            review a schema change
package main

import (
	"bytes"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

func must(err error) {
	if err != nil {
		panic(err)
	}
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: codegen ingest|generate|corpus|coverage|diff ...")
		os.Exit(2)
	}
	flags := flag.NewFlagSet(os.Args[1], flag.ExitOnError)
	root := flags.String("root", ".", "repository root")
	manifest := flags.String("manifest", "", "protocolgen checkout at the pinned revision")
	check := flags.Bool("check", false, "fail instead of writing when output differs")
	samples := flags.Int("samples", 1, "corpus samples per packet and direction")
	out := flags.String("out", "", "corpus output file (default: tests/corpus.txt under -root)")
	must(flags.Parse(os.Args[2:]))
	schemaPath := filepath.Join(*root, "protocol", "schema", "bedrock.json")
	switch os.Args[1] {
	case "ingest":
		if *manifest == "" {
			fmt.Fprintln(os.Stderr, "ingest requires -manifest")
			os.Exit(2)
		}
		schema := ingest(*manifest, filepath.Join(*root, "protocol", "schema", "reconciliation.json"))
		files := map[string]string{schemaPath: schema.encode()}
		os.Exit(sync(files, nil, *check))
	case "generate":
		schema := loadSchema(schemaPath)
		files := generate(schema)
		out := map[string]string{}
		for path, contents := range files {
			out[filepath.Join(*root, filepath.FromSlash(path))] = contents
		}
		os.Exit(sync(out, generatedDirs(*root), *check))
	case "corpus":
		schema := loadSchema(schemaPath)
		hints := loadHints(filepath.Join(*root, "protocol", "schema", "sample-hints.json"))
		path := filepath.Join(*root, "tests", "corpus.txt")
		if *out != "" {
			path = *out
		}
		os.Exit(sync(map[string]string{path: corpus(schema, hints, uint64(schema.Target.ProtocolVersion), *samples)}, nil, *check))
	case "coverage":
		report, err := coverage(loadSchema(schemaPath))
		fmt.Print(report)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
	case "diff":
		if flags.NArg() != 2 {
			fmt.Fprintln(os.Stderr, "diff requires OLD.json NEW.json")
			os.Exit(2)
		}
		fmt.Print(diffSchemas(loadSchema(flags.Arg(0)), loadSchema(flags.Arg(1))))
	default:
		fmt.Fprintf(os.Stderr, "unknown command %q\n", os.Args[1])
		os.Exit(2)
	}
}

// generatedDirs lists directories whose .zig files are owned by the generator,
// so stale files from removed packets or types are detected and deleted.
func generatedDirs(root string) []string {
	return []string{filepath.Join(root, "src", "generated")}
}

// sync writes (or with check, verifies) files atomically and removes stale
// generated files. It returns the process exit code.
func sync(files map[string]string, owned []string, check bool) int {
	var stale []string
	paths := make([]string, 0, len(files))
	for path := range files {
		paths = append(paths, path)
	}
	sort.Strings(paths)
	for _, path := range paths {
		actual, err := os.ReadFile(path)
		if err == nil && !strings.HasSuffix(path, ".bin") {
			// Text outputs may have been checked out with CRLF line endings.
			actual = bytes.ReplaceAll(actual, []byte("\r\n"), []byte("\n"))
		}
		if err == nil && bytes.Equal(actual, []byte(files[path])) {
			continue
		}
		if check {
			stale = append(stale, "differs: "+path)
			continue
		}
		must(os.MkdirAll(filepath.Dir(path), 0o755))
		temporary := path + ".tmp"
		must(os.WriteFile(temporary, []byte(files[path]), 0o644))
		must(os.Rename(temporary, path))
	}
	for _, dir := range owned {
		_ = filepath.WalkDir(dir, func(path string, entry os.DirEntry, err error) error {
			if err != nil || entry.IsDir() || !strings.HasSuffix(path, ".zig") {
				return nil
			}
			if _, ok := files[path]; ok {
				return nil
			}
			if check {
				stale = append(stale, "stale: "+path)
			} else {
				must(os.Remove(path))
			}
			return nil
		})
	}
	if len(stale) != 0 {
		fmt.Fprintln(os.Stderr, strings.Join(stale, "\n"))
		return 1
	}
	return 0
}
