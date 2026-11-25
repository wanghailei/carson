package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"debug/buildinfo"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"
)

const carsonGitHub = "https://github.com/wanghailei/carson"
const maxUpdateArchive = 32 << 20

type releaseSource struct {
	client            *http.Client
	latest, downloads string
}

func githubReleases() releaseSource {
	return releaseSource{
		client: &http.Client{Timeout: 45 * time.Second, CheckRedirect: githubRedirect},
		latest: "https://api.github.com/repos/wanghailei/carson/releases/latest", downloads: carsonGitHub + "/releases/download/",
	}
}

func githubRedirect(request *http.Request, via []*http.Request) error {
	// Release downloads are redirected to GitHub's asset store. Never accept a non-HTTPS or third-party destination.
	host := request.URL.Hostname()
	if len(via) >= 5 || request.URL.Scheme != "https" || (host != "github.com" && host != "api.github.com" && host != "release-assets.githubusercontent.com") {
		return errors.New("unexpected redirect from GitHub")
	}
	return nil
}

type githubRelease struct {
	Tag        string `json:"tag_name"`
	Draft      bool   `json:"draft"`
	Prerelease bool   `json:"prerelease"`
	Assets     []struct {
		Name   string `json:"name"`
		Digest string `json:"digest"`
	} `json:"assets"`
	version [3]uint64
}

func (r githubRelease) number() string { return strings.TrimPrefix(r.Tag, "v") }

func (s releaseSource) latestRelease() (githubRelease, error) {
	var release githubRelease
	body, err := s.fetch(s.latest, 1<<20)
	if err != nil {
		return release, fmt.Errorf("cannot check the latest Carson release on GitHub: %w", err)
	}
	if err := json.Unmarshal(body, &release); err != nil {
		return release, fmt.Errorf("cannot read GitHub's latest release information: %w", err)
	}
	release.version, err = parseReleaseVersion(release.number())
	if err != nil || !strings.HasPrefix(release.Tag, "v") || release.Draft || release.Prerelease {
		return release, fmt.Errorf("GitHub's latest release tag %q is not a stable Carson version", release.Tag)
	}
	return release, nil
}

func parseReleaseVersion(number string) ([3]uint64, error) {
	var version [3]uint64
	parts := strings.Split(number, ".")
	if len(parts) != len(version) {
		return version, fmt.Errorf("%q is not a stable Carson version", number)
	}
	for i, part := range parts {
		value, err := strconv.ParseUint(part, 10, 64)
		if err != nil || strconv.FormatUint(value, 10) != part {
			return version, fmt.Errorf("%q is not a stable Carson version", number)
		}
		version[i] = value
	}
	return version, nil
}

type releaseDownload struct {
	archive []byte
	member  string
	version string
}

func (s releaseSource) download(release githubRelease) (releaseDownload, error) {
	name := fmt.Sprintf("carson-%s-%s-%s", release.number(), runtime.GOOS, runtime.GOARCH)
	filename := name + ".tar.gz"
	for _, asset := range release.Assets {
		if asset.Name != filename {
			continue
		}
		digest, tagged := strings.CutPrefix(asset.Digest, "sha256:")
		expected, err := hex.DecodeString(digest)
		if !tagged || err != nil || len(expected) != sha256.Size {
			return releaseDownload{}, fmt.Errorf("GitHub has no valid SHA-256 digest for %s", filename)
		}
		archive, err := s.fetch(s.downloads+release.Tag+"/"+filename, maxUpdateArchive)
		if err != nil {
			return releaseDownload{}, fmt.Errorf("cannot download %s: %w", filename, err)
		}
		actual := sha256.Sum256(archive)
		if !bytes.Equal(actual[:], expected) {
			return releaseDownload{}, fmt.Errorf("%s does not match its SHA-256 digest", filename)
		}
		return releaseDownload{archive: archive, member: name + "/carson", version: release.number()}, nil
	}
	return releaseDownload{}, fmt.Errorf("Carson %s has no build for %s/%s", release.number(), runtime.GOOS, runtime.GOARCH)
}

