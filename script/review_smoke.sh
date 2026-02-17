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
tmp_root="$(mktemp -d "$tmp_base/butler-review-smoke.XXXXXX")"
cleanup() {
	rm -rf "$tmp_root"
}
trap cleanup EXIT

work_repo="$tmp_root/work"
remote_repo="$tmp_root/remote.git"
mock_root="$tmp_root/mock"
mock_bin="$mock_root/bin"
mock_state="$mock_root/state"
mock_log="$mock_root/gh.log"

mkdir -p "$mock_bin" "$mock_state"
git init --bare "$remote_repo" >/dev/null
git clone "$remote_repo" "$work_repo" >/dev/null

cat > "$mock_bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

scenario="${BUTLER_MOCK_GH_SCENARIO:-}"
state_dir="${BUTLER_MOCK_GH_STATE_DIR:?}"
log_file="${BUTLER_MOCK_GH_LOG_FILE:?}"
mkdir -p "$state_dir"
printf '%s\n' "$*" >> "$log_file"

if [[ "${1:-}" == "--version" ]]; then
  if [[ "$scenario" == "gh_unavailable" ]]; then
    exit 1
  fi
  echo "gh version mock"
  exit 0
fi

emit_gate_payload() {
  local mode="$1"
  local updated_at="$2"
  case "$mode" in
    unresolved)
      cat <<JSON
{"data":{"repository":{"pullRequest":{"number":77,"title":"Mock gate PR","url":"https://github.com/mock-org/mock-repo/pull/77","state":"OPEN","updatedAt":"$updated_at","mergedAt":null,"closedAt":null,"author":{"login":"owner"},"reviewThreads":{"nodes":[{"isResolved":false,"isOutdated":false,"comments":{"nodes":[{"author":{"login":"reviewer"},"body":"Needs update","url":"https://github.com/mock-org/mock-repo/pull/77#discussion_r1","createdAt":"2026-02-16T00:00:01Z"}]}}]},"comments":{"nodes":[]},"reviews":{"nodes":[]}}}}}
JSON
      ;;
    outdated_unresolved)
      cat <<JSON
{"data":{"repository":{"pullRequest":{"number":77,"title":"Mock gate PR","url":"https://github.com/mock-org/mock-repo/pull/77","state":"OPEN","updatedAt":"$updated_at","mergedAt":null,"closedAt":null,"author":{"login":"owner"},"reviewThreads":{"nodes":[{"isResolved":false,"isOutdated":true,"comments":{"nodes":[{"author":{"login":"reviewer"},"body":"Old diff comment","url":"https://github.com/mock-org/mock-repo/pull/77#discussion_r_outdated","createdAt":"2026-02-16T00:00:01Z"}]}}]},"comments":{"nodes":[]},"reviews":{"nodes":[]}}}}}
JSON
      ;;
    missing_ack)
      cat <<JSON
{"data":{"repository":{"pullRequest":{"number":77,"title":"Mock gate PR","url":"https://github.com/mock-org/mock-repo/pull/77","state":"OPEN","updatedAt":"$updated_at","mergedAt":null,"closedAt":null,"author":{"login":"owner"},"reviewThreads":{"nodes":[]},"comments":{"nodes":[{"author":{"login":"reviewer"},"body":"This has a security bug.","url":"https://github.com/mock-org/mock-repo/pull/77#issuecomment-risk","createdAt":"2026-02-16T00:00:01Z"}]},"reviews":{"nodes":[]}}}}}
JSON
      ;;
    ack_ok)
      cat <<JSON
{"data":{"repository":{"pullRequest":{"number":77,"title":"Mock gate PR","url":"https://github.com/mock-org/mock-repo/pull/77","state":"OPEN","updatedAt":"$updated_at","mergedAt":null,"closedAt":null,"author":{"login":"owner"},"reviewThreads":{"nodes":[]},"comments":{"nodes":[{"author":{"login":"reviewer"},"body":"Potential security regression.","url":"https://github.com/mock-org/mock-repo/pull/77#issuecomment-risk","createdAt":"2026-02-16T00:00:01Z"},{"author":{"login":"owner"},"body":"Codex: accepted https://github.com/mock-org/mock-repo/pull/77#issuecomment-risk","url":"https://github.com/mock-org/mock-repo/pull/77#issuecomment-ack","createdAt":"2026-02-16T00:00:02Z"}]},"reviews":{"nodes":[]}}}}}
JSON
      ;;
    summary_only)
      cat <<JSON
{"data":{"repository":{"pullRequest":{"number":77,"title":"Mock gate PR","url":"https://github.com/mock-org/mock-repo/pull/77","state":"OPEN","updatedAt":"$updated_at","mergedAt":null,"closedAt":null,"author":{"login":"owner"},"reviewThreads":{"nodes":[]},"comments":{"nodes":[{"author":{"login":"review-bot"},"body":"Summary: files changed and checks observed.","url":"https://github.com/mock-org/mock-repo/pull/77#issuecomment-summary","createdAt":"2026-02-16T00:00:01Z"}]},"reviews":{"nodes":[]}}}}}
JSON
      ;;
    sweep_findings)
      cat <<JSON
{"data":{"repository":{"pullRequest":{"number":88,"title":"Closed PR","url":"https://github.com/mock-org/mock-repo/pull/88","state":"MERGED","updatedAt":"2026-02-17T00:00:00Z","mergedAt":"2026-02-16T00:00:00Z","closedAt":"2026-02-16T00:00:00Z","author":{"login":"owner"},"reviewThreads":{"nodes":[]},"comments":{"nodes":[{"author":{"login":"reviewer"},"body":"Late security bug found.","url":"https://github.com/mock-org/mock-repo/pull/88#issuecomment-late","createdAt":"2026-02-16T08:00:00Z"}]},"reviews":{"nodes":[]}}}}}
JSON
      ;;
    sweep_clear)
      cat <<JSON
{"data":{"repository":{"pullRequest":{"number":88,"title":"Closed PR","url":"https://github.com/mock-org/mock-repo/pull/88","state":"MERGED","updatedAt":"2026-02-17T00:00:00Z","mergedAt":"2026-02-16T00:00:00Z","closedAt":"2026-02-16T00:00:00Z","author":{"login":"owner"},"reviewThreads":{"nodes":[]},"comments":{"nodes":[{"author":{"login":"reviewer"},"body":"Old security note before merge.","url":"https://github.com/mock-org/mock-repo/pull/88#issuecomment-old","createdAt":"2026-02-15T08:00:00Z"}]},"reviews":{"nodes":[]}}}}}
JSON
      ;;
    *)
      cat <<JSON
{"data":{"repository":{"pullRequest":{"number":77,"title":"Mock gate PR","url":"https://github.com/mock-org/mock-repo/pull/77","state":"OPEN","updatedAt":"$updated_at","mergedAt":null,"closedAt":null,"author":{"login":"owner"},"reviewThreads":{"nodes":[]},"comments":{"nodes":[]},"reviews":{"nodes":[]}}}}}
JSON
      ;;
  esac
}

