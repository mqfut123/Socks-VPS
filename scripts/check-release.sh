#!/usr/bin/env bash

set -Eeuo pipefail

die() {
    printf 'check-release: %s\n' "$*" >&2
    exit 1
}

sha256_stream() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 | awk '{print $1}'
    else
        die 'sha256sum or shasum is required'
    fi
}

sha256_file() {
    local path=$1

    sha256_stream <"${path}"
}

source_input_paths() {
    local project_root=$1

    (
        cd "${project_root}"
        {
            printf '%s\n' \
                go.mod \
                go.sum \
                README.md \
                THIRD_PARTY_NOTICES.md \
                scripts/install.sh \
                scripts/firewall.sh \
                packaging/systemd/socks-vps.service \
                packaging/systemd/socks-vps-firewall.service \
                packaging/licenses/go-gost-gosocks5-LICENSE \
                assets/ipdeny/cn-aggregated.zone \
                assets/ipdeny/Copyrights.txt \
                assets/ipdeny/MD5SUM.upstream \
                assets/ipdeny/SOURCE.json
            find cmd internal -type f -name '*.go' -print
            find scripts tests/integration -type f -name '*.sh' -print
        } | LC_ALL=C sort -u
    )
}

source_manifest_text() {
    local project_root=$1
    local relative digest

    while IFS= read -r relative; do
        [[ -f ${project_root}/${relative} ]] ||
            die "source input is missing: ${relative}"
        digest=$(sha256_file "${project_root}/${relative}")
        printf '%s  %s\n' "${digest}" "${relative}"
    done < <(source_input_paths "${project_root}")
}

render_release_stream() {
    local source=$1
    local version=$2
    local project_url=$3
    local release_base_url bootstrap_url

    if [[ -n ${project_url} ]]; then
        project_url=${project_url%/}
        release_base_url="${project_url}/releases/download"
        bootstrap_url="${release_base_url}/v${version}/install-v${version}.sh"
        sed \
            -e "s|@PROJECT_URL@|${project_url}|g" \
            -e "s|@RELEASE_BASE_URL@|${release_base_url}|g" \
            -e "s|@BOOTSTRAP_URL@|${bootstrap_url}|g" \
            -e "s|@RELEASE_VERSION@|${version}|g" \
            "${source}"
    else
        sed \
            -e 's|@PROJECT_URL@|https://REPLACE_WITH_RELEASE_HOST|g' \
            -e 's|@RELEASE_BASE_URL@|https://REPLACE_WITH_RELEASE_HOST/releases/download|g' \
            -e "s|@BOOTSTRAP_URL@|https://REPLACE_WITH_RELEASE_HOST/releases/download/v${version}/install-v${version}.sh|g" \
            -e "s|@RELEASE_VERSION@|${version}|g" \
            "${source}"
    fi
}

compare_archive_member() {
    local archive=$1
    local member=$2
    local source=$3

    cmp -s "${source}" <(tar -xOzf "${archive}" "${member}") ||
        die "packaged file differs from source: ${member}"
}

