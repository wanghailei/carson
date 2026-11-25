package main

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
)

// updater updates the running standalone installation, without looking at the current repository or searching PATH for another copy.
type updater struct {
	current    string
	env        func(string) string
	executable func() (string, error)
	releases   releaseSource
}

func (u updater) run(args []string, out io.Writer) int {
	if len(args) != 0 {
		fmt.Fprintln(out, "Not updated: this command takes no arguments. Run carson update without arguments.")
		return refused
	}
	path, installed, err := u.installation()
	if err != nil {
		fmt.Fprintf(out, "Not updated: %s\n", err)
		return codeOf(err)
	}
	version, backup, err := u.upgrade(path, installed)
	if err != nil {
		fmt.Fprintf(out, "Not updated: %s. Carson did not replace the installed binary. Run carson update again once that is cleared, or download a release from %s/releases.\n", err, carsonGitHub)
		return codeOf(err)
	}
	if backup == "" {
		fmt.Fprintf(out, "No update needed. Installed Carson: %s; latest stable release: %s.\n", u.current, version)
		return done
	}
	fmt.Fprintf(out, "Updated Carson from %s to %s.\nPrevious binary kept at %s\n", u.current, version, backup)
	return done
}

func (u updater) upgrade(path string, installed os.FileInfo) (version, backup string, err error) {
	current, err := parseReleaseVersion(u.current)
	if err != nil {
		return "", "", err
	}
	latest, err := u.releases.latestRelease()
	if err != nil {
		return "", "", err
	}
	if slices.Compare(latest.version[:], current[:]) <= 0 {
		return latest.number(), "", nil
	}
	download, err := u.releases.download(latest)
	if err != nil {
		return "", "", err
	}
	backup, err = replaceInstallation(path, installed, download)
	return latest.number(), backup, err
}

func (u updater) installation() (string, os.FileInfo, error) {
	path, err := u.executable()
	if err != nil {
		return "", nil, fmt.Errorf("cannot find the running Carson binary (%w). Reinstall Carson from %s/releases", err, carsonGitHub)
	}
	path, err = filepath.EvalSymlinks(path)
	if err != nil {
		return "", nil, fmt.Errorf("cannot resolve the running Carson binary (%w). Reinstall Carson from %s/releases", err, carsonGitHub)
	}
	if u.miseInstallation(path) {
		return "", nil, refuse(refused, "mise manages this installation. Run mise upgrade --bump github:wanghailei/carson instead.")
	}
	if strings.Contains(path, "/Cellar/carson/") {
		return "", nil, refuse(refused, "Homebrew manages this installation. Run brew upgrade carson instead.")
	}
	// A writable directory alone is not evidence of a standalone install. Use only the normal personal bin directories, and don't
	// follow a link out of them to replace what might be a package manager's copy.
	home, err := filepath.EvalSymlinks(u.env("HOME"))
	if err != nil || !filepath.IsAbs(home) || (path != filepath.Join(home, ".local", "bin", "carson") && path != filepath.Join(home, "bin", "carson")) {
		return "", nil, refuse(refused, "Carson cannot confirm a standalone install at %s; use the method you installed Carson with.", path)
	}
	info, err := os.Lstat(path)
	if err != nil {
		return "", nil, fmt.Errorf("cannot read the installed binary (%w). Run carson update again once that is cleared", err)
	}
	if !info.Mode().IsRegular() || info.Sys().(*syscall.Stat_t).Uid != uint32(os.Geteuid()) {
		return "", nil, refuse(refused, "Carson only updates a standalone binary you own; use the method you installed Carson with.")
	}
	return path, info, nil
}

func (u updater) miseInstallation(path string) bool {
	data := u.env("MISE_DATA_DIR")
	if data == "" {
		root := u.env("XDG_DATA_HOME")
		if root == "" {
			root = filepath.Join(u.env("HOME"), ".local", "share")
		}
		data = filepath.Join(root, "mise")
	}
	installs, err := filepath.EvalSymlinks(filepath.Join(data, "installs"))
	return err == nil && filepath.IsAbs(installs) && strings.HasPrefix(path, installs+string(filepath.Separator))
}

func replaceInstallation(path string, installed os.FileInfo, download releaseDownload) (backup string, err error) {
	stage, err := os.MkdirTemp(filepath.Dir(path), ".carson-update-")
	if err != nil {
		return "", fmt.Errorf("cannot stage an update beside the installed binary: %w", err)
	}
	defer func() {
		if backup == "" {
			os.RemoveAll(stage)
		}
	}()
	candidate := filepath.Join(stage, "carson")
	if err := download.stage(candidate, installed.Mode().Perm()); err != nil {
		return "", err
	}

	// Lock the original inode so two Carson processes cannot both replace it. A process that opened it before another update
	// replaced it will see the changed path after acquiring the lock, and leave the new installation alone.
	original, err := os.Open(path)
	if err != nil {
		return "", fmt.Errorf("cannot open the installed binary: %w", err)
	}
	defer original.Close()
	if err := syscall.Flock(int(original.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		return "", fmt.Errorf("cannot lock the installed binary: %w", err)
	}
	opened, openErr := original.Stat()
	atPath, pathErr := os.Lstat(path)
	if openErr != nil || pathErr != nil || !os.SameFile(installed, opened) || !os.SameFile(opened, atPath) {
		return "", fmt.Errorf("the Carson installation changed while downloading; run the installed version to check it")
	}
	saved := filepath.Join(stage, "carson.previous")
	if err := os.Link(path, saved); err != nil {
		return "", fmt.Errorf("cannot keep a copy of the previous binary: %w", err)
	}
	// Staging beside the old binary makes this one atomic rename. It leaves either the old binary or the fully written new one.
	if err := os.Rename(candidate, path); err != nil {
		return "", fmt.Errorf("cannot replace the installed binary: %w", err)
	}
	return saved, nil
}
