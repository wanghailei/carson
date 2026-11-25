package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
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
	original := testInstalledVersion("0.0.0")
	if err := os.WriteFile(installed, []byte(original), 0o700); err != nil {
		t.Fatal(err)
	}
	name := "carson-" + Version + "-" + runtime.GOOS + "-" + runtime.GOARCH
	archive, newBinary := testPackagedRelease(t, name)
	u.releases = testReleaseThroughAssetRedirect(t, "v"+Version, name, archive)

	var out bytes.Buffer
	code := u.run(nil, &out)

	if code != done || !strings.Contains(out.String(), "Updated Carson from 0.0.0 to "+Version+".") {
		t.Fatalf("exit %d, output %q", code, out.String())
	}
	assertBinary(t, installed, newBinary)
	_, backup, saved := strings.Cut(out.String(), "Previous binary kept at ")
	if !saved {
		t.Fatalf("no backup location in %q", out.String())
	}
	assertBinary(t, strings.TrimSpace(backup), original)
	if target, err := os.Readlink(installed); err != nil || target != filepath.Join(testStandaloneFolder(u), "current") {
		t.Fatalf("the launcher was replaced: %q, %v", target, err)
	}
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
	badArchive := []byte("not a gzip archive")
	wrongVersion := testArchive(t, name+"/carson", testReleaseExecutable(t, "5.10.1"))
	noUpdater := testArchive(t, name+"/carson", testNativeRelease(t, "5.10.0", ""))
	link := testArchiveEntry(t, &tar.Header{Name: name + "/carson", Linkname: "../../elsewhere", Typeflag: tar.TypeSymlink}, "")
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
		{"not a native binary", "v5.10.0", archive, fmt.Sprintf("sha256:%x", sha256.Sum256(archive)), "not a native Go executable"},
		{"binary reports another version", "v5.10.0", wrongVersion, fmt.Sprintf("sha256:%x", sha256.Sum256(wrongVersion)), "did not report the expected version 5.10.0"},
		{"binary has no updater", "v5.10.0", noUpdater, fmt.Sprintf("sha256:%x", sha256.Sum256(noUpdater)), "does not offer carson update"},
		{"corrupt archive", "v5.10.0", badArchive, fmt.Sprintf("sha256:%x", sha256.Sum256(badArchive)), "cannot read the release archive"},
		{"link in place of the binary", "v5.10.0", link, fmt.Sprintf("sha256:%x", sha256.Sum256(link)), "does not contain a valid regular Carson binary"},
		{"prerelease version", "v5.10.0-rc.1", nil, "", "not a stable Carson version"},
		{"non-numeric version", "v5.invalid.0", nil, "", "not a stable Carson version"},
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

func TestWhenGitHubCannotProvideTrustedReleaseInformationCarsonLeavesTheInstallationInPlace(t *testing.T) {
	for _, scenario := range []struct {
		label    string
		response func(http.ResponseWriter)
		message  string
	}{
		{"unavailable", func(w http.ResponseWriter) { w.WriteHeader(http.StatusServiceUnavailable) }, "GitHub returned HTTP 503"},
		{"not JSON", func(w http.ResponseWriter) { io.WriteString(w, "not JSON") }, "cannot read GitHub's latest release information"},
		{"oversized", func(w http.ResponseWriter) { io.WriteString(w, strings.Repeat("a", (1<<20)+1)) }, "response was larger than expected"},
		{"truncated", func(w http.ResponseWriter) { w.Header().Set("Content-Length", "9"); io.WriteString(w, "{") }, "unexpected EOF"},
		{"unexpected host", func(w http.ResponseWriter) { redirectTo(w, "https://third-party.invalid/releases/latest") }, "unexpected redirect from GitHub"},
		{"insecure scheme", func(w http.ResponseWriter) { redirectTo(w, "http://api.github.com/releases/latest") }, "unexpected redirect from GitHub"},
	} {
		t.Run(scenario.label, func(t *testing.T) {
			u, installed := testInstallation(t)
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { scenario.response(w) }))
			t.Cleanup(server.Close)
			u.releases = githubReleases()
			u.releases.latest = server.URL

			var out bytes.Buffer
			code := u.run(nil, &out)

			if code != failed || !strings.Contains(out.String(), scenario.message) {
				t.Fatalf("exit %d, output %q", code, out.String())
			}
			assertUnchangedInstallation(t, installed)
		})
	}
}

