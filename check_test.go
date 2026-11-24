package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestWhenCheckingCarsonMiseIsAskedForTheLatestGo(t *testing.T) {
	tools := t.TempDir()
	// Stand in for the external version manager to test the request without a download.
	mise := `#!/bin/sh
if [ "$1" != exec ] || [ "$2" != go@latest ]; then
	printf 'mise was not asked for the latest Go\n' >&2
	exit 1
fi
printf 'Latest Go requested\n'
`
	if err := os.WriteFile(filepath.Join(tools, "mise"), []byte(mise), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", tools+string(os.PathListSeparator)+os.Getenv("PATH"))

	output, err := exec.Command("sh", "bin/check").CombinedOutput()
	if err != nil {
		t.Fatalf("bin/check failed: %v\n%s", err, output)
	}
	if strings.TrimSpace(string(output)) != "Latest Go requested" {
		t.Fatalf("bin/check did not request the latest Go: %q", output)
	}
}
