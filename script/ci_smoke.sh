#!/usr/bin/env bash
# CI smoke runner for Butler CLI.
# Exercises critical command flows and policy exits in isolated temporary Git
# repositories so CI catches behavioural regressions early.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
butler_bin="$repo_root/exe/butler"

# Shared launch helpers for Butler invocations in smoke scenarios.
run_butler() {
	HOME="$tmp_root/home" BUTLER_HOOKS_BASE_PATH="$tmp_root/global-hooks" ruby "$butler_bin" "$@"
}

run_butler_with_mock_gh() {
	PATH="$mock_bin:$PATH" run_butler "$@"
}

run_butler_with_report_env() {
	local report_home="$1"
	local report_tmpdir="$2"
	shift 2
	HOME="$report_home" TMPDIR="$report_tmpdir" BUTLER_HOOKS_BASE_PATH="$tmp_root/global-hooks" ruby "$butler_bin" "$@"
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

# Temporary sandbox setup for all smoke checks.
default_tmp_base="$HOME/.cache/tmp"
mkdir -p "$default_tmp_base" 2>/dev/null || default_tmp_base="/tmp"
tmp_base="${BUTLER_TMP_BASE:-$default_tmp_base}"
mkdir -p "$tmp_base"
tmp_root="$(mktemp -d "$tmp_base/butler-ci.XXXXXX")"
mkdir -p "$tmp_root/home"
export HOME="$tmp_root/home"
export BUTLER_HOOKS_BASE_PATH="$tmp_root/global-hooks"
export BUTLER_BIN="$butler_bin"
cleanup() {
	rm -rf "$tmp_root"
}
trap cleanup EXIT

remote_repo="$tmp_root/remote.git"
work_repo="$tmp_root/work"
init_repo="$tmp_root/init-work"
mock_bin="$tmp_root/mock-bin"

git init --bare "$remote_repo" >/dev/null
git clone "$remote_repo" "$work_repo" >/dev/null
mkdir -p "$mock_bin"

# Minimal gh stub used by stale-branch prune evidence tests.
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

	if [[ "$head_filter" == "local:tool/stale-prune-squash" ]]; then
		tip_sha="$(git rev-parse --verify tool/stale-prune-squash 2>/dev/null || true)"
		cat <<JSON
[{"number":999,"html_url":"https://github.com/mock/mock-repo/pull/999","merged_at":"2026-02-17T00:00:00Z","head":{"ref":"tool/stale-prune-squash","sha":"$tip_sha"},"base":{"ref":"main"}}]
JSON
		exit 0
	fi

	if [[ "$head_filter" == "local:tool/stale-prune-no-evidence" ]]; then
		cat <<JSON
[{"number":1000,"html_url":"https://github.com/mock/mock-repo/pull/1000","merged_at":"2026-02-17T00:00:00Z","head":{"ref":"tool/stale-prune-no-evidence","sha":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"},"base":{"ref":"main"}}]
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

# Baseline toolchain and version contract checks.
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

# Seed disposable repo and validate init/offboard lifecycle.
cd "$work_repo"
git switch -c main >/dev/null
git config user.name "Butler CI"
git config user.email "butler-ci@example.com"
git remote rename origin github

printf "# Butler Smoke Repo\n" > README.md
git add README.md
git commit -m "initial commit" >/dev/null
git push -u github main >/dev/null

git clone "$remote_repo" "$init_repo" >/dev/null
(
	cd "$init_repo"
	git config user.name "Butler CI"
	git config user.email "butler-ci@example.com"
	# CI runners may default bare-repo HEAD to master; prefer tracking origin/main first.
	git switch main >/dev/null 2>&1 || git switch -c main --track origin/main >/dev/null 2>&1 || git switch -c main >/dev/null
)
cd "$repo_root"
expect_exit 0 "init initialises repo path and renames origin remote" run_butler init "$init_repo"
if ! git -C "$init_repo" remote get-url github >/dev/null 2>&1; then
	echo "FAIL: init did not align remote name to github" >&2
	exit 1
fi
echo "PASS: init aligned remote name to github"
cd "$init_repo"
expect_exit 0 "check passes after init" run_butler check
legacy_hooks_dir="$tmp_root/legacy-hooks/$expected_butler_version"
mkdir -p "$legacy_hooks_dir"
cp "$tmp_root/global-hooks/$expected_butler_version/"* "$legacy_hooks_dir/"
git config core.hooksPath "$legacy_hooks_dir"
mkdir -p .github/workflows .tools/butler bin
printf "review: {}\n" > .butler.yml
printf "#!/usr/bin/env bash\n" > bin/butler
chmod +x bin/butler
printf "name: Butler governance\n" > .github/workflows/butler-governance.yml
printf "name: Butler policy\n" > .github/workflows/butler_policy.yml
expect_exit 0 "offboard removes Butler integration and legacy artefacts" run_butler offboard
if git config --get core.hooksPath >/dev/null 2>&1; then
	echo "FAIL: offboard did not unset Butler-managed core.hooksPath" >&2
	exit 1
fi
for removed_path in \
	".github/copilot-instructions.md" \
	".github/pull_request_template.md" \
	".github/workflows/butler-governance.yml" \
	".github/workflows/butler_policy.yml" \
	".butler.yml" \
	"bin/butler" \
	".tools/butler"; do
	if [[ -e "$removed_path" ]]; then
		echo "FAIL: offboard did not remove $removed_path" >&2
		exit 1
	fi
done
echo "PASS: offboard cleaned Butler-managed repo artefacts"
expect_exit 0 "offboard is idempotent on an already cleaned repo" run_butler offboard
expect_exit 1 "legacy run command is rejected" run_butler run "$init_repo"

# Validate core setup flows (check/sync/hook/template).
cd "$work_repo"
expect_exit 2 "check blocks before hooks are installed" run_butler check
expect_exit 0 "sync keeps local main aligned to github/main" run_butler sync
expect_exit 0 "hook installs required hooks to global runtime path" run_butler hook
expect_exit 0 "check passes after hook install" run_butler check
for required_hook in pre-commit prepare-commit-msg pre-merge-commit pre-push; do
	if [[ ! -x "$tmp_root/global-hooks/$expected_butler_version/$required_hook" ]]; then
		echo "FAIL: required hook missing or non-executable: $required_hook" >&2
		exit 1
	fi
done
echo "PASS: required hooks include pre-commit and are executable"

git switch -c tool/scope-policy-block >/dev/null
mkdir -p app/models
printf "scope enforcement smoke\n" > app/models/scope_policy_smoke.rb
git add app/models/scope_policy_smoke.rb
expect_exit 2 "audit blocks lane/scope mismatch for staged non-doc files" run_butler audit
set +e
git commit -m "scope mismatch should fail pre-commit" >/dev/null 2>&1
commit_status="$?"
set -e
if [[ "$commit_status" -eq 0 ]]; then
	echo "FAIL: pre-commit hook should block commit on scope mismatch" >&2
	exit 1
fi
git reset --hard HEAD >/dev/null
git switch main >/dev/null
git branch -D tool/scope-policy-block >/dev/null

git switch -c tool/staged-scope-only >/dev/null
mkdir -p app/models lib
printf "staged scope pass\n" > lib/staged_scope_ok.rb
printf "unstaged mismatch should not block\n" > app/models/unstaged_scope_violation.rb
git add lib/staged_scope_ok.rb
expect_exit 0 "audit enforces scope using staged paths when index changes exist" run_butler audit
set +e
git commit -m "staged scope only commit should pass pre-commit" >/dev/null 2>&1
commit_status="$?"
set -e
if [[ "$commit_status" -ne 0 ]]; then
	echo "FAIL: pre-commit hook should ignore unstaged scope mismatches when staged scope is valid" >&2
	exit 1
fi
echo "PASS: pre-commit ignores unstaged scope mismatches when staged scope is valid"
git reset --hard HEAD >/dev/null
git clean -fd >/dev/null
git switch main >/dev/null
git branch -D tool/staged-scope-only >/dev/null

expect_exit 2 "template check reports drift when managed github files are missing" run_butler template check
expect_exit 0 "template apply writes managed github files" run_butler template apply
expect_exit 0 "template check passes after apply" run_butler template check
expect_exit 1 "unknown command returns runtime/configuration error" run_butler template lint

# Validate report directory fallback precedence for invalid HOME.
tmpdir_report_root="$tmp_root/custom-tmpdir"
mkdir -p "$tmpdir_report_root"
tmpdir_report_output="$(run_butler_with_report_env "relative-home" "$tmpdir_report_root" audit)"
expected_tmpdir_report_path="$tmpdir_report_root/butler/pr_report_latest.md"
if [[ "$tmpdir_report_output" != *"report_markdown: $expected_tmpdir_report_path"* ]]; then
	echo "FAIL: audit did not use TMPDIR fallback when HOME is invalid" >&2
	echo "expected output to include: report_markdown: $expected_tmpdir_report_path" >&2
	echo "actual output: $tmpdir_report_output" >&2
	exit 1
fi
echo "PASS: report path falls back to TMPDIR/butler when HOME is invalid"

tmp_fallback_output="$(run_butler_with_report_env "relative-home" "relative-tmpdir" audit)"
if [[ "$tmp_fallback_output" != *"report_markdown: /tmp/butler/pr_report_latest.md"* ]]; then
	echo "FAIL: audit did not use /tmp fallback when HOME and TMPDIR are invalid" >&2
	echo "expected output to include: report_markdown: /tmp/butler/pr_report_latest.md" >&2
	echo "actual output: $tmp_fallback_output" >&2
	exit 1
fi
echo "PASS: report path falls back to /tmp/butler when HOME and TMPDIR are invalid"

# Stale-branch prune behaviour: safe removal without force evidence.
git switch -c tool/stale-prune >/dev/null
git push -u github tool/stale-prune >/dev/null
git switch main >/dev/null
git push github --delete tool/stale-prune >/dev/null

expect_exit 0 "prune deletes stale local branches safely" run_butler prune
if git show-ref --verify --quiet refs/heads/tool/stale-prune; then
	echo "FAIL: stale branch still exists after prune" >&2
	exit 1
fi
echo "PASS: stale branch removed locally"

# Stale-branch prune behaviour: force deletion with matching merged-PR evidence.
git switch -c tool/stale-prune-squash >/dev/null
mkdir -p lib
printf "stale squash candidate\n" > lib/stale_squash.rb
git add lib/stale_squash.rb
git commit -m "stale squash candidate branch" >/dev/null
git push -u github tool/stale-prune-squash >/dev/null
git switch main >/dev/null
original_hooks_path="$(git config --get core.hooksPath || true)"
git config core.hooksPath .git/hooks
git merge --squash tool/stale-prune-squash >/dev/null 2>&1
git commit -m "squash-merge tool/stale-prune-squash into main" >/dev/null
git push github main >/dev/null
if [[ -n "$original_hooks_path" ]]; then
	git config core.hooksPath "$original_hooks_path"
else
	git config --unset core.hooksPath
fi
git push github --delete tool/stale-prune-squash >/dev/null

expect_exit 0 "prune force-deletes stale branch when merged PR evidence exists" run_butler_with_mock_gh prune
if git show-ref --verify --quiet refs/heads/tool/stale-prune-squash; then
	echo "FAIL: stale squash branch still exists after prune" >&2
	exit 1
fi
echo "PASS: stale squash branch removed locally via merged PR evidence"

# Stale-branch prune behaviour: retain branch when evidence does not match tip.
git switch -c tool/stale-prune-no-evidence >/dev/null
mkdir -p lib
printf "stale no-evidence candidate\n" > lib/stale_no_evidence.rb
git add lib/stale_no_evidence.rb
git commit -m "stale no-evidence candidate branch" >/dev/null
git push -u github tool/stale-prune-no-evidence >/dev/null
git switch main >/dev/null
git push github --delete tool/stale-prune-no-evidence >/dev/null

expect_exit 0 "prune skips force-delete when merged PR evidence does not match branch tip" run_butler_with_mock_gh prune
if ! git show-ref --verify --quiet refs/heads/tool/stale-prune-no-evidence; then
	echo "FAIL: no-evidence branch should remain after prune skip" >&2
	exit 1
fi
echo "PASS: no-evidence branch retained when merged PR evidence does not match branch tip"

# Outsider boundary audit blocks forbidden host-repo artefacts.
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

# Include dedicated review smoke suite from CI smoke entrypoint.
cd "$repo_root"
bash script/review_smoke.sh

echo "Butler smoke tests passed."
