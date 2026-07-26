#!/usr/bin/env bash

set -Eeuo pipefail

readonly script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly project_root=$(cd -- "${script_dir}/.." && pwd -P)
readonly asset_dir="${project_root}/assets/ipdeny"
readonly zone_url=https://www.ipdeny.com/ipblocks/data/aggregated/cn-aggregated.zone
readonly copyright_url=https://www.ipdeny.com/ipblocks/data/aggregated/Copyrights.txt
readonly md5_url=https://www.ipdeny.com/ipblocks/data/aggregated/MD5SUM

die() {
    printf 'update-ipdeny: %s\n' "$*" >&2
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

md5_file() {
    local path=$1

    if command -v md5sum >/dev/null 2>&1; then
        md5sum "${path}" | awk '{print $1}'
    elif command -v md5 >/dev/null 2>&1; then
        md5 -q "${path}"
    else
        die 'md5sum or md5 is required'
    fi
}

http_date_to_iso() {
    local value=$1

    if date -u -d "${value}" '+%Y-%m-%dT%H:%M:%SZ' >/dev/null 2>&1; then
        date -u -d "${value}" '+%Y-%m-%dT%H:%M:%SZ'
        return
    fi
    if date -j -u -f '%a, %d %b %Y %T %Z' "${value}" '+%Y-%m-%dT%H:%M:%SZ' \
        >/dev/null 2>&1; then
        date -j -u -f '%a, %d %b %Y %T %Z' "${value}" '+%Y-%m-%dT%H:%M:%SZ'
        return
    fi
    die "could not parse upstream Last-Modified header: ${value}"
}

main() {
    local timestamp stage history expected_md5 actual_md5 sha line_count
    local last_modified_raw last_modified answer path

    command -v curl >/dev/null 2>&1 || die 'curl is required'
    command -v go >/dev/null 2>&1 || die 'Go is required'
    timestamp=$(date -u +%Y%m%dT%H%M%SZ)
    stage="${asset_dir}/.updates/${timestamp}"
    history="${asset_dir}/.history/${timestamp}"
    [[ ! -e ${stage} ]] || die "staging path already exists: ${stage}"
    [[ ! -e ${history} ]] || die "history path already exists: ${history}"
    install -d "${stage}"

    printf 'Fetching each IPdeny upstream artifact once.\n'
    curl --fail --silent --show-error --location \
        --proto '=https' --tlsv1.2 \
        --dump-header "${stage}/zone.headers" \
        --output "${stage}/cn-aggregated.zone" \
        "${zone_url}"
    sleep 1
    curl --fail --silent --show-error --location \
        --proto '=https' --tlsv1.2 \
        --output "${stage}/Copyrights.txt" \
        "${copyright_url}"
    sleep 1
    curl --fail --silent --show-error --location \
        --proto '=https' --tlsv1.2 \
        --output "${stage}/MD5SUM.upstream" \
        "${md5_url}"

    [[ -s ${stage}/cn-aggregated.zone ]] || die 'downloaded zone is empty'
    [[ -s ${stage}/Copyrights.txt ]] || die 'downloaded copyright notice is empty'
    [[ -s ${stage}/MD5SUM.upstream ]] || die 'downloaded MD5SUM is empty'
    (
        cd "${project_root}"
        go run ./cmd/socks-vps ipdeny-check --zone "${stage}/cn-aggregated.zone"
    )

    expected_md5=$(awk '$2 == "cn-aggregated.zone" {print $1}' "${stage}/MD5SUM.upstream")
    [[ ${expected_md5} =~ ^[0-9a-fA-F]{32}$ ]] ||
        die 'upstream MD5SUM has no valid CN entry'
    actual_md5=$(md5_file "${stage}/cn-aggregated.zone")
    actual_md5=$(printf '%s' "${actual_md5}" | tr '[:upper:]' '[:lower:]')
    expected_md5=$(printf '%s' "${expected_md5}" | tr '[:upper:]' '[:lower:]')
    [[ ${actual_md5} == ${expected_md5} ]] || die 'upstream MD5 mismatch'

    last_modified_raw=$(awk '
        tolower($0) ~ /^last-modified:/ {
            sub(/^[^:]*:[[:space:]]*/, "")
            sub(/\r$/, "")
            print
            exit
        }
    ' "${stage}/zone.headers")
    [[ -n ${last_modified_raw} ]] || die 'zone response has no Last-Modified header'
    last_modified=$(http_date_to_iso "${last_modified_raw}")
    sha=$(sha256_file "${stage}/cn-aggregated.zone")
    line_count=$(wc -l <"${stage}/cn-aggregated.zone" | tr -d '[:space:]')

    printf '%s\n' \
        '{' \
        '  "dataset": "IPdeny CN IPv4 aggregated zone",' \
        "  \"source_url\": \"${zone_url}\"," \
        "  \"copyright_url\": \"${copyright_url}\"," \
        "  \"upstream_md5_url\": \"${md5_url}\"," \
        "  \"fetched_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"," \
        "  \"upstream_last_modified\": \"${last_modified}\"," \
        "  \"upstream_md5\": \"${actual_md5}\"," \
        "  \"sha256\": \"${sha}\"," \
        "  \"line_count\": ${line_count}" \
        '}' >"${stage}/SOURCE.json"

    (
        cd "${project_root}"
        go run ./cmd/socks-vps firewall-render \
            --port 1080 \
            --zone "${stage}/cn-aggregated.zone" \
            --output "${stage}/socks-vps.nft"
    )
    if command -v nft >/dev/null 2>&1; then
        nft --check --file "${stage}/socks-vps.nft"
    else
        printf 'Generated staged nftables rules; Linux nft syntax acceptance is pending CI/VPS.\n'
    fi

    printf 'Validated raw update in %s\n' "${stage}"
    printf 'The following repository files will be moved to %s and replaced:\n' "${history}"
    printf '  %s\n' \
        "${asset_dir}/cn-aggregated.zone" \
        "${asset_dir}/Copyrights.txt" \
        "${asset_dir}/MD5SUM.upstream" \
        "${asset_dir}/SOURCE.json"
    IFS= read -r -p 'Apply this repository data update? [y/N]: ' answer
    [[ ${answer} == y || ${answer} == Y ]] || exit 0

    install -d "${history}"
    for path in cn-aggregated.zone Copyrights.txt MD5SUM.upstream SOURCE.json; do
        mv "${asset_dir}/${path}" "${history}/${path}"
        mv "${stage}/${path}" "${asset_dir}/${path}"
    done
    (
        cd "${project_root}"
        go test -mod=readonly ./...
    )
    printf 'IPdeny source data updated. Review and commit the four canonical files.\n'
}

main "$@"
