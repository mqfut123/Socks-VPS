#!/usr/bin/env bash

set +x
set -Eeuo pipefail

readonly script_path=$(readlink -f -- "${BASH_SOURCE[0]}")
readonly script_dir=$(cd -- "$(dirname -- "${script_path}")" && pwd -P)

readonly package_root=$(cd -- "${script_dir}/.." && pwd -P)
readonly package_binary="${package_root}/bin/socks-vps"
readonly package_version_file="${package_root}/VERSION"
readonly package_target_file="${package_root}/TARGET"
readonly latest_installer_url='@BOOTSTRAP_URL@'

readonly config_dir=/etc/socks-vps
readonly instances_dir="${config_dir}/instances"
readonly legacy_config_file="${config_dir}/config.json"
readonly install_root=/usr/local/lib/socks-vps
readonly releases_dir="${install_root}/releases"
readonly current_link="${install_root}/current"
readonly public_binary=/usr/local/bin/socks-vps
readonly control_binary=/usr/local/bin/socks-vpsctl
readonly main_unit=/etc/systemd/system/socks-vps.service
readonly firewall_unit=/etc/systemd/system/socks-vps-firewall.service
readonly backup_root=/var/backups/socks-vps
readonly runtime_dir=/run/socks-vps
readonly transaction_fallback_root=/var/tmp
installed_release_dir=
transaction_dir=
transaction_active=false
transaction_kind=
transaction_current_target=
transaction_public_kind=
transaction_public_target=
transaction_control_target=
transaction_control_present=false
transaction_new_release=

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

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "缺少必需命令：$1"
}

read_package_version() {
    local version

    [[ -r ${package_version_file} ]] || die '安装包缺少版本信息'
    IFS= read -r version <"${package_version_file}" || die '无法读取安装包版本'
    [[ ${version} =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] ||
        die "安装包版本无效：${version}"
    printf '%s\n' "${version}"
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
            die "不支持当前架构：$(uname -m)"
            ;;
    esac
}

check_package() {
    local version=$1
    local arch target
    local required
    local -a required_files=(
        "VERSION"
        "TARGET"
        "bin/socks-vps"
        "scripts/install.sh"
        "scripts/firewall.sh"
        "packaging/systemd/socks-vps.service"
        "packaging/systemd/socks-vps-firewall.service"
        "assets/ipdeny/cn-aggregated.zone"
        "assets/ipdeny/Copyrights.txt"
        "assets/ipdeny/MD5SUM.upstream"
        "assets/ipdeny/SOURCE.json"
        "LICENSE"
        "licenses/go-gost-gosocks5-LICENSE"
        "THIRD_PARTY_NOTICES.md"
        "README.md"
        "SOURCE_MANIFEST.sha256"
        "MANIFEST.sha256"
    )

    [[ $(uname -s) == Linux ]] || die '仅支持 Linux'
    require_command systemctl
    require_command sha256sum
    [[ -d /run/systemd/system ]] || die 'systemd 未运行'

    arch=$(detect_arch)
    [[ -r ${package_target_file} ]] || die '安装包缺少平台信息'
    IFS= read -r target <"${package_target_file}" || die '无法读取安装包平台'
    [[ ${target} == "linux/${arch}" ]] ||
        die "安装包平台 ${target} 与当前 linux/${arch} 不匹配"

    for required in "${required_files[@]}"; do
        [[ -f ${package_root}/${required} ]] ||
            die "安装包不完整：缺少 ${required}"
    done
    [[ -x ${package_binary} ]] || die '安装包内的主程序不可执行'
    [[ -x ${package_root}/scripts/firewall.sh ]] || die '安装包内的防火墙脚本不可执行'
    [[ ${version} == "$(read_package_version)" ]] || die '校验期间安装包版本发生变化'

    (
        cd "${package_root}"
        sha256sum --quiet --check MANIFEST.sha256
    ) || die '安装包完整性校验失败'
}

choose_port() {
    local requested

    IFS= read -r -p 'TCP 端口 [回车 = 随机选择 1024-65535]：' requested
    if [[ -z ${requested} ]]; then
        selected_port_mode=automatic
        selected_port=$("${package_binary}" port-select)
    else
        selected_port_mode=manual
        selected_port=${requested}
    fi
}

choose_cn_access() {
    local answer

    IFS= read -r -p '是否阻止中国大陆 IPv4 TCP 访问？[Y/n]：' answer
    case ${answer:-y} in
        y | Y | yes | YES | Yes)
            selected_allow_cn=false
            ;;
        n | N | no | NO | No)
            selected_allow_cn=true
            ;;
        *)
            die '请输入 y 或 n'
            ;;
    esac
}

generate_secret_pair() {
    local descriptor

    exec {descriptor}< <("${package_binary}" credentials-generate)
    IFS= read -r -d '' selected_username <&"${descriptor}" ||
        die '无法生成用户名'
    IFS= read -r -d '' selected_password <&"${descriptor}" ||
        die '无法生成密码'
    exec {descriptor}<&-
}

read_replacement_secret_pair() {
    local requested_username requested_password
    local generated_username generated_password descriptor

    exec {descriptor}< <("${package_binary}" credentials-generate)
    IFS= read -r -d '' generated_username <&"${descriptor}" ||
        die '无法生成用户名'
    IFS= read -r -d '' generated_password <&"${descriptor}" ||
        die '无法生成密码'
    exec {descriptor}<&-

    IFS= read -r -p '新用户名 [回车 = 安全随机值]：' requested_username
    IFS= read -r -s -p '新密码 [回车 = 安全随机值]：' requested_password
    printf '\n'
    selected_username=${requested_username:-${generated_username}}
    selected_password=${requested_password:-${generated_password}}
}

check_new_config_without_write() {
    local port=$1
    local version=$2
    local username=$3
    local password=$4
    local allow_cn=$5

    if ! printf '%s\0%s\0' "${username}" "${password}" |
        "${package_binary}" config-create \
            --check \
            --port "${port}" \
            --allow-cn="${allow_cn}" \
            --version "${version}" >/dev/null; then
        die '配置输入无效'
    fi
}

installation_exists() {
    [[ (-d ${instances_dir} || -f ${legacy_config_file}) &&
       -L ${current_link} &&
       (-f ${public_binary} || -L ${public_binary}) ]]
}

installation_entry_exists() {
    [[ -L ${current_link} &&
       (-f ${public_binary} || -L ${public_binary}) ]]
}

installation_detected() {
    local path

    for path in \
        "${config_dir}" \
        "${install_root}" \
        "${public_binary}" \
        "${control_binary}" \
        "${main_unit}" \
        "${firewall_unit}"; do
        if [[ -e ${path} || -L ${path} ]]; then
            return 0
        fi
    done
    return 1
}

show_status() {
    local healthy=true
    local config_healthy=false
    local legacy_config=false

    printf 'Socks-VPS 服务：'
    if systemctl is-active --quiet socks-vps.service; then
        printf '运行中\n'
    else
        printf '未运行\n'
        healthy=false
    fi

    printf '防火墙服务：'
    if systemctl is-active --quiet socks-vps-firewall.service; then
        printf '运行中\n'
    else
        printf '未运行\n'
        healthy=false
    fi

    if [[ -x ${public_binary} ]]; then
        if [[ -d ${instances_dir} ]] &&
           "${public_binary}" config-check \
               --config-dir "${instances_dir}" >/dev/null 2>&1; then
            config_healthy=true
        elif [[ -f ${legacy_config_file} ]] &&
             "${public_binary}" config-check \
                 --config "${legacy_config_file}" >/dev/null 2>&1; then
            config_healthy=true
            legacy_config=true
        fi
    fi
    if [[ ${config_healthy} == true ]]; then
        printf '配置检查：正常\n'
    else
        printf '配置检查：异常\n'
        healthy=false
    fi

    if [[ ${config_healthy} == true ]] &&
       current_service_owns_configured_listener >/dev/null 2>&1; then
        printf '监听与认证：正常\n'
    else
        printf '监听与认证：异常\n'
        healthy=false
    fi

    if [[ ${config_healthy} == true ]] &&
       required_firewall_state_is_healthy; then
        printf '防火墙规则：正常\n'
    else
        printf '防火墙规则：异常\n'
        healthy=false
    fi

    if [[ ${healthy} == true ]]; then
        success 'Socks-VPS 运行正常'
    else
        status_line error 'Socks-VPS 当前不可用，请查看上方状态和 systemd 日志' 2
    fi

    if [[ ${config_healthy} == true ]]; then
        printf '\n'
        if [[ ${legacy_config} == true ]]; then
            print_instance_summary socks-1 "${legacy_config_file}"
        else
            list_instances
        fi
    fi
}

