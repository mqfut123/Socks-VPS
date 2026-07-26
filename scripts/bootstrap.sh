#!/usr/bin/env bash

set +x
set -Eeuo pipefail

readonly release_base_url='@RELEASE_BASE_URL@'
readonly release_version='@RELEASE_VERSION@'

die() {
    printf 'Socks-VPS bootstrap: %s\n' "$*" >&2
    exit 1
}

sha256_file() {
    local path=$1

    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "${path}" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "${path}" | awk '{print $1}'
    else
        die 'sha256sum or shasum is required'
    fi
}

detect_arch() {
    case $(uname -m) in
        x86_64)
            printf '%s\n' amd64
            ;;
        aarch64 | arm64)
            printf '%s\n' arm64
            ;;
        *)
            die "unsupported architecture: $(uname -m)"
            ;;
    esac
}

check_member_path() {
    local member=$1

    [[ ${member} != /* ]] || die "archive contains an absolute path: ${member}"
    [[ /${member}/ != *'/../'* ]] || die "archive contains a parent traversal: ${member}"
    [[ ${member} != *'/._'* ]] || die "archive contains AppleDouble metadata: ${member}"
}

main() {
    local arch archive archive_url checksum_url expected actual work_dir package_root

    [[ $(uname -s) == Linux ]] || die 'Linux is required'
    command -v systemctl >/dev/null 2>&1 || die 'systemd is required'
    [[ -d /run/systemd/system ]] || die 'systemd is not running'
    if ! command -v apt-get >/dev/null 2>&1 &&
       ! command -v dnf >/dev/null 2>&1 &&
       ! command -v yum >/dev/null 2>&1; then
        die 'apt, dnf, or yum is required'
    fi
    command -v curl >/dev/null 2>&1 || die 'curl is required'
    command -v tar >/dev/null 2>&1 || die 'tar is required'

    [[ ${release_base_url} != *REPLACE_WITH_RELEASE_HOST* ]] ||
        die 'release URL has not been configured'
    [[ ${release_base_url} == https://* ]] || die 'release URL must use HTTPS'
    [[ ${release_version} =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] ||
        die 'release version is invalid'

    arch=$(detect_arch)
    archive="socks-vps-v${release_version}-linux-${arch}.tar.gz"
    archive_url="${release_base_url%/}/v${release_version}/${archive}"
    checksum_url="${archive_url}.sha256"
    work_dir=$(mktemp -d "${TMPDIR:-/tmp}/socks-vps-bootstrap.XXXXXXXX")

    printf 'Downloading Socks-VPS %s for linux/%s\n' "${release_version}" "${arch}"
    curl --fail --silent --show-error --location \
        --proto '=https' --tlsv1.2 \
        --output "${work_dir}/${archive}" "${archive_url}"
    curl --fail --silent --show-error --location \
        --proto '=https' --tlsv1.2 \
        --output "${work_dir}/${archive}.sha256" "${checksum_url}"

    read -r expected extra <"${work_dir}/${archive}.sha256" ||
        die 'could not read release checksum'
    [[ ${expected} =~ ^[0-9a-fA-F]{64}$ && -z ${extra:-} ]] ||
        die 'release checksum file has an invalid format'
    actual=$(sha256_file "${work_dir}/${archive}")
    actual=$(printf '%s' "${actual}" | tr '[:upper:]' '[:lower:]')
    expected=$(printf '%s' "${expected}" | tr '[:upper:]' '[:lower:]')
    [[ ${actual} == ${expected} ]] || die 'release checksum mismatch'

    while IFS= read -r member; do
        check_member_path "${member}"
    done < <(tar -tzf "${work_dir}/${archive}")

    tar -xzf "${work_dir}/${archive}" -C "${work_dir}"
    package_root="${work_dir}/socks-vps-v${release_version}-linux-${arch}"
    [[ -x ${package_root}/scripts/install.sh ]] ||
        die 'release package does not contain the installer'

    exec "${package_root}/scripts/install.sh"
}

main "$@"
