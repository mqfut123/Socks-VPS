#!/usr/bin/env bash

set +x
set -Eeuo pipefail

readonly script_path=$(readlink -f -- "${BASH_SOURCE[0]}")
readonly script_dir=$(cd -- "$(dirname -- "${script_path}")" && pwd -P)

resolve_package_root() {
    local normal_root backup_target backup_release

    normal_root=$(cd -- "${script_dir}/.." && pwd -P)
    if [[ -x ${normal_root}/bin/socks-vps ]]; then
        printf '%s\n' "${normal_root}"
        return
    fi
    if [[ -x ${script_dir}/restore-runtime/bin/socks-vps ]]; then
        printf '%s\n' "${script_dir}/restore-runtime"
        return
    fi
    if [[ -x ${script_dir}/release/bin/socks-vps ]]; then
        printf '%s\n' "${script_dir}/release"
        return
    fi
    if [[ -L ${script_dir}/usr-local-lib-socks-vps/current ]]; then
        backup_target=$(readlink "${script_dir}/usr-local-lib-socks-vps/current")
        backup_release="${script_dir}/usr-local-lib-socks-vps/releases/${backup_target##*/}"
        if [[ -x ${backup_release}/bin/socks-vps ]]; then
            printf '%s\n' "${backup_release}"
            return
        fi
    fi
    printf '%s\n' "${normal_root}"
}

readonly package_root=$(resolve_package_root)
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
active_recovery_dir=
created_backup_dir=
installed_release_dir=

print_recovery_command() {
    local backup_dir=$1

    printf 'sudo %s/restore.sh --restore %s' "${backup_dir}" "${backup_dir}"
}

die() {
    printf 'Socks-VPS installer: %s\n' "$*" >&2
    if [[ -n ${active_recovery_dir} ]]; then
        printf 'Restore with: %s\n' \
            "$(print_recovery_command "${active_recovery_dir}")" >&2
    fi
    exit 1
}

note() {
    printf '==> %s\n' "$*"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command is unavailable: $1"
}

read_package_version() {
    local version

    [[ -r ${package_version_file} ]] || die "missing ${package_version_file}"
    IFS= read -r version <"${package_version_file}" || die 'could not read package version'
    [[ ${version} =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] ||
        die "invalid package version: ${version}"
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
            die "unsupported architecture: $(uname -m)"
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

    [[ $(uname -s) == Linux ]] || die 'Linux is required'
    require_command systemctl
    [[ -d /run/systemd/system ]] || die 'systemd is not running'

    arch=$(detect_arch)
    [[ -r ${package_target_file} ]] || die "missing ${package_target_file}"
    IFS= read -r target <"${package_target_file}" || die 'could not read package target'
    [[ ${target} == "linux/${arch}" ]] ||
        die "package target ${target} does not match linux/${arch}"

    for required in "${required_files[@]}"; do
        [[ -f ${package_root}/${required} ]] ||
            die "release package is incomplete: missing ${required}"
    done
    [[ -x ${package_binary} ]] || die 'release binary is not executable'
    [[ -x ${package_root}/scripts/firewall.sh ]] || die 'firewall helper is not executable'
    [[ ${version} == "$(read_package_version)" ]] || die 'package version changed during validation'

    (
        cd "${package_root}"
        sha256sum --check MANIFEST.sha256
    )
}

choose_port() {
    local requested

    IFS= read -r -p 'TCP port [Enter = random 1024-65535]: ' requested
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

    IFS= read -r -p 'Block mainland China IPv4 TCP access? [Y/n]: ' answer
    case ${answer:-y} in
        y | Y | yes | YES | Yes)
            selected_allow_cn=false
            ;;
        n | N | no | NO | No)
            selected_allow_cn=true
            ;;
        *)
            die 'please answer y or n'
            ;;
    esac
}

generate_secret_pair() {
    local descriptor

    exec {descriptor}< <("${package_binary}" credentials-generate)
    IFS= read -r -d '' selected_username <&"${descriptor}" ||
        die 'could not generate a username'
    IFS= read -r -d '' selected_password <&"${descriptor}" ||
        die 'could not generate a password'
    exec {descriptor}<&-
}

read_replacement_secret_pair() {
    local requested_username requested_password
    local generated_username generated_password descriptor

    exec {descriptor}< <("${package_binary}" credentials-generate)
    IFS= read -r -d '' generated_username <&"${descriptor}" ||
        die 'could not generate a username'
    IFS= read -r -d '' generated_password <&"${descriptor}" ||
        die 'could not generate a password'
    exec {descriptor}<&-

    IFS= read -r -p 'New username [Enter = secure random]: ' requested_username
    IFS= read -r -s -p 'New password [Enter = secure random]: ' requested_password
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

    printf '%s\0%s\0' "${username}" "${password}" |
        "${package_binary}" config-create \
            --check \
            --port "${port}" \
            --allow-cn="${allow_cn}" \
            --version "${version}"
}

installation_exists() {
    [[ (-d ${instances_dir} || -f ${legacy_config_file}) &&
       -L ${current_link} &&
       -L ${public_binary} ]]
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
    printf 'Socks-VPS service: '
    if systemctl is-active --quiet socks-vps.service; then
        printf 'active\n'
    else
        printf 'inactive\n'
    fi

    printf 'Socks-VPS firewall: '
    if systemctl is-active --quiet socks-vps-firewall.service; then
        printf 'active\n'
    else
        printf 'inactive\n'
    fi

    if [[ -d ${instances_dir} && -x ${public_binary} ]]; then
        printf '\n'
        list_instances
    fi
}