func TestWhenTheReleaseDownloadFailsCarsonLeavesTheInstallationInPlace(t *testing.T) {
	u, installed := testInstallation(t)
	name := "carson-5.10.0-" + runtime.GOOS + "-" + runtime.GOARCH
	digest := "sha256:" + strings.Repeat("0", 64)
	u.releases = testRelease(t, "v5.10.0", name, nil, digest, nil)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
	}))
	t.Cleanup(server.Close)
	u.releases.downloads = server.URL + "/download/"

	var out bytes.Buffer
	if code := u.run(nil, &out); code != failed || !strings.Contains(out.String(), "cannot download "+name+".tar.gz: GitHub returned HTTP 503") {
		t.Fatalf("exit %d, output %q", code, out.String())
	}
	assertUnchangedInstallation(t, installed)
}

func redirectTo(w http.ResponseWriter, target string) {
	w.Header().Set("Location", target)
	w.WriteHeader(http.StatusFound)
}

func TestWhenMiseOwnsTheInstallationCarsonShowsTheMiseUpdateCommand(t *testing.T) {
	u, installed := testInstallation(t)
	miseData := filepath.Join(u.env("HOME"), ".local", "share", "mise")
	managed := filepath.Join(miseData, "installs", "github-wanghailei-carson", "5.9.0", "carson")
	if err := os.MkdirAll(filepath.Dir(managed), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(managed, []byte("managed binary"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(installed); err != nil {
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
	assertBinary(t, managed, "managed binary")
	if target, err := os.Readlink(installed); err != nil || target != managed {
		t.Fatalf("the installed link changed: %q, %v", target, err)
	}
}

func TestWhenHomebrewOwnsTheInstallationCarsonShowsTheHomebrewUpdateCommand(t *testing.T) {
	u, _ := testInstallation(t)
	managed := filepath.Join(u.env("HOME"), "brew", "Cellar", "carson", "5.9.0", "bin", "carson")
	if err := os.MkdirAll(filepath.Dir(managed), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(managed, []byte("managed binary"), 0o700); err != nil {
		t.Fatal(err)
	}
	u.executable = func() (string, error) { return managed, nil }

	var out bytes.Buffer
	code := u.run(nil, &out)

	if code != refused || !strings.Contains(out.String(), "brew upgrade carson") {
		t.Fatalf("exit %d, output %q", code, out.String())
	}
	assertBinary(t, managed, "managed binary")
}

func TestWhenACopyInThePersonalBinDirectoryWasNotSetUpForUpdatesCarsonLeavesItAlone(t *testing.T) {
	home := t.TempDir()
	installed := filepath.Join(home, ".local", "bin", "carson")
	if err := os.MkdirAll(filepath.Dir(installed), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(installed, []byte("unregistered binary"), 0o700); err != nil {
		t.Fatal(err)
	}
	u := updater{env: environment{"HOME": home}.get, executable: func() (string, error) { return installed, nil }}
	u.releases = testRelease(t, "v5.10.0", "", nil, "", nil)

	var out bytes.Buffer
	code := u.run(nil, &out)

	if code != refused || !strings.Contains(out.String(), "this copy is not set up for standalone updates") {
		t.Fatalf("exit %d, output %q", code, out.String())
	}
	assertBinary(t, installed, "unregistered binary")
}

func TestWhenTheStandaloneFolderIsNotPrivateCarsonLeavesItAlone(t *testing.T) {
	u, installed := testInstallation(t)
	if err := os.Chmod(testStandaloneFolder(u), 0o755); err != nil {
		t.Fatal(err)
	}

	var out bytes.Buffer
	if code := u.run(nil, &out); code != refused || !strings.Contains(out.String(), "the standalone folder is not private") {
		t.Fatalf("exit %d, output %q", code, out.String())
	}
	assertUnchangedInstallation(t, installed)
}

func TestWhenTheActiveLinkNamesAnOutsideBinaryCarsonLeavesItAlone(t *testing.T) {
	for _, scenario := range []struct {
		name    string
		linked  bool
		message string
	}{
		{"absolute path", false, "no valid active version"},
		{"linked version folder", true, "does not point to a version folder in the standalone installation"},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			u, installed := testInstallation(t)
			folder := testStandaloneFolder(u)
			original := filepath.Join(folder, "version-original/carson")
			u.executable = func() (string, error) { return original, nil }
			outside := filepath.Join(u.env("HOME"), "carson")
			if err := os.WriteFile(outside, []byte("outside binary"), 0o700); err != nil {
				t.Fatal(err)
			}
			target := outside
			if scenario.linked {
				if err := os.Symlink(filepath.Dir(outside), filepath.Join(folder, "version-linked")); err != nil {
					t.Fatal(err)
				}
				target = "version-linked/carson"
			}
			current := filepath.Join(folder, "current")
			if err := os.Remove(current); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(target, current); err != nil {
				t.Fatal(err)
			}

			var out bytes.Buffer
			if code := u.run(nil, &out); code != failed || !strings.Contains(out.String(), scenario.message) {
				t.Fatalf("exit %d, output %q", code, out.String())
			}
			assertBinary(t, installed, "outside binary")
			assertBinary(t, original, testInstalledVersion("5.9.0"))
		})
	}
}

func TestWhenTheActiveBinaryCannotReportItsVersionCarsonLeavesItAlone(t *testing.T) {
	for _, contents := range []string{"not executable", "#!/bin/sh\necho wrong command\n"} {
		t.Run(strings.SplitN(contents, "\n", 2)[0], func(t *testing.T) {
			u, installed := testInstallation(t)
			active := filepath.Join(testStandaloneFolder(u), "version-original/carson")
			if err := os.WriteFile(active, []byte(contents), 0o700); err != nil {
				t.Fatal(err)
			}
			var out bytes.Buffer
			if code := u.run(nil, &out); code != failed || !strings.Contains(out.String(), "cannot read the active Carson version") {
				t.Fatalf("exit %d, output %q", code, out.String())
			}
			assertBinary(t, installed, contents)
		})
	}
}

func TestWhenTheLauncherChangesDuringDownloadCarsonDoesNotOverwriteIt(t *testing.T) {
	u, installed := testInstallation(t)
	name := "carson-5.10.0-" + runtime.GOOS + "-" + runtime.GOARCH
	newBinary := testReleaseExecutable(t, "5.10.0")
	archive := testArchive(t, name+"/carson", newBinary)
	other := filepath.Join(u.env("HOME"), "another-carson")
	if err := os.WriteFile(other, []byte("another update"), 0o700); err != nil {
		t.Fatal(err)
	}
	u.releases = testRelease(t, "v5.10.0", name, archive, fmt.Sprintf("sha256:%x", sha256.Sum256(archive)), func() error {
		return os.Rename(other, installed)
	})

	var out bytes.Buffer
	code := u.run(nil, &out)

	if code != done || !strings.Contains(out.String(), "Updated Carson from 5.9.0 to 5.10.0.") {
		t.Fatalf("exit %d, output %q", code, out.String())
	}
	assertBinary(t, installed, "another update")
	assertBinary(t, filepath.Join(testStandaloneFolder(u), "current"), newBinary)
}

func TestWhenTheStandaloneStoreIsReplacedDuringDownloadCarsonDoesNotChangeTheNewStore(t *testing.T) {
	u, installed := testInstallation(t)
	folder := testStandaloneFolder(u)
	name := "carson-5.10.0-" + runtime.GOOS + "-" + runtime.GOARCH
	archive := testArchive(t, name+"/carson", testReleaseExecutable(t, "5.10.0"))
	previous := "version-original/carson"
	newStore := folder + "-replacement"
	oldStore := folder + "-moved"
	if err := os.MkdirAll(filepath.Dir(filepath.Join(newStore, previous)), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(newStore, previous), []byte(testInstalledVersion("5.11.0")), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(previous, filepath.Join(newStore, "current")); err != nil {
		t.Fatal(err)
	}
	u.releases = testRelease(t, "v5.10.0", name, archive, fmt.Sprintf("sha256:%x", sha256.Sum256(archive)), func() error {
		if err := os.Rename(folder, oldStore); err != nil {
			return err
		}
		return os.Rename(newStore, folder)
	})

	var out bytes.Buffer
	if code := u.run(nil, &out); code != failed || !strings.Contains(out.String(), "the standalone folder moved during the update") {
		t.Fatalf("exit %d, output %q", code, out.String())
	}
	assertBinary(t, installed, testInstalledVersion("5.11.0"))
	assertBinary(t, filepath.Join(oldStore, "current"), testInstalledVersion("5.9.0"))
	assertOnlyOriginalVersion(t, folder)
	assertOnlyOriginalVersion(t, oldStore)
}

func TestWhenThePrivateActiveLinkChangesDuringDownloadCarsonDoesNotSwitchItBack(t *testing.T) {
	u, installed := testInstallation(t)
	folder := testStandaloneFolder(u)
	name := "carson-5.10.0-" + runtime.GOOS + "-" + runtime.GOARCH
	archive := testArchive(t, name+"/carson", testReleaseExecutable(t, "5.10.0"))
	next := "version-newer/carson"
	if err := os.Mkdir(filepath.Dir(filepath.Join(folder, next)), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(folder, next), []byte(testInstalledVersion("5.11.0")), 0o700); err != nil {
		t.Fatal(err)
	}
	replacement := filepath.Join(folder, "other-link")
	if err := os.Symlink(next, replacement); err != nil {
		t.Fatal(err)
	}
	u.releases = testRelease(t, "v5.10.0", name, archive, fmt.Sprintf("sha256:%x", sha256.Sum256(archive)), func() error {
		return os.Rename(replacement, filepath.Join(folder, "current"))
	})

	var out bytes.Buffer
	if code := u.run(nil, &out); code != failed || !strings.Contains(out.String(), "the active version link changed during the update") {
		t.Fatalf("exit %d, output %q", code, out.String())
	}
	assertBinary(t, installed, testInstalledVersion("5.11.0"))
	assertBinary(t, filepath.Join(folder, "version-original/carson"), testInstalledVersion("5.9.0"))
}

func TestWhenACarsonProcessIsOlderThanTheActiveInstallationTheUpdateUsesTheActiveVersion(t *testing.T) {
	u, installed := testInstallation(t)
	folder := testStandaloneFolder(u)
	next := "version-newer/carson"
	if err := os.Mkdir(filepath.Join(folder, "version-newer"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(folder, next), []byte(testInstalledVersion("5.10.0")), 0o700); err != nil {
		t.Fatal(err)
	}
	current := filepath.Join(folder, "current")
	if err := os.Remove(current); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(next, current); err != nil {
		t.Fatal(err)
	}
	u.executable = func() (string, error) { return filepath.Join(folder, "version-original/carson"), nil }
	u.releases = testRelease(t, "v5.9.0", "", nil, "", nil)

	var out bytes.Buffer
	code := u.run(nil, &out)

	if code != done || !strings.Contains(out.String(), "Installed Carson: 5.10.0; latest stable release: 5.9.0.") {
		t.Fatalf("exit %d, output %q", code, out.String())
	}
	assertBinary(t, installed, testInstalledVersion("5.10.0"))
}

func TestWhenAnotherUpdateOwnsTheInstallationCarsonDoesNotStartASecondUpdate(t *testing.T) {
	u, installed := testInstallation(t)
	name := "carson-5.10.0-" + runtime.GOOS + "-" + runtime.GOARCH
	newBinary := testReleaseExecutable(t, "5.10.0")
	archive := testArchive(t, name+"/carson", newBinary)
	second := u
	second.releases = testRelease(t, "v5.9.0", "", nil, "", nil)
	u.releases = testRelease(t, "v5.10.0", name, archive, fmt.Sprintf("sha256:%x", sha256.Sum256(archive)), func() error {
		var out bytes.Buffer
		if code := second.run(nil, &out); code != refused || !strings.Contains(out.String(), "another Carson update is running") {
			return fmt.Errorf("concurrent update: exit %d, output %q", code, out.String())
		}
		return nil
	})

	var out bytes.Buffer
	if code := u.run(nil, &out); code != done {
		t.Fatalf("exit %d, output %q", code, out.String())
	}
	assertBinary(t, installed, newBinary)
}

func testInstallation(t *testing.T) (updater, string) {
	t.Helper()
	home := t.TempDir()
	installed := filepath.Join(home, ".local", "bin", "carson")
	if err := os.MkdirAll(filepath.Dir(installed), 0o700); err != nil {
		t.Fatal(err)
	}
	u := updater{env: environment{"HOME": home}.get, executable: func() (string, error) { return installed, nil }}
	folder := testStandaloneFolder(u)
	original := "version-original/carson"
	if err := os.MkdirAll(filepath.Join(folder, "version-original"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(folder, original), []byte(testInstalledVersion("5.9.0")), 0o700); err != nil {
		t.Fatal(err)
	}
	current := filepath.Join(folder, "current")
	if err := os.Symlink(original, current); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(current, installed); err != nil {
		t.Fatal(err)
	}
	return u, installed
}

func testStandaloneFolder(u updater) string {
	return filepath.Join(u.env("HOME"), ".local", "share", "carson")
}

func testInstalledVersion(version string) string {
	return "#!/bin/sh\nprintf '%s\\n' '" + Badge + " carson " + version + "'\n"
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

// bin/release runs the tests before publishing. Exercise the real command built and packed the same way as the native release.
func testPackagedRelease(t *testing.T, name string) ([]byte, string) {
	t.Helper()
	out := t.TempDir()
	staging := filepath.Join(out, name)
	if err := os.Mkdir(staging, 0o755); err != nil {
		t.Fatal(err)
	}
	binary := filepath.Join(staging, "carson")
	build := exec.Command("go", "build", "-trimpath", "-ldflags", "-s -w", "-o", binary, ".")
	build.Env = append(os.Environ(), "CGO_ENABLED=0")
	if output, err := build.CombinedOutput(); err != nil {
		t.Fatalf("build release executable: %v\n%s", err, output)
	}
	for _, file := range []string{"README.md", "LICENSE"} {
		contents, err := os.ReadFile(file)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(staging, file), contents, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if output, err := exec.Command("bash", "bin/release-archive.bash", out, name).CombinedOutput(); err != nil {
		t.Fatalf("package release executable: %v\n%s", err, output)
	}
	archive, err := os.ReadFile(filepath.Join(out, name+".tar.gz"))
	if err != nil {
		t.Fatal(err)
	}
	contents, err := os.ReadFile(binary)
	if err != nil {
		t.Fatal(err)
	}
	return archive, string(contents)
}

func testReleaseThroughAssetRedirect(t *testing.T, tag, name string, archive []byte) releaseSource {
	t.Helper()
	const assets = "release-assets.githubusercontent.com"
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/latest":
			fmt.Fprintf(w, `{"tag_name":%q,"assets":[{"name":%q,"digest":"sha256:%x"}]}`, tag, name+".tar.gz", sha256.Sum256(archive))
		case r.URL.Path == "/download/"+tag+"/"+name+".tar.gz":
			redirectTo(w, "https://"+assets+"/archive")
		case r.Host == assets && r.URL.Path == "/archive":
			w.Write(archive)
		default:
			t.Errorf("unexpected TLS release request: %s %s", r.Host, r.URL.Path)
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(server.Close)
	client := server.Client()
	client.CheckRedirect = githubRedirect
	transport := client.Transport.(*http.Transport)
	address := server.Listener.Addr().String()
	host, _, err := net.SplitHostPort(address)
	if err != nil {
		t.Fatal(err)
	}
	// Both test hosts are served by the same local TLS server and checked against its certificate, not by the Internet.
	transport.TLSClientConfig.ServerName = host
	transport.DialContext = func(ctx context.Context, network, destination string) (net.Conn, error) {
		if destination != address && destination != assets+":443" {
			return nil, fmt.Errorf("unexpected TLS release destination: %s", destination)
		}
		return new(net.Dialer).DialContext(ctx, network, address)
	}
	return releaseSource{client: client, latest: server.URL + "/latest", downloads: server.URL + "/download/"}
}

func testReleaseExecutable(t *testing.T, version string) string {
	t.Helper()
	return testNativeRelease(t, version, Badge+" carson update     update the standalone installation")
}

func testNativeRelease(t *testing.T, version, help string) string {
	t.Helper()
	dir := t.TempDir()
	source := filepath.Join(dir, "main.go")
	binary := filepath.Join(dir, "carson")
	program := "package main\nimport (\"fmt\"; \"os\")\nfunc main() { if os.Args[1] == \"--help\" { fmt.Println(" + strconv.Quote(help) + "); return }; fmt.Println(" + strconv.Quote(Badge+" carson "+version) + ") }\n"
	if err := os.WriteFile(source, []byte(program), 0o600); err != nil {
		t.Fatal(err)
	}
	if output, err := exec.Command("go", "build", "-o", binary, source).CombinedOutput(); err != nil {
		t.Fatalf("build test executable: %v\n%s", err, output)
	}
	contents, err := os.ReadFile(binary)
	if err != nil {
		t.Fatal(err)
	}
	return string(contents)
}

func testArchive(t *testing.T, name, contents string) []byte {
	t.Helper()
	return testArchiveEntry(t, &tar.Header{Name: name, Mode: 0o755, Size: int64(len(contents)), Typeflag: tar.TypeReg}, contents)
}

func testArchiveEntry(t *testing.T, header *tar.Header, contents string) []byte {
	t.Helper()
	var archive bytes.Buffer
	compressed := gzip.NewWriter(&archive)
	entries := tar.NewWriter(compressed)
	if err := entries.WriteHeader(header); err != nil {
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
	assertBinary(t, installed, testInstalledVersion("5.9.0"))
	current, err := os.Readlink(installed)
	if err != nil {
		t.Fatal(err)
	}
	assertOnlyOriginalVersion(t, filepath.Dir(current))
}

func assertOnlyOriginalVersion(t *testing.T, folder string) {
	t.Helper()
	entries, err := os.ReadDir(folder)
	if err != nil || len(entries) != 2 || entries[0].Name() != "current" || entries[1].Name() != "version-original" {
		t.Fatalf("unexpected files in the installation folder: %v, %v", entries, err)
	}
}

func assertBinary(t *testing.T, installed, want string) {
	t.Helper()
	contents, err := os.ReadFile(installed)
	if err != nil || string(contents) != want {
		t.Fatalf("%s has unexpected contents (%d bytes, wanted %d): %v", installed, len(contents), len(want), err)
	}
	info, err := os.Stat(installed)
	if err != nil || info.Mode().Perm() != 0o700 {
		t.Fatalf("%s did not keep its executable permissions: %v, %v", installed, info, err)
	}
}
