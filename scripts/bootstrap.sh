#!/usr/bin/env bash

set +x
set -Eeuo pipefail

readonly release_base_url='@RELEASE_BASE_URL@'
readonly release_version='@RELEASE_VERSION@'
readonly archive_sha256_amd64='@ARCHIVE_SHA256_AMD64@'
readonly archive_sha256_arm64='@ARCHIVE_SHA256_ARM64@'

bootstrap_temp_dir=''

readonly color_reset=$'\033[0m'
readonly color_cyan=$'\033[36m'
readonly color_yellow=$'\033[33m'
readonly color_green=$'\033[32m'
readonly color_red=$'\033[31m'

supports_color() {
    local fd=$1

    [[ ${TERM:-} != dumb && -t ${fd} ]]
}

status_line() {
    local kind=$1
    local text=$2
    local fd=${3:-1}
    local color symbol

    case ${kind} in
        info)
            color=${color_cyan}
            symbol='•'
            ;;
        progress)
            color=${color_yellow}
            symbol='→'
            ;;
        success)
            color=${color_green}
            symbol='✓'
            ;;
        error)
            color=${color_red}
            symbol='✗'
            ;;
        *)
            color=
            symbol='•'
            ;;
    esac
    if supports_color "${fd}"; then
        printf '%s%s %s%s\n' "${color}" "${symbol}" "${text}" "${color_reset}" >&"${fd}"
    else
        printf '%s %s\n' "${symbol}" "${text}" >&"${fd}"
    fi
}

die() {
    status_line error "$*" 2
    exit 1
}

info() {
    status_line info "$*"
}

note() {
    status_line progress "$*"
}

success() {
    status_line success "$*"
}

sha256_file() {
    local path=$1

    sha256sum -- "${path}" | awk '{print $1}'
}

cleanup_temp_dir() {
    if [[ -n ${bootstrap_temp_dir} ]]; then
        rm -rf -- "${bootstrap_temp_dir}"
        bootstrap_temp_dir=''
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
            die "不支持的处理器架构：$(uname -m)"
            ;;
    esac
}

check_member_path() {
    local member=$1

    [[ ${member} != /* ]] || die "安装包包含绝对路径：${member}"
    [[ /${member}/ != *'/../'* ]] || die "安装包包含上级目录路径：${member}"
    [[ ${member} != *'/._'* ]] || die "安装包包含 AppleDouble 元数据：${member}"
}

main() {
    local arch archive archive_url expected actual work_dir package_root

    note '正在检查运行环境'
    [[ $(uname -s) == Linux ]] || die '仅支持 Linux 系统'
    command -v systemctl >/dev/null 2>&1 || die '未找到 systemctl，需要 systemd'
    [[ -d /run/systemd/system ]] || die 'systemd 未运行'
    command -v curl >/dev/null 2>&1 || die '未找到 curl'
    command -v tar >/dev/null 2>&1 || die '未找到 tar'
    command -v sha256sum >/dev/null 2>&1 || die '未找到 sha256sum'

    [[ ${release_base_url} != *REPLACE_WITH_RELEASE_HOST* ]] ||
        die '发布地址尚未配置'
    [[ ${release_base_url} == https://* ]] || die '发布地址必须使用 HTTPS'
    [[ ${release_version} =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] ||
        die '发布版本格式无效'

    arch=$(detect_arch)
    case ${arch} in
        amd64)
            expected=${archive_sha256_amd64}
            ;;
        arm64)
            expected=${archive_sha256_arm64}
            ;;
    esac
    [[ ${expected} =~ ^[0-9a-fA-F]{64}$ ]] ||
        die '内置安装包校验值无效'
    success '运行环境检查通过'

    archive="socks-vps-v${release_version}-linux-${arch}.tar.gz"
    archive_url="${release_base_url%/}/v${release_version}/${archive}"
    work_dir=$(mktemp -d "${TMPDIR:-/tmp}/socks-vps-bootstrap.XXXXXXXX")
    bootstrap_temp_dir=${work_dir}
    trap cleanup_temp_dir EXIT

    note "正在下载 Socks-VPS ${release_version}（linux/${arch}）"
    curl --fail --silent --show-error --location \
        --proto '=https' --tlsv1.2 \
        --output "${work_dir}/${archive}" "${archive_url}"

    note '正在校验安装包'
    actual=$(sha256_file "${work_dir}/${archive}")
    actual=$(printf '%s' "${actual}" | tr '[:upper:]' '[:lower:]')
    expected=$(printf '%s' "${expected}" | tr '[:upper:]' '[:lower:]')
    [[ ${actual} == ${expected} ]] || die '安装包校验失败'

    while IFS= read -r member; do
        check_member_path "${member}"
    done < <(tar -tzf "${work_dir}/${archive}")

    tar -xzf "${work_dir}/${archive}" -C "${work_dir}"
    package_root="${work_dir}/socks-vps-v${release_version}-linux-${arch}"
    [[ -x ${package_root}/scripts/install.sh ]] ||
        die '安装包中缺少安装程序'
    success '安装包校验通过'

    note '正在启动 Socks-VPS 安装程序'
    "${package_root}/scripts/install.sh" "$@"
}

main "$@"
