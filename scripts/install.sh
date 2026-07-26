#!/usr/bin/env bash

set +x
set -Eeuo pipefail

readonly script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly package_root=$(cd -- "${script_dir}/.." && pwd -P)
readonly package_binary="${package_root}/bin/socks-vps"
readonly package_version_file="${package_root}/VERSION"
readonly package_target_file="${package_root}/TARGET"

readonly config_dir=/etc/socks-vps
readonly config_file="${config_dir}/config.json"
readonly install_root=/usr/local/lib/socks-vps
readonly releases_dir="${install_root}/releases"
readonly current_link="${install_root}/current"
readonly public_binary=/usr/local/bin/socks-vps
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

read_secret_pair() {
    local prompt_username=${1:-'Username'}

    IFS= read -r -p "${prompt_username}: " selected_username
    IFS= read -r -s -p 'Password: ' selected_password
    printf '\n'
}

choose_port() {
    local choice requested

    printf 'Port selection:\n'
    printf '  1) Automatic unused TCP port\n'
    printf '  2) Specify a TCP port\n'
    IFS= read -r -p 'Select [1]: ' choice
    choice=${choice:-1}

    case ${choice} in
        1)
            selected_port_mode=automatic
            selected_port=$("${package_binary}" port-select)
            ;;
        2)
            IFS= read -r -p 'TCP port (1024-65535): ' requested
            selected_port_mode=manual
            selected_port=${requested}
            ;;
        *)
            die 'invalid port selection'
            ;;
    esac
}

check_new_config_without_write() {
    local port=$1
    local version=$2
    local username=$3
    local password=$4

    printf '%s\0%s\0' "${username}" "${password}" |
        "${package_binary}" config-create \
            --check \
            --port "${port}" \
            --version "${version}"
}

installation_exists() {
    [[ -f ${config_file} && -L ${current_link} && -L ${public_binary} ]]
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

    if command -v nft >/dev/null 2>&1; then
        if ! nft list table ip socks_vps; then
            printf 'table ip socks_vps is not readable or is not loaded\n' >&2
        fi
    fi
}

choose_existing_action() {
    local choice

    printf 'Existing Socks-VPS installation detected.\n'
    printf '  1) Status\n'
    printf '  2) Update and preserve port and credentials\n'
    printf '  3) Reinstall with new port and credentials\n'
    printf '  4) Uninstall to a recoverable backup\n'
    printf '  5) Cancel\n'
    IFS= read -r -p 'Select: ' choice

    case ${choice} in
        1)
            show_status
            exit 0
            ;;
        2)
            selected_action=update
            selected_port_mode=preserve
            selected_port=0
            selected_username=
            selected_password=
            ;;
        3)
            selected_action=reinstall
            choose_port
            read_secret_pair
            ;;
        4)
            selected_action=uninstall
            selected_port_mode=preserve
            selected_port=0
            selected_username=
            selected_password=
            ;;
        5)
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
    local username=$5
    local password=$6

    if [[ ${EUID} -eq 0 ]]; then
        privileged_apply "${action}" "${mode}" "${port}" "${version}" "${username}" "${password}"
        return
    fi

    require_command sudo
    sudo -v </dev/tty
    printf '%s\0%s\0' "${username}" "${password}" |
        sudo -- "${script_dir}/install.sh" \
            --privileged-apply "${action}" "${mode}" "${port}" "${version}"
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
    local manager
    local need_nft=0
    local need_ss=0

    command -v nft >/dev/null 2>&1 || need_nft=1
    command -v ss >/dev/null 2>&1 || need_ss=1
    if ((need_nft == 0 && need_ss == 0)); then
        return
    fi

    manager=$(detect_package_manager)
    note "Installing required system packages with ${manager}"
    case ${manager} in
        apt)
            apt-get update
            apt-get install -y nftables iproute2 ca-certificates
            ;;
        dnf)
            dnf install -y nftables iproute ca-certificates
            ;;
        yum)
            yum install -y nftables iproute ca-certificates
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

