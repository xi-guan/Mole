set shell := ["bash", "-euo", "pipefail", "-c"]

_default:
    @just --list --unsorted --list-heading '' --list-prefix='- '

# rebase local main onto upstream/main (fork's main may lag; push manually)
pull:
    #!/usr/bin/env bash
    set -euo pipefail
    source scripts/lib/log.sh
    log_info "fetching upstream"
    git fetch upstream
    log_info "rebasing local main onto upstream/main"
    git pull --rebase --autostash upstream main
    log_done "pull complete"

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