choose_existing_action() {
    local choice

    status_line info '检测到现有 Socks-VPS'
    printf '  1) 查看状态与 SOCKS 列表\n'
    printf '  2) 更新\n'
    printf '  3) 新增 SOCKS\n'
    printf '  4) 修改凭据\n'
    printf '  5) 删除 SOCKS\n'
    printf '  6) 重装并永久替换全部 SOCKS 配置\n'
    printf '  7) 清理日志\n'
    printf '  8) 永久卸载\n'
    printf '  9) 取消\n'
    IFS= read -r -p '请选择：' choice

    case ${choice} in
        1)
            ensure_root_for_command status
            show_status
            exit 0
            ;;
        2)
            if [[ $(readlink -f "${current_link}") == "${package_root}" ]]; then
                run_latest_update
            else
                direct_update
            fi
            exit 0
            ;;
        3)
            selected_action=add
            choose_port
            choose_cn_access
            generate_secret_pair
            ;;
        4)
            ensure_root_for_command credentials
            direct_credentials ''
            exit 0
            ;;
        5)
            ensure_root_for_command remove
            direct_remove ''
            exit 0
            ;;
        6)
            selected_action=reinstall
            selected_instance_name=socks-1
            choose_port
            choose_cn_access
            generate_secret_pair
            ;;
        7)
            direct_cleanup
            exit 0
            ;;
        8)
            selected_action=uninstall
            selected_port_mode=preserve
            selected_port=0
            selected_username=
            selected_password=
            selected_allow_cn=false
            ;;
        9)
            exit 0
            ;;
        *)
            die '选择无效'
            ;;
    esac
}

print_impact() {
    local action=$1
    local _version=$2

    case ${action} in
        uninstall)
            printf '将永久卸载 Socks-VPS，包括全部配置、版本、命令、服务、防火墙规则、历史备份、运行目录以及专用用户和组。\n'
            ;;
        reinstall)
            printf '重装会永久删除全部现有 SOCKS 配置，只创建一组新配置。\n'
            ;;
        *)
            return
            ;;
    esac
    printf 'WARP VPS Manager 不会被修改，共享系统软件包不会被删除。\n'
}

confirm_action() {
    local answer

    IFS= read -r -p '确认继续？[y/N]：' answer
    [[ ${answer} == y || ${answer} == Y ]] || exit 0
}

run_privileged() {
    local action=$1
    local mode=$2
    local port=$3
    local version=$4
    local allow_cn=$5
    local instance_name=$6
    local username=$7
    local password=$8

    if [[ ${action} == uninstall ]]; then
        require_owned_installation false
    fi
    if [[ ${action} != cleanup ]]; then
        confirm_system_dependency_installation
    fi

    if [[ ${EUID} -eq 0 ]]; then
        privileged_apply \
            "${action}" \
            "${mode}" \
            "${port}" \
            "${version}" \
            "${allow_cn}" \
            "${instance_name}" \
            "${username}" \
            "${password}"
        return
    fi

    require_command sudo
    sudo -v </dev/tty
    printf '%s\0%s\0' "${username}" "${password}" |
        sudo -- "${script_dir}/install.sh" \
            --privileged-apply \
            "${action}" \
            "${mode}" \
            "${port}" \
            "${version}" \
            "${allow_cn}" \
            "${instance_name}"
}

require_root() {
    [[ ${EUID} -eq 0 ]] || die '当前操作必须以 root 权限执行'
}

detect_package_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        printf '%s\n' apt
    elif command -v dnf >/dev/null 2>&1; then
        printf '%s\n' dnf
    elif command -v yum >/dev/null 2>&1; then
        printf '%s\n' yum
    else
        die '系统需要 apt、dnf 或 yum'
    fi
}

missing_system_dependency_packages() {
    local manager=$1

    if ! command -v nft >/dev/null 2>&1; then
        printf '%s\n' nftables
    fi
    if ! command -v ss >/dev/null 2>&1 ||
       ! command -v ip >/dev/null 2>&1; then
        case ${manager} in
            apt)
                printf '%s\n' iproute2
                ;;
            dnf | yum)
                printf '%s\n' iproute
                ;;
        esac
    fi
}

confirm_system_dependency_installation() {
    local manager answer package package_text=
    local -a packages=()

    if command -v nft >/dev/null 2>&1 &&
       command -v ss >/dev/null 2>&1 &&
       command -v ip >/dev/null 2>&1; then
        return
    fi

    manager=$(detect_package_manager)
    while IFS= read -r package; do
        [[ -n ${package} ]] && packages+=("${package}")
    done < <(missing_system_dependency_packages "${manager}")
    ((${#packages[@]} > 0)) || return
    for package in "${packages[@]}"; do
        if [[ -n ${package_text} ]]; then
            package_text+='、'
        fi
        package_text+=${package}
    done

    status_line info "检测到缺少系统依赖：${package_text}"
    IFS= read -r -p '是否安装以上依赖？[Y/n]（回车确认，输入 n/N 取消）：' answer
    case ${answer:-y} in
        y | Y | yes | YES | Yes)
            ;;
        n | N | no | NO | No)
            status_line info '已取消操作'
            exit 0
            ;;
        *)
            die '请输入 y 或 n'
            ;;
    esac
}

ensure_system_dependencies() {
    local manager package
    local -a packages=()

    if command -v nft >/dev/null 2>&1 &&
       command -v ss >/dev/null 2>&1 &&
       command -v ip >/dev/null 2>&1; then
        return
    fi

    manager=$(detect_package_manager)
    while IFS= read -r package; do
        [[ -n ${package} ]] && packages+=("${package}")
    done < <(missing_system_dependency_packages "${manager}")
    ((${#packages[@]} > 0)) || return
    note "正在通过 ${manager} 安装所需系统软件包"
    case ${manager} in
        apt)
            apt-get update
            apt-get install -y "${packages[@]}"
            ;;
        dnf)
            dnf install -y "${packages[@]}"
            ;;
        yum)
            yum install -y "${packages[@]}"
            ;;
    esac
}

report_port_conflict() {
    local port=$1
    local output pid

    printf 'IPv4 TCP 端口 %s 已被占用。\n' "${port}" >&2
    if output=$(ss -H -ltnp "sport = :${port}" 2>&1); then
        printf '%s\n' "${output}" >&2
        pid=$(printf '%s\n' "${output}" |
            sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' |
            head -n 1)
        if [[ -n ${pid} ]]; then
            if ! systemctl status "${pid}" --no-pager; then
                printf 'PID %s 未对应到可读取的 systemd 服务。\n' "${pid}" >&2
            fi
        fi
    else
        printf '%s\n' "${output}" >&2
    fi
}

current_service_owns_port() {
    local port=$1
    local main_pid output

    main_pid=$(systemctl show socks-vps.service --property=MainPID --value)
    [[ ${main_pid} =~ ^[1-9][0-9]*$ ]] || return 1
    output=$(ss -H -ltnp "sport = :${port}" 2>/dev/null) || return 1
    [[ ${output} == *"pid=${main_pid},"* || ${output} == *"pid=${main_pid})"* ]]
}

owned_wildcard_listener_ports() {
    local main_pid=$1

    sed -n "s/.*0\\.0\\.0\\.0:\\([0-9][0-9]*\\).*pid=${main_pid}[,)].*/\\1/p" |
        LC_ALL=C sort -u
}

is_single_port_value() {
    [[ ${1:-} =~ ^[0-9]+$ ]]
}

configured_ports() {
    if [[ -d ${instances_dir} ]]; then
        "${package_binary}" config-ports --config-dir "${instances_dir}"
    elif [[ -f ${legacy_config_file} ]]; then
        "${package_binary}" config-port --config "${legacy_config_file}"
    else
        return 1
    fi
}

blocked_cn_ports() {
    if [[ -d ${instances_dir} ]]; then
        "${package_binary}" config-ports \
            --config-dir "${instances_dir}" \
            --blocked-cn-only
    elif [[ -f ${legacy_config_file} ]]; then
        "${package_binary}" config-port --config "${legacy_config_file}"
    else
        return 1
    fi
}

configuration_requires_nft() {
    configuration_tree_requires_nft "${config_dir}"
}

configuration_tree_requires_nft() {
    local tree=$1
    local ports

    if [[ -d ${tree}/instances ]]; then
        ports=$(
            "${package_binary}" config-ports \
                --config-dir "${tree}/instances" \
                --blocked-cn-only
        ) || return 1
        if [[ -n ${ports} ]]; then
            return 0
        fi
        return 1
    fi
    [[ -f ${tree}/config.json ]]
}