current_service_owns_configured_listener() {
    local configured_port main_pid output ports

    "${public_binary}" self-check --config "${config_file}"
    configured_port=$("${public_binary}" config-port --config "${config_file}")
    is_single_port_value "${configured_port}" || return 1
    main_pid=$(systemctl show socks-vps.service --property=MainPID --value)
    [[ ${main_pid} =~ ^[1-9][0-9]*$ ]] || return 1
    output=$(ss -H -ltnp 2>/dev/null) || return 1
    ports=$(printf '%s\n' "${output}" | owned_wildcard_listener_ports "${main_pid}")
    [[ ${ports} == "${configured_port}" ]]
}

check_or_reselect_port() {
    local mode=$1
    local port=$2
    local allow_current_owner=${3:-false}
    local status

    if "${package_binary}" port-check --port "${port}" >/dev/null; then
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
    note 'Read-only coexistence check'
    if ! systemctl list-unit-files 'warp-vps*' --no-legend --no-pager; then
        printf 'Could not list WARP VPS Manager units.\n' >&2
    fi
    for unit in nftables.service firewalld.service ufw.service; do
        if systemctl is-active --quiet "${unit}"; then
            printf 'Detected active firewall service: %s\n' "${unit}"
        fi
    done
    printf '%s\n' 'IPv4 TCP listeners:'
    ss -H -ltnp
    printf '%s\n' 'Network interfaces:'
    ip -brief link
    printf '%s\n' 'IPv4 routes:'
    ip -4 route show
    printf '%s\n' 'IPv4 policy rules:'
    ip -4 rule show
    if command -v nft >/dev/null 2>&1; then
        if nft list table inet warp_vps >/dev/null 2>&1; then
            printf 'Detected external nftables table: inet warp_vps (unchanged)\n'
        fi
        nft list tables
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
    local action=$1
    local port_mode=$2
    local selected_port=$3
    local tables
    local table_state=absent
    local -a render_args

    if nft --json list table ip socks_vps >/dev/null 2>&1; then
        if [[ ${action} == install ]]; then
            die 'table ip socks_vps already exists; a fresh install cannot prove ownership'
        fi
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
        render_args+=(--config "${config_file}")
    else
        render_args+=(--port "${selected_port}")
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

    if nft list table ip socks_vps >/dev/null 2>&1; then
        die 'table ip socks_vps is still loaded'
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
    local passwd_entry group_entry account_group account_home account_shell
    local group_members all_groups

    if passwd_entry=$(getent passwd socks-vps); then
        IFS=: read -r _ _ _ _ _ account_home account_shell <<<"${passwd_entry}"
        group_entry=$(getent group socks-vps) || die 'socks-vps user exists without socks-vps group'
        IFS=: read -r _ _ _ group_members <<<"${group_entry}"
        account_group=$(id -gn socks-vps)
        all_groups=$(id -Gn socks-vps)
        [[ ${account_group} == socks-vps ]] || die 'existing socks-vps user has a different primary group'
        [[ ${all_groups} == socks-vps ]] ||
            die 'existing socks-vps user belongs to additional groups'
        [[ -z ${group_members} ]] ||
            die 'existing socks-vps group has supplemental members'
        [[ ${account_home} == /nonexistent ]] || die 'existing socks-vps user has an unexpected home'
        [[ ${account_shell} == */nologin || ${account_shell} == */false ]] ||
            die 'existing socks-vps user has an interactive shell'
        [[ -n ${group_entry} ]] || die 'existing socks-vps group is invalid'
        return 0
    fi

    if getent group socks-vps >/dev/null; then
        die 'socks-vps group already exists without the project user'
    fi
    return 1
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
    "${public_binary}" config-check --config "${config_file}"
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
    install -m 0640 -o root -g root "${config_file}" "${destination}/config.json"
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
    local port=$1
    local version=$2
    local username=$3
    local password=$4
    local attempt=$5
    local pending="${config_dir}/config.json.pending-${version}-${attempt}"

    [[ ! -e ${pending} ]] || die "pending configuration already exists: ${pending}"
    printf '%s\0%s\0' "${username}" "${password}" |
        "${package_binary}" config-create \
            --port "${port}" \
            --version "${version}" \
            --output "${pending}"
    chown root:socks-vps "${pending}"
    chmod 0640 "${pending}"
    mv -T "${pending}" "${config_file}"
}

