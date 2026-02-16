#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
butler_bin="$repo_root/bin/butler"

run_butler() {
  ruby "$butler_bin" "$@"
}

exit_text() {
  case "${1:-}" in
    0) echo "OK" ;;
    1) echo "runtime/configuration error" ;;
    2) echo "policy blocked (hard stop)" ;;
    *) echo "unknown" ;;
  esac
}

expect_exit() {
  expected="$1"
  description="$2"
  shift 2

  set +e
  "$@"
  actual="$?"
  set -e

  if [[ "$actual" -ne "$expected" ]]; then
    echo "FAIL: $description" >&2
    echo "expected: $expected - $(exit_text "$expected")" >&2
    echo "actual:   $actual - $(exit_text "$actual")" >&2
    exit 1
  fi

  echo "PASS: $description ($actual - $(exit_text "$actual"))"
}

tmp_base="$repo_root/tmp"
mkdir -p "$tmp_base"
tmp_root="$(mktemp -d "$tmp_base/butler-ci.XXXXXX")"
cleanup() {
  rm -rf "$tmp_root"
}
trap cleanup EXIT

remote_repo="$tmp_root/remote.git"
work_repo="$tmp_root/work"

git init --bare "$remote_repo" >/dev/null
git clone "$remote_repo" "$work_repo" >/dev/null

ruby_major="$(ruby -e 'print RUBY_VERSION.split(".").first.to_i')"
if [[ "$ruby_major" -lt 4 ]]; then
  echo "FAIL: Ruby >= 4.0 is required; found $(ruby -v)" >&2
  exit 1
fi

cd "$work_repo"
git switch -c main >/dev/null
git config user.name "Butler CI"
git config user.email "butler-ci@example.com"
git remote rename origin github

printf "# Butler Smoke Repo\n" > README.md
git add README.md
git commit -m "initial commit" >/dev/null
git push -u github main >/dev/null

expect_exit 2 "check blocks before hooks are installed" run_butler check
expect_exit 0 "sync keeps local main aligned to github/main" run_butler sync
expect_exit 0 "hook installs required hooks" run_butler hook
expect_exit 0 "check passes after hook install" run_butler check

expect_exit 2 "template check reports drift when shared blocks are missing" run_butler template check
expect_exit 0 "template apply writes managed shared blocks" run_butler template apply
expect_exit 0 "template check passes after apply" run_butler template check
expect_exit 0 "common alias remains compatible (check)" run_butler common check

git switch -c codex/tool/stale-prune >/dev/null
git push -u github codex/tool/stale-prune >/dev/null
git switch main >/dev/null
git push github --delete codex/tool/stale-prune >/dev/null

expect_exit 0 "prune deletes stale local branches safely" run_butler prune
if git show-ref --verify --quiet refs/heads/codex/tool/stale-prune; then
  echo "FAIL: stale branch still exists after prune" >&2
  exit 1
fi
echo "PASS: stale branch removed locally"

expect_exit 0 "audit completes without a local hard block" run_butler audit

printf 'git: [\n' > .butler.yml
expect_exit 1 "invalid YAML returns configuration/runtime error" run_butler check

echo "Butler smoke tests passed."