current_service_owns_configured_listener() {
    local main_pid output expected_ports actual_ports

    if [[ -d ${instances_dir} ]]; then
        "${public_binary}" self-check --config-dir "${instances_dir}" >/dev/null
        expected_ports=$(
            "${public_binary}" config-ports --config-dir "${instances_dir}" |
                LC_ALL=C sort -n
        ) || return 1
    else
        "${public_binary}" self-check --config "${legacy_config_file}" >/dev/null
        expected_ports=$(
            "${public_binary}" config-port --config "${legacy_config_file}"
        ) || return 1
    fi
    [[ -n ${expected_ports} ]] || return 1
    main_pid=$(systemctl show socks-vps.service --property=MainPID --value)
    [[ ${main_pid} =~ ^[1-9][0-9]*$ ]] || return 1
    output=$(ss -H -ltnp 2>/dev/null) || return 1
    actual_ports=$(
        printf '%s\n' "${output}" |
            owned_wildcard_listener_ports "${main_pid}" |
            LC_ALL=C sort -n
    )
    [[ ${actual_ports} == "${expected_ports}" ]]
}

check_or_reselect_port() {
    local mode=$1
    local port=$2
    local allow_current_owner=${3:-false}
    local status output

    if [[ ${mode} == automatic ]]; then
        if [[ -d ${instances_dir} ]]; then
            "${package_binary}" port-select \
                --config-dir "${instances_dir}"
            return $?
        fi
        printf '%s\n' "${port}"
        return 0
    fi
    [[ ${mode} == manual ]] ||
        die "新配置的端口模式无效：${mode}"

    if output=$("${package_binary}" port-check --port "${port}" 2>&1); then
        printf '%s\n' "${port}"
        return 0
    else
        status=$?
    fi

    if [[ ${status} == 78 ]]; then
        if [[ ${allow_current_owner} == true ]] && current_service_owns_port "${port}"; then
            printf '%s\n' "${port}"
            return 0
        fi
        report_port_conflict "${port}"
    else
        [[ -z ${output} ]] || printf '%s\n' "${output}" >&2
        printf '无法检查 TCP 端口 %s（退出码 %s）。\n' "${port}" "${status}" >&2
    fi
    return 1
}

show_coexistence_state() {
    local unit warp_status warp_units
    local firewall_detected=false

    note '正在只读检查共存环境'
    if warp_units=$(systemctl list-unit-files 'warp-vps*' --no-legend --no-pager 2>&1); then
        if [[ -n ${warp_units} ]]; then
            status_line info '检测到 WARP VPS Manager，保持不变'
        fi
    else
        warp_status=$?
        if [[ ${warp_status} != 1 || -n ${warp_units} ]]; then
            [[ -z ${warp_units} ]] || printf '%s\n' "${warp_units}" >&2
            printf '无法列出 WARP VPS Manager 服务。\n' >&2
        fi
    fi
    for unit in nftables.service firewalld.service ufw.service; do
        if systemctl is-active --quiet "${unit}"; then
            firewall_detected=true
        fi
    done
    if [[ ${firewall_detected} == true ]]; then
        status_line info '检测到现有主机防火墙服务，保持不变'
    fi
    if command -v nft >/dev/null 2>&1; then
        if nft list table inet warp_vps >/dev/null 2>&1; then
            status_line info '检测到 WARP nftables 表，保持不变'
        fi
    fi
    success '共存环境检查完成'
}

rollback_transaction() {
    local failed=false

    status_line error '操作失败，正在恢复本次操作前的状态' 2
    rm -f -- \
        "${current_link}.pending-$$" \
        "${public_binary}.pending-$$" \
        "${control_binary}.pending-$$"
    if [[ ${transaction_kind} == install ]]; then
        if systemctl stop socks-vps.service socks-vps-firewall.service >/dev/null 2>&1; then
            :
        fi
        if [[ -f ${main_unit} ]] &&
           ! systemctl disable --quiet socks-vps.service; then
            failed=true
        fi
        rm -rf -- "${config_dir}"
        rm -f -- "${public_binary}" "${control_binary}" "${main_unit}" "${firewall_unit}"
        rm -rf -- "${install_root}"
        rm -rf -- /run/socks-vps
        if ! systemctl daemon-reload; then
            failed=true
        fi
        if getent passwd socks-vps >/dev/null && ! userdel socks-vps; then
            failed=true
        fi
        if getent group socks-vps >/dev/null && ! groupdel socks-vps; then
            failed=true
        fi
        if [[ ${failed} == true ]]; then
            status_line error '新安装未能完整清理，请检查上方错误' 2
            return 1
        fi
        status_line success '已清理本次未完成的新安装' 2
        return 0
    fi
    if ! systemctl stop socks-vps.service socks-vps-firewall.service >/dev/null 2>&1; then
        failed=true
    fi
    if [[ -d ${transaction_dir}/config ]]; then
        rm -rf -- "${config_dir}"
        if ! cp -a "${transaction_dir}/config" "${config_dir}"; then
            failed=true
        fi
    fi
    if [[ -n ${transaction_current_target} ]]; then
        if ! ln -sfn "${transaction_current_target}" "${current_link}"; then
            failed=true
        fi
    fi
    if [[ ${transaction_public_kind} == symlink ]]; then
        if ! ln -s "${transaction_public_target}" "${public_binary}.pending-$$"; then
            failed=true
        elif ! mv -f "${public_binary}.pending-$$" "${public_binary}"; then
            rm -f -- "${public_binary}.pending-$$"
            failed=true
        fi
    elif [[ ${transaction_public_kind} == file ]]; then
        if ! install -m 0755 -o root -g root \
            "${transaction_dir}/socks-vps" "${public_binary}.pending-$$"; then
            failed=true
        elif ! mv -f "${public_binary}.pending-$$" "${public_binary}"; then
            rm -f -- "${public_binary}.pending-$$"
            failed=true
        fi
    else
        failed=true
    fi
    if [[ ${transaction_control_present} == true ]]; then
        if ! ln -sfn "${transaction_control_target}" "${control_binary}"; then
            failed=true
        fi
    elif [[ -e ${control_binary} || -L ${control_binary} ]]; then
        if ! rm -f -- "${control_binary}"; then
            failed=true
        fi
    fi
    if [[ -f ${transaction_dir}/socks-vps.service ]] &&
       ! install -m 0644 -o root -g root \
            "${transaction_dir}/socks-vps.service" "${main_unit}"; then
        failed=true
    fi
    if [[ -f ${transaction_dir}/socks-vps-firewall.service ]] &&
       ! install -m 0644 -o root -g root \
            "${transaction_dir}/socks-vps-firewall.service" "${firewall_unit}"; then
        failed=true
    fi
    if [[ -n ${transaction_new_release} &&
          ${transaction_new_release} == "${releases_dir}/"* &&
          ${transaction_new_release} != "${transaction_current_target}" &&
          -e ${transaction_new_release} ]] &&
       ! rm -rf -- "${transaction_new_release}"; then
        failed=true
    fi
    if ! systemctl daemon-reload; then
        failed=true
    fi
    if ! systemctl reset-failed \
        socks-vps.service \
        socks-vps-firewall.service; then
        failed=true
    fi
    if ! systemctl start socks-vps-firewall.service socks-vps.service; then
        failed=true
    elif ! verify_active_installation; then
        failed=true
    fi
    if [[ ${failed} == true ]]; then
        status_line error '本次操作未能完整恢复，请检查 systemd 状态' 2
        return 1
    fi
    status_line success '已恢复本次操作前的状态' 2
}

transaction_exit() {
    local status=$?
    local rollback_status=0

    trap - EXIT INT TERM
    if [[ ${transaction_active} == true ]]; then
        rollback_transaction || rollback_status=$?
    fi
    if transaction_dir_is_owned; then
        rm -rf -- "${transaction_dir}"
    fi
    if ((status == 0)); then
        status=1
    fi
    if ((rollback_status != 0)); then
        status=${rollback_status}
    fi
    exit "${status}"
}

begin_transaction() {
    local kind=$1

    [[ ${transaction_active} == false ]] || die '当前操作已经存在临时事务'
    transaction_dir=$(mktemp -d "${install_root}/.transaction.XXXXXXXX")
    trap transaction_exit EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    chmod 0700 "${transaction_dir}"
    cp -a "${config_dir}" "${transaction_dir}/config"
    install -m 0644 -o root -g root "${main_unit}" "${transaction_dir}/socks-vps.service"
    install -m 0644 -o root -g root \
        "${firewall_unit}" "${transaction_dir}/socks-vps-firewall.service"
    transaction_kind=${kind}
    transaction_current_target=$(readlink -f "${current_link}")
    if [[ -L ${public_binary} ]]; then
        transaction_public_kind=symlink
        transaction_public_target=$(readlink -f "${public_binary}")
    else
        transaction_public_kind=file
        transaction_public_target=
        install -m 0755 -o root -g root \
            "${public_binary}" "${transaction_dir}/socks-vps"
    fi
    if [[ -e ${control_binary} || -L ${control_binary} ]]; then
        transaction_control_present=true
        transaction_control_target=$(readlink -f "${control_binary}")
    else
        transaction_control_present=false
        transaction_control_target=
    fi
    transaction_active=true
}

begin_fresh_transaction() {
    [[ ${transaction_active} == false ]] || die '当前操作已经存在临时事务'
    transaction_dir=$(mktemp -d /var/tmp/socks-vps-transaction.XXXXXXXX)
    trap transaction_exit EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    chmod 0700 "${transaction_dir}"
    transaction_kind=install
    transaction_active=true
}

