package main

import (
	"os"
	"path/filepath"
	"testing"
)

func mustPanic(t *testing.T, f func()) {
	t.Helper()
	defer func() {
		if recover() == nil {
			t.Fatal("expected rejection")
		}
	}()
	f()
}
func TestInvalidCatalog(t *testing.T) {
	for _, packets := range []string{
		`[{"name":"A","id":1,"directions":["client"]},{"name":"B","id":1,"directions":["server"]}]`,
		`[{"name":"A","id":1,"directions":["client"]},{"name":"A","id":2,"directions":["client"]}]`,
		`[{"name":"A","id":1024,"directions":["client"]}]`,
		`[{"name":"A","id":1,"directions":["invalid"]}]`,
	} {
		t.Run(packets, func(t *testing.T) {
			t.Chdir(t.TempDir())
			must(os.MkdirAll("protocol/schema", 0755))
			must(os.WriteFile(baseSchemaPath, []byte(`{"packets":`+packets+`}`), 0644))
			must(os.WriteFile(overlayPath, []byte(`{"additions":[]}`), 0644))
			mustPanic(t, func() { loadPackets() })
		})
	}
}
func TestCheckDoesNotOverwriteStaleOutput(t *testing.T) {
	path := filepath.Join(t.TempDir(), "output.zig")
	must(os.WriteFile(path, []byte("stale"), 0644))
	args := os.Args
	defer func() { os.Args = args }()
	os.Args = []string{"generator", "--check"}
	mustPanic(t, func() { writeAtomic(path, "fresh") })
	data, err := os.ReadFile(path)
	must(err)
	if string(data) != "stale" {
		t.Fatal("check changed output")
	}
}
