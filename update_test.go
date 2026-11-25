package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestWhenUpdateIsRequestedWithAnArgumentCarsonShowsHowToRunIt(t *testing.T) {
	var out bytes.Buffer
	code := Main([]string{"update", "v5.6.1"}, Machine{Out: &out})
	if code != refused || !strings.Contains(out.String(), "Run carson update without arguments.") {
		t.Fatalf("exit %d, output %q", code, out.String())
	}
}

func TestWhenANewerStableReleaseExistsCarsonInstallsItAndKeepsThePreviousBinary(t *testing.T) {
	u, installed := testInstallation(t)
	name := "carson-5.10.0-" + runtime.GOOS + "-" + runtime.GOARCH
	archive := testArchive(t, name+"/carson", "new binary")
	u.releases = testRelease(t, "v5.10.0", name, archive, fmt.Sprintf("sha256:%x", sha256.Sum256(archive)), nil)

	var out bytes.Buffer
	code := u.run(nil, &out)

	if code != done || !strings.Contains(out.String(), "Updated Carson from 5.9.0 to 5.10.0.") {
		t.Fatalf("exit %d, output %q", code, out.String())
	}
	assertBinary(t, installed, "new binary")
	_, backup, saved := strings.Cut(out.String(), "Previous binary kept at ")
	if !saved {
		t.Fatalf("no backup location in %q", out.String())
	}
	assertBinary(t, strings.TrimSpace(backup), "old binary")
}

func TestWhenTheInstalledVersionIsNotOlderCarsonLeavesItInPlace(t *testing.T) {
	for _, tag := range []string{"v5.9.0", "v5.8.0"} {
		t.Run(tag, func(t *testing.T) {
			u, installed := testInstallation(t)
			u.releases = testRelease(t, tag, "", nil, "", nil)

			var out bytes.Buffer
			code := u.run(nil, &out)

			if code != done || !strings.Contains(out.String(), "No update needed.") {
				t.Fatalf("exit %d, output %q", code, out.String())
			}
			assertUnchangedInstallation(t, installed)
		})
	}
}

func TestWhenTheReleaseCannotBeVerifiedCarsonLeavesTheInstalledBinaryInPlace(t *testing.T) {
	name := "carson-5.10.0-" + runtime.GOOS + "-" + runtime.GOARCH
	archive := testArchive(t, name+"/carson", "new binary")
	otherMember := testArchive(t, name+"/../../carson", "not the release binary")
	for _, scenario := range []struct {
		label   string
		tag     string
		archive []byte
		digest  string
		message string
	}{
		{"missing checksum", "v5.10.0", archive, "", "no valid SHA-256 digest"},
		{"wrong checksum", "v5.10.0", archive, "sha256:" + strings.Repeat("0", 64), "does not match its SHA-256 digest"},
		{"wrong archive member", "v5.10.0", otherMember, fmt.Sprintf("sha256:%x", sha256.Sum256(otherMember)), "release archive contains no Carson binary"},
		{"prerelease version", "v5.10.0-rc.1", nil, "", "not a stable Carson version"},
	} {
		t.Run(scenario.label, func(t *testing.T) {
			u, installed := testInstallation(t)
			u.releases = testRelease(t, scenario.tag, name, scenario.archive, scenario.digest, nil)

			var out bytes.Buffer
			code := u.run(nil, &out)

			if code != failed || !strings.Contains(out.String(), scenario.message) {
				t.Fatalf("exit %d, output %q", code, out.String())
			}
			assertUnchangedInstallation(t, installed)
		})
	}
}

func TestWhenTheReleaseHasNoBuildForThisMachineCarsonLeavesTheInstallationInPlace(t *testing.T) {
	u, installed := testInstallation(t)
	u.releases = testRelease(t, "v5.10.0", "", nil, "", nil)

	var out bytes.Buffer
	code := u.run(nil, &out)

	if code != failed || !strings.Contains(out.String(), "has no build for "+runtime.GOOS+"/"+runtime.GOARCH) {
		t.Fatalf("exit %d, output %q", code, out.String())
	}
	assertUnchangedInstallation(t, installed)
}

func TestWhenGitHubIsUnavailableCarsonLeavesTheInstallationInPlace(t *testing.T) {
	u, installed := testInstallation(t)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
	}))
	t.Cleanup(server.Close)
	u.releases = releaseSource{client: server.Client(), latest: server.URL}

	var out bytes.Buffer
	code := u.run(nil, &out)

	if code != failed || !strings.Contains(out.String(), "GitHub returned HTTP 503") {
		t.Fatalf("exit %d, output %q", code, out.String())
	}
	assertUnchangedInstallation(t, installed)
}

