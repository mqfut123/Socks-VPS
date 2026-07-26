#!/usr/bin/env bash

set -Eeuo pipefail

readonly script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly project_root=$(cd -- "${script_dir}/.." && pwd -P)

die() {
    printf 'build-release: %s\n' "$*" >&2
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

source_input_paths() {
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

write_source_manifest() {
    local destination=$1
    local relative digest

    while IFS= read -r relative; do
        [[ -f ${project_root}/${relative} ]] ||
            die "source input is missing: ${relative}"
        digest=$(sha256_file "${project_root}/${relative}")
        printf '%s  %s\n' "${digest}" "${relative}"
    done < <(source_input_paths) >"${destination}"
}

verify_dependency_lock() {
    grep -Fxq 'require github.com/go-gost/gosocks5 v0.5.0' \
        "${project_root}/go.mod" ||
        die 'go.mod does not lock github.com/go-gost/gosocks5 v0.5.0'
    grep -Fxq \
        'github.com/go-gost/gosocks5 v0.5.0 h1:YE37l1MJwde8diIQdynStqogMotG5enoTdborhA5yic=' \
        "${project_root}/go.sum" ||
        die 'go.sum does not contain the expected gosocks5 v0.5.0 module checksum'
}

verify_binary_metadata() {
    local binary=$1
    local arch=$2
    local source_digest=$3
    local metadata build_id

    metadata=$(go version -m "${binary}") ||
        die "could not read Go build metadata from ${binary}"
    grep -Fqx \
        $'\tdep\tgithub.com/go-gost/gosocks5\tv0.5.0\th1:YE37l1MJwde8diIQdynStqogMotG5enoTdborhA5yic=' \
        <<<"${metadata}" ||
        die 'built binary dependency metadata does not match the locked gosocks5 module'
    grep -Fqx $'\tbuild\tGOOS=linux' <<<"${metadata}" ||
        die 'built binary metadata does not declare GOOS=linux'
    grep -Fqx $'\tbuild\tGOARCH='"${arch}" <<<"${metadata}" ||
        die "built binary metadata does not declare GOARCH=${arch}"
    grep -Fqx $'\tbuild\tCGO_ENABLED=0' <<<"${metadata}" ||
        die 'built binary metadata does not declare CGO_ENABLED=0'
    build_id=$(go tool buildid "${binary}") ||
        die "could not read Go build ID from ${binary}"
    [[ ${build_id} == "${source_digest}" ]] ||
        die 'built binary build ID does not match the source manifest'
}

render_release_text() {
    local source=$1
    local destination=$2
    local version=$3
    local project_url=$4
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
            "${source}" >"${destination}"
    else
        sed \
            -e 's|@PROJECT_URL@|https://REPLACE_WITH_RELEASE_HOST|g' \
            -e 's|@RELEASE_BASE_URL@|https://REPLACE_WITH_RELEASE_HOST/releases/download|g' \
            -e "s|@BOOTSTRAP_URL@|https://REPLACE_WITH_RELEASE_HOST/releases/download/v${version}/install-v${version}.sh|g" \
            -e "s|@RELEASE_VERSION@|${version}|g" \
            "${source}" >"${destination}"
    fi
}

copy_release_files() {
    local stage=$1
    local version=$2
    local arch=$3
    local project_url=$4
    local source_digest

    install -d \
        "${stage}/bin" \
        "${stage}/scripts" \
        "${stage}/packaging/systemd" \
        "${stage}/assets/ipdeny" \
        "${stage}/licenses"

    write_source_manifest "${stage}/SOURCE_MANIFEST.sha256"
    source_digest=$(sha256_file "${stage}/SOURCE_MANIFEST.sha256")
    (
        cd "${project_root}"
        CGO_ENABLED=0 GOOS=linux GOARCH="${arch}" \
            go build \
                -buildvcs=false \
                -mod=readonly \
                -trimpath \
                -ldflags="-buildid=${source_digest}" \
                -o "${stage}/bin/socks-vps" \
                ./cmd/socks-vps
    )
    verify_binary_metadata "${stage}/bin/socks-vps" "${arch}" "${source_digest}"
    install -m 0755 "${project_root}/scripts/install.sh" "${stage}/scripts/install.sh"
    install -m 0755 "${project_root}/scripts/firewall.sh" "${stage}/scripts/firewall.sh"
    render_release_text \
        "${project_root}/packaging/systemd/socks-vps.service" \
        "${stage}/packaging/systemd/socks-vps.service" \
        "${version}" \
        "${project_url}"
    render_release_text \
        "${project_root}/packaging/systemd/socks-vps-firewall.service" \
        "${stage}/packaging/systemd/socks-vps-firewall.service" \
        "${version}" \
        "${project_url}"
    install -m 0644 \
        "${project_root}/assets/ipdeny/cn-aggregated.zone" \
        "${project_root}/assets/ipdeny/Copyrights.txt" \
        "${project_root}/assets/ipdeny/MD5SUM.upstream" \
        "${project_root}/assets/ipdeny/SOURCE.json" \
        "${stage}/assets/ipdeny/"
    install -m 0644 \
        "${project_root}/packaging/licenses/go-gost-gosocks5-LICENSE" \
        "${stage}/licenses/go-gost-gosocks5-LICENSE"
    install -m 0644 "${project_root}/THIRD_PARTY_NOTICES.md" "${stage}/"
    render_release_text \
        "${project_root}/README.md" \
        "${stage}/README.md" \
        "${version}" \
        "${project_url}"
    printf '%s\n' "${version}" >"${stage}/VERSION"
    printf 'linux/%s\n' "${arch}" >"${stage}/TARGET"
}

write_manifest() {
    local stage=$1
    local relative digest

    (
        cd "${stage}"
        while IFS= read -r relative; do
            digest=$(sha256_file "${relative}")
            printf '%s  %s\n' "${digest}" "${relative}"
        done < <(find . -type f ! -name MANIFEST.sha256 -print |
            sed 's|^\./||' |
            LC_ALL=C sort)
    ) >"${stage}/MANIFEST.sha256"
}

build_target() {
    local version=$1
    local arch=$2
    local project_url=$3
    local root_name="socks-vps-v${version}-linux-${arch}"
    local stage="${project_root}/dist/staging/${root_name}"
    local archive="${project_root}/dist/${root_name}.tar.gz"
    local digest

    [[ ! -e ${stage} ]] || die "staging path already exists: ${stage}"
    [[ ! -e ${archive} ]] || die "archive already exists: ${archive}"
    [[ ! -e ${archive}.sha256 ]] || die "checksum already exists: ${archive}.sha256"

    install -d "${stage}"
    copy_release_files "${stage}" "${version}" "${arch}" "${project_url}"
    write_manifest "${stage}"

    if tar --version 2>&1 | grep -Fq bsdtar; then
        COPYFILE_DISABLE=1 COPY_EXTENDED_ATTRIBUTES_DISABLE=1 \
            tar -czf "${archive}" \
                --no-xattrs --no-acls --no-fflags \
                --uid 0 --gid 0 --uname root --gname root \
                -C "${project_root}/dist/staging" "${root_name}"
    else
        tar -czf "${archive}" \
            --owner=0 --group=0 --numeric-owner \
            -C "${project_root}/dist/staging" "${root_name}"
    fi
    digest=$(sha256_file "${archive}")
    printf '%s\n' "${digest}" >"${archive}.sha256"
    "${script_dir}/check-release.sh" "${archive}" "${project_root}" "${project_url}"
}

main() {
    local version=${1:-}
    local project_url=${2:-}
    local rendered_bootstrap="${project_root}/dist/install-v${version}.sh"

    [[ ${version} =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] ||
        die 'usage: build-release.sh VERSION [HTTPS_PROJECT_URL]'
    if [[ -n ${project_url} ]]; then
        [[ ${project_url} == https://* ]] || die 'project URL must use HTTPS'
        [[ ${project_url} != *'|'* && ${project_url} != *'&'* ]] ||
            die 'project URL contains unsupported template characters'
        [[ ${project_url} != *REPLACE_WITH_RELEASE_HOST* ]] ||
            die 'project URL is still a placeholder'
        grep -Fq \
            "${project_url%/}/releases/download/v${version}/install-v${version}.sh" \
            "${project_root}/README.md" ||
            die 'README installation command does not match the project URL and version'
    fi

    require_go_files=("${project_root}/go.mod" "${project_root}/go.sum")
    for required in "${require_go_files[@]}"; do
        [[ -f ${required} ]] || die "missing Go dependency lock: ${required}"
    done
    verify_dependency_lock
    [[ ! -e ${rendered_bootstrap} ]] ||
        die "bootstrap output already exists: ${rendered_bootstrap}"

    (
        cd "${project_root}"
        go mod verify
        go test -mod=readonly ./...
    )
    install -d "${project_root}/dist/staging"
    build_target "${version}" amd64 "${project_url}"
    build_target "${version}" arm64 "${project_url}"
    render_release_text \
        "${project_root}/scripts/bootstrap.sh" \
        "${rendered_bootstrap}" \
        "${version}" \
        "${project_url}"
    chmod 0755 "${rendered_bootstrap}"

    if [[ -z ${project_url} ]]; then
        printf 'Local packages built. Public release is blocked until HTTPS_PROJECT_URL is supplied.\n'
        return 0
    fi
    "${script_dir}/check-public-release.sh" "${rendered_bootstrap}" "${project_url}" "${version}"
}

main "$@"
