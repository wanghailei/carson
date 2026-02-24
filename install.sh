#!/usr/bin/env bash
# Overview:
# - Installs Carson for the current user from a local checkout or a trusted fallback clone.
# - Builds the gem into an ephemeral work directory so source trees stay clean.
set -euo pipefail

fail() {
	echo "$1" >&2
	exit 1
}

require_command() {
	if ! command -v "$1" >/dev/null 2>&1; then
		fail "Missing required command: $1"
	fi
}

ruby_supported() {
	ruby -e 'major, minor, = RUBY_VERSION.split( "." ).map( &:to_i ); exit( (major > 4 || ( major == 4 && minor >= 0 )) ? 0 : 1 )'
}

require_command git
require_command ruby

if ! ruby_supported; then
	fail "Carson install error: Ruby >= 4.0 is required (current: $(ruby -e 'print RUBY_VERSION'))."
fi

require_command gem

home_root="${HOME:-}"
if [[ -z "$home_root" || "${home_root#/}" == "$home_root" ]]; then
	fail "Carson install error: HOME must be set to an absolute path."
fi

tmp_root="$home_root/.cache"
if ! mkdir -p "$tmp_root" 2>/dev/null; then
	tmp_root="/tmp"
	mkdir -p "$tmp_root"
fi

work_dir="$(mktemp -d "${tmp_root%/}/carson-install-XXXXXX")"
cleanup() {
	rm -rf "$work_dir"
}
trap cleanup EXIT

script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")"
script_dir="$(dirname "$script_path")"

source_dir=""
source_label=""
# Prefer local source when this script is executed from a Carson checkout.
if [[ -f "$script_dir/carson.gemspec" && -f "$script_dir/VERSION" ]]; then
	source_dir="$script_dir"
	source_label="$script_dir"
else
	source_dir="$work_dir/source"
	if ! git clone --depth 1 "https://github.com/wanghailei/carson.git" "$source_dir"; then
		fail "Carson install error: failed to clone https://github.com/wanghailei/carson.git."
	fi
	source_label="wanghailei/carson@main"
fi

cd "$source_dir"

if [[ ! -f VERSION ]]; then
	fail "Carson install error: VERSION file is missing in source directory $source_dir."
fi
version="$(cat VERSION)"
if [[ -z "$version" ]]; then
	fail "Carson install error: VERSION file is empty in source directory $source_dir."
fi

# Build into the ephemeral installer workspace to avoid leaving repo-root artefacts.
gem_file="$work_dir/carson-${version}.gem"
if ! gem build carson.gemspec --output "$gem_file" >/dev/null; then
	fail "Carson install error: failed to build carson.gemspec."
fi

if [[ ! -f "$gem_file" ]]; then
	fail "Carson install error: expected gem file '$gem_file' was not created."
fi

if ! gem install --user-install --local "$gem_file"; then
	fail "Carson install error: failed to install gem '$gem_file'."
fi

user_bin="$(ruby -e 'print Gem.user_dir')/bin"
if [[ ! -x "$user_bin/carson" ]]; then
	fail "Carson install error: expected executables not found in $user_bin."
fi

home_bin="$home_root/.local/bin"
mkdir -p "$home_bin"

carson_link="$home_bin/carson"
if [[ -e "$carson_link" && ! -L "$carson_link" ]]; then
	fail "Carson install error: refusing to overwrite non-symlink at $carson_link."
fi

ln -sfn "$user_bin/carson" "$carson_link"

echo "Installed Carson ${version} from ${source_label}"
echo "Launcher linked: $carson_link"
echo "If \`carson\` is not found, add \`$home_bin\` to PATH."
echo "Post-upgrade step (per governed repository):"
echo "  carson hook && carson check"
echo "This aligns core.hooksPath to ~/.carson/hooks/${version}."
