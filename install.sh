#!/usr/bin/env bash
set -euo pipefail

require_command() {
	if ! command -v "$1" >/dev/null 2>&1; then
		echo "Missing required command: $1" >&2
		exit 1
	fi
}

ruby_supported() {
	ruby -e 'major, minor, = RUBY_VERSION.split( "." ).map( &:to_i ); exit( (major > 4 || ( major == 4 && minor >= 0 )) ? 0 : 1 )'
}

require_command git
require_command ruby
require_command gem

if ! ruby_supported; then
	echo "Butler install error: Ruby >= 4.0 is required (current: $(ruby -e 'print RUBY_VERSION'))." >&2
	exit 1
fi

tmp_root="${TMPDIR:-/tmp}"
if [[ "${tmp_root#/}" == "$tmp_root" || ! -d "$tmp_root" ]]; then
	tmp_root="/tmp"
fi
work_dir="$(mktemp -d "${tmp_root%/}/butler-install-XXXXXX")"
cleanup() {
	rm -rf "$work_dir"
}
trap cleanup EXIT

source_dir="$work_dir/source"
git clone --depth 1 "https://github.com/wanghailei/butler.git" "$source_dir"

cd "$source_dir"
version="$(cat VERSION)"
gem build butler.gemspec >/dev/null
gem_file="butler-to-merge-${version}.gem"
gem install --user-install --local "$gem_file"

user_bin="$(ruby -e 'print Gem.user_dir')/bin"
mkdir -p "$HOME/.local/bin"
ln -sf "$user_bin/butler" "$HOME/.local/bin/butler"
ln -sf "$user_bin/butler-to-merge" "$HOME/.local/bin/butler-to-merge"

echo "Installed Butler ${version} from wanghailei/butler@main"
echo "Launcher linked: $HOME/.local/bin/butler"
echo "Alias linked: $HOME/.local/bin/butler-to-merge"
echo "If \`butler\` is not found, add \`$HOME/.local/bin\` to PATH."
