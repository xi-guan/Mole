#!/usr/bin/env bash
# Usage: scripts/pull_release.sh
# Rebases the current branch onto the latest upstream release tag after printing
# its commits, full diff path and security hints. Answering N exits 1, so a
# chained `just pull install` stops before building.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib/log.sh
source scripts/lib/log.sh

# hints only: every match still needs a human read of the diff
scan_added_lines() {
    awk '
        /^diff --git / { in_hunk = 0; next }
        /^@@/ { in_hunk = 1; next }
        !in_hunk && /^\+\+\+ / { file = substr($0, 7); next }
        !in_hunk || !/^\+/ { next }
        {
            l = substr($0, 2)
            hit = ""
            if (l ~ /(^|[^[:alnum:]_])rm[[:space:]]+-[[:alpha:]]*([rR][[:alpha:]]*f|f[[:alpha:]]*[rR])/) hit = "recursive rm"
            else if (l ~ /(curl|wget)[^|]*[|][[:space:]]*(sudo[[:space:]]+)?(ba|z)?sh([^[:alnum:]_]|$)/) hit = "pipe to sh"
            else if (l ~ /(^|[^[:alnum:]_])sudo([^[:alnum:]_]|$)/) hit = "sudo"
            else if (l ~ /(^|[^[:alnum:]_])eval([^[:alnum:]_]|$)/) hit = "eval"
            else if (l ~ /base64[[:space:]]+(-d|-D|--decode)/) hit = "base64 -d"
            else if (l ~ /osascript/) hit = "osascript"
            else if (l ~ /launchctl/) hit = "launchctl"
            else if (l ~ /chmod[[:space:]]+([ugoa]*[+][rwxXt]*s|[2-7][0-7][0-7][0-7])/) hit = "chmod +s"
            else if (l ~ /https?:\/\//) hit = "url"
            if (hit == "") next
            sub(/^[[:space:]]+/, "", l)
            printf "  [%s] %s: %s\n", hit, file, substr(l, 1, 160)
            n++
        }
        END { printf "  %d hint lines\n", n }
    '
}

log_info "fetching upstream with tags"
# --quiet would also hide the per-tag "would clobber existing tag" rejections
if ! fetch_output=$(git fetch upstream --tags 2>&1); then
    printf '%s\n' "$fetch_output"
    log_error "git fetch upstream failed; on 'would clobber existing tag' upstream moved those tags: compare git rev-parse <tag>^{tree} with the upstream commit's tree, and if they match run: git fetch upstream --tags --force"
    exit 1
fi

# the Windows CLI publishes V<x.y.z>-windows tags in the same repo; only plain tags are macOS releases
tag=""
while IFS= read -r candidate; do
    if [[ $candidate =~ ^V[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        tag=$candidate
        break
    fi
done < <(git tag --list 'V*' --sort=-v:refname)
if [[ -z $tag ]]; then
    log_error "no V<x.y.z> tag found after fetching upstream; check: git ls-remote --tags upstream"
    exit 1
fi
# a tag that never reached upstream main could come from another remote or a local edit
if ! git merge-base --is-ancestor "$tag" upstream/main; then
    log_error "$tag is not on upstream/main, refusing to rebase onto it; inspect: git show $tag"
    exit 1
fi

branch=$(git rev-parse --abbrev-ref HEAD)
base=$(git merge-base HEAD "$tag")
if [[ $base == "$(git rev-parse "$tag^{commit}")" ]]; then
    log_done "$branch already contains $tag"
    exit 0
fi
short_base=$(git rev-parse --short "$base")

log_info "upstream commits $short_base..$tag"
git --no-pager log --no-merges --format='  %h %s' "$base..$tag"
echo
git --no-pager diff --stat=120 "$base" "$tag"

log_info "local commits to replay onto $tag"
git --no-pager log --format='  %h %s' "$base..HEAD"

review_dir="$(git rev-parse --absolute-git-dir)/pull-review"
mkdir -p "$review_dir"
diff_file="$review_dir/$short_base..$tag.diff"
git diff --no-color --no-ext-diff "$base" "$tag" > "$diff_file"
log_info "full diff: $diff_file"

log_info "added lines worth a look"
# CONTRIBUTORS.svg inlines base64 avatars, which would bury every real hint
git diff -U0 --no-color --no-ext-diff --no-textconv --src-prefix=a/ --dst-prefix=b/ \
    "$base" "$tag" -- . ':(exclude)*.svg' | scan_added_lines

if git diff --quiet "$base" "$tag" -- go.mod go.sum; then
    log_info "go.mod and go.sum unchanged"
else
    log_warn "go.mod or go.sum changed"
    git --no-pager diff "$base" "$tag" -- go.mod
fi

# scan the tag's own tree, not the current checkout
scan_dir=$(mktemp -d "${TMPDIR:-/tmp}/mole-pull-review.XXXXXX")
cleanup() {
    git worktree remove --force "$scan_dir" > /dev/null 2>&1 || rmdir "$scan_dir" 2> /dev/null || true
    # this trap replaces the one log.sh set for its own temp log
    rm -f "$_BUILD_LOG"
}
trap cleanup EXIT
git worktree add --quiet --detach "$scan_dir" "$tag"

govulncheck_bin=$(command -v govulncheck || echo "$HOME/go/bin/govulncheck")
if [[ -x $govulncheck_bin ]]; then
    log_info "govulncheck at $tag"
    vuln_rc=0
    "$govulncheck_bin" -C "$scan_dir" ./... || vuln_rc=$?
    if [[ $vuln_rc -eq 3 ]]; then
        log_warn "govulncheck found known vulnerabilities, listed above"
    elif [[ $vuln_rc -ne 0 ]]; then
        # a binary built by an older Go cannot load packages that need a newer one
        log_warn "govulncheck could not run (exit $vuln_rc); on 'requires newer Go version' run: go install golang.org/x/vuln/cmd/govulncheck@latest"
    fi
else
    log_warn "govulncheck not found, skipped; install: go install golang.org/x/vuln/cmd/govulncheck@latest"
fi

changed_shell=()
while IFS= read -r path; do
    changed_shell+=("$scan_dir/$path")
done < <(git diff --name-only --diff-filter=d "$base" "$tag" -- '*.sh' mole)
if ! command -v shellcheck > /dev/null 2>&1; then
    log_warn "shellcheck not found, skipped; install: brew install shellcheck"
elif [[ ${#changed_shell[@]} -gt 0 ]]; then
    log_info "shellcheck on ${#changed_shell[@]} changed shell files"
    if shellcheck "${changed_shell[@]}"; then
        log_done "shellcheck clean"
    else
        log_warn "shellcheck reported issues, listed above"
    fi
fi

echo
read -r -p "rebase $branch onto $tag? [y/N] " reply || reply=""
if [[ $reply != [yY] ]]; then
    log_warn "not rebased, $branch is unchanged"
    exit 1
fi
if ! git rebase --autostash "$tag"; then
    log_error "rebase stopped: resolve and run git rebase --continue, or undo with git rebase --abort"
    exit 1
fi
log_info "local commits on top of $tag"
git --no-pager log --format='  %h %s' "$tag..HEAD"
log_done "pull complete, push manually"
