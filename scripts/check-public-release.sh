#!/usr/bin/env bash

set -Eeuo pipefail

die() {
    printf 'check-public-release: %s\n' "$*" >&2
    exit 1
}

main() {
    local bootstrap=${1:-}
    local project_url=${2:-}
    local version=${3:-}
    local release_base_url

    [[ -f ${bootstrap} && -n ${project_url} && -n ${version} ]] ||
        die 'usage: check-public-release.sh BOOTSTRAP HTTPS_PROJECT_URL VERSION'
    [[ ${project_url} == https://* ]] || die 'project URL must use HTTPS'
    release_base_url="${project_url%/}/releases/download"
    grep -Fq "readonly release_base_url='${release_base_url}'" "${bootstrap}" ||
        die 'bootstrap release base URL mismatch'
    grep -Fq "readonly release_version='${version}'" "${bootstrap}" ||
        die 'bootstrap version mismatch'
    bash -n "${bootstrap}"
    printf 'Validated public bootstrap for %s\n' "${project_url}"
}

main "$@"
