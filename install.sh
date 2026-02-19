#!/usr/bin/env bash
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
	fail "Butler install error: Ruby >= 4.0 is required (current: $(ruby -e 'print RUBY_VERSION'))."
fi

require_command gem

home_root="${HOME:-}"
if [[ -z "$home_root" || "${home_root#/}" == "$home_root" ]]; then
	fail "Butler install error: HOME must be set to an absolute path."
fi

tmp_root="$home_root/.cache"
if ! mkdir -p "$tmp_root" 2>/dev/null; then
	tmp_root="/tmp"
	mkdir -p "$tmp_root"
fi

work_dir="$(mktemp -d "${tmp_root%/}/butler-install-XXXXXX")"
cleanup() {
	rm -rf "$work_dir"
}
trap cleanup EXIT

script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")"
script_dir="$(dirname "$script_path")"

source_dir=""
source_label=""
if [[ -f "$script_dir/butler.gemspec" && -f "$script_dir/VERSION" ]]; then
	source_dir="$script_dir"
	source_label="$script_dir"
else
	source_dir="$work_dir/source"
	if ! git clone --depth 1 "https://github.com/wanghailei/butler.git" "$source_dir"; then
		fail "Butler install error: failed to clone https://github.com/wanghailei/butler.git."
	fi
	source_label="wanghailei/butler@main"
fi

cd "$source_dir"

if [[ ! -f VERSION ]]; then
	fail "Butler install error: VERSION file is missing in source directory $source_dir."
fi
version="$(cat VERSION)"
if [[ -z "$version" ]]; then
	fail "Butler install error: VERSION file is empty in source directory $source_dir."
fi

if ! gem build butler.gemspec >/dev/null; then
	fail "Butler install error: failed to build butler.gemspec."
fi

gem_file="butler-to-merge-${version}.gem"
if [[ ! -f "$gem_file" ]]; then
	fail "Butler install error: expected gem file '$gem_file' was not created."
fi

if ! gem install --user-install --local "$gem_file"; then
	fail "Butler install error: failed to install gem '$gem_file'."
fi

user_bin="$(ruby -e 'print Gem.user_dir')/bin"
if [[ ! -x "$user_bin/butler" || ! -x "$user_bin/butler-to-merge" ]]; then
	fail "Butler install error: expected executables not found in $user_bin."
fi

home_bin="$home_root/.local/bin"
mkdir -p "$home_bin"

butler_link="$home_bin/butler"
if [[ -e "$butler_link" && ! -L "$butler_link" ]]; then
	fail "Butler install error: refusing to overwrite non-symlink at $butler_link."
fi

alias_link="$home_bin/butler-to-merge"
if [[ -e "$alias_link" && ! -L "$alias_link" ]]; then
	fail "Butler install error: refusing to overwrite non-symlink at $alias_link."
fi

ln -sfn "$user_bin/butler" "$butler_link"
ln -sfn "$user_bin/butler-to-merge" "$alias_link"

echo "Installed Butler ${version} from ${source_label}"
echo "Launcher linked: $butler_link"
echo "Alias linked: $alias_link"
echo "If \`butler\` is not found, add \`$home_bin\` to PATH."
