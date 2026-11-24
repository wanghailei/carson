#!/usr/bin/env bash
# Pack one release archive and check its layout before it can be published.
set -euo pipefail

out=$1
name=$2
members=("$name/" "$name/carson" "$name/LICENSE" "$name/README.md")
# mise only strips the outer directory automatically if it is the sole top-level entry.
# Disable macOS AppleDouble metadata and pack only the intended files, even in a reused staging directory.
COPYFILE_DISABLE=1 tar --format=ustar --no-recursion -C "$out" -czf "$out/$name.tar.gz" "${members[@]}"
contents="$(tar -tzf "$out/$name.tar.gz")"
if [[ "$contents" != "$(printf '%s\n' "${members[@]}")" ]]; then
	printf 'Not released: %s.tar.gz must contain only carson, LICENSE and README.md inside %s. Check tar and rerun.\n' "$name" "$name" >&2
	exit 2
fi
