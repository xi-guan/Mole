set shell := ["bash", "-euo", "pipefail", "-c"]

_default:
    @just --list --unsorted --list-heading '' --list-prefix='- '

# rebase onto the latest upstream release tag after showing its diff and security hints (push manually)
pull:
    ./scripts/pull_release.sh

# install dev dependencies
setup:
    #!/usr/bin/env bash
    set -euo pipefail
    source scripts/lib/log.sh
    run_quiet "installing brew dependencies" brew install shfmt shellcheck bats-core golangci-lint
    run_quiet "installing goimports" go install golang.org/x/tools/cmd/goimports@latest
    run_quiet "downloading go modules" go mod download
    git config core.hooksPath .githooks
    log_done "setup complete"

# build go binaries and place where mole expects them
install:
    #!/usr/bin/env bash
    set -euo pipefail
    source scripts/lib/log.sh
    run_quiet "building go binaries" make build
    log_done "install complete"

# remove built artifacts
uninstall:
    #!/usr/bin/env bash
    set -euo pipefail
    source scripts/lib/log.sh
    log_info "cleaning binaries"
    make clean
    log_done "uninstall complete"

# run all tests (shellcheck + bats + go)
test:
    ./scripts/test.sh

# format and lint (shell + go)
lint:
    ./scripts/check.sh
