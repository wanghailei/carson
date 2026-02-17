#!/usr/bin/env bash
set -euo pipefail

usage() {
	cat <<'USAGE'
Usage:
  script/bootstrap_repo_defaults.sh <owner/repo> [options]

Options:
  --branch <name>             Branch to protect (default: main)
  --checks <csv>              Required status checks, comma-separated (default: "Syntax and smoke tests,Butler governance")
  --local-path <path>         Local repository path for wrapper and Butler setup
  --set-butler-read-token     Set BUTLER_REPO_READ_TOKEN from current gh auth token

Examples:
  script/bootstrap_repo_defaults.sh wanghailei/new-project --checks "Syntax and smoke tests,Butler governance,lint,test"
  script/bootstrap_repo_defaults.sh wanghailei/new-project --local-path ~/Studio/new-project --set-butler-read-token
USAGE
}

require_command() {
	if ! command -v "$1" >/dev/null 2>&1; then
		echo "Missing required command: $1" >&2
		exit 1
	fi
}

repo_slug="${1:-}"
if [[ "${repo_slug}" == "--help" || "${repo_slug}" == "-h" ]]; then
	usage
	exit 0
fi
if [[ -z "${repo_slug}" ]]; then
	usage
	exit 1
fi
if [[ "${repo_slug}" != */* ]]; then
	echo "Repository must be in owner/repo format: ${repo_slug}" >&2
	exit 1
fi
shift || true

branch="main"
checks_csv="Syntax and smoke tests,Butler governance"
local_path=""
set_butler_read_token=0

while [[ $# -gt 0 ]]; do
	case "$1" in
		--branch)
			branch="${2:-}"
			shift 2
			;;
		--checks)
			checks_csv="${2:-}"
			shift 2
			;;
		--local-path)
			local_path="${2:-}"
			shift 2
			;;
		--set-butler-read-token)
			set_butler_read_token=1
			shift
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

require_command gh
require_command ruby

contexts_json="$(ruby -rjson -e 'raw = ARGV.fetch( 0, "" ); list = raw.split( "," ).map { |entry| entry.strip }.reject( &:empty? ); print JSON.generate( list )' "${checks_csv}")"

payload="$(
cat <<JSON
{
  "required_status_checks": {
    "strict": true,
    "contexts": ${contexts_json}
  },
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": false,
    "require_code_owner_reviews": false,
    "required_approving_review_count": 0,
    "require_last_push_approval": false
  },
  "restrictions": null,
  "required_linear_history": true,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "block_creations": false,
  "required_conversation_resolution": true,
  "lock_branch": false,
  "allow_fork_syncing": false
}
JSON
)"

printf "%s" "${payload}" | gh api --method PUT -H "Accept: application/vnd.github+json" "repos/${repo_slug}/branches/${branch}/protection" --input - >/dev/null
echo "Applied branch protection to ${repo_slug}:${branch}"
echo "required checks: ${checks_csv:-none}"
echo "approvals: 0"
echo "required conversation resolution: true"
echo "required linear history: true"
echo "allow force push: false"
echo "allow deletion: false"

if [[ "${set_butler_read_token}" -eq 1 ]]; then
	gh auth token | gh secret set BUTLER_REPO_READ_TOKEN --repo "${repo_slug}"
	echo "Set secret BUTLER_REPO_READ_TOKEN on ${repo_slug}"
fi

if [[ -n "${local_path}" ]]; then
	if [[ ! -d "${local_path}" ]]; then
		echo "Local path does not exist: ${local_path}" >&2
		exit 1
	fi
	# Local bootstrap is optional and only handles repo-local setup.
	# GitHub branch protection is already applied above via API.
	absolute_local_path="$(cd "${local_path}" && pwd)"
	template_bin="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/templates/project/bin/butler"
	mkdir -p "${absolute_local_path}/bin"
	cp "${template_bin}" "${absolute_local_path}/bin/butler"
	chmod +x "${absolute_local_path}/bin/butler"
	(
		cd "${absolute_local_path}"
		bin/butler hook
		bin/butler template apply
	)
	echo "Installed bin/butler and applied local Butler bootstrap in ${absolute_local_path}"
fi
