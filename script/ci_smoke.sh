#!/usr/bin/env bash
# CI smoke runner for Carson CLI.
# Exercises critical command flows and policy exits in isolated temporary Git
# repositories so CI catches behavioural regressions early.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
carson_bin="$repo_root/exe/carson"

# Shared launch helpers for Carson invocations in smoke scenarios.
run_carson() {
	HOME="$tmp_root/home" CARSON_HOOKS_BASE_PATH="$tmp_root/global-hooks" ruby "$carson_bin" "$@"
}

run_carson_with_mock_gh() {
	PATH="$mock_bin:$PATH" run_carson "$@"
}

run_carson_with_report_env() {
	local report_home="$1"
	local report_tmpdir="$2"
	shift 2
	HOME="$report_home" TMPDIR="$report_tmpdir" CARSON_HOOKS_BASE_PATH="$tmp_root/global-hooks" ruby "$carson_bin" "$@"
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
tmp_base="${CARSON_TMP_BASE:-$default_tmp_base}"
mkdir -p "$tmp_base"
tmp_root="$(mktemp -d "$tmp_base/carson-ci.XXXXXX")"
mkdir -p "$tmp_root/home"
export HOME="$tmp_root/home"
export CARSON_HOOKS_BASE_PATH="$tmp_root/global-hooks"
export CARSON_BIN="$carson_bin"
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

expected_carson_version="$(cat "$repo_root/VERSION")"
for arg in "version" "--version"; do
	description="version output for '${arg}'"
	actual_version="$(run_carson "$arg")"
	if [[ "$actual_version" != "$expected_carson_version" ]]; then
		echo "FAIL: ${description} mismatch" >&2
		echo "expected: ${expected_carson_version}" >&2
		echo "actual:   ${actual_version}" >&2
		exit 1
	fi
	echo "PASS: ${description} reports ${actual_version}"
done

# Seed disposable repo and validate init/offboard lifecycle.
cd "$work_repo"
git switch -c main >/dev/null
git config user.name "Carson CI"
git config user.email "carson-ci@example.com"
git remote rename origin github

printf "# Carson Smoke Repo\n" > README.md
git add README.md
git commit -m "initial commit" >/dev/null
git push -u github main >/dev/null

git clone "$remote_repo" "$init_repo" >/dev/null
(
	cd "$init_repo"
	git config user.name "Carson CI"
	git config user.email "carson-ci@example.com"
	# CI runners may default bare-repo HEAD to master; prefer tracking origin/main first.
	git switch main >/dev/null 2>&1 || git switch -c main --track origin/main >/dev/null 2>&1 || git switch -c main >/dev/null
)
cd "$repo_root"
expect_exit 0 "init initialises repo path and renames origin remote" run_carson init "$init_repo"
if ! git -C "$init_repo" remote get-url github >/dev/null 2>&1; then
	echo "FAIL: init did not align remote name to github" >&2
	exit 1
fi
echo "PASS: init aligned remote name to github"
cd "$init_repo"
expect_exit 0 "check passes after init" run_carson check
legacy_hooks_dir="$tmp_root/legacy-hooks/$expected_carson_version"
mkdir -p "$legacy_hooks_dir"
cp "$tmp_root/global-hooks/$expected_carson_version/"* "$legacy_hooks_dir/"
git config core.hooksPath "$legacy_hooks_dir"
mkdir -p .github/workflows .tools/carson bin
printf "review: {}\n" > .carson.yml
printf "#!/usr/bin/env bash\n" > bin/carson
chmod +x bin/carson
printf "name: Carson governance\n" > .github/workflows/carson-governance.yml
printf "name: Carson policy\n" > .github/workflows/carson_policy.yml
expect_exit 0 "offboard removes Carson integration and legacy artefacts" run_carson offboard
if git config --get core.hooksPath >/dev/null 2>&1; then
	echo "FAIL: offboard did not unset Carson-managed core.hooksPath" >&2
	exit 1
fi
for removed_path in \
	".github/copilot-instructions.md" \
	".github/pull_request_template.md" \
	".github/workflows/carson-governance.yml" \
	".github/workflows/carson_policy.yml" \
	".carson.yml" \
	"bin/carson" \
	".tools/carson"; do
	if [[ -e "$removed_path" ]]; then
		echo "FAIL: offboard did not remove $removed_path" >&2
		exit 1
	fi
done
echo "PASS: offboard cleaned Carson-managed repo artefacts"
expect_exit 0 "offboard is idempotent on an already cleaned repo" run_carson offboard
expect_exit 1 "legacy run command is rejected" run_carson run "$init_repo"

# Validate core setup flows (check/sync/hook/template).
cd "$work_repo"
expect_exit 2 "check blocks before hooks are installed" run_carson check
expect_exit 0 "sync keeps local main aligned to github/main" run_carson sync
expect_exit 0 "hook installs required hooks to global runtime path" run_carson hook
expect_exit 0 "check passes after hook install" run_carson check
for required_hook in pre-commit prepare-commit-msg pre-merge-commit pre-push; do
	if [[ ! -x "$tmp_root/global-hooks/$expected_carson_version/$required_hook" ]]; then
		echo "FAIL: required hook missing or non-executable: $required_hook" >&2
		exit 1
	fi
done
echo "PASS: required hooks include pre-commit and are executable"

git switch -c feature/scope-policy-block >/dev/null
mkdir -p app/models lib
printf "scope enforcement smoke\n" > app/models/scope_policy_smoke.rb
printf "scope enforcement mixed module smoke\n" > lib/scope_policy_tool_smoke.rb
git add app/models/scope_policy_smoke.rb lib/scope_policy_tool_smoke.rb
expect_exit 2 "audit blocks mixed module groups for staged non-doc files" run_carson audit
set +e
git commit -m "mixed module groups should fail pre-commit" >/dev/null 2>&1
commit_status="$?"
set -e
if [[ "$commit_status" -eq 0 ]]; then
	echo "FAIL: pre-commit hook should block commit on mixed module groups" >&2
	exit 1
fi
git reset --hard HEAD >/dev/null
git switch main >/dev/null
git branch -D feature/scope-policy-block >/dev/null

git switch -c feature/staged-scope-only >/dev/null
mkdir -p app/models lib
printf "staged scope pass\n" > lib/staged_scope_ok.rb
printf "unstaged mismatch should not block\n" > app/models/unstaged_scope_violation.rb
git add lib/staged_scope_ok.rb
expect_exit 0 "audit enforces scope using staged paths when index changes exist" run_carson audit
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
git branch -D feature/staged-scope-only >/dev/null

expect_exit 2 "template check reports drift when managed github files are missing" run_carson template check
expect_exit 0 "template apply writes managed github files" run_carson template apply
expect_exit 0 "template check passes after apply" run_carson template check
expect_exit 1 "unknown command returns runtime/configuration error" run_carson template lint

# Validate report directory fallback precedence for invalid HOME.
tmpdir_report_root="$tmp_root/custom-tmpdir"
mkdir -p "$tmpdir_report_root"
tmpdir_report_output="$(run_carson_with_report_env "relative-home" "$tmpdir_report_root" audit)"
expected_tmpdir_report_path="$tmpdir_report_root/carson/pr_report_latest.md"
if [[ "$tmpdir_report_output" != *"report_markdown: $expected_tmpdir_report_path"* ]]; then
	echo "FAIL: audit did not use TMPDIR fallback when HOME is invalid" >&2
	echo "expected output to include: report_markdown: $expected_tmpdir_report_path" >&2
	echo "actual output: $tmpdir_report_output" >&2
	exit 1
fi
echo "PASS: report path falls back to TMPDIR/carson when HOME is invalid"

tmp_fallback_output="$(run_carson_with_report_env "relative-home" "relative-tmpdir" audit)"
if [[ "$tmp_fallback_output" != *"report_markdown: /tmp/carson/pr_report_latest.md"* ]]; then
	echo "FAIL: audit did not use /tmp fallback when HOME and TMPDIR are invalid" >&2
	echo "expected output to include: report_markdown: /tmp/carson/pr_report_latest.md" >&2
	echo "actual output: $tmp_fallback_output" >&2
	exit 1
fi
echo "PASS: report path falls back to /tmp/carson when HOME and TMPDIR are invalid"

# Stale-branch prune behaviour: safe removal without force evidence.
git switch -c tool/stale-prune >/dev/null
git push -u github tool/stale-prune >/dev/null
git switch main >/dev/null
git push github --delete tool/stale-prune >/dev/null

expect_exit 0 "prune deletes stale local branches safely" run_carson prune
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

expect_exit 0 "prune force-deletes stale branch when merged PR evidence exists" run_carson_with_mock_gh prune
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

expect_exit 0 "prune skips force-delete when merged PR evidence does not match branch tip" run_carson_with_mock_gh prune
if ! git show-ref --verify --quiet refs/heads/tool/stale-prune-no-evidence; then
	echo "FAIL: no-evidence branch should remain after prune skip" >&2
	exit 1
fi
echo "PASS: no-evidence branch retained when merged PR evidence does not match branch tip"

# Outsider boundary audit blocks forbidden host-repo artefacts.
expect_exit 0 "audit completes without a local hard block" run_carson audit

printf 'review: {}\n' > .carson.yml
expect_exit 2 "outsider boundary blocks host repo .carson.yml" run_carson audit
rm -f .carson.yml

mkdir -p bin
printf '#!/usr/bin/env bash\n' > bin/carson
chmod +x bin/carson
expect_exit 2 "outsider boundary blocks host repo bin/carson" run_carson audit
rm -f bin/carson
rmdir bin

mkdir -p .tools/carson
printf 'runtime\n' > .tools/carson/README
expect_exit 2 "outsider boundary blocks host repo .tools/carson" run_carson audit
rm -rf .tools

mkdir -p .github
marker_word="$(printf '%s' c o m m o n)"
printf "<!-- carson:${marker_word}:start old -->\nlegacy\n<!-- carson:${marker_word}:end old -->\n" > .github/copilot-instructions.md
expect_exit 2 "outsider boundary blocks legacy marker artefacts" run_carson audit
rm -rf .github

# Include dedicated review smoke suite from CI smoke entrypoint.
cd "$repo_root"
bash script/review_smoke.sh

echo "Carson smoke tests passed."