create_preserved_config() {
    local version=$1
    local pending="${config_dir}/config.json.pending-${version}-preserve"

    [[ ! -e ${pending} ]] || die "pending configuration already exists: ${pending}"
    "${package_binary}" config-create \
        --preserve "${config_file}" \
        --version "${version}" \
        --output "${pending}"
    chown root:socks-vps "${pending}"
    chmod 0640 "${pending}"
    mv -T "${pending}" "${config_file}"
}

activate_release() {
    local release_dir=$1

    replace_symlink "${release_dir}" "${current_link}"
    replace_symlink "${current_link}/bin/socks-vps" "${public_binary}"
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
    nft --json list table ip socks_vps >/dev/null || return 1
    systemctl enable socks-vps.service
}

verify_started_port() {
    local port=$1

    "${public_binary}" self-check --config "${config_file}" || return 1
    [[ $("${public_binary}" config-port --config "${config_file}") == "${port}" ]] ||
        return 1
    current_service_owns_port "${port}" || return 1
    systemctl is-active --quiet socks-vps-firewall.service || return 1
    nft --json list table ip socks_vps >/dev/null
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
    local username=$3
    local password=$4
    local port=$5
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
            systemctl enable socks-vps.service
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
        create_new_config "${port}" "${version}" "${username}" "${password}" "${attempt}"
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
    local username=$5
    local password=$6
    local backup_dir=
    local release_dir
    local selected
    local allow_current_owner=false

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

    ensure_system_dependencies
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
        printf '%s\0%s\0' "${username}" "${password}" |
            "${package_binary}" config-create \
                --check \
                --port "${requested_port}" \
                --version "${version}"
    fi

    preflight_firewall "${action}" "${port_mode}" "${requested_port}"

    if [[ ${action} != install ]]; then
        stop_owned_services
        new_backup_dir "${action}"
        backup_dir=${created_backup_dir}
        backup_current_installation "${backup_dir}"
        enable_recovery_error "${backup_dir}"
        printf 'Socks-VPS snapshot saved to %s\n' "${backup_dir}"
        printf 'Recovery command: %s\n' \
            "$(print_recovery_command "${backup_dir}")"
    fi

    if [[ ${action} == install ]]; then
        create_account
    fi
    install -d -m 0755 -o root -g root "${install_root}" "${releases_dir}"
    install -d -m 0750 -o root -g socks-vps "${config_dir}"
    install_release_tree "${version}" "${action}"
    release_dir=${installed_release_dir}

    if [[ ${action} == update ]]; then
        create_preserved_config "${version}"
    else
        create_new_config "${requested_port}" "${version}" "${username}" "${password}" 0
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
        "${username}" \
        "${password}" \
        "${requested_port}"
    disable_recovery_error
}

uninstall_to_backup() {
    local backup_dir

    require_owned_installation
    validate_account || die 'Socks-VPS system account is missing'
    ensure_system_dependencies
    stop_owned_services
    "${public_binary}" port-check --config "${config_file}"
    if ! systemctl disable socks-vps.service; then
        die 'could not disable socks-vps.service'
    fi

    new_backup_dir uninstall
    backup_dir=${created_backup_dir}

    install -d -m 0700 -o root -g root "${backup_dir}/units"
    printf 'uninstall\n' >"${backup_dir}/kind"
    install -m 0755 -o root -g root \
        "${package_root}/scripts/install.sh" \
        "${backup_dir}/restore.sh"
    enable_recovery_error "${backup_dir}"
    mv "${config_dir}" "${backup_dir}/etc-socks-vps"
    mv "${install_root}" "${backup_dir}/usr-local-lib-socks-vps"
    mv "${public_binary}" "${backup_dir}/usr-local-bin-socks-vps"
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
    local version restored_target

    [[ -r ${backup_dir}/config.json ]] || die 'backup is missing config.json'
    [[ -r ${backup_dir}/socks-vps.service ]] || die 'backup is missing the main unit'
    [[ -r ${backup_dir}/socks-vps-firewall.service ]] || die 'backup is missing the firewall unit'
    [[ -r ${backup_dir}/VERSION ]] || die 'backup is missing VERSION'
    [[ -x ${backup_dir}/release/bin/socks-vps ]] ||
        die 'backup is missing the saved release binary'
    [[ -r ${backup_dir}/release/assets/ipdeny/cn-aggregated.zone ]] ||
        die 'backup is missing the saved firewall source data'
    IFS= read -r version <"${backup_dir}/VERSION" || die 'could not read backup VERSION'
    [[ $(<"${backup_dir}/release/VERSION") == "${version}" ]] ||
        die 'saved release VERSION does not match the backup'

    require_owned_installation
    validate_account || die 'Socks-VPS system account is missing'
    ensure_system_dependencies
    stop_owned_services

    restored_target="${releases_dir}/${version}-restored-$(date -u +%Y%m%dT%H%M%SZ)-$$"
    [[ ! -e ${restored_target} ]] ||
        die "restore release target already exists: ${restored_target}"
    cp -a "${backup_dir}/release" "${restored_target}"
    install -m 0640 -o root -g socks-vps "${backup_dir}/config.json" "${config_file}"
    install -m 0644 -o root -g root "${backup_dir}/socks-vps.service" "${main_unit}"
    install -m 0644 -o root -g root \
        "${backup_dir}/socks-vps-firewall.service" \
        "${firewall_unit}"
    replace_symlink "${restored_target}" "${current_link}"
    replace_symlink "${current_link}/bin/socks-vps" "${public_binary}"
    systemctl daemon-reload
    start_preserved_and_verify
}

