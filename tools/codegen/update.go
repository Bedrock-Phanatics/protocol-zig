package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

var manifestFiles = []string{"manifest.json", "naming.json", "gophertunnel-layout.json", "domains.json"}

// pin points reconciliation.json at the protocolgen output for release in
// checkout: target, revision, path and file digests. Everything else in the
// file is left byte for byte as it was.
func pin(reconciliationPath, checkout, release string) {
	dir := filepath.Join(checkout, "generated", release)
	var lock struct {
		Target Target `json:"target"`
	}
	data, err := os.ReadFile(filepath.Join(dir, "source-lock.json"))
	must(err)
	must(json.Unmarshal(data, &lock))
	if lock.Target.MinecraftVersion != release {
		panic(fmt.Errorf("%s targets Minecraft %s", dir, lock.Target.MinecraftVersion))
	}
	out, err := exec.Command("git", "-C", checkout, "rev-parse", "HEAD").Output()
	must(err)
	revision := strings.TrimSpace(string(out))

	var files []string
	for _, name := range manifestFiles {
		data, err := os.ReadFile(filepath.Join(dir, name))
		if os.IsNotExist(err) && name == "gophertunnel-layout.json" {
			continue
		}
		must(err)
		sum := sha256.Sum256(bytes.ReplaceAll(data, []byte("\r\n"), []byte("\n")))
		files = append(files, fmt.Sprintf("      %q: \"sha256:%s\"", name, hex.EncodeToString(sum[:])))
	}

	data, err = os.ReadFile(reconciliationPath)
	must(err)
	text := string(data)
	replace := func(pattern, value string) {
		re := regexp.MustCompile(pattern)
		loc := re.FindStringSubmatchIndex(text)
		if loc == nil {
			panic(fmt.Errorf("reconciliation.json has no %s", pattern))
		}
		text = text[:loc[2]] + value + text[loc[3]:]
	}
	// The target and manifest blocks come first, so the first match of each
	// key is the one to update.
	replace(`"minecraft_version": "([^"]*)"`, release)
	replace(`"protocol_version": (\d+)`, strconv.Itoa(lock.Target.ProtocolVersion))
	replace(`"revision": "([^"]*)"`, revision)
	replace(`"path": "([^"]*)"`, "generated/"+release)
	replace(`(?s)"files": \{\n(.*?)\n    \}`, strings.Join(files, ",\n"))

	var rec Reconciliation
	must(json.Unmarshal([]byte(text), &rec))
	if rec.Target.MinecraftVersion != release || rec.Manifest.Revision != revision || len(rec.Manifest.Files) != len(files) {
		panic(fmt.Errorf("reconciliation.json did not take the new pin"))
	}
	must(os.WriteFile(reconciliationPath, []byte(text), 0o644))
}
