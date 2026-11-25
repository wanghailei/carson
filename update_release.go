package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
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

func (s releaseSource) download(release githubRelease) (archive []byte, name string, err error) {
	name = fmt.Sprintf("carson-%s-%s-%s", release.number(), runtime.GOOS, runtime.GOARCH)
	filename := name + ".tar.gz"
	for _, asset := range release.Assets {
		if asset.Name != filename {
			continue
		}
		digest, tagged := strings.CutPrefix(asset.Digest, "sha256:")
		expected, err := hex.DecodeString(digest)
		if !tagged || err != nil || len(expected) != sha256.Size {
			return nil, "", fmt.Errorf("GitHub has no valid SHA-256 digest for %s", filename)
		}
		archive, err := s.fetch(s.downloads+release.Tag+"/"+filename, maxUpdateArchive)
		if err != nil {
			return nil, "", fmt.Errorf("cannot download %s: %w", filename, err)
		}
		actual := sha256.Sum256(archive)
		if !bytes.Equal(actual[:], expected) {
			return nil, "", fmt.Errorf("%s does not match its SHA-256 digest", filename)
		}
		return archive, name, nil
	}
	return nil, "", fmt.Errorf("Carson %s has no build for %s/%s", release.number(), runtime.GOOS, runtime.GOARCH)
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