restore_uninstall_backup() {
    local backup_dir=$1

    validate_restore_pair \
        "${backup_dir}/etc-socks-vps" "${config_dir}" directory
    validate_restore_pair \
        "${backup_dir}/usr-local-lib-socks-vps" "${install_root}" directory
    validate_restore_pair \
        "${backup_dir}/usr-local-bin-socks-vps" "${public_binary}" symlink
    validate_restore_pair \
        "${backup_dir}/units/socks-vps.service" "${main_unit}" file
    validate_restore_pair \
        "${backup_dir}/units/socks-vps-firewall.service" "${firewall_unit}" file
    validate_account || die 'Socks-VPS system account is missing'
    ensure_system_dependencies
    if systemctl is-active --quiet socks-vps.service ||
       systemctl is-active --quiet socks-vps-firewall.service; then
        die 'a Socks-VPS service is active while its owned files are absent'
    fi
    require_socks_table_absent

    restore_owned_path "${backup_dir}/etc-socks-vps" "${config_dir}"
    restore_owned_path "${backup_dir}/usr-local-lib-socks-vps" "${install_root}"
    restore_owned_path "${backup_dir}/usr-local-bin-socks-vps" "${public_binary}"
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

privileged_apply() {
    local action=$1
    local port_mode=$2
    local port=$3
    local version=$4
    local username=$5
    local password=$6

    require_root
    check_package "${version}"

    case ${action} in
        install | update | reinstall)
            install_or_replace \
                "${action}" \
                "${port_mode}" \
                "${port}" \
                "${version}" \
                "${username}" \
                "${password}"
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
    local username password

    require_root
    IFS= read -r -d '' username || die 'privileged input is missing username'
    IFS= read -r -d '' password || die 'privileged input is missing password'
    privileged_apply "${action}" "${port_mode}" "${port}" "${version}" "${username}" "${password}"
}

interactive_main() {
    local version

    version=$(read_package_version)
    check_package "${version}"

    if installation_exists; then
        choose_existing_action
    else
        selected_action=install
        choose_port
        read_secret_pair
    fi

    if [[ ${selected_action} == install || ${selected_action} == reinstall ]]; then
        check_new_config_without_write \
            "${selected_port}" \
            "${version}" \
            "${selected_username}" \
            "${selected_password}"
    fi

    print_impact "${selected_action}" "${version}"
    confirm_action
    run_privileged \
        "${selected_action}" \
        "${selected_port_mode}" \
        "${selected_port}" \
        "${version}" \
        "${selected_username}" \
        "${selected_password}"
}

main() {
    case ${1:-} in
        '')
            interactive_main
            ;;
        --privileged-apply)
            [[ $# -eq 5 ]] || die 'invalid privileged invocation'
            privileged_entry "$2" "$3" "$4" "$5"
            ;;
        --restore)
            [[ $# -eq 2 ]] || die 'usage: install.sh --restore BACKUP_DIR'
            require_root
            restore_backup "$2"
            ;;
        --status)
            [[ $# -eq 1 ]] || die 'usage: install.sh --status'
            show_status
            ;;
        *)
            die 'usage: install.sh [--status|--restore BACKUP_DIR]'
            ;;
    esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