check_member_path() {
    local member=$1

    [[ ${member} != /* ]] || die "absolute archive member: ${member}"
    [[ /${member}/ != *'/../'* ]] || die "parent traversal archive member: ${member}"
    [[ ${member} != *'/._'* ]] || die "AppleDouble archive member: ${member}"
}

main() {
    local archive=${1:-}
    local project_root=${2:-}
    local project_url=${3:-}
    local archive_name root_name version arch target member digest path actual
    local actual_member_list expected_member_list manifest_file_list expected_manifest_file_list
    local actual_source_manifest expected_source_manifest source_digest
    local archive_binary_digest rebuilt_binary_digest
    local -a expected_files expected_members

    [[ -f ${archive} && -d ${project_root} ]] ||
        die 'usage: check-release.sh ARCHIVE PROJECT_ROOT [HTTPS_PROJECT_URL]'
    if [[ -n ${project_url} ]]; then
        [[ ${project_url} == https://* ]] ||
            die 'configured project URL must use HTTPS'
        [[ ${project_url} != *REPLACE_WITH_RELEASE_HOST* ]] ||
            die 'configured project URL is still a placeholder'
        [[ ${project_url} != *'|'* && ${project_url} != *'&'* ]] ||
            die 'configured project URL contains unsupported template characters'
    fi
    archive_name=$(basename "${archive}")
    [[ ${archive_name} =~ ^(socks-vps-v(.+)-linux-(amd64|arm64))\.tar\.gz$ ]] ||
        die "invalid archive name: ${archive_name}"
    root_name=${BASH_REMATCH[1]}
    version=${BASH_REMATCH[2]}
    arch=${BASH_REMATCH[3]}

    expected_files=(
        "${root_name}/MANIFEST.sha256"
        "${root_name}/README.md"
        "${root_name}/SOURCE_MANIFEST.sha256"
        "${root_name}/TARGET"
        "${root_name}/THIRD_PARTY_NOTICES.md"
        "${root_name}/VERSION"
        "${root_name}/assets/ipdeny/Copyrights.txt"
        "${root_name}/assets/ipdeny/MD5SUM.upstream"
        "${root_name}/assets/ipdeny/SOURCE.json"
        "${root_name}/assets/ipdeny/cn-aggregated.zone"
        "${root_name}/bin/socks-vps"
        "${root_name}/licenses/go-gost-gosocks5-LICENSE"
        "${root_name}/packaging/systemd/socks-vps-firewall.service"
        "${root_name}/packaging/systemd/socks-vps.service"
        "${root_name}/scripts/firewall.sh"
        "${root_name}/scripts/install.sh"
    )
    expected_members=(
        "${root_name}/"
        "${root_name}/assets/"
        "${root_name}/assets/ipdeny/"
        "${root_name}/bin/"
        "${root_name}/licenses/"
        "${root_name}/packaging/"
        "${root_name}/packaging/systemd/"
        "${root_name}/scripts/"
        "${expected_files[@]}"
    )

    actual_member_list=$(
        tar -tzf "${archive}" |
            while IFS= read -r member; do
                check_member_path "${member}"
                printf '%s\n' "${member}"
            done |
            LC_ALL=C sort
    )
    expected_member_list=$(printf '%s\n' "${expected_members[@]}" | LC_ALL=C sort)
    [[ ${actual_member_list} == "${expected_member_list}" ]] ||
        die 'archive member allowlist mismatch'

    target=$(tar -xOzf "${archive}" "${root_name}/TARGET")
    [[ ${target} == "linux/${arch}" ]] || die "TARGET mismatch: ${target}"
    [[ $(tar -xOzf "${archive}" "${root_name}/VERSION") == "${version}" ]] ||
        die 'VERSION does not match archive name'

    while read -r digest path; do
        [[ ${digest} =~ ^[0-9a-f]{64}$ ]] || die "invalid manifest digest for ${path}"
        [[ -n ${path} && ${path} != MANIFEST.sha256 ]] ||
            die 'invalid manifest path'
        actual=$(tar -xOzf "${archive}" "${root_name}/${path}" | sha256_stream)
        [[ ${actual} == "${digest}" ]] || die "manifest mismatch: ${path}"
    done < <(tar -xOzf "${archive}" "${root_name}/MANIFEST.sha256")
    manifest_file_list=$(
        tar -xOzf "${archive}" "${root_name}/MANIFEST.sha256" |
            awk '{print $2}' |
            LC_ALL=C sort
    )
    expected_manifest_file_list=$(
        printf '%s\n' "${expected_files[@]}" |
            sed "s|^${root_name}/||" |
            grep -Fvx MANIFEST.sha256 |
            LC_ALL=C sort
    )
    [[ ${manifest_file_list} == "${expected_manifest_file_list}" ]] ||
        die 'manifest path set does not match the archive allowlist'

    if [[ -f ${archive}.sha256 ]]; then
        read -r digest path <"${archive}.sha256" ||
            die 'could not read archive checksum'
        [[ ${digest} =~ ^[0-9a-f]{64}$ && -z ${path:-} ]] ||
            die 'archive checksum file has an invalid format'
        actual=$(sha256_stream <"${archive}")
        [[ ${actual} == "${digest}" ]] || die 'archive checksum mismatch'
    fi

    compare_archive_member \
        "${archive}" "${root_name}/scripts/install.sh" \
        "${project_root}/scripts/install.sh"
    compare_archive_member \
        "${archive}" "${root_name}/scripts/firewall.sh" \
        "${project_root}/scripts/firewall.sh"
    compare_archive_member \
        "${archive}" "${root_name}/THIRD_PARTY_NOTICES.md" \
        "${project_root}/THIRD_PARTY_NOTICES.md"
    compare_archive_member \
        "${archive}" "${root_name}/licenses/go-gost-gosocks5-LICENSE" \
        "${project_root}/packaging/licenses/go-gost-gosocks5-LICENSE"
    for path in cn-aggregated.zone Copyrights.txt MD5SUM.upstream SOURCE.json; do
        compare_archive_member \
            "${archive}" "${root_name}/assets/ipdeny/${path}" \
            "${project_root}/assets/ipdeny/${path}"
    done
    cmp -s \
        <(tar -xOzf "${archive}" "${root_name}/README.md") \
        <(render_release_stream \
            "${project_root}/README.md" "${version}" "${project_url}") ||
        die 'packaged README differs from the rendered source'
    cmp -s \
        <(tar -xOzf "${archive}" "${root_name}/packaging/systemd/socks-vps.service") \
        <(render_release_stream \
            "${project_root}/packaging/systemd/socks-vps.service" \
            "${version}" \
            "${project_url}") ||
        die 'packaged main unit differs from the rendered source'
    cmp -s \
        <(tar -xOzf "${archive}" "${root_name}/packaging/systemd/socks-vps-firewall.service") \
        <(render_release_stream \
            "${project_root}/packaging/systemd/socks-vps-firewall.service" \
            "${version}" \
            "${project_url}") ||
        die 'packaged firewall unit differs from the rendered source'

    actual_source_manifest=$(
        tar -xOzf "${archive}" "${root_name}/SOURCE_MANIFEST.sha256"
    )
    expected_source_manifest=$(source_manifest_text "${project_root}")
    [[ ${actual_source_manifest} == "${expected_source_manifest}" ]] ||
        die 'source manifest does not match the current source tree'
    source_digest=$(printf '%s\n' "${actual_source_manifest}" | sha256_stream)

    grep -Fxq 'require github.com/go-gost/gosocks5 v0.5.0' \
        "${project_root}/go.mod" ||
        die 'go.mod does not lock github.com/go-gost/gosocks5 v0.5.0'
    grep -Fxq \
        'github.com/go-gost/gosocks5 v0.5.0 h1:YE37l1MJwde8diIQdynStqogMotG5enoTdborhA5yic=' \
        "${project_root}/go.sum" ||
        die 'go.sum does not contain the expected gosocks5 v0.5.0 module checksum'
    archive_binary_digest=$(
        tar -xOzf "${archive}" "${root_name}/bin/socks-vps" |
            sha256_stream
    )
    rebuilt_binary_digest=$(
        (
            cd "${project_root}"
            CGO_ENABLED=0 GOOS=linux GOARCH="${arch}" \
                go build \
                    -mod=readonly \
                    -trimpath \
                    -ldflags="-buildid=${source_digest}" \
                    -o /dev/stdout \
                    ./cmd/socks-vps
        ) | sha256_stream
    )
    [[ ${archive_binary_digest} == "${rebuilt_binary_digest}" ]] ||
        die 'packaged binary does not match a locked rebuild from the current source tree'

    if [[ -n ${project_url} ]]; then
        if tar -xOzf "${archive}" "${root_name}/README.md" |
            grep -Fq REPLACE_WITH_RELEASE_HOST; then
            die 'configured release still contains the release-host placeholder'
        fi
        if tar -xOzf "${archive}" "${root_name}/packaging/systemd/socks-vps.service" |
            grep -Fq REPLACE_WITH_RELEASE_HOST; then
            die 'configured main unit still contains the release-host placeholder'
        fi
        if tar -xOzf "${archive}" "${root_name}/packaging/systemd/socks-vps-firewall.service" |
            grep -Fq REPLACE_WITH_RELEASE_HOST; then
            die 'configured firewall unit still contains the release-host placeholder'
        fi
    fi

    if command -v file >/dev/null 2>&1; then
        actual=$(tar -xOzf "${archive}" "${root_name}/bin/socks-vps" | file -)
        [[ ${actual} == *ELF* ]] || die 'packaged executable is not an ELF binary'
        case ${arch} in
            amd64)
                [[ ${actual} == *x86-64* || ${actual} == *x86_64* ]] ||
                    die 'packaged executable is not amd64'
                ;;
            arm64)
                [[ ${actual} == *ARM\ aarch64* || ${actual} == *aarch64* ]] ||
                    die 'packaged executable is not arm64'
                ;;
        esac
    fi

    printf 'Validated %s\n' "${archive}"
}

main "$@"
