#!/usr/bin/env bash

set +x
set -Eeuo pipefail

readonly binary=/usr/local/bin/socks-vps
readonly config_dir=/etc/socks-vps/instances
readonly zone=/usr/local/lib/socks-vps/current/assets/ipdeny/cn-aggregated.zone
readonly runtime_dir=/run/socks-vps
readonly existing_json="${runtime_dir}/existing-table.json"
readonly rules_file="${runtime_dir}/socks-vps.nft"
readonly remove_file="${runtime_dir}/remove-socks-vps.nft"

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

note() {
    status_line progress "$*"
}

success() {
    status_line success "$*"
}

cleanup_runtime_files() {
    rm -f -- \
        "${existing_json}" \
        "${rules_file}" \
        "${remove_file}" \
        "${runtime_dir}/nft-list.stderr" \
        "${runtime_dir}/nft-tables.txt"
}

require_root() {
    [[ ${EUID} -eq 0 ]] || die '此操作需要 root 权限'
}

prepare_runtime_dir() {
    install -d -m 0750 -o root -g root "${runtime_dir}"
}

require_apply_runtime() {
    [[ -x ${binary} ]] || die "缺少可执行文件：${binary}"
    [[ -d ${config_dir} ]] || die "缺少配置目录：${config_dir}"
    prepare_runtime_dir
}

require_remove_runtime() {
    [[ -x ${binary} ]] || die "缺少可执行文件：${binary}"
    prepare_runtime_dir
}

nft_available() {
    command -v nft >/dev/null 2>&1
}

blocked_cn_ports() {
    "${binary}" config-ports \
        --config-dir "${config_dir}" \
        --blocked-cn-only
}

capture_existing_table() {
    local stderr_file="${runtime_dir}/nft-list.stderr"
    local tables_file="${runtime_dir}/nft-tables.txt"

    if nft --json list table ip socks_vps >"${existing_json}" 2>"${stderr_file}"; then
        printf '%s\n' present
        return 0
    fi

    if ! nft list tables >"${tables_file}" 2>>"${stderr_file}"; then
        cat "${stderr_file}" >&2
        die '无法检查 nftables 表'
    fi
    if grep -Eq '^[[:space:]]*table ip socks_vps[[:space:]]*$' "${tables_file}"; then
        cat "${stderr_file}" >&2
        die '无法检查现有的 table ip socks_vps'
    fi

    : >"${existing_json}"
    printf '%s\n' absent
}

render_apply_batch() {
    local table_state=$1
    local blocked_ports=$2
    local -a render_args

    render_args=(
        firewall-render
        --config-dir "${config_dir}"
        --output "${rules_file}"
    )
    if [[ -n ${blocked_ports} ]]; then
        [[ -r ${zone} ]] || die "缺少 IPdeny 地址库：${zone}"
        render_args+=(--zone "${zone}")
    fi
    if [[ ${table_state} == present ]]; then
        render_args+=(--existing-table-json "${existing_json}")
    fi

    "${binary}" "${render_args[@]}" >/dev/null
}

render_remove_batch() {
    "${binary}" firewall-render \
        --remove \
        --existing-table-json "${existing_json}" \
        --output "${remove_file}" >/dev/null
}

apply_batch() {
    local path=$1

    nft --check --file "${path}"
    nft --file "${path}"
}

batch_has_commands() {
    [[ -s $1 ]]
}

record_owned_table() {
    nft --json list table ip socks_vps >"${existing_json}"
}

owned_table_is_absent() {
    ! nft list table ip socks_vps >/dev/null 2>&1
}

apply_rules() {
    local blocked_ports table_state

    blocked_ports=$(blocked_cn_ports)
    if ! nft_available; then
        [[ -z ${blocked_ports} ]] && return 0
        die '存在拦截中国大陆来源的端口，但系统未找到 nft'
    fi

    table_state=$(capture_existing_table)
    render_apply_batch "${table_state}" "${blocked_ports}"
    if ! batch_has_commands "${rules_file}"; then
        return 0
    fi
    apply_batch "${rules_file}"

    if [[ -n ${blocked_ports} ]]; then
        record_owned_table
    elif ! owned_table_is_absent; then
        die '关闭中国大陆来源拦截后，自有 nftables 表仍然存在'
    fi
}

remove_rules() {
    local table_state

    if ! nft_available; then
        die '未找到 nft，无法确认并移除自有 nftables 表'
    fi

    table_state=$(capture_existing_table)
    if [[ ${table_state} == absent ]]; then
        return 0
    fi

    render_remove_batch || die '无法判断现有 nftables 表的所有权'
    if ! batch_has_commands "${remove_file}"; then
        status_line info '现有的 table ip socks_vps 不属于 Socks-VPS，已保留原状'
        return 0
    fi
    apply_batch "${remove_file}"

    if ! owned_table_is_absent; then
        die '自有 nftables 表移除后仍然存在'
    fi
}

reload_rules() {
    local status

    if "$0" apply; then
        return 0
    else
        status=$?
    fi
    if ! systemctl --no-block stop socks-vps.service; then
        die '防火墙规则重载失败，并且无法安排停止主服务'
    fi
    status_line error '防火墙规则重载失败，已安排停止主服务' 2
    return "${status}"
}

main() {
    require_root
    trap cleanup_runtime_files EXIT

    case ${1:-} in
        apply)
            require_apply_runtime
            note '正在同步 Socks-VPS 防火墙规则'
            apply_rules
            success 'Socks-VPS 防火墙规则已同步'
            ;;
        reload)
            reload_rules
            ;;
        remove)
            require_remove_runtime
            note '正在移除 Socks-VPS 自有防火墙规则'
            remove_rules
            success 'Socks-VPS 防火墙清理完成'
            ;;
        *)
            die '用法：firewall.sh {apply|reload|remove}'
            ;;
    esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