func (d releaseDownload) stage(root *os.Root, path string) error {
	file, err := root.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	defer file.Close()
	if err := extractReleaseBinary(file, d.archive, d.member); err != nil {
		return err
	}
	if err := file.Chmod(0o700); err != nil {
		return err
	}
	if err := file.Sync(); err != nil {
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	if err := sameInstallation(root); err != nil {
		return err
	}
	return d.checkExecutable(filepath.Join(root.Name(), path))
}

func (d releaseDownload) checkExecutable(path string) error {
	info, err := buildinfo.ReadFile(path)
	if err != nil {
		return errors.New("the release member is not a native Go executable")
	}
	var operatingSystem, architecture string
	for _, setting := range info.Settings {
		switch setting.Key {
		case "GOOS":
			operatingSystem = setting.Value
		case "GOARCH":
			architecture = setting.Value
		}
	}
	if operatingSystem != runtime.GOOS || architecture != runtime.GOARCH {
		return fmt.Errorf("the release binary is not built for %s/%s", runtime.GOOS, runtime.GOARCH)
	}
	// A matching archive digest does not prove that the packaged command runs or reports the published version.
	if version, err := binaryVersion(path); err != nil || version != d.version {
		return fmt.Errorf("the release binary did not report the expected version %s", d.version)
	}
	help, err := runBinary(path, "--help")
	if err == nil {
		for _, line := range strings.Split(string(help), "\n") {
			if strings.HasPrefix(line, Badge+" carson update ") {
				return nil
			}
		}
	}
	return errors.New("the release binary does not offer carson update")
}

func runBinary(path, option string) ([]byte, error) {
	deadline, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	command := exec.CommandContext(deadline, path, option)
	command.Dir = filepath.Dir(path)
	return command.Output()
}

func binaryVersion(path string) (string, error) {
	output, err := runBinary(path, "--version")
	if err != nil {
		return "", err
	}
	version, recognised := strings.CutPrefix(strings.TrimSpace(string(output)), Badge+" carson ")
	if !recognised {
		return "", errors.New("the binary did not report a Carson version")
	}
	return version, nil
}

func (s releaseSource) fetch(address string, limit int64) ([]byte, error) {
	request, err := http.NewRequest(http.MethodGet, address, nil)
	if err != nil {
		return nil, err
	}
	request.Header.Set("User-Agent", "carson/"+Version)
	response, err := s.client.Do(request)
	if err != nil {
		// The HTTP client can include a signed asset link in an error; report the cause without that URL.
		var requestError *url.Error
		if errors.As(err, &requestError) {
			return nil, requestError.Err
		}
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("GitHub returned HTTP %d", response.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(body)) > limit {
		return nil, errors.New("GitHub's response was larger than expected")
	}
	return body, nil
}

func extractReleaseBinary(destination io.Writer, archive []byte, member string) error {
	compressed, err := gzip.NewReader(bytes.NewReader(archive))
	if err != nil {
		return fmt.Errorf("cannot read the release archive: %w", err)
	}
	defer compressed.Close()
	entries := tar.NewReader(io.LimitReader(compressed, maxUpdateArchive))
	for {
		entry, err := entries.Next()
		if err == io.EOF {
			return errors.New("the release archive contains no Carson binary")
		}
		if err != nil {
			return fmt.Errorf("cannot read the release archive: %w", err)
		}
		if entry.Name != member {
			continue
		}
		if entry.Typeflag != tar.TypeReg || entry.Size <= 0 || entry.Size > maxUpdateArchive {
			return errors.New("the release archive does not contain a valid regular Carson binary")
		}
		// Only these bytes are extracted, to a destination Carson chose. No archive path or link is written to disk.
		if _, err := io.Copy(destination, entries); err != nil {
			return fmt.Errorf("cannot extract Carson from the release archive: %w", err)
		}
		return nil
	}
}