choose_existing_action() {
    local choice

    printf 'Existing Socks-VPS installation detected.\n'
    printf '  1) Status and SOCKS list\n'
    printf '  2) Update\n'
    printf '  3) Add a SOCKS\n'
    printf '  4) Change credentials\n'
    printf '  5) Remove a SOCKS\n'
    printf '  6) Reinstall and replace all SOCKS configs\n'
    printf '  7) Uninstall to a recoverable backup\n'
    printf '  8) Cancel\n'
    IFS= read -r -p 'Select: ' choice

    case ${choice} in
        1)
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
            selected_action=credentials
            selected_port_mode=preserve
            selected_port=0
            selected_allow_cn=false
            select_instance_name ''
            read_replacement_secret_pair
            ;;
        5)
            selected_action=remove
            selected_port_mode=preserve
            selected_port=0
            selected_username=
            selected_password=
            selected_allow_cn=false
            select_instance_name ''
            ;;
        6)
            selected_action=reinstall
            selected_instance_name=socks-1
            choose_port
            choose_cn_access
            generate_secret_pair
            ;;
        7)
            selected_action=uninstall
            selected_port_mode=preserve
            selected_port=0
            selected_username=
            selected_password=
            selected_allow_cn=false
            ;;
        8)
            exit 0
            ;;
        *)
            die 'invalid selection'
            ;;
    esac
}

print_impact() {
    local action=$1
    local version=$2

    case ${action} in
        install)
            printf 'The installer will create:\n'
            ;;
        update | reinstall)
            printf 'The installer will back up and replace the active Socks-VPS version:\n'
            ;;
        uninstall)
            printf 'The installer will stop Socks-VPS and move these owned paths into %s:\n' "${backup_root}"
            ;;
        restore)
            printf 'The installer will restore Socks-VPS from the selected backup:\n'
            ;;
    esac

    printf '  %s\n' \
        "${config_dir}" \
        "${install_root}" \
        "${public_binary}" \
        "${control_binary}" \
        "${main_unit}" \
        "${firewall_unit}" \
        'systemd units: socks-vps.service, socks-vps-firewall.service' \
        'nftables table: ip socks_vps'
    if [[ ${action} != uninstall ]]; then
        printf '  target release: %s\n' "${version}"
    fi
    printf 'WARP VPS Manager resources are read-only external resources and are not changed.\n'
}

confirm_action() {
    local answer

    IFS= read -r -p 'Continue? [y/N]: ' answer
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
    [[ ${EUID} -eq 0 ]] || die 'privileged phase must run as root'
}

detect_package_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        printf '%s\n' apt
    elif command -v dnf >/dev/null 2>&1; then
        printf '%s\n' dnf
    elif command -v yum >/dev/null 2>&1; then
        printf '%s\n' yum
    else
        die 'apt, dnf, or yum is required'
    fi
}

ensure_system_dependencies() {
    local require_nft=${1:-true}
    local manager
    local need_nft=0
    local need_iproute=0
    local -a packages=()

    if [[ ${require_nft} == true ]] &&
       ! command -v nft >/dev/null 2>&1; then
        need_nft=1
    fi
    if ! command -v ss >/dev/null 2>&1 ||
       ! command -v ip >/dev/null 2>&1; then
        need_iproute=1
    fi
    if ((need_nft == 0 && need_iproute == 0)); then
        return
    fi

    manager=$(detect_package_manager)
    note "Installing required system packages with ${manager}"
    case ${manager} in
        apt)
            ((need_nft == 0)) || packages+=(nftables)
            ((need_iproute == 0)) || packages+=(iproute2)
            apt-get update
            apt-get install -y "${packages[@]}"
            ;;
        dnf)
            ((need_nft == 0)) || packages+=(nftables)
            ((need_iproute == 0)) || packages+=(iproute)
            dnf install -y "${packages[@]}"
            ;;
        yum)
            ((need_nft == 0)) || packages+=(nftables)
            ((need_iproute == 0)) || packages+=(iproute)
            yum install -y "${packages[@]}"
            ;;
    esac
}

report_port_conflict() {
    local port=$1
    local output pid

    printf 'TCP port %s is already occupied on IPv4.\n' "${port}" >&2
    if output=$(ss -H -ltnp "sport = :${port}" 2>&1); then
        printf '%s\n' "${output}" >&2
        pid=$(printf '%s\n' "${output}" |
            sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' |
            head -n 1)
        if [[ -n ${pid} ]]; then
            if ! systemctl status "${pid}" --no-pager; then
                printf 'PID %s is not mapped to a readable systemd service.\n' "${pid}" >&2
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
        [[ -n ${ports} ]]
        return
    fi
    [[ -f ${tree}/config.json ]]
}

current_service_owns_configured_listener() {
    local main_pid output expected_ports actual_ports

    if [[ -d ${instances_dir} ]]; then
        "${public_binary}" self-check --config-dir "${instances_dir}"
        expected_ports=$(
            "${public_binary}" config-ports --config-dir "${instances_dir}" |
                LC_ALL=C sort -n
        ) || return 1
    else
        "${public_binary}" self-check --config "${legacy_config_file}"
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

    if output=$("${package_binary}" port-check --port "${port}" 2>&1); then
        printf '%s\n' "${port}"
        return 0
    else
        status=$?
    fi

    if [[ ${mode} == manual ]]; then
        if [[ ${status} == 78 ]]; then
            if [[ ${allow_current_owner} == true ]] && current_service_owns_port "${port}"; then
                printf '%s\n' "${port}"
                return 0
            fi
            report_port_conflict "${port}"
        else
            [[ -z ${output} ]] || printf '%s\n' "${output}" >&2
            printf 'Could not check TCP port %s (exit %s).\n' "${port}" "${status}" >&2
        fi
        return 1
    fi
    if [[ ${mode} == automatic ]]; then
        [[ ${status} == 78 ]] ||
            die "automatic port check failed with exit status ${status}"
        "${package_binary}" port-select
        return 0
    fi
    die "invalid port mode for a new configuration: ${mode}"
}

show_coexistence_state() {
    local unit warp_status warp_units

    note 'Read-only coexistence check'
    if warp_units=$(systemctl list-unit-files 'warp-vps*' --no-legend --no-pager 2>&1); then
        [[ -z ${warp_units} ]] || printf '%s\n' "${warp_units}"
    else
        warp_status=$?
        if [[ ${warp_status} != 1 || -n ${warp_units} ]]; then
            [[ -z ${warp_units} ]] || printf '%s\n' "${warp_units}" >&2
            printf 'Could not list WARP VPS Manager units.\n' >&2
        fi
    fi
    for unit in nftables.service firewalld.service ufw.service; do
        if systemctl is-active --quiet "${unit}"; then
            printf 'Detected active firewall service: %s\n' "${unit}"
        fi
    done
    if command -v nft >/dev/null 2>&1; then
        if nft list table inet warp_vps >/dev/null 2>&1; then
            printf 'Detected external nftables table: inet warp_vps (unchanged)\n'
        fi
    fi
}