transaction_dir_is_owned() {
    [[ -n ${transaction_dir} &&
       (${transaction_dir} == "${install_root}/.transaction."* ||
        ${transaction_dir} == /var/tmp/socks-vps-transaction.*) ]]
}

commit_transaction() {
    [[ ${transaction_active} == true ]] || die '当前操作没有可提交的临时事务'
    if transaction_dir_is_owned; then
        rm -rf -- "${transaction_dir}"
    fi
    transaction_active=false
    trap - EXIT INT TERM
    transaction_dir=
    transaction_kind=
    transaction_current_target=
    transaction_public_kind=
    transaction_public_target=
    transaction_control_target=
    transaction_control_present=false
    transaction_new_release=
}

cleanup_legacy_artifacts() {
    local current_target release

    if [[ -e ${backup_root} ]]; then
        rm -rf -- "${backup_root}"
    fi
    if [[ -d ${install_root} ]]; then
        find "${install_root}" -maxdepth 1 -type d \
            -name '.transaction.*' \
            -exec rm -rf -- {} + ||
            die '无法清理安装目录内的事务残留'
    fi
    if [[ -d ${transaction_fallback_root} ]]; then
        find "${transaction_fallback_root}" -maxdepth 1 -type d \
            -name 'socks-vps-transaction.*' \
            -exec rm -rf -- {} + ||
            die '无法清理临时目录内的事务残留'
    fi
    if [[ -d ${config_dir} ]]; then
        find "${config_dir}" -maxdepth 2 -type f \
            \( -name '*.migrated-*' \
               -o -name '*.bind-failed-*' \
               -o -name '.config.json.*' \
               -o -name 'config.json.pending-*' \
               -o -name '.*.pending-*' \
               -o -name '.*.retry-*' \
               -o -name '.*.credentials-*' \) \
            -delete
    fi
    find \
        "${install_root}" \
        "$(dirname -- "${public_binary}")" \
        -maxdepth 1 \( -type f -o -type l \) \
        \( -path "${current_link}.pending-*" \
           -o -path "${public_binary}.pending-*" \
           -o -path "${control_binary}.pending-*" \) \
        -delete 2>/dev/null || die '无法清理历史切换残留'
    [[ -d ${releases_dir} && -L ${current_link} ]] || return 0
    current_target=$(readlink -f "${current_link}")
    [[ ${current_target} == "${releases_dir}/"* ]] ||
        die '当前版本链接超出自有版本目录，无法清理旧版本'
    while IFS= read -r -d '' release; do
        [[ ${release} == "${releases_dir}/"* ]] ||
            die '发现超出自有目录的版本路径'
        if [[ $(readlink -f "${release}") != "${current_target}" ]]; then
            rm -rf -- "${release}"
        fi
    done < <(find "${releases_dir}" -mindepth 1 -maxdepth 1 -print0)
}

cleanup_runtime_artifacts() {
    [[ -d ${runtime_dir} ]] || return 0
    rm -f -- \
        "${runtime_dir}/existing-table.json" \
        "${runtime_dir}/socks-vps.nft" \
        "${runtime_dir}/remove-socks-vps.nft" \
        "${runtime_dir}/nft-list.stderr" \
        "${runtime_dir}/nft-tables.txt"
}

preflight_firewall() {
    local port_mode=$1
    local selected_port=$2
    local allow_cn=$3
    local tables
    local table_state=absent
    local require_nft=false
    local -a render_args

    if [[ ${port_mode} == preserve ]]; then
        if configuration_requires_nft; then
            require_nft=true
        fi
    elif [[ ${allow_cn} == false ]]; then
        require_nft=true
    fi
    if ! command -v nft >/dev/null 2>&1; then
        [[ ${require_nft} == false ]] || die '启用中国大陆来源拦截时必须安装 nft'
        return 0
    fi

    if nft --json list table ip socks_vps >/dev/null 2>&1; then
        table_state=present
    else
        tables=$(nft list tables) || die '无法检查 nftables 表'
        if grep -Eq '^[[:space:]]*table ip socks_vps[[:space:]]*$' <<<"${tables}"; then
            die '无法读取现有的 table ip socks_vps'
        fi
    fi

    render_args=(
        firewall-render
        --zone "${package_root}/assets/ipdeny/cn-aggregated.zone"
        --output -
    )
    if [[ ${port_mode} == preserve ]]; then
        if [[ -d ${instances_dir} ]]; then
            render_args+=(--config-dir "${instances_dir}")
        else
            render_args+=(--config "${legacy_config_file}")
        fi
    else
        render_args+=(--port "${selected_port}" --allow-cn="${allow_cn}")
    fi
    if [[ ${table_state} == present ]]; then
        render_args+=(--existing-table-json -)
        nft --json list table ip socks_vps |
            "${package_binary}" "${render_args[@]}" |
            nft --check --file -
    else
        "${package_binary}" "${render_args[@]}" |
            nft --check --file -
    fi
}

require_socks_table_absent() {
    local tables existing_json removal_batch

    if ! command -v nft >/dev/null 2>&1; then
        return 0
    fi
    if existing_json=$(nft --json list table ip socks_vps 2>/dev/null); then
        if ! removal_batch=$(
            printf '%s\n' "${existing_json}" |
                "${package_binary}" firewall-render \
                    --remove \
                    --existing-table-json - \
                    --output - 2>/dev/null
        ); then
            die '无法判断现有 nftables 表的所有权'
        fi
        [[ -z ${removal_batch} ]] ||
            die 'Socks-VPS 自有 nftables 表仍未移除'
        status_line info '检测到外部同名 nftables 表，已保持不变'
        return 0
    fi
    tables=$(nft list tables) || die '无法确认 nftables 表已移除'
    if grep -Eq '^[[:space:]]*table ip socks_vps[[:space:]]*$' <<<"${tables}"; then
        die '现有 table ip socks_vps 无法读取'
    fi
}

remove_owned_firewall_for_uninstall() {
    local existing_json removal_batch tables

    command -v nft >/dev/null 2>&1 ||
        die '未找到 nft，无法确认并移除自有 nftables 表'
    if existing_json=$(nft --json list table ip socks_vps 2>/dev/null); then
        removal_batch=$(
            printf '%s\n' "${existing_json}" |
                "${package_binary}" firewall-render \
                    --remove \
                    --existing-table-json - \
                    --output -
        ) || die '无法判断现有 nftables 表的所有权'
        if [[ -z ${removal_batch} ]]; then
            status_line info '检测到外部同名 nftables 表，已保持不变'
            return 0
        fi
        printf '%s\n' "${removal_batch}" | nft --check --file - ||
            die '自有 nftables 表删除规则校验失败'
        printf '%s\n' "${removal_batch}" | nft --file - ||
            die '无法删除自有 nftables 表'
        require_socks_table_absent
        return
    fi
    tables=$(nft list tables) || die '无法确认 nftables 表状态'
    if grep -Eq '^[[:space:]]*table ip socks_vps[[:space:]]*$' <<<"${tables}"; then
        die '现有 table ip socks_vps 无法读取'
    fi
}

stop_owned_services() {
    if ! systemctl stop socks-vps.service; then
        die '无法停止 socks-vps.service'
    fi
    if ! systemctl stop socks-vps-firewall.service; then
        die '无法停止 socks-vps-firewall.service'
    fi
    if systemctl is-active --quiet socks-vps.service; then
        die '停止后 socks-vps.service 仍在运行'
    fi
    if systemctl is-active --quiet socks-vps-firewall.service; then
        die '停止后 socks-vps-firewall.service 仍在运行'
    fi
    require_socks_table_absent
}

validate_account() {
    getent passwd socks-vps >/dev/null &&
        getent group socks-vps >/dev/null
}

check_fresh_account_conflicts() {
    if getent passwd socks-vps >/dev/null || getent group socks-vps >/dev/null; then
        die '系统中已存在不属于当前安装的 socks-vps 用户或组'
    fi
}

create_account() {
    local nologin_shell

    if nologin_shell=$(command -v nologin); then
        :
    elif [[ -x /sbin/nologin ]]; then
        nologin_shell=/sbin/nologin
    else
        die '系统缺少 nologin shell'
    fi
    groupadd --system socks-vps
    useradd \
        --system \
        --gid socks-vps \
        --home-dir /nonexistent \
        --shell "${nologin_shell}" \
        socks-vps
}