func TestWhenMiseOwnsTheInstallationCarsonShowsTheMiseUpdateCommand(t *testing.T) {
	u, installed := testInstallation(t)
	miseData := filepath.Join(u.env("HOME"), ".local", "share", "mise")
	managed := filepath.Join(miseData, "installs", "github-wanghailei-carson", "5.9.0", "carson")
	if err := os.MkdirAll(filepath.Dir(managed), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(installed, managed); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(managed, installed); err != nil {
		t.Fatal(err)
	}

	var out bytes.Buffer
	code := u.run(nil, &out)

	if code != refused || !strings.Contains(out.String(), "mise upgrade --bump github:wanghailei/carson") {
		t.Fatalf("exit %d, output %q", code, out.String())
	}
	assertBinary(t, managed, "old binary")
	if target, err := os.Readlink(installed); err != nil || target != managed {
		t.Fatalf("the installed link changed: %q, %v", target, err)
	}
}

func TestWhenTheInstallationIsNotInAKnownStandaloneLocationCarsonDoesNotReplaceIt(t *testing.T) {
	u, installed := testInstallation(t)
	elsewhere := filepath.Join(u.env("HOME"), "custom", "carson")
	if err := os.MkdirAll(filepath.Dir(elsewhere), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(installed, elsewhere); err != nil {
		t.Fatal(err)
	}
	u.executable = func() (string, error) { return elsewhere, nil }

	var out bytes.Buffer
	code := u.run(nil, &out)

	if code != refused || !strings.Contains(out.String(), "use the method you installed Carson with") {
		t.Fatalf("exit %d, output %q", code, out.String())
	}
	assertUnchangedInstallation(t, elsewhere)
}

func TestWhenTheInstallationChangesDuringDownloadCarsonDoesNotOverwriteIt(t *testing.T) {
	u, installed := testInstallation(t)
	name := "carson-5.10.0-" + runtime.GOOS + "-" + runtime.GOARCH
	archive := testArchive(t, name+"/carson", "new binary")
	other := filepath.Join(u.env("HOME"), "another-carson")
	if err := os.WriteFile(other, []byte("another update"), 0o700); err != nil {
		t.Fatal(err)
	}
	u.releases = testRelease(t, "v5.10.0", name, archive, fmt.Sprintf("sha256:%x", sha256.Sum256(archive)), func() error {
		return os.Rename(other, installed)
	})

	var out bytes.Buffer
	code := u.run(nil, &out)

	if code != failed || !strings.Contains(out.String(), "installation changed while downloading") {
		t.Fatalf("exit %d, output %q", code, out.String())
	}
	assertBinary(t, installed, "another update")
	assertOnlyBinary(t, installed)
}

func testInstallation(t *testing.T) (updater, string) {
	t.Helper()
	home := t.TempDir()
	installed := filepath.Join(home, ".local", "bin", "carson")
	if err := os.MkdirAll(filepath.Dir(installed), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(installed, []byte("old binary"), 0o700); err != nil {
		t.Fatal(err)
	}
	return updater{
		current: "5.9.0", env: environment{"HOME": home}.get,
		executable: func() (string, error) { return installed, nil },
	}, installed
}

func testRelease(t *testing.T, tag, name string, archive []byte, digest string, beforeDownload func() error) releaseSource {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/latest":
			metadata := map[string]any{"tag_name": tag}
			if name != "" {
				metadata["assets"] = []map[string]string{{"name": name + ".tar.gz", "digest": digest}}
			}
			if err := json.NewEncoder(w).Encode(metadata); err != nil {
				t.Error(err)
			}
		case name != "" && r.URL.Path == "/download/"+tag+"/"+name+".tar.gz":
			if beforeDownload != nil {
				if err := beforeDownload(); err != nil {
					t.Error(err)
					w.WriteHeader(http.StatusInternalServerError)
					return
				}
			}
			w.Write(archive)
		default:
			t.Errorf("unexpected release request: %s", r.URL.Path)
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(server.Close)
	return releaseSource{client: server.Client(), latest: server.URL + "/latest", downloads: server.URL + "/download/"}
}

func testArchive(t *testing.T, name, contents string) []byte {
	t.Helper()
	var archive bytes.Buffer
	compressed := gzip.NewWriter(&archive)
	entries := tar.NewWriter(compressed)
	if err := entries.WriteHeader(&tar.Header{Name: name, Mode: 0o755, Size: int64(len(contents)), Typeflag: tar.TypeReg}); err != nil {
		t.Fatal(err)
	}
	if _, err := entries.Write([]byte(contents)); err != nil {
		t.Fatal(err)
	}
	if err := entries.Close(); err != nil {
		t.Fatal(err)
	}
	if err := compressed.Close(); err != nil {
		t.Fatal(err)
	}
	return archive.Bytes()
}

func assertUnchangedInstallation(t *testing.T, installed string) {
	t.Helper()
	assertBinary(t, installed, "old binary")
	assertOnlyBinary(t, installed)
}

func assertBinary(t *testing.T, installed, want string) {
	t.Helper()
	contents, err := os.ReadFile(installed)
	if err != nil || string(contents) != want {
		t.Fatalf("%s contains %q, %v; want %q", installed, contents, err, want)
	}
	info, err := os.Stat(installed)
	if err != nil || info.Mode().Perm() != 0o700 {
		t.Fatalf("%s did not keep its executable permissions: %v, %v", installed, info, err)
	}
}

func assertOnlyBinary(t *testing.T, installed string) {
	t.Helper()
	entries, err := os.ReadDir(filepath.Dir(installed))
	if err != nil || len(entries) != 1 || entries[0].Name() != "carson" {
		t.Fatalf("unexpected files in the installation folder: %v, %v", entries, err)
	}
}
