#!/usr/bin/env bash

set -Eeuo pipefail

readonly test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly project_root=$(cd -- "${test_dir}/../.." && pwd -P)

[[ $# -ge 1 && $# -le 2 ]] || {
    printf 'usage: package_test.sh ARCHIVE [HTTPS_PROJECT_URL]\n' >&2
    exit 1
}

"${project_root}/scripts/check-release.sh" "$1" "${project_root}" "${2:-}"