recovery_error() {
    local status=$?

    trap - ERR
    printf 'Socks-VPS change failed with exit status %s.\n' "${status}" >&2
    printf 'Restore with: %s\n' \
        "$(print_recovery_command "${active_recovery_dir}")" >&2
    exit "${status}"
}

enable_recovery_error() {
    active_recovery_dir=$1
    trap recovery_error ERR
}

disable_recovery_error() {
    trap - ERR
    active_recovery_dir=
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
        [[ ${require_nft} == false ]] || die 'nft is required while CN blocking is enabled'
        return 0
    fi

    if nft --json list table ip socks_vps >/dev/null 2>&1; then
        table_state=present
    else
        tables=$(nft list tables) || die 'could not inspect nftables tables'
        if grep -Eq '^[[:space:]]*table ip socks_vps[[:space:]]*$' <<<"${tables}"; then
            die 'table ip socks_vps exists but could not be inspected'
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
    local tables
    local verify_dir=/run/socks-vps
    local verify_json="${verify_dir}/verify-existing-table.json"
    local verify_rules="${verify_dir}/verify-owned-table.nft"

    if ! command -v nft >/dev/null 2>&1; then
        if [[ -d ${instances_dir} || -f ${legacy_config_file} ]] &&
           configuration_requires_nft; then
            die 'nft is unavailable while a CN-blocked configuration exists'
        fi
        return 0
    fi
    install -d -m 0750 -o root -g root "${verify_dir}"
    if nft --json list table ip socks_vps >"${verify_json}" 2>/dev/null; then
        "${package_binary}" firewall-render \
            --port 1024 \
            --allow-cn=true \
            --existing-table-json "${verify_json}" \
            --output "${verify_rules}"
        [[ ! -s ${verify_rules} ]] ||
            die 'owned table ip socks_vps is still loaded'
        return 0
    fi
    tables=$(nft list tables) || die 'could not verify nftables table removal'
    if grep -Eq '^[[:space:]]*table ip socks_vps[[:space:]]*$' <<<"${tables}"; then
        die 'table ip socks_vps exists but could not be inspected'
    fi
}

stop_owned_services() {
    if ! systemctl stop socks-vps.service; then
        die 'could not stop socks-vps.service'
    fi
    if ! systemctl stop socks-vps-firewall.service; then
        die 'could not stop socks-vps-firewall.service'
    fi
    if systemctl is-active --quiet socks-vps.service; then
        die 'socks-vps.service remained active after stop'
    fi
    if systemctl is-active --quiet socks-vps-firewall.service; then
        die 'socks-vps-firewall.service remained active after stop'
    fi
    require_socks_table_absent
}

validate_account() {
    getent passwd socks-vps >/dev/null &&
        getent group socks-vps >/dev/null
}

check_fresh_account_conflicts() {
    if getent passwd socks-vps >/dev/null || getent group socks-vps >/dev/null; then
        die 'socks-vps user or group already exists outside a proven installation'
    fi
}

create_account() {
    local nologin_shell

    if nologin_shell=$(command -v nologin); then
        :
    elif [[ -x /sbin/nologin ]]; then
        nologin_shell=/sbin/nologin
    else
        die 'nologin shell is unavailable'
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
    installation_exists || die 'Socks-VPS ownership boundary is incomplete'
    [[ -f ${main_unit} && -f ${firewall_unit} ]] ||
        die 'Socks-VPS systemd unit ownership boundary is incomplete'
    if [[ -d ${instances_dir} ]]; then
        "${package_binary}" config-check --config-dir "${instances_dir}"
    else
        "${package_binary}" config-check --config "${legacy_config_file}"
    fi
    [[ $(readlink -f "${public_binary}") == "${install_root}/releases/"*"/bin/socks-vps" ]] ||
        die "${public_binary} does not point into the Socks-VPS release directory"
    [[ $(readlink -f "${current_link}") == "${install_root}/releases/"* ]] ||
        die "${current_link} does not point into the Socks-VPS release directory"
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
        [[ ! -e ${path} && ! -L ${path} ]] || die "installation path already exists: ${path}"
    done
}

new_backup_dir() {
    local purpose=$1
    local timestamp
    local destination

    timestamp=$(date -u +%Y%m%dT%H%M%SZ)
    destination="${backup_root}/${timestamp}-${purpose}-$$"
    [[ ! -e ${destination} ]] || die "backup path already exists: ${destination}"
    install -d -m 0700 -o root -g root "${destination}"
    created_backup_dir=${destination}
}

backup_current_installation() {
    local destination=$1
    local current_target

    current_target=$(readlink -f "${current_link}")
    [[ ${current_target} == "${releases_dir}/"* && -x ${current_target}/bin/socks-vps ]] ||
        die 'current release target is outside the owned release tree'
    printf 'snapshot\n' >"${destination}/kind"
    if [[ -e ${control_binary} || -L ${control_binary} ]]; then
        printf 'present\n' >"${destination}/control-state"
    else
        printf 'absent\n' >"${destination}/control-state"
    fi
    cp -a "${config_dir}" "${destination}/etc-socks-vps"
    install -d -m 0700 -o root -g root "${destination}/restore-runtime/bin"
    install -m 0755 -o root -g root \
        "${package_binary}" \
        "${destination}/restore-runtime/bin/socks-vps"
    install -m 0644 -o root -g root "${main_unit}" "${destination}/socks-vps.service"
    install -m 0644 -o root -g root "${firewall_unit}" "${destination}/socks-vps-firewall.service"
    install -m 0644 -o root -g root "${current_target}/VERSION" "${destination}/VERSION"
    install -m 0755 -o root -g root \
        "${package_root}/scripts/install.sh" \
        "${destination}/restore.sh"
    cp -a "${current_target}" "${destination}/release"
}

