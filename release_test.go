package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func TestWhenReleaseStagingHasAppleMetadataTheArchiveContainsOnlyTheReleaseFiles(t *testing.T) {
	out := t.TempDir()
	name := "carson-release"
	staging := filepath.Join(out, name)
	if err := os.Mkdir(staging, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, file := range []string{"carson", "LICENSE", "README.md", "._carson"} {
		if err := os.WriteFile(filepath.Join(staging, file), []byte(file), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	if output, err := exec.Command("bash", "bin/release-archive.bash", out, name).CombinedOutput(); err != nil {
		t.Fatalf("packaging failed: %v\n%s", err, output)
	}
	listing, err := exec.Command("tar", "-tzf", filepath.Join(out, name+".tar.gz")).Output()
	if err != nil {
		t.Fatal(err)
	}
	want := "carson-release/\ncarson-release/carson\ncarson-release/LICENSE\ncarson-release/README.md\n"
	if string(listing) != want {
		t.Fatalf("release archive contains %q; want %q", listing, want)
	}
}