require_owned_installation() {
    local require_config=${1:-true}
    local current_target public_target control_target

    if [[ ${require_config} == true ]]; then
        installation_exists || die 'Socks-VPS 安装所有权边界不完整'
    else
        [[ -L ${current_link} &&
           (-f ${public_binary} || -L ${public_binary}) ]] ||
            die 'Socks-VPS 安装所有权边界不完整'
    fi
    [[ -f ${main_unit} && -f ${firewall_unit} ]] ||
        die 'Socks-VPS systemd unit 所有权边界不完整'
    current_target=$(readlink -f "${current_link}")
    [[ ${current_target} == "${releases_dir}/"* &&
       -x ${current_target}/bin/socks-vps ]] ||
        die '当前版本链接未指向 Socks-VPS 自有版本目录'
    if [[ -L ${public_binary} ]]; then
        public_target=$(readlink -f "${public_binary}")
        [[ ${public_target} == "${current_target}/bin/socks-vps" ]] ||
            die '公开主程序与当前版本不一致'
    elif [[ ! -f ${public_binary} ||
            ! -x ${public_binary} ]] ||
         ! cmp -s "${public_binary}" "${current_target}/bin/socks-vps"; then
        die '公开主程序与当前版本不一致'
    fi
    if [[ -e ${control_binary} || -L ${control_binary} ]]; then
        control_target=$(readlink -f "${control_binary}")
        [[ ${control_target} == "${current_target}/scripts/install.sh" ]] ||
            die '管理命令与当前版本不一致'
    elif [[ ! -r ${current_target}/VERSION ||
            $(<"${current_target}/VERSION") != 1.0.* ]]; then
        die '缺少当前版本的管理命令'
    fi
    cmp -s "${main_unit}" "${current_target}/packaging/systemd/socks-vps.service" ||
        die '主服务 unit 与当前版本不一致'
    cmp -s \
        "${firewall_unit}" \
        "${current_target}/packaging/systemd/socks-vps-firewall.service" ||
        die '防火墙服务 unit 与当前版本不一致'
    validate_account || die 'Socks-VPS 专用用户或组缺失'
    if [[ ${require_config} == true ]]; then
        if [[ -d ${instances_dir} ]]; then
            "${current_target}/bin/socks-vps" \
                config-check --config-dir "${instances_dir}" >/dev/null
        else
            "${current_target}/bin/socks-vps" \
                config-check --config "${legacy_config_file}" >/dev/null
        fi
    fi
}

check_fresh_path_conflicts() {
    local path
    local -a paths=(
        "${config_dir}"
        "${install_root}"
        "${public_binary}"
        "${control_binary}"
        "${main_unit}"
        "${firewall_unit}"
    )

    for path in "${paths[@]}"; do
        [[ ! -e ${path} && ! -L ${path} ]] || die "安装路径已存在：${path}"
    done
}

install_release_tree() {
    local version=$1
    local action=$2
    local release_dir="${releases_dir}/${version}"
    local current_target=

    if [[ -e ${release_dir} ]]; then
        if [[ -L ${current_link} ]]; then
            current_target=$(readlink -f "${current_link}")
        fi
        if [[ ${action} == update && ${release_dir} != "${current_target}" ]]; then
            rm -rf -- "${release_dir}"
        elif [[ ${action} != reinstall ]]; then
            die "版本目录已存在：${release_dir}"
        else
            release_dir="${releases_dir}/${version}-reinstall-$$"
            [[ ! -e ${release_dir} ]] || die "重装临时目录已存在：${release_dir}"
        fi
    fi

    transaction_new_release=${release_dir}
    install -d -m 0755 -o root -g root \
        "${release_dir}/bin" \
        "${release_dir}/scripts" \
        "${release_dir}/packaging/systemd" \
        "${release_dir}/assets/ipdeny" \
        "${release_dir}/licenses"
    install -m 0755 -o root -g root "${package_binary}" "${release_dir}/bin/socks-vps"
    install -m 0755 -o root -g root "${package_root}/scripts/install.sh" "${release_dir}/scripts/install.sh"
    install -m 0755 -o root -g root "${package_root}/scripts/firewall.sh" "${release_dir}/scripts/firewall.sh"
    install -m 0644 -o root -g root \
        "${package_root}/packaging/systemd/socks-vps.service" \
        "${release_dir}/packaging/systemd/socks-vps.service"
    install -m 0644 -o root -g root \
        "${package_root}/packaging/systemd/socks-vps-firewall.service" \
        "${release_dir}/packaging/systemd/socks-vps-firewall.service"
    install -m 0644 -o root -g root \
        "${package_root}/assets/ipdeny/cn-aggregated.zone" \
        "${package_root}/assets/ipdeny/Copyrights.txt" \
        "${package_root}/assets/ipdeny/MD5SUM.upstream" \
        "${package_root}/assets/ipdeny/SOURCE.json" \
        "${release_dir}/assets/ipdeny/"
    install -m 0644 -o root -g root \
        "${package_root}/licenses/go-gost-gosocks5-LICENSE" \
        "${release_dir}/licenses/go-gost-gosocks5-LICENSE"
    install -m 0644 -o root -g root \
        "${package_root}/LICENSE" \
        "${package_root}/THIRD_PARTY_NOTICES.md" \
        "${package_root}/README.md" \
        "${package_root}/SOURCE_MANIFEST.sha256" \
        "${package_root}/VERSION" \
        "${package_root}/TARGET" \
        "${package_root}/MANIFEST.sha256" \
        "${release_dir}/"

    installed_release_dir=${release_dir}
}

