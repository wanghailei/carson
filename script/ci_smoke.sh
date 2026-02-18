#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
butler_bin="$repo_root/exe/butler"

run_butler() {
	BUTLER_HOOKS_BASE_PATH="$tmp_root/global-hooks" BUTLER_REPORT_DIR="$tmp_root/reports" ruby "$butler_bin" "$@"
}

run_butler_with_mock_gh() {
	PATH="$mock_bin:$PATH" BUTLER_HOOKS_BASE_PATH="$tmp_root/global-hooks" BUTLER_REPORT_DIR="$tmp_root/reports" ruby "$butler_bin" "$@"
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

tmp_base="${BUTLER_TMP_BASE:-/tmp}"
tmp_root="$(mktemp -d "$tmp_base/butler-ci.XXXXXX")"
cleanup() {
	rm -rf "$tmp_root"
}
trap cleanup EXIT

remote_repo="$tmp_root/remote.git"
work_repo="$tmp_root/work"
run_repo="$tmp_root/run-work"
mock_bin="$tmp_root/mock-bin"

git init --bare "$remote_repo" >/dev/null
git clone "$remote_repo" "$work_repo" >/dev/null
mkdir -p "$mock_bin"

cat > "$mock_bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--version" ]]; then
	echo "gh version mock"
	exit 0
fi