cmd="${1:-}"
case "$cmd" in
  pr)
    sub="${2:-}"
    case "$sub" in
      view)
        cat <<JSON
{"number":77,"title":"Mock gate PR","url":"https://github.com/mock-org/mock-repo/pull/77","state":"OPEN"}
JSON
        ;;
      list)
        case "$scenario" in
          sweep_findings|sweep_clear)
            cat <<JSON
[{"number":88,"title":"Closed PR","url":"https://github.com/mock-org/mock-repo/pull/88","state":"MERGED","updatedAt":"2026-02-17T00:00:00Z","mergedAt":"2026-02-16T00:00:00Z","closedAt":"2026-02-16T00:00:00Z","author":{"login":"owner"}}]
JSON
            ;;
          *)
            echo "[]"
            ;;
        esac
        ;;
      *)
        echo "unsupported gh pr subcommand: $sub" >&2
        exit 1
        ;;
    esac
    ;;
  api)
    endpoint="${2:-}"
    api_page="1"
    for arg in "$@"; do
      if [[ "$arg" == page=* ]]; then
        api_page="${arg#page=}"
      fi
    done
    if [[ "$endpoint" == "graphql" ]]; then
      case "$scenario" in
        gate_unresolved)
          emit_gate_payload unresolved "2026-02-16T00:00:02Z"
          ;;
        gate_missing_ack)
          emit_gate_payload missing_ack "2026-02-16T00:00:02Z"
          ;;
        gate_outdated_unresolved)
          emit_gate_payload outdated_unresolved "2026-02-16T00:00:02Z"
          ;;
        gate_ack_ok)
          emit_gate_payload ack_ok "2026-02-16T00:00:02Z"
          ;;
        gate_summary_only)
          emit_gate_payload summary_only "2026-02-16T00:00:02Z"
          ;;
        gate_timeout)
          counter_file="$state_dir/gate_timeout_counter"
          count=0
          if [[ -f "$counter_file" ]]; then
            count="$(cat "$counter_file")"
          fi
          count="$((count + 1))"
          echo "$count" > "$counter_file"
          updated="$(printf '2026-02-16T00:00:%02dZ' "$count")"
          emit_gate_payload summary_only "$updated"
          ;;
        gate_parse_error)
          echo "{invalid-json"
          ;;
        sweep_findings)
          emit_gate_payload sweep_findings "2026-02-17T00:00:00Z"
          ;;
        sweep_clear)
          emit_gate_payload sweep_clear "2026-02-17T00:00:00Z"
          ;;
        *)
          emit_gate_payload summary_only "2026-02-16T00:00:02Z"
          ;;
      esac
    elif [[ "$endpoint" == repos/*/pulls ]]; then
      case "$scenario" in
        sweep_findings|sweep_clear)
          if [[ "$api_page" != "1" ]]; then
            echo "[]"
            exit 0
          fi
          cat <<JSON
[{"number":88,"title":"Closed PR","html_url":"https://github.com/mock-org/mock-repo/pull/88","state":"closed","updated_at":"2026-02-17T00:00:00Z","merged_at":"2026-02-16T00:00:00Z","closed_at":"2026-02-16T00:00:00Z","user":{"login":"owner"}}]
JSON
          ;;
        *)
          echo "[]"
          ;;
      esac
    else
      echo "unsupported gh api subcommand: ${2:-}" >&2
      exit 1
    fi
    ;;
  issue)
    sub="${2:-}"
    case "$sub" in
      list)
        case "$scenario" in
          sweep_findings)
            if [[ -f "$state_dir/issue_created" ]]; then
              cat <<JSON
[{"number":501,"title":"Butler review sweep findings","state":"OPEN","url":"https://github.com/mock-org/mock-repo/issues/501","labels":[]}]
JSON
            else
              echo "[]"
            fi
            ;;
          sweep_clear)
            cat <<JSON
[{"number":501,"title":"Butler review sweep findings","state":"OPEN","url":"https://github.com/mock-org/mock-repo/issues/501","labels":[]}]
JSON
            ;;
          *)
            echo "[]"
            ;;
        esac
        ;;
      create)
        touch "$state_dir/issue_created"
        echo "https://github.com/mock-org/mock-repo/issues/501"
        ;;
      edit|reopen|close|comment)
        ;;
      *)
        echo "unsupported gh issue subcommand: $sub" >&2
        exit 1
        ;;
    esac
    ;;
  label)
    sub="${2:-}"
    if [[ "$sub" != "create" ]]; then
      echo "unsupported gh label subcommand: $sub" >&2
      exit 1
    fi
    ;;
  *)
    echo "unsupported gh command: $*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$mock_bin/gh"

cd "$work_repo"
git switch -c main >/dev/null
git config user.name "Butler Review Smoke"
git config user.email "butler-review-smoke@example.com"
git remote rename origin github
printf "# Butler Review Smoke Repo\n" > README.md
git add README.md
git commit -m "initial commit" >/dev/null
git push -u github main >/dev/null
git switch -c codex/tool/review-smoke >/dev/null
cat > .butler.yml <<'YAML'
review:
  wait_seconds: 0
  poll_seconds: 0
  max_polls: 3
  sweep:
    window_days: 3
    states:
      - open
      - closed
YAML

run_with_mock() {
	scenario="$1"
	shift
	rm -rf "$mock_state"
	mkdir -p "$mock_state"
	: > "$mock_log"
	PATH="$mock_bin:$PATH" \
		BUTLER_MOCK_GH_SCENARIO="$scenario" \
		BUTLER_MOCK_GH_STATE_DIR="$mock_state" \
		BUTLER_MOCK_GH_LOG_FILE="$mock_log" \
		run_butler "$@"
}

expect_exit 2 "review gate blocks unresolved threads" run_with_mock gate_unresolved review gate
expect_exit 2 "review gate blocks missing Codex disposition for actionable top-level finding" run_with_mock gate_missing_ack review gate
expect_exit 0 "review gate ignores unresolved outdated threads from superseded diffs" run_with_mock gate_outdated_unresolved review gate
expect_exit 0 "review gate passes with Codex disposition and target URL" run_with_mock gate_ack_ok review gate
expect_exit 0 "review gate ignores non-actionable summary-only top-level comment" run_with_mock gate_summary_only review gate
expect_exit 2 "review gate blocks non-converged snapshots" run_with_mock gate_timeout review gate
expect_exit 1 "review gate returns runtime/configuration error on invalid gh JSON" run_with_mock gate_parse_error review gate
expect_exit 1 "review gate returns runtime/configuration error when gh is unavailable" run_with_mock gh_unavailable review gate

expect_exit 2 "review sweep blocks and upserts tracking issue on late actionable comments" run_with_mock sweep_findings review sweep
if ! grep -q "issue create" "$mock_log"; then
	echo "FAIL: review sweep expected to create tracking issue for findings" >&2
	exit 1
fi
echo "PASS: review sweep created tracking issue for findings"

expect_exit 0 "review sweep returns OK and closes open tracking issue when clear" run_with_mock sweep_clear review sweep
if ! grep -q "issue close" "$mock_log"; then
	echo "FAIL: review sweep expected to close tracking issue on clear run" >&2
	exit 1
fi
echo "PASS: review sweep closed tracking issue on clear run"

echo "Butler review smoke tests passed."