create_new_config() {
    local name=$1
    local port=$2
    local version=$3
    local username=$4
    local password=$5
    local allow_cn=$6
    local attempt=$7
    local target="${instances_dir}/${name}.json"
    local pending="${instances_dir}/.${name}.pending-${version}-${attempt}"

    [[ ${name} =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] ||
        die "SOCKS 配置名称无效：${name}"
    [[ ! -e ${target} ]] || die "SOCKS 配置已存在：${name}"
    [[ ! -e ${pending} ]] || die "待写入配置已存在：${pending}"
    printf '%s\0%s\0' "${username}" "${password}" |
        "${package_binary}" config-create \
            --port "${port}" \
            --allow-cn="${allow_cn}" \
            --version "${version}" \
            --output "${pending}" >/dev/null
    chown root:socks-vps "${pending}"
    chmod 0640 "${pending}"
    mv -T "${pending}" "${target}"
}

create_preserved_configs() {
    local version=$1
    local source name pending
    local -a sources

    install -d -m 0750 -o root -g socks-vps "${instances_dir}"
    if [[ -f ${legacy_config_file} ]]; then
        pending="${instances_dir}/.socks-1.pending-${version}-migration"
        [[ ! -e ${pending} && ! -e ${instances_dir}/socks-1.json ]] ||
            die '旧版配置迁移目标已存在'
        "${package_binary}" config-create \
            --preserve "${legacy_config_file}" \
            --version "${version}" \
            --output "${pending}" >/dev/null
        chown root:socks-vps "${pending}"
        chmod 0640 "${pending}"
        mv -T "${pending}" "${instances_dir}/socks-1.json"
        rm -f -- "${legacy_config_file}"
        return
    fi

    shopt -s nullglob
    sources=("${instances_dir}"/*.json)
    shopt -u nullglob
    ((${#sources[@]} > 0)) || die '未安装任何 SOCKS 配置'
    for source in "${sources[@]}"; do
        name=$(basename "${source}" .json)
        pending="${instances_dir}/.${name}.pending-${version}-preserve"
        [[ ! -e ${pending} ]] || die "待写入配置已存在：${pending}"
        "${package_binary}" config-create \
            --preserve "${source}" \
            --version "${version}" \
            --output "${pending}" >/dev/null
        chown root:socks-vps "${pending}"
        chmod 0640 "${pending}"
        mv -T "${pending}" "${source}"
    done
}

activate_release() {
    local release_dir=$1

    replace_symlink "${release_dir}" "${current_link}"
    replace_executable "${release_dir}/bin/socks-vps" "${public_binary}"
    replace_symlink "${current_link}/scripts/install.sh" "${control_binary}"
    install -m 0644 -o root -g root \
        "${release_dir}/packaging/systemd/socks-vps.service" \
        "${main_unit}"
    install -m 0644 -o root -g root \
        "${release_dir}/packaging/systemd/socks-vps-firewall.service" \
        "${firewall_unit}"
    systemctl daemon-reload
}

replace_executable() {
    local source=$1
    local destination=$2
    local pending="${destination}.pending-$$"

    [[ -f ${source} && -x ${source} ]] ||
        die "主程序不可执行：${source}"
    if [[ -e ${destination} &&
          ! -f ${destination} &&
          ! -L ${destination} ]]; then
        die "主程序目标位置存在非文件对象：${destination}"
    fi
    [[ ! -e ${pending} && ! -L ${pending} ]] ||
        die "待切换主程序已存在：${pending}"
    if ! install -m 0755 -o root -g root "${source}" "${pending}"; then
        rm -f -- "${pending}"
        die "无法安装待切换主程序：${pending}"
    fi
    if ! mv -f "${pending}" "${destination}"; then
        rm -f -- "${pending}"
        die "无法切换主程序：${destination}"
    fi
}

replace_symlink() {
    local target=$1
    local link_path=$2
    local pending="${link_path}.pending-$$"

    if [[ -e ${link_path} && ! -L ${link_path} ]]; then
        die "链接目标位置存在非符号链接文件：${link_path}"
    fi
    [[ ! -e ${pending} && ! -L ${pending} ]] ||
        die "待切换符号链接已存在：${pending}"
    if ! ln -s "${target}" "${pending}"; then
        rm -f -- "${pending}"
        die "无法创建待切换符号链接：${pending}"
    fi
    if ! mv -T "${pending}" "${link_path}"; then
        rm -f -- "${pending}"
        die "无法切换符号链接：${link_path}"
    fi
}

verify_active_installation() {
    systemctl is-active --quiet socks-vps.service || return 1
    current_service_owns_configured_listener || return 1
    systemctl is-active --quiet socks-vps-firewall.service || return 1
    required_firewall_state_is_healthy
}

required_firewall_state_is_healthy() {
    local existing_json removal_batch tables
    local require_nft=false
    local -a health_config

    if configuration_requires_nft; then
        require_nft=true
    fi
    if ! command -v nft >/dev/null 2>&1; then
        if [[ ${require_nft} == false ]]; then
            return 0
        fi
        return 1
    fi
    if existing_json=$(nft --json list table ip socks_vps 2>/dev/null); then
        if [[ ${require_nft} == true ]]; then
            if [[ -d ${instances_dir} ]]; then
                health_config=(--config-dir "${instances_dir}")
            else
                health_config=(--config "${legacy_config_file}")
            fi
            if printf '%s\n' "${existing_json}" |
                "${package_binary}" firewall-render \
                    --check-health \
                    "${health_config[@]}" \
                    --existing-table-json - >/dev/null 2>&1; then
                return 0
            fi
            return 1
        fi
        removal_batch=$(
            printf '%s\n' "${existing_json}" |
                "${package_binary}" firewall-render \
                    --remove \
                    --existing-table-json - \
                    --output - 2>/dev/null
        ) || return 1
        if [[ ${require_nft} == true ]]; then
            if [[ -n ${removal_batch} ]]; then
                return 0
            fi
            return 1
        fi
        if [[ -z ${removal_batch} ]]; then
            return 0
        fi
        return 1
    fi
    tables=$(nft list tables 2>/dev/null) || return 1
    if grep -Eq '^[[:space:]]*table ip socks_vps[[:space:]]*$' <<<"${tables}"; then
        return 1
    fi
    [[ ${require_nft} == false ]]
}

verify_started_port() {
    local port=$1

    verify_active_installation || return 1
    current_service_owns_port "${port}"
}

start_and_verify() {
    local port_mode=$1
    local version=$2
    local name=$3
    local username=$4
    local password=$5
    local allow_cn=$6
    local port=$7
    local attempt=1
    local start_status verify_status exec_status
    local pending

    while ((attempt <= 2)); do
        start_status=0
        systemctl reset-failed \
            socks-vps.service \
            socks-vps-firewall.service
        systemctl start socks-vps.service || start_status=$?
        verify_status=1
        if [[ ${start_status} == 0 ]]; then
            if verify_started_port "${port}"; then
                verify_status=0
            else
                verify_status=$?
            fi
        fi

        if [[ ${start_status} == 0 && ${verify_status} == 0 ]]; then
            success "Socks-VPS ${version} 已在 TCP 端口 ${port} 运行"
            return 0
        fi

        if ! exec_status=$(
            systemctl show socks-vps.service --property=ExecMainStatus --value
        ); then
            exec_status=unavailable
        fi
        [[ -n ${exec_status} ]] || exec_status=unavailable
        stop_owned_services

        if [[ ${port_mode} != automatic ||
              ${exec_status} != 78 ||
              ${attempt} -ne 1 ]]; then
            if ! systemctl status socks-vps.service --no-pager; then
                printf '上方为启动失败时的服务状态。\n' >&2
            fi
            die "服务启动失败（start=${start_status}，verify=${verify_status}，ExecMainStatus=${exec_status}）"
        fi

        note "自动端口 ${port} 在绑定前被占用，重新选择一次"
        port=$(
            "${package_binary}" port-select \
                --config-dir "${instances_dir}"
        )
        check_new_config_without_write \
            "${port}" "${version}" "${username}" "${password}" "${allow_cn}"
        pending="${instances_dir}/.${name}.retry-${version}-$$"
        [[ ! -e ${pending} ]] || die "待重试配置已存在：${pending}"
        printf '%s\0%s\0' "${username}" "${password}" |
            "${package_binary}" config-create \
                --port "${port}" \
                --allow-cn="${allow_cn}" \
                --version "${version}" \
                --output "${pending}" >/dev/null
        chown root:socks-vps "${pending}"
        chmod 0640 "${pending}"
        mv -T "${pending}" "${instances_dir}/${name}.json"
        attempt=$((attempt + 1))
    done
    die '自动端口重试次数异常'
}

start_preserved_and_verify() {
    local start_status=0
    local verify_status=1
    local exec_status

    systemctl reset-failed \
        socks-vps.service \
        socks-vps-firewall.service
    systemctl start socks-vps.service || start_status=$?
    if [[ ${start_status} == 0 ]]; then
        if verify_active_installation; then
            verify_status=0
        else
            verify_status=$?
        fi
    fi
    if [[ ${start_status} == 0 && ${verify_status} == 0 ]]; then
        return 0
    fi

    if ! exec_status=$(
        systemctl show socks-vps.service --property=ExecMainStatus --value
    ); then
        exec_status=unavailable
    fi
    [[ -n ${exec_status} ]] || exec_status=unavailable
    stop_owned_services
    die "服务启动失败（start=${start_status}，verify=${verify_status}，ExecMainStatus=${exec_status}）"
}

install_or_replace() {
    local action=$1
    local port_mode=$2
    local requested_port=$3
    local version=$4
    local allow_cn=$5
    local name=$6
    local username=$7
    local password=$8
    local release_dir
    local selected
    local allow_current_owner=false
    local installed_version_file

    if [[ ${action} == install ]]; then
        check_fresh_path_conflicts
        check_fresh_account_conflicts
    else
        require_owned_installation
    fi

    ensure_system_dependencies
    if [[ ${action} == update ]]; then
        installed_version_file="$(readlink -f "${current_link}")/VERSION"
        if [[ -r ${installed_version_file} &&
              $(<"${installed_version_file}") == "${version}" ]]; then
            cleanup_legacy_artifacts
            success "Socks-VPS ${version} 已是当前版本"
            return
        fi
    fi
    show_coexistence_state

    if [[ ${action} == install || ${action} == reinstall ]]; then
        if [[ ${action} == reinstall ]]; then
            allow_current_owner=true
        fi
        selected=$(check_or_reselect_port \
            "${port_mode}" \
            "${requested_port}" \
                "${allow_current_owner}") ||
            die '所选端口不可用'
        requested_port=${selected}
        check_new_config_without_write \
            "${requested_port}" \
            "${version}" \
            "${username}" \
            "${password}" \
            "${allow_cn}"
    fi

    preflight_firewall "${port_mode}" "${requested_port}" "${allow_cn}"

    if [[ ${action} == install ]]; then
        begin_fresh_transaction
    else
        begin_transaction "${action}"
        stop_owned_services
    fi

    if [[ ${action} == install ]]; then
        create_account
    fi
    install -d -m 0755 -o root -g root "${install_root}" "${releases_dir}"
    install -d -m 0750 -o root -g socks-vps "${config_dir}"
    if [[ ${action} == reinstall ]]; then
        rm -rf -- "${config_dir}"
        install -d -m 0750 -o root -g socks-vps "${config_dir}"
    fi
    install -d -m 0750 -o root -g socks-vps "${instances_dir}"
    install_release_tree "${version}" "${action}"
    release_dir=${installed_release_dir}
    transaction_new_release=${release_dir}

    if [[ ${action} == update ]]; then
        create_preserved_configs "${version}"
    else
        create_new_config \
            "${name}" \
            "${requested_port}" \
            "${version}" \
            "${username}" \
            "${password}" \
            "${allow_cn}" \
            0
    fi
    activate_release "${release_dir}"
    if [[ ${action} == install ]]; then
        systemctl enable --quiet socks-vps.service
    fi
    note '正在启动服务并执行自检'

    if [[ ${action} == update ]]; then
        start_preserved_and_verify
        commit_transaction
        cleanup_legacy_artifacts
        success "Socks-VPS 已更新到 ${version}，端口和凭据保持不变"
        return
    fi

    start_and_verify \
        "${port_mode}" \
        "${version}" \
        "${name}" \
        "${username}" \
        "${password}" \
        "${allow_cn}" \
        "${requested_port}"
    commit_transaction
    cleanup_legacy_artifacts
    print_connection_details "${name}"
}

uninstall_permanently() {
    local main_pid listeners current_sockets

    require_owned_installation false
    ensure_system_dependencies
    main_pid=$(systemctl show socks-vps.service --property=MainPID --value) ||
        die '无法读取 Socks-VPS 主服务进程状态'
    listeners=
    if [[ ${main_pid} =~ ^[1-9][0-9]*$ ]]; then
        require_command ss
        listeners=$(
            ss -H -ltnp 2>/dev/null |
                owned_wildcard_listener_ports "${main_pid}"
        ) || die '无法读取 Socks-VPS 监听状态'
    fi

    if ! systemctl stop socks-vps.service; then
        status_line info '主服务停止命令返回失败，正在核对最终状态'
    fi
    if ! systemctl stop socks-vps-firewall.service; then
        status_line info '防火墙服务停止命令返回失败，正在核对最终状态'
    fi
    if systemctl is-active --quiet socks-vps.service ||
       systemctl is-active --quiet socks-vps-firewall.service; then
        die 'Socks-VPS 服务停止失败，未执行永久删除'
    fi
    remove_owned_firewall_for_uninstall
    if ! systemctl disable --quiet socks-vps.service; then
        die '无法禁用 Socks-VPS systemd 服务，未执行永久删除'
    fi
    if [[ -n ${listeners} ]]; then
        current_sockets=$(ss -H -ltnp 2>/dev/null) ||
            die '无法确认 Socks-VPS 监听已释放'
        if grep -Eq "pid=${main_pid}[,)]" <<<"${current_sockets}"; then
            die 'Socks-VPS 监听进程仍然存在，未执行永久删除'
        fi
    fi

    cleanup_legacy_artifacts
    rm -rf -- "${config_dir}"
    rm -f -- "${public_binary}" "${control_binary}" "${main_unit}" "${firewall_unit}"
    rm -rf -- "${install_root}" "${backup_root}" /run/socks-vps
    systemctl daemon-reload
    if getent passwd socks-vps >/dev/null; then
        userdel socks-vps || die '无法删除 socks-vps 专用用户'
    fi
    if getent group socks-vps >/dev/null; then
        groupdel socks-vps || die '无法删除 socks-vps 专用组'
    fi
    if getent passwd socks-vps >/dev/null || getent group socks-vps >/dev/null; then
        die '专用用户或组未能完整删除'
    fi
    success 'Socks-VPS 已永久卸载'
}

read_config_detail() {
    local path=$1
    local descriptor

    exec {descriptor}< <("${package_binary}" config-detail --config "${path}")
    IFS= read -r -d '' detail_port <&"${descriptor}" ||
        die "无法读取配置端口：${path}"
    IFS= read -r -d '' detail_username <&"${descriptor}" ||
        die "无法读取配置用户名：${path}"
    IFS= read -r -d '' detail_password <&"${descriptor}" ||
        die "无法读取配置密码：${path}"
    IFS= read -r -d '' detail_allow_cn <&"${descriptor}" ||
        die "无法读取中国大陆访问设置：${path}"
    exec {descriptor}<&-
}

print_instance_summary() {
    local name=$1
    local path=$2
    local cn_text

    read_config_detail "${path}"
    if [[ ${detail_allow_cn} == true ]]; then
        cn_text='不拦截'
    else
        cn_text='已拦截'
    fi
    printf '配置：%s\n' "${name}"
    printf '  端口：%s\n' "${detail_port}"
    printf '  中国大陆来源：%s\n' "${cn_text}"
}

list_instances() {
    local path name
    local -a paths

    shopt -s nullglob
    paths=("${instances_dir}"/*.json)
    shopt -u nullglob
    ((${#paths[@]} > 0)) || die '未安装任何 SOCKS 配置'

    for path in "${paths[@]}"; do
        name=$(basename "${path}" .json)
        print_instance_summary "${name}" "${path}"
    done
}

select_instance_name() {
    local requested=${1:-}
    local path
    local -a paths

    if [[ -n ${requested} ]]; then
        [[ ${requested} =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] ||
            die "SOCKS 配置名称无效：${requested}"
        [[ -f ${instances_dir}/${requested}.json ]] ||
            die "SOCKS 配置不存在：${requested}"
        selected_instance_name=${requested}
        return
    fi

    shopt -s nullglob
    paths=("${instances_dir}"/*.json)
    shopt -u nullglob
    ((${#paths[@]} > 0)) || die '未安装任何 SOCKS 配置'
    if ((${#paths[@]} == 1)); then
        selected_instance_name=$(basename "${paths[0]}" .json)
        return
    fi

    list_instances
    IFS= read -r -p '配置名称：' requested
    [[ ${requested} =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] ||
        die 'SOCKS 配置名称无效'
    path="${instances_dir}/${requested}.json"
    [[ -f ${path} ]] || die "SOCKS 配置不存在：${requested}"
    selected_instance_name=${requested}
}

next_instance_name() {
    local number=1

    while [[ -e ${instances_dir}/socks-${number}.json ]]; do
        number=$((number + 1))
    done
    printf 'socks-%s\n' "${number}"
}

detect_server_ipv4() {
    local address

    if command -v curl >/dev/null 2>&1; then
        address=$(
            curl --fail --silent --show-error --location \
                --ipv4 --max-time 2 https://api.ipify.org 2>/dev/null || :
        )
    fi
    [[ ${address:-} =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
        address='请填写 VPS 公网 IPv4'
    printf '%s\n' "${address}"
}

print_connection_details() {
    local name=$1
    local server_ip cn_text

    read_config_detail "${instances_dir}/${name}.json"
    server_ip=$(detect_server_ipv4)
    if [[ ${detail_allow_cn} == true ]]; then
        cn_text='不拦截'
    else
        cn_text='已拦截'
    fi

    printf '\n'
    success 'Socks-VPS 已就绪'
    printf '服务器 IPv4：%s\n' "${server_ip}"
    printf '端口：%s\n' "${detail_port}"
    printf '用户名：%s\n' "${detail_username}"
    printf '密码：%s\n' "${detail_password}"
    printf '配置名称：%s\n' "${name}"
    printf '中国大陆来源：%s\n' "${cn_text}"
    printf '\n'
}

add_instance() {
    local port_mode=$1
    local requested_port=$2
    local version=$3
    local allow_cn=$4
    local username=$5
    local password=$6
    local name selected

    require_owned_installation
    [[ -d ${instances_dir} ]] ||
        die '请先更新 Socks-VPS，再新增 SOCKS 配置'
    name=$(next_instance_name)
    ensure_system_dependencies
    selected=$(check_or_reselect_port "${port_mode}" "${requested_port}") ||
        die '所选端口不可用'
    check_new_config_without_write \
        "${selected}" "${version}" "${username}" "${password}" "${allow_cn}"
    preflight_firewall "${port_mode}" "${selected}" "${allow_cn}"
    begin_transaction add
    stop_owned_services
    create_new_config \
        "${name}" \
        "${selected}" \
        "${version}" \
        "${username}" \
        "${password}" \
        "${allow_cn}" \
        0
    note '正在启动服务并执行自检'
    start_and_verify \
        "${port_mode}" \
        "${version}" \
        "${name}" \
        "${username}" \
        "${password}" \
        "${allow_cn}" \
        "${selected}"
    commit_transaction
    cleanup_legacy_artifacts
    print_connection_details "${name}"
}

change_instance_credentials() {
    local name=$1
    local version=$2
    local username=$3
    local password=$4
    local target pending

    require_owned_installation
    [[ -d ${instances_dir} ]] ||
        die '请先更新 Socks-VPS，再通过 socks-vpsctl 修改凭据'
    target="${instances_dir}/${name}.json"
    [[ -f ${target} ]] || die "SOCKS 配置不存在：${name}"
    read_config_detail "${target}"
    check_new_config_without_write \
        "${detail_port}" \
        "${version}" \
        "${username}" \
        "${password}" \
        "${detail_allow_cn}"
    ensure_system_dependencies
    begin_transaction credentials
    stop_owned_services

    pending="${instances_dir}/.${name}.credentials-${version}-$$"
    [[ ! -e ${pending} ]] || die "待写入配置已存在：${pending}"
    printf '%s\0%s\0' "${username}" "${password}" |
        "${package_binary}" config-create \
            --port "${detail_port}" \
            --allow-cn="${detail_allow_cn}" \
            --version "${version}" \
            --output "${pending}" >/dev/null
    chown root:socks-vps "${pending}"
    chmod 0640 "${pending}"
    mv -T "${pending}" "${target}"
    note '正在启动服务并执行自检'
    start_preserved_and_verify
    commit_transaction
    cleanup_legacy_artifacts
    print_connection_details "${name}"
}

remove_instance() {
    local name=$1
    local target
    local -a paths

    require_owned_installation
    [[ -d ${instances_dir} ]] ||
        die '请先更新 Socks-VPS，再删除 SOCKS 配置'
    shopt -s nullglob
    paths=("${instances_dir}"/*.json)
    shopt -u nullglob
    ((${#paths[@]} > 1)) ||
        die '不能删除最后一组 SOCKS 配置，请使用 socks-vpsctl uninstall'
    target="${instances_dir}/${name}.json"
    [[ -f ${target} ]] || die "SOCKS 配置不存在：${name}"
    ensure_system_dependencies
    begin_transaction remove
    stop_owned_services
    rm -f -- "${target}"
    note '正在启动服务并执行自检'
    start_preserved_and_verify
    commit_transaction
    cleanup_legacy_artifacts
    success "已永久删除 SOCKS 配置 ${name}"
    printf '\n'
    list_instances
}

cleanup_logs() {
    require_owned_installation false
    cleanup_legacy_artifacts
    cleanup_runtime_artifacts
    success 'Socks-VPS 日志与临时残留已清理'
    status_line info 'systemd journal 属于系统共享日志，未做清理'
}

run_latest_update() {
    local work_dir bootstrap status=0

    [[ ${latest_installer_url} == https://* ]] ||
        die '当前源码包没有公开更新地址，请使用正式发布包'
    require_command curl
    work_dir=$(mktemp -d "${TMPDIR:-/tmp}/socks-vps-update.XXXXXXXX")
    trap 'rm -rf -- "${work_dir}"' EXIT INT TERM
    bootstrap="${work_dir}/install.sh"
    note '正在下载最新安装入口'
    curl --fail --silent --show-error --location \
        --proto '=https' --tlsv1.2 \
        --output "${bootstrap}" \
        "${latest_installer_url}"
    bash "${bootstrap}" --update || status=$?
    rm -rf -- "${work_dir}"
    trap - EXIT INT TERM
    return "${status}"
}

privileged_apply() {
    local action=$1
    local port_mode=$2
    local port=$3
    local version=$4
    local allow_cn=$5
    local instance_name=$6
    local username=$7
    local password=$8

    require_root
    if [[ ${action} == install || ${action} == update || ${action} == reinstall ]]; then
        note '正在校验安装包'
        check_package "${version}"
        success '安装包校验通过'
    fi

    case ${action} in
        install | update | reinstall)
            install_or_replace \
                "${action}" \
                "${port_mode}" \
                "${port}" \
                "${version}" \
                "${allow_cn}" \
                "${instance_name}" \
                "${username}" \
                "${password}"
            ;;
        add)
            add_instance \
                "${port_mode}" \
                "${port}" \
                "${version}" \
                "${allow_cn}" \
                "${username}" \
                "${password}"
            ;;
        credentials)
            change_instance_credentials \
                "${instance_name}" \
                "${version}" \
                "${username}" \
                "${password}"
            ;;
        remove)
            remove_instance "${instance_name}"
            ;;
        uninstall)
            uninstall_permanently
            ;;
        cleanup)
            cleanup_logs
            ;;
        *)
            die "特权操作无效：${action}"
            ;;
    esac
}

privileged_entry() {
    local action=$1
    local port_mode=$2
    local port=$3
    local version=$4
    local allow_cn=$5
    local instance_name=$6
    local username password

    require_root
    IFS= read -r -d '' username || die '特权操作缺少用户名输入'
    IFS= read -r -d '' password || die '特权操作缺少密码输入'
    privileged_apply \
        "${action}" \
        "${port_mode}" \
        "${port}" \
        "${version}" \
        "${allow_cn}" \
        "${instance_name}" \
        "${username}" \
        "${password}"
}

interactive_main() {
    local version=0.0.0

    if installation_entry_exists; then
        choose_existing_action
    elif installation_detected; then
        die '检测到不完整或外部占用的 Socks-VPS 路径，请先检查后再安装'
    else
        selected_action=install
        selected_instance_name=socks-1
        version=$(read_package_version)
        choose_port
        choose_cn_access
        generate_secret_pair
    fi

    if [[ ${selected_action} != uninstall && ${version} == 0.0.0 ]]; then
        version=$(read_package_version)
    fi
    if [[ ${selected_action} == install ||
          ${selected_action} == reinstall ||
          ${selected_action} == add ]]; then
        check_new_config_without_write \
            "${selected_port}" \
            "${version}" \
            "${selected_username}" \
            "${selected_password}" \
            "${selected_allow_cn}"
    fi

    if [[ ${selected_action} == uninstall || ${selected_action} == reinstall ]]; then
        print_impact "${selected_action}" "${version}"
        confirm_action
    fi
    run_privileged \
        "${selected_action}" \
        "${selected_port_mode}" \
        "${selected_port}" \
        "${version}" \
        "${selected_allow_cn}" \
        "${selected_instance_name:-}" \
        "${selected_username}" \
        "${selected_password}"
}

direct_update() {
    local version

    version=$(read_package_version)
    installation_entry_exists || die '尚未安装 Socks-VPS'
    run_privileged update preserve 0 "${version}" false '' '' ''
}

direct_add() {
    local version

    version=$(read_package_version)
    installation_entry_exists || die '尚未安装 Socks-VPS'
    choose_port
    choose_cn_access
    generate_secret_pair
    check_new_config_without_write \
        "${selected_port}" \
        "${version}" \
        "${selected_username}" \
        "${selected_password}" \
        "${selected_allow_cn}"
    run_privileged \
        add \
        "${selected_port_mode}" \
        "${selected_port}" \
        "${version}" \
        "${selected_allow_cn}" \
        '' \
        "${selected_username}" \
        "${selected_password}"
}

direct_credentials() {
    local requested=${1:-}
    local version

    version=$(read_package_version)
    installation_exists || die '尚未安装 Socks-VPS'
    [[ -d ${instances_dir} ]] ||
        die '请先更新 Socks-VPS，再通过 socks-vpsctl 修改凭据'
    select_instance_name "${requested}"
    read_replacement_secret_pair
    run_privileged \
        credentials \
        preserve \
        0 \
        "${version}" \
        false \
        "${selected_instance_name}" \
        "${selected_username}" \
        "${selected_password}"
}

direct_remove() {
    local requested=${1:-}
    local version

    version=$(read_package_version)
    installation_exists || die '尚未安装 Socks-VPS'
    [[ -d ${instances_dir} ]] ||
        die '请先更新 Socks-VPS，再删除 SOCKS 配置'
    select_instance_name "${requested}"
    run_privileged \
        remove \
        preserve \
        0 \
        "${version}" \
        false \
        "${selected_instance_name}" \
        '' \
        ''
}

direct_uninstall() {
    installation_detected || die '尚未安装 Socks-VPS'
    print_impact uninstall 0.0.0
    confirm_action
    run_privileged uninstall preserve 0 0.0.0 false '' '' ''
}

direct_cleanup() {
    installation_entry_exists || die '尚未安装 Socks-VPS'
    require_owned_installation false
    run_privileged cleanup preserve 0 0.0.0 false '' '' ''
}

ensure_root_for_command() {
    if [[ ${EUID} -eq 0 ]]; then
        return
    fi
    require_command sudo
    exec sudo -- "${script_path}" "$@"
}

main() {
    case ${1:-} in
        '')
            interactive_main
            ;;
        list | --list)
            [[ $# -eq 1 ]] || die '用法：socks-vpsctl list'
            ensure_root_for_command "$@"
            installation_exists || die '尚未安装 Socks-VPS'
            list_instances
            ;;
        status | --status)
            [[ $# -eq 1 ]] || die '用法：socks-vpsctl status'
            ensure_root_for_command "$@"
            installation_detected || die '尚未安装 Socks-VPS'
            show_status
            ;;
        add)
            [[ $# -eq 1 ]] || die '用法：socks-vpsctl add'
            direct_add
            ;;
        credentials)
            [[ $# -le 2 ]] || die '用法：socks-vpsctl credentials [CONFIG]'
            ensure_root_for_command "$@"
            direct_credentials "${2:-}"
            ;;
        remove)
            [[ $# -le 2 ]] || die '用法：socks-vpsctl remove [CONFIG]'
            ensure_root_for_command "$@"
            direct_remove "${2:-}"
            ;;
        update)
            [[ $# -eq 1 ]] || die '用法：socks-vpsctl update'
            run_latest_update
            ;;
        --update)
            [[ $# -eq 1 ]] || die '用法：install.sh --update'
            direct_update
            ;;
        uninstall)
            [[ $# -eq 1 ]] || die '用法：socks-vpsctl uninstall'
            direct_uninstall
            ;;
        cleanup)
            [[ $# -eq 1 ]] || die '用法：socks-vpsctl cleanup'
            direct_cleanup
            ;;
        --privileged-apply)
            [[ $# -eq 7 ]] || die '特权调用参数无效'
            privileged_entry "$2" "$3" "$4" "$5" "$6" "$7"
            ;;
        *)
            die '用法：socks-vpsctl {list|status|add|credentials [CONFIG]|remove [CONFIG]|update|cleanup|uninstall}'
            ;;
    esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
