#!/usr/bin/env bash

set -Eeuo pipefail

readonly test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly project_root=$(cd -- "${test_dir}/../.." && pwd -P)

# shellcheck source=../../scripts/install.sh
source "${project_root}/scripts/install.sh"

fail() {
    printf 'restore_state_test: %s\n' "$*" >&2
    exit 1
}

path_exists() {
    case $1 in
        source-present | target-present)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

[[ $(restore_pair_state source-present target-absent) == move ]] ||
    fail 'unmoved path was not classified as move'
[[ $(restore_pair_state source-absent target-present) == done ]] ||
    fail 'already restored path was not classified as done'
[[ $(restore_pair_state source-present target-present) == conflict ]] ||
    fail 'double-present path was not rejected'
[[ $(restore_pair_state source-absent target-absent) == missing ]] ||
    fail 'double-missing path was not rejected'

printf 'Reentrant uninstall restore state passed\n'
