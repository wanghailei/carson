#!/usr/bin/env bash
set -euo pipefail

usage() {
	cat <<'USAGE'
Usage:
  script/install_global_carson.sh [options]

Options:
  --version <semver>   Carson gem version to install (default: VERSION file)
  --source <url>       Gem source URL (default: https://rubygems.pkg.github.com/wanghailei)
  --help               Show this message
USAGE
}

require_command() {
	if ! command -v "$1" >/dev/null 2>&1; then
		echo "Missing required command: $1" >&2
		exit 1
	fi
}

version="$(cat "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/VERSION")"
source_url="https://rubygems.pkg.github.com/wanghailei"

while [[ $# -gt 0 ]]; do
	case "$1" in
		--version)
			version="${2:-}"
			shift 2
			;;
		--source)
			source_url="${2:-}"
			shift 2
			;;
		--help|-h)
			usage
			exit 0
			;;
		*)
			echo "Unknown option: $1" >&2
			usage
			exit 1
			;;
	esac
done

require_command ruby
require_command gem

# Keep installer temporary artefacts out of user project paths.
cache_tmp_dir="$HOME/.cache"
mkdir -p "$cache_tmp_dir"
export TMPDIR="$cache_tmp_dir"

if ! ruby -e 'major, minor, = RUBY_VERSION.split( "." ).map( &:to_i ); exit( (major > 4 || ( major == 4 && minor >= 0 )) ? 0 : 1 )'; then
	echo "Carson install error: Ruby >= 4.0 is required (current: $(ruby -e 'print RUBY_VERSION'))." >&2
	exit 1
fi

# Suppress the RubyGems PATH warning — Carson symlinks the executable to
# ~/.carson/bin so the gem bin directory does not need to be in PATH.
gem_stderr_file="$(mktemp "${TMPDIR%/}/carson-gem-stderr-XXXXXX")"
if ! gem install --user-install "carson" -v "$version" --clear-sources --source "$source_url" 2>"$gem_stderr_file"; then
	cat "$gem_stderr_file" >&2
	rm -f "$gem_stderr_file"
	echo "Carson install error: failed to install gem." >&2
	exit 1
fi
grep -v -e "WARNING:.*in your PATH" -e "gem executables.*will not run" "$gem_stderr_file" >&2 || true
rm -f "$gem_stderr_file"

user_bin="$(ruby -e 'print Gem.user_dir')/bin"
mkdir -p "$HOME/.carson/bin"
ln -sf "$user_bin/carson" "$HOME/.carson/bin/carson"

echo "Installed Carson ${version}"
echo "Launcher linked: $HOME/.carson/bin/carson"
echo "Post-upgrade step (per governed repository):"
echo "  carson refresh"
echo "This aligns core.hooksPath to ~/.carson/hooks/${version}."