if [[ "${1:-}" == "api" && "${2:-}" == repos/*/pulls ]]; then
	head_filter=""
	page_number="1"
	while [[ "$#" -gt 0 ]]; do
		if [[ "$1" == "-f" ]]; then
			field="${2:-}"
			case "$field" in
				head=*) head_filter="${field#head=}" ;;
				page=*) page_number="${field#page=}" ;;
			esac
			shift 2
		else
			shift
		fi
	done

	if [[ "$page_number" != "1" ]]; then
		echo "[]"
		exit 0
	fi

	if [[ "$head_filter" == "local:codex/tool/stale-prune-squash" ]]; then
		tip_sha="$(git rev-parse --verify codex/tool/stale-prune-squash 2>/dev/null || true)"
		cat <<JSON
[{"number":999,"html_url":"https://github.com/mock/mock-repo/pull/999","merged_at":"2026-02-17T00:00:00Z","head":{"ref":"codex/tool/stale-prune-squash","sha":"$tip_sha"},"base":{"ref":"main"}}]
JSON
		exit 0
	fi

	if [[ "$head_filter" == "local:codex/tool/stale-prune-no-evidence" ]]; then
		cat <<JSON
[{"number":1000,"html_url":"https://github.com/mock/mock-repo/pull/1000","merged_at":"2026-02-17T00:00:00Z","head":{"ref":"codex/tool/stale-prune-no-evidence","sha":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"},"base":{"ref":"main"}}]
JSON
		exit 0
	fi

	echo "[]"
	exit 0
fi

echo "unsupported gh invocation: $*" >&2
exit 1
EOF
chmod +x "$mock_bin/gh"

ruby_major="$(ruby -e 'print RUBY_VERSION.split(".").first.to_i')"
if [[ "$ruby_major" -lt 4 ]]; then
	echo "FAIL: Ruby >= 4.0 is required; found $(ruby -v)" >&2
	exit 1
fi

expected_butler_version="$(cat "$repo_root/VERSION")"
for arg in "version" "--version"; do
	description="version output for '${arg}'"
	actual_version="$(run_butler "$arg")"
	if [[ "$actual_version" != "$expected_butler_version" ]]; then
		echo "FAIL: ${description} mismatch" >&2
		echo "expected: ${expected_butler_version}" >&2
		echo "actual:   ${actual_version}" >&2
		exit 1
	fi
	echo "PASS: ${description} reports ${actual_version}"
done

cd "$work_repo"
git switch -c main >/dev/null
git config user.name "Butler CI"
git config user.email "butler-ci@example.com"
git remote rename origin github

printf "# Butler Smoke Repo\n" > README.md
git add README.md
git commit -m "initial commit" >/dev/null
git push -u github main >/dev/null

git clone "$remote_repo" "$run_repo" >/dev/null
(
	cd "$run_repo"
	git config user.name "Butler CI"
	git config user.email "butler-ci@example.com"
	git switch -c main >/dev/null 2>&1 || git switch main >/dev/null
)
cd "$repo_root"
expect_exit 0 "run bootstraps repo path and renames origin remote" run_butler run "$run_repo"
if ! git -C "$run_repo" remote get-url github >/dev/null 2>&1; then
	echo "FAIL: run bootstrap did not align remote name to github" >&2
	exit 1
fi
echo "PASS: run bootstrap aligned remote name to github"
cd "$run_repo"
expect_exit 0 "check passes after run bootstrap" run_butler check

cd "$work_repo"
expect_exit 2 "check blocks before hooks are installed" run_butler check
expect_exit 0 "sync keeps local main aligned to github/main" run_butler sync
expect_exit 0 "hook installs required hooks to global runtime path" run_butler hook
expect_exit 0 "check passes after hook install" run_butler check

expect_exit 2 "template check reports drift when managed github files are missing" run_butler template check
expect_exit 0 "template apply writes managed github files" run_butler template apply
expect_exit 0 "template check passes after apply" run_butler template check
expect_exit 1 "unknown command returns runtime/configuration error" run_butler template lint

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

git switch -c codex/tool/stale-prune-squash >/dev/null
printf "stale squash candidate\n" > stale_squash.txt
git add stale_squash.txt
git commit -m "stale squash candidate branch" >/dev/null
git push -u github codex/tool/stale-prune-squash >/dev/null
git switch main >/dev/null
original_hooks_path="$(git config --get core.hooksPath || true)"
git config core.hooksPath .git/hooks
git merge --squash codex/tool/stale-prune-squash >/dev/null 2>&1
git commit -m "squash-merge codex/tool/stale-prune-squash into main" >/dev/null
git push github main >/dev/null
if [[ -n "$original_hooks_path" ]]; then
	git config core.hooksPath "$original_hooks_path"
else
	git config --unset core.hooksPath
fi
git push github --delete codex/tool/stale-prune-squash >/dev/null

expect_exit 0 "prune force-deletes stale branch when merged PR evidence exists" run_butler_with_mock_gh prune
if git show-ref --verify --quiet refs/heads/codex/tool/stale-prune-squash; then
	echo "FAIL: stale squash branch still exists after prune" >&2
	exit 1
fi
echo "PASS: stale squash branch removed locally via merged PR evidence"

git switch -c codex/tool/stale-prune-no-evidence >/dev/null
printf "stale no-evidence candidate\n" > stale_no_evidence.txt
git add stale_no_evidence.txt
git commit -m "stale no-evidence candidate branch" >/dev/null
git push -u github codex/tool/stale-prune-no-evidence >/dev/null
git switch main >/dev/null
git push github --delete codex/tool/stale-prune-no-evidence >/dev/null

expect_exit 0 "prune skips force-delete when merged PR evidence does not match branch tip" run_butler_with_mock_gh prune
if ! git show-ref --verify --quiet refs/heads/codex/tool/stale-prune-no-evidence; then
	echo "FAIL: no-evidence branch should remain after prune skip" >&2
	exit 1
fi
echo "PASS: no-evidence branch retained when merged PR evidence does not match branch tip"

expect_exit 0 "audit completes without a local hard block" run_butler audit

printf 'review: {}\n' > .butler.yml
expect_exit 2 "outsider boundary blocks host repo .butler.yml" run_butler audit
rm -f .butler.yml

mkdir -p bin
printf '#!/usr/bin/env bash\n' > bin/butler
chmod +x bin/butler
expect_exit 2 "outsider boundary blocks host repo bin/butler" run_butler audit
rm -f bin/butler
rmdir bin

mkdir -p .tools/butler
printf 'runtime\n' > .tools/butler/README
expect_exit 2 "outsider boundary blocks host repo .tools/butler" run_butler audit
rm -rf .tools

mkdir -p .github
marker_word="$(printf '%s' c o m m o n)"
printf "<!-- butler:${marker_word}:start old -->\nlegacy\n<!-- butler:${marker_word}:end old -->\n" > .github/copilot-instructions.md
expect_exit 2 "outsider boundary blocks legacy marker artefacts" run_butler audit
rm -rf .github

cd "$repo_root"
bash script/review_smoke.sh

echo "Butler smoke tests passed."