install_release_tree() {
    local version=$1
    local action=$2
    local release_dir="${releases_dir}/${version}"

    if [[ -e ${release_dir} ]]; then
        if [[ ${action} != reinstall ]]; then
            die "release directory already exists: ${release_dir}"
        fi
        release_dir="${releases_dir}/${version}-reinstall-$(date -u +%Y%m%dT%H%M%SZ)-$$"
        [[ ! -e ${release_dir} ]] || die "reinstall staging path already exists: ${release_dir}"
    fi

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
        die "invalid SOCKS config name: ${name}"
    [[ ! -e ${target} ]] || die "SOCKS config already exists: ${name}"
    [[ ! -e ${pending} ]] || die "pending configuration already exists: ${pending}"
    printf '%s\0%s\0' "${username}" "${password}" |
        "${package_binary}" config-create \
            --port "${port}" \
            --allow-cn="${allow_cn}" \
            --version "${version}" \
            --output "${pending}"
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
            die 'legacy migration target already exists'
        "${package_binary}" config-create \
            --preserve "${legacy_config_file}" \
            --version "${version}" \
            --output "${pending}"
        chown root:socks-vps "${pending}"
        chmod 0640 "${pending}"
        mv -T "${pending}" "${instances_dir}/socks-1.json"
        mv "${legacy_config_file}" "${legacy_config_file}.migrated-${version}"
        return
    fi

    shopt -s nullglob
    sources=("${instances_dir}"/*.json)
    shopt -u nullglob
    ((${#sources[@]} > 0)) || die 'no SOCKS configurations are installed'
    for source in "${sources[@]}"; do
        name=$(basename "${source}" .json)
        pending="${instances_dir}/.${name}.pending-${version}-preserve"
        [[ ! -e ${pending} ]] || die "pending configuration already exists: ${pending}"
        "${package_binary}" config-create \
            --preserve "${source}" \
            --version "${version}" \
            --output "${pending}"
        chown root:socks-vps "${pending}"
        chmod 0640 "${pending}"
        mv -T "${pending}" "${source}"
    done
}

activate_release() {
    local release_dir=$1

    replace_symlink "${release_dir}" "${current_link}"
    replace_symlink "${current_link}/bin/socks-vps" "${public_binary}"
    replace_symlink "${current_link}/scripts/install.sh" "${control_binary}"
    install -m 0644 -o root -g root \
        "${release_dir}/packaging/systemd/socks-vps.service" \
        "${main_unit}"
    install -m 0644 -o root -g root \
        "${release_dir}/packaging/systemd/socks-vps-firewall.service" \
        "${firewall_unit}"
    systemctl daemon-reload
}

replace_symlink() {
    local target=$1
    local link_path=$2
    local pending="${link_path}.pending-$$"

    if [[ -e ${link_path} && ! -L ${link_path} ]]; then
        die "symlink destination is an existing non-symlink: ${link_path}"
    fi
    [[ ! -e ${pending} && ! -L ${pending} ]] ||
        die "pending symlink already exists: ${pending}"
    ln -s "${target}" "${pending}"
    mv -T "${pending}" "${link_path}"
}

verify_active_installation() {
    systemctl is-active --quiet socks-vps.service || return 1
    current_service_owns_configured_listener || return 1
    systemctl is-active --quiet socks-vps-firewall.service || return 1
    if configuration_requires_nft; then
        command -v nft >/dev/null 2>&1 || return 1
        nft --json list table ip socks_vps >/dev/null || return 1
    fi
    systemctl enable socks-vps.service
}

verify_started_port() {
    local port=$1

    verify_active_installation || return 1
    current_service_owns_port "${port}"
}

start_attempt_decision() {
    local port_mode=$1
    local start_status=$2
    local verify_status=$3
    local exec_status=$4

    if [[ ${start_status} == 0 && ${verify_status} == 0 ]]; then
        printf 'success\n'
    elif [[ ${port_mode} == automatic && ${exec_status} == 78 ]]; then
        printf 'retry\n'
    else
        printf 'fail\n'
    fi
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
    local start_status verify_status exec_status decision

    while :; do
        start_status=0
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
            printf 'Socks-VPS %s is active on TCP port %s.\n' "${version}" "${port}"
            return 0
        fi

        if ! exec_status=$(
            systemctl show socks-vps.service --property=ExecMainStatus --value
        ); then
            exec_status=unavailable
        fi
        [[ -n ${exec_status} ]] || exec_status=unavailable
        stop_owned_services
        decision=$(start_attempt_decision \
            "${port_mode}" \
            "${start_status}" \
            "${verify_status}" \
            "${exec_status}")

        if [[ ${decision} != retry ]]; then
            if ! systemctl status socks-vps.service --no-pager; then
                printf 'The failed service status is shown above.\n' >&2
            fi
            die "service attempt failed (start=${start_status}, verify=${verify_status}, ExecMainStatus=${exec_status})"
        fi

        note "Automatically selected port ${port} was claimed before bind; selecting another port"
        port=$("${package_binary}" port-select)
        mv \
            "${instances_dir}/${name}.json" \
            "${instances_dir}/.${name}.bind-failed-${attempt}"
        create_new_config \
            "${name}" \
            "${port}" \
            "${version}" \
            "${username}" \
            "${password}" \
            "${allow_cn}" \
            "${attempt}"
        attempt=$((attempt + 1))
    done
}

start_preserved_and_verify() {
    local start_status=0
    local verify_status=1
    local exec_status

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
    die "preserved service attempt failed (start=${start_status}, verify=${verify_status}, ExecMainStatus=${exec_status})"
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
    local backup_dir=
    local release_dir
    local selected
    local allow_current_owner=false
    local require_nft=false

    if [[ ${action} == install ]]; then
        check_fresh_path_conflicts
        check_fresh_account_conflicts
    else
        require_owned_installation
        validate_account || die 'Socks-VPS system account is missing'
    fi
    if [[ ${action} == update && -e ${releases_dir}/${version} ]]; then
        die "version ${version} is already installed; use reinstall if replacement is required"
    fi

    if [[ ${action} != install ]] && configuration_requires_nft; then
        require_nft=true
    elif [[ ${action} != update && ${allow_cn} == false ]]; then
        require_nft=true
    fi
    ensure_system_dependencies "${require_nft}"
    show_coexistence_state

    if [[ ${action} == install || ${action} == reinstall ]]; then
        if [[ ${action} == reinstall ]]; then
            allow_current_owner=true
        fi
        selected=$(check_or_reselect_port \
            "${port_mode}" \
            "${requested_port}" \
                "${allow_current_owner}") ||
            die 'selected port is unavailable'
        requested_port=${selected}
        check_new_config_without_write \
            "${requested_port}" \
            "${version}" \
            "${username}" \
            "${password}" \
            "${allow_cn}"
    fi

    preflight_firewall "${port_mode}" "${requested_port}" "${allow_cn}"

    if [[ ${action} != install ]]; then
        new_backup_dir "${action}"
        backup_dir=${created_backup_dir}
        backup_current_installation "${backup_dir}"
        enable_recovery_error "${backup_dir}"
        printf 'Socks-VPS snapshot saved to %s\n' "${backup_dir}"
        printf 'Recovery command: %s\n' \
            "$(print_recovery_command "${backup_dir}")"
        stop_owned_services
    fi

    if [[ ${action} == install ]]; then
        create_account
    fi
    install -d -m 0755 -o root -g root "${install_root}" "${releases_dir}"
    install -d -m 0750 -o root -g socks-vps "${config_dir}"
    if [[ ${action} == reinstall ]]; then
        mv "${config_dir}" "${backup_dir}/replaced-etc-socks-vps"
        install -d -m 0750 -o root -g socks-vps "${config_dir}"
    fi
    install -d -m 0750 -o root -g socks-vps "${instances_dir}"
    install_release_tree "${version}" "${action}"
    release_dir=${installed_release_dir}

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

    if [[ ${action} == update ]]; then
        start_preserved_and_verify
        disable_recovery_error
        printf 'Socks-VPS updated to %s. Port and credentials were preserved.\n' "${version}"
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
    disable_recovery_error
    print_connection_details "${name}"
}

uninstall_to_backup() {
    local backup_dir
    local require_nft=false

    require_owned_installation
    if configuration_requires_nft; then
        require_nft=true
    fi
    ensure_system_dependencies "${require_nft}"

    new_backup_dir uninstall
    backup_dir=${created_backup_dir}

    install -d -m 0700 -o root -g root \
        "${backup_dir}/units" \
        "${backup_dir}/restore-runtime/bin"
    printf 'uninstall\n' >"${backup_dir}/kind"
    install -m 0755 -o root -g root \
        "${package_root}/scripts/install.sh" \
        "${backup_dir}/restore.sh"
    install -m 0755 -o root -g root \
        "${package_binary}" \
        "${backup_dir}/restore-runtime/bin/socks-vps"
    enable_recovery_error "${backup_dir}"
    stop_owned_services
    if ! systemctl disable socks-vps.service; then
        die 'could not disable socks-vps.service'
    fi
    mv "${config_dir}" "${backup_dir}/etc-socks-vps"
    mv "${install_root}" "${backup_dir}/usr-local-lib-socks-vps"
    mv "${public_binary}" "${backup_dir}/usr-local-bin-socks-vps"
    if [[ -e ${control_binary} || -L ${control_binary} ]]; then
        mv "${control_binary}" "${backup_dir}/usr-local-bin-socks-vpsctl"
    fi
    mv "${main_unit}" "${backup_dir}/units/socks-vps.service"
    mv "${firewall_unit}" "${backup_dir}/units/socks-vps-firewall.service"
    systemctl daemon-reload

    if getent passwd socks-vps >/dev/null; then
        usermod --lock socks-vps
    fi

    disable_recovery_error
    printf 'Socks-VPS was stopped and moved to %s\n' "${backup_dir}"
    printf 'The dedicated locked system account was retained for recoverability.\n'
    printf 'Restore with: %s\n' "$(print_recovery_command "${backup_dir}")"
}

path_exists() {
    [[ -e $1 || -L $1 ]]
}

restore_pair_state() {
    local source_path=$1
    local target_path=$2
    local source_exists=0
    local target_exists=0

    path_exists "${source_path}" && source_exists=1
    path_exists "${target_path}" && target_exists=1
    case "${source_exists}${target_exists}" in
        10)
            printf 'move\n'
            ;;
        01)
            printf 'done\n'
            ;;
        11)
            printf 'conflict\n'
            ;;
        00)
            printf 'missing\n'
            ;;
    esac
}

validate_restore_path_type() {
    local path=$1
    local expected_type=$2

    case ${expected_type} in
        directory)
            [[ -d ${path} ]] || die "restore path is not a directory: ${path}"
            ;;
        file)
            [[ -f ${path} && ! -L ${path} ]] ||
                die "restore path is not a regular file: ${path}"
            ;;
        symlink)
            [[ -L ${path} ]] || die "restore path is not a symlink: ${path}"
            ;;
        *)
            die "unknown restore path type: ${expected_type}"
            ;;
    esac
}

validate_restore_pair() {
    local source_path=$1
    local target_path=$2
    local expected_type=$3
    local state

    state=$(restore_pair_state "${source_path}" "${target_path}")
    case ${state} in
        move)
            validate_restore_path_type "${source_path}" "${expected_type}"
            ;;
        done)
            validate_restore_path_type "${target_path}" "${expected_type}"
            ;;
        conflict)
            die "restore source and target both exist: ${source_path}, ${target_path}"
            ;;
        missing)
            die "restore source and target are both missing: ${source_path}, ${target_path}"
            ;;
    esac
}

restore_owned_path() {
    local source_path=$1
    local target_path=$2
    local state

    state=$(restore_pair_state "${source_path}" "${target_path}")
    case ${state} in
        move)
            mv "${source_path}" "${target_path}"
            ;;
        done)
            ;;
        *)
            die "restore path state changed unexpectedly: ${source_path}, ${target_path}"
            ;;
    esac
}

restore_snapshot_backup() {
    local backup_dir=$1
    local version restored_target control_state

    [[ -d ${backup_dir}/etc-socks-vps ]] ||
        die 'backup is missing the configuration directory'
    [[ -r ${backup_dir}/socks-vps.service ]] || die 'backup is missing the main unit'
    [[ -r ${backup_dir}/socks-vps-firewall.service ]] || die 'backup is missing the firewall unit'
    [[ -r ${backup_dir}/VERSION ]] || die 'backup is missing VERSION'
    [[ -r ${backup_dir}/control-state ]] ||
        die 'backup is missing the control command state'
    [[ -x ${backup_dir}/release/bin/socks-vps ]] ||
        die 'backup is missing the saved release binary'
    [[ -x ${backup_dir}/restore-runtime/bin/socks-vps ]] ||
        die 'backup is missing the restore runtime'
    [[ -r ${backup_dir}/release/assets/ipdeny/cn-aggregated.zone ]] ||
        die 'backup is missing the saved firewall source data'
    IFS= read -r version <"${backup_dir}/VERSION" || die 'could not read backup VERSION'
    IFS= read -r control_state <"${backup_dir}/control-state" ||
        die 'could not read the control command state'
    [[ ${control_state} == present || ${control_state} == absent ]] ||
        die 'backup has an invalid control command state'
    [[ $(<"${backup_dir}/release/VERSION") == "${version}" ]] ||
        die 'saved release VERSION does not match the backup'

    [[ -L ${current_link} && -L ${public_binary} &&
       -f ${main_unit} && -f ${firewall_unit} ]] ||
        die 'current Socks-VPS runtime paths are incomplete'
    validate_account || die 'Socks-VPS system account is missing'
    if configuration_tree_requires_nft "${backup_dir}/etc-socks-vps"; then
        ensure_system_dependencies true
    else
        ensure_system_dependencies false
    fi
    stop_owned_services

    restored_target="${releases_dir}/${version}-restored-$(date -u +%Y%m%dT%H%M%SZ)-$$"
    [[ ! -e ${restored_target} ]] ||
        die "restore release target already exists: ${restored_target}"
    cp -a "${backup_dir}/release" "${restored_target}"
    if [[ -e ${config_dir} ]]; then
        mv \
            "${config_dir}" \
            "${backup_dir}/failed-etc-socks-vps-$(date -u +%Y%m%dT%H%M%SZ)-$$"
    fi
    cp -a "${backup_dir}/etc-socks-vps" "${config_dir}"
    install -m 0644 -o root -g root "${backup_dir}/socks-vps.service" "${main_unit}"
    install -m 0644 -o root -g root \
        "${backup_dir}/socks-vps-firewall.service" \
        "${firewall_unit}"
    replace_symlink "${restored_target}" "${current_link}"
    replace_symlink "${current_link}/bin/socks-vps" "${public_binary}"
    if [[ ${control_state} == present ]]; then
        replace_symlink "${current_link}/scripts/install.sh" "${control_binary}"
    elif [[ -e ${control_binary} || -L ${control_binary} ]]; then
        mv \
            "${control_binary}" \
            "${backup_dir}/failed-usr-local-bin-socks-vpsctl-$(date -u +%Y%m%dT%H%M%SZ)-$$"
    fi
    systemctl daemon-reload
    start_preserved_and_verify
}

restore_uninstall_backup() {
    local backup_dir=$1

    [[ -x ${backup_dir}/restore-runtime/bin/socks-vps ]] ||
        die 'backup is missing the restore runtime'
    validate_restore_pair \
        "${backup_dir}/etc-socks-vps" "${config_dir}" directory
    validate_restore_pair \
        "${backup_dir}/usr-local-lib-socks-vps" "${install_root}" directory
    validate_restore_pair \
        "${backup_dir}/usr-local-bin-socks-vps" "${public_binary}" symlink
    if path_exists "${backup_dir}/usr-local-bin-socks-vpsctl" ||
       path_exists "${control_binary}"; then
        validate_restore_pair \
            "${backup_dir}/usr-local-bin-socks-vpsctl" "${control_binary}" symlink
    fi
    validate_restore_pair \
        "${backup_dir}/units/socks-vps.service" "${main_unit}" file
    validate_restore_pair \
        "${backup_dir}/units/socks-vps-firewall.service" "${firewall_unit}" file
    validate_account || die 'Socks-VPS system account is missing'
    if configuration_tree_requires_nft "${backup_dir}/etc-socks-vps"; then
        ensure_system_dependencies true
    else
        ensure_system_dependencies false
    fi
    if systemctl is-active --quiet socks-vps.service ||
       systemctl is-active --quiet socks-vps-firewall.service; then
        die 'a Socks-VPS service is active while its owned files are absent'
    fi

    restore_owned_path "${backup_dir}/etc-socks-vps" "${config_dir}"
    restore_owned_path "${backup_dir}/usr-local-lib-socks-vps" "${install_root}"
    restore_owned_path "${backup_dir}/usr-local-bin-socks-vps" "${public_binary}"
    if path_exists "${backup_dir}/usr-local-bin-socks-vpsctl" ||
       path_exists "${control_binary}"; then
        restore_owned_path \
            "${backup_dir}/usr-local-bin-socks-vpsctl" \
            "${control_binary}"
    fi
    restore_owned_path "${backup_dir}/units/socks-vps.service" "${main_unit}"
    restore_owned_path \
        "${backup_dir}/units/socks-vps-firewall.service" \
        "${firewall_unit}"
    require_owned_installation
    systemctl daemon-reload
    start_preserved_and_verify
}

restore_backup() {
    local backup_dir=$1
    local kind

    [[ ${backup_dir} == "${backup_root}/"* ]] ||
        die 'restore path is outside the Socks-VPS backup root'
    [[ -x ${backup_dir}/restore.sh ]] || die 'backup is missing restore.sh'
    [[ -r ${backup_dir}/kind ]] || die 'backup is missing its kind marker'
    IFS= read -r kind <"${backup_dir}/kind" || die 'could not read backup kind'

    enable_recovery_error "${backup_dir}"
    case ${kind} in
        snapshot)
            restore_snapshot_backup "${backup_dir}"
            ;;
        uninstall)
            restore_uninstall_backup "${backup_dir}"
            ;;
        *)
            die "unsupported backup kind: ${kind}"
            ;;
    esac
    disable_recovery_error
    printf 'Socks-VPS restored from %s\n' "${backup_dir}"
}

read_config_detail() {
    local path=$1
    local descriptor

    exec {descriptor}< <("${package_binary}" config-detail --config "${path}")
    IFS= read -r -d '' detail_port <&"${descriptor}" ||
        die "could not read port from ${path}"
    IFS= read -r -d '' detail_username <&"${descriptor}" ||
        die "could not read username from ${path}"
    IFS= read -r -d '' detail_password <&"${descriptor}" ||
        die "could not read password from ${path}"
    IFS= read -r -d '' detail_allow_cn <&"${descriptor}" ||
        die "could not read CN access setting from ${path}"
    exec {descriptor}<&-
}

list_instances() {
    local path name cn_text
    local -a paths

    shopt -s nullglob
    paths=("${instances_dir}"/*.json)
    shopt -u nullglob
    ((${#paths[@]} > 0)) || die 'no SOCKS configurations are installed'

    printf '%-18s %-8s %-10s\n' 'CONFIG' 'PORT' 'CN BLOCK'
    for path in "${paths[@]}"; do
        name=$(basename "${path}" .json)
        read_config_detail "${path}"
        if [[ ${detail_allow_cn} == true ]]; then
            cn_text=disabled
        else
            cn_text=enabled
        fi
        printf '%-18s %-8s %-10s\n' "${name}" "${detail_port}" "${cn_text}"
    done
}

select_instance_name() {
    local requested=${1:-}
    local path
    local -a paths

    if [[ -n ${requested} ]]; then
        [[ ${requested} =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] ||
            die "invalid SOCKS config name: ${requested}"
        [[ -f ${instances_dir}/${requested}.json ]] ||
            die "SOCKS config does not exist: ${requested}"
        selected_instance_name=${requested}
        return
    fi

    shopt -s nullglob
    paths=("${instances_dir}"/*.json)
    shopt -u nullglob
    ((${#paths[@]} > 0)) || die 'no SOCKS configurations are installed'
    if ((${#paths[@]} == 1)); then
        selected_instance_name=$(basename "${paths[0]}" .json)
        return
    fi

    list_instances
    IFS= read -r -p 'Config name: ' requested
    [[ ${requested} =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] ||
        die 'invalid SOCKS config name'
    path="${instances_dir}/${requested}.json"
    [[ -f ${path} ]] || die "SOCKS config does not exist: ${requested}"
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
    if [[ -z ${address:-} ]] && command -v ip >/dev/null 2>&1; then
        address=$(
            ip -4 route get 1.1.1.1 2>/dev/null |
                sed -n 's/.* src \([0-9.][0-9.]*\).*/\1/p' |
                head -n 1
        )
    fi
    [[ ${address:-} =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
        address='check your VPS public IPv4'
    printf '%s\n' "${address}"
}

print_connection_details() {
    local name=$1
    local server_ip cn_text

    read_config_detail "${instances_dir}/${name}.json"
    server_ip=$(detect_server_ipv4)
    if [[ ${detail_allow_cn} == true ]]; then
        cn_text=disabled
    else
        cn_text=enabled
    fi

    printf '\nSocks-VPS is ready.\n\n'
    printf '  %-10s %s\n' 'Server IP' "${server_ip}"
    printf '  %-10s %s\n' 'Port' "${detail_port}"
    printf '  %-10s %s\n' 'Username' "${detail_username}"
    printf '  %-10s %s\n' 'Password' "${detail_password}"
    printf '  %-10s %s\n' 'Config' "${name}"
    printf '  %-10s %s\n' 'CN block' "${cn_text}"
    printf '\n'
}

snapshot_for_change() {
    local purpose=$1

    new_backup_dir "${purpose}"
    backup_current_installation "${created_backup_dir}"
    printf 'Recovery snapshot: %s\n' "${created_backup_dir}"
    enable_recovery_error "${created_backup_dir}"
}

add_instance() {
    local port_mode=$1
    local requested_port=$2
    local version=$3
    local allow_cn=$4
    local username=$5
    local password=$6
    local name selected require_nft=false

    require_owned_installation
    [[ -d ${instances_dir} ]] ||
        die 'update Socks-VPS before adding another SOCKS config'
    name=$(next_instance_name)
    if configuration_requires_nft || [[ ${allow_cn} == false ]]; then
        require_nft=true
    fi
    ensure_system_dependencies "${require_nft}"
    selected=$(check_or_reselect_port "${port_mode}" "${requested_port}") ||
        die 'selected port is unavailable'
    check_new_config_without_write \
        "${selected}" "${version}" "${username}" "${password}" "${allow_cn}"
    preflight_firewall "${port_mode}" "${selected}" "${allow_cn}"
    snapshot_for_change add
    stop_owned_services
    create_new_config \
        "${name}" \
        "${selected}" \
        "${version}" \
        "${username}" \
        "${password}" \
        "${allow_cn}" \
        0
    start_and_verify \
        "${port_mode}" \
        "${version}" \
        "${name}" \
        "${username}" \
        "${password}" \
        "${allow_cn}" \
        "${selected}"
    disable_recovery_error
    print_connection_details "${name}"
}

change_instance_credentials() {
    local name=$1
    local version=$2
    local username=$3
    local password=$4
    local target pending require_nft=false

    require_owned_installation
    [[ -d ${instances_dir} ]] ||
        die 'update Socks-VPS before changing credentials with socks-vpsctl'
    target="${instances_dir}/${name}.json"
    [[ -f ${target} ]] || die "SOCKS config does not exist: ${name}"
    read_config_detail "${target}"
    check_new_config_without_write \
        "${detail_port}" \
        "${version}" \
        "${username}" \
        "${password}" \
        "${detail_allow_cn}"
    if configuration_requires_nft; then
        require_nft=true
    fi
    ensure_system_dependencies "${require_nft}"
    snapshot_for_change credentials
    stop_owned_services

    pending="${instances_dir}/.${name}.credentials-${version}-$$"
    [[ ! -e ${pending} ]] || die "pending configuration already exists: ${pending}"
    printf '%s\0%s\0' "${username}" "${password}" |
        "${package_binary}" config-create \
            --port "${detail_port}" \
            --allow-cn="${detail_allow_cn}" \
            --version "${version}" \
            --output "${pending}"
    chown root:socks-vps "${pending}"
    chmod 0640 "${pending}"
    mv -T "${pending}" "${target}"
    start_preserved_and_verify
    disable_recovery_error
    print_connection_details "${name}"
}

remove_instance() {
    local name=$1
    local target
    local -a paths
    local require_nft=false

    require_owned_installation
    [[ -d ${instances_dir} ]] ||
        die 'update Socks-VPS before removing a SOCKS config'
    shopt -s nullglob
    paths=("${instances_dir}"/*.json)
    shopt -u nullglob
    ((${#paths[@]} > 1)) ||
        die 'the last SOCKS config cannot be removed; use socks-vpsctl uninstall'
    target="${instances_dir}/${name}.json"
    [[ -f ${target} ]] || die "SOCKS config does not exist: ${name}"
    if configuration_requires_nft; then
        require_nft=true
    fi
    ensure_system_dependencies "${require_nft}"
    snapshot_for_change remove
    stop_owned_services
    mv "${target}" "${created_backup_dir}/removed-${name}.json"
    start_preserved_and_verify
    disable_recovery_error
    printf 'Removed SOCKS config %s.\n\n' "${name}"
    list_instances
}

run_latest_update() {
    local work_dir bootstrap

    [[ ${latest_installer_url} == https://* ]] ||
        die 'this source checkout has no public update URL; use a release package'
    require_command curl
    work_dir=$(mktemp -d "${TMPDIR:-/tmp}/socks-vps-update.XXXXXXXX")
    bootstrap="${work_dir}/install.sh"
    curl --fail --silent --show-error --location \
        --proto '=https' --tlsv1.2 \
        --output "${bootstrap}" \
        "${latest_installer_url}"
    exec bash "${bootstrap}" --update
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
    check_package "${version}"

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
            uninstall_to_backup
            ;;
        *)
            die "invalid privileged action: ${action}"
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
    IFS= read -r -d '' username || die 'privileged input is missing username'
    IFS= read -r -d '' password || die 'privileged input is missing password'
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
    local version

    version=$(read_package_version)
    check_package "${version}"

    if installation_exists; then
        choose_existing_action
    elif installation_detected; then
        die 'partial or foreign Socks-VPS paths were detected; inspect the project paths before installing'
    else
        selected_action=install
        selected_instance_name=socks-1
        choose_port
        choose_cn_access
        generate_secret_pair
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

    if [[ ${selected_action} == uninstall ]]; then
        print_impact uninstall "${version}"
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
    local version installed_version_file installed_version

    version=$(read_package_version)
    check_package "${version}"
    installation_exists || die 'Socks-VPS is not installed'
    installed_version_file="$(readlink -f "${current_link}")/VERSION"
    if [[ -r ${installed_version_file} ]]; then
        IFS= read -r installed_version <"${installed_version_file}" ||
            die 'could not read the installed version'
        if [[ ${installed_version} == "${version}" ]]; then
            printf 'Socks-VPS %s is already current.\n' "${version}"
            return
        fi
    fi
    run_privileged update preserve 0 "${version}" false '' '' ''
}

direct_add() {
    local version

    version=$(read_package_version)
    check_package "${version}"
    installation_exists || die 'Socks-VPS is not installed'
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
    check_package "${version}"
    installation_exists || die 'Socks-VPS is not installed'
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
    check_package "${version}"
    installation_exists || die 'Socks-VPS is not installed'
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
    local version

    version=$(read_package_version)
    check_package "${version}"
    installation_exists || die 'Socks-VPS is not installed'
    print_impact uninstall "${version}"
    confirm_action
    run_privileged uninstall preserve 0 "${version}" false '' '' ''
}

ensure_root_entry() {
    if [[ ${EUID} -eq 0 ]]; then
        return
    fi
    require_command sudo
    exec sudo -- "${script_path}" "$@"
}

main() {
    ensure_root_entry "$@"

    case ${1:-} in
        '')
            interactive_main
            ;;
        list | --list)
            [[ $# -eq 1 ]] || die 'usage: socks-vpsctl list'
            installation_exists || die 'Socks-VPS is not installed'
            list_instances
            ;;
        status | --status)
            [[ $# -eq 1 ]] || die 'usage: socks-vpsctl status'
            show_status
            ;;
        add)
            [[ $# -eq 1 ]] || die 'usage: socks-vpsctl add'
            direct_add
            ;;
        credentials)
            [[ $# -le 2 ]] || die 'usage: socks-vpsctl credentials [CONFIG]'
            direct_credentials "${2:-}"
            ;;
        remove)
            [[ $# -le 2 ]] || die 'usage: socks-vpsctl remove [CONFIG]'
            direct_remove "${2:-}"
            ;;
        update)
            [[ $# -eq 1 ]] || die 'usage: socks-vpsctl update'
            run_latest_update
            ;;
        --update)
            [[ $# -eq 1 ]] || die 'usage: install.sh --update'
            direct_update
            ;;
        uninstall)
            [[ $# -eq 1 ]] || die 'usage: socks-vpsctl uninstall'
            direct_uninstall
            ;;
        --privileged-apply)
            [[ $# -eq 7 ]] || die 'invalid privileged invocation'
            privileged_entry "$2" "$3" "$4" "$5" "$6" "$7"
            ;;
        --restore)
            [[ $# -eq 2 ]] || die 'usage: install.sh --restore BACKUP_DIR'
            require_root
            restore_backup "$2"
            ;;
        *)
            die 'usage: socks-vpsctl {list|status|add|credentials [CONFIG]|remove [CONFIG]|update|uninstall}'
            ;;
    esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
