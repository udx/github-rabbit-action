#!/usr/bin/env bash
# Minimal GitHub API helpers for lifecycle resolution.

if [[ "${GITHUB_LIB_LOADED:-}" == "true" ]]; then
    return 0
fi

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$LIB_DIR/logging.sh"

readonly GITHUB_API_BASE="https://api.github.com"
readonly GITHUB_API_VERSION="2022-11-28"

# Return success only when GitHub confirms the branch is protected. A missing
# token or an unavailable branch remains compatible with the historical
# fallback-to-development behavior, but is visible in debug logs.
github_check_branch_protection() {
    local branch="$1"
    local repository="${2:-${GITHUB_REPOSITORY:-}}"
    local token="${3:-${GITHUB_TOKEN:-}}"

    if [[ -z "$branch" || -z "$repository" || -z "$token" ]]; then
        dbg "Skipping branch protection check because branch, repository, or token is unavailable"
        return 1
    fi

    local response http_code body
    response="$(curl -sS -w $'\n%{http_code}' \
        -H "Authorization: Bearer $token" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: $GITHUB_API_VERSION" \
        "$GITHUB_API_BASE/repos/$repository/branches/$branch" 2>/dev/null || true)"
    http_code="${response##*$'\n'}"
    body="${response%$'\n'*}"

    if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
        if grep -q '"protected"[[:space:]]*:[[:space:]]*true' <<<"$body"; then
            return 0
        fi
        return 1
    fi

    warn "Could not determine branch protection for '$branch' (GitHub API HTTP ${http_code:-unknown}); using lifecycle fallback rules"
    return 1
}

readonly GITHUB_LIB_LOADED="true"
