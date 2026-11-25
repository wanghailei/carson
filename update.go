package main

import (
	"crypto/rand"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
)

// updater updates only the private standalone installation set up by the user. It does not look at the repository or rewrite a
// launcher on PATH, even if that launcher was the way this process got here.
type updater struct {
	env        func(string) string
	executable func() (string, error)
	releases   releaseSource
}

func (u updater) run(args []string, out io.Writer) int {
	if len(args) != 0 {
		fmt.Fprintln(out, "Not updated: this command takes no arguments. Run carson update without arguments.")
		return refused
	}
	folder, err := u.installation()
	if err != nil {
		fmt.Fprintf(out, "Not updated: %s\n", err)
		return codeOf(err)
	}
	if err := u.upgrade(folder, out); err != nil {
		fmt.Fprintf(out, "Not updated: %s. Carson did not switch versions. Run carson update again once that is cleared.\n", err)
		return codeOf(err)
	}
	return done
}

func (u updater) upgrade(folder string, out io.Writer) error {
	root, err := os.OpenRoot(folder)
	if err != nil {
		return fmt.Errorf("cannot open the standalone installation: %w", err)
	}
	defer root.Close()
	lock, err := lockInstallation(root)
	if err != nil {
		return err
	}
	defer lock.Close()
	// The running process may be older than the version already selected. Check the active binary under the installation lock.
	previous, err := activeBinary(root)
	if err != nil {
		return err
	}
	installed, err := binaryVersion(filepath.Join(folder, previous))
	if err != nil {
		return fmt.Errorf("cannot read the active Carson version: %w", err)
	}
	if err := sameInstallation(root); err != nil {
		return err
	}
	current, err := parseReleaseVersion(installed)
	if err != nil {
		return err
	}
	latest, err := u.releases.latestRelease()
	if err != nil {
		return err
	}
	if slices.Compare(latest.version[:], current[:]) <= 0 {
		fmt.Fprintf(out, "No update needed. Installed Carson: %s; latest stable release: %s.\n", installed, latest.number())
		return nil
	}
	download, err := u.releases.download(latest)
	if err != nil {
		return err
	}
	if err := activateRelease(root, previous, download); err != nil {
		return err
	}
	fmt.Fprintf(out, "Updated Carson from %s to %s.\nPrevious binary kept at %s\n", installed, latest.number(), filepath.Join(folder, previous))
	return nil
}

func (u updater) installation() (string, error) {
	path, err := u.executable()
	if err != nil {
		return "", fmt.Errorf("cannot find the running Carson binary (%w). Reinstall Carson from %s/releases", err, carsonGitHub)
	}
	path, err = filepath.EvalSymlinks(path)
	if err != nil {
		return "", fmt.Errorf("cannot resolve the running Carson binary (%w). Reinstall Carson from %s/releases", err, carsonGitHub)
	}
	if u.miseInstallation(path) {
		return "", refuse(refused, "mise manages this installation. Run mise upgrade --bump github:wanghailei/carson instead.")
	}
	if strings.Contains(path, "/Cellar/carson/") {
		return "", refuse(refused, "Homebrew manages this installation. Run brew upgrade carson instead.")
	}
	home := u.env("HOME")
	if !filepath.IsAbs(home) {
		return "", refuse(refused, "HOME does not name an absolute folder. Set HOME and run carson update again.")
	}
	folder, err := filepath.EvalSymlinks(filepath.Join(home, ".local", "share", "carson"))
	if err == nil {
		relative, err := filepath.Rel(folder, path)
		if err == nil && standaloneBinary(relative) {
			return folder, nil
		}
	}
	return "", refuse(refused, "this copy is not set up for standalone updates. Use the method you installed Carson with, or see %s#updating-carson for standalone setup.", carsonGitHub)
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

func standaloneBinary(relative string) bool {
	folder, binary, found := strings.Cut(relative, string(filepath.Separator))
	return found && binary == "carson" && strings.HasPrefix(folder, "version-") && folder != "version-"
}

func lockInstallation(root *os.Root) (*os.File, error) {
	directory, err := root.Open(".")
	if err != nil {
		return nil, fmt.Errorf("cannot open the standalone installation: %w", err)
	}
	info, err := directory.Stat()
	if err != nil || !info.IsDir() || !ownedByUser(info) || info.Mode().Perm()&0o077 != 0 {
		directory.Close()
		return nil, refuse(refused, "the standalone folder is not private and owned by you; check %s", root.Name())
	}
	// All versions lock the same directory, not the binary or pointer that changes when an update succeeds.
	if err := syscall.Flock(int(directory.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		directory.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) {
			return nil, refuse(refused, "another Carson update is running; let it finish first")
		}
		return nil, fmt.Errorf("cannot lock the standalone installation: %w", err)
	}
	return directory, nil
}

func ownedByUser(info os.FileInfo) bool {
	return info.Sys().(*syscall.Stat_t).Uid == uint32(os.Geteuid())
}

// Writes use the held directory, not its spelling. The name still has to point there when executing a binary by path.
func sameInstallation(root *os.Root) error {
	opened, openErr := root.Stat(".")
	atPath, pathErr := os.Stat(root.Name())
	if openErr != nil || pathErr != nil || !os.SameFile(opened, atPath) {
		return fmt.Errorf("the standalone folder moved during the update")
	}
	return nil
}

func activeBinary(root *os.Root) (string, error) {
	if err := sameInstallation(root); err != nil {
		return "", err
	}
	target, err := root.Readlink("current")
	if err != nil || !standaloneBinary(target) {
		return "", fmt.Errorf("the standalone installation has no valid active version at %s", root.Name())
	}
	versionFolder, err := root.Lstat(filepath.Dir(target))
	if err != nil || !versionFolder.IsDir() {
		return "", fmt.Errorf("the active version does not point to a version folder in the standalone installation")
	}
	info, err := root.Lstat(target)
	if err != nil || !info.Mode().IsRegular() || !ownedByUser(info) {
		return "", fmt.Errorf("the active version is not a regular binary you own")
	}
	return target, nil
}

func activateRelease(root *os.Root, previous string, download releaseDownload) error {
	if err := sameInstallation(root); err != nil {
		return err
	}
	stage := "version-" + download.version + "-" + rand.Text()
	if err := root.Mkdir(stage, 0o700); err != nil {
		return fmt.Errorf("cannot stage the release in the standalone folder: %w", err)
	}
	activated := false
	defer func() {
		if !activated {
			root.RemoveAll(stage)
		}
	}()
	binary := filepath.Join(stage, "carson")
	if err := download.stage(root, binary); err != nil {
		return err
	}
	pending := filepath.Join(stage, "current")
	if err := root.Symlink(binary, pending); err != nil {
		return fmt.Errorf("cannot prepare the active version link: %w", err)
	}
	if err := sameInstallation(root); err != nil {
		return err
	}
	if target, err := root.Readlink("current"); err != nil || target != previous {
		return fmt.Errorf("the active version link changed during the update")
	}
	// Only this private symlink is replaced. The launcher and every previously installed executable keep their own paths.
	if err := root.Rename(pending, "current"); err != nil {
		return fmt.Errorf("cannot activate the release: %w", err)
	}
	activated = true
	return nil
}
