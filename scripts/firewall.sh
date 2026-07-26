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

die() {
    printf 'socks-vps-firewall: %s\n' "$*" >&2
    exit 1
}

require_root() {
    [[ ${EUID} -eq 0 ]] || die 'must run as root'
}

require_runtime() {
    [[ -x ${binary} ]] || die "missing executable: ${binary}"
    [[ -d ${config_dir} ]] || die "missing configuration directory: ${config_dir}"
    install -d -m 0750 -o root -g root "${runtime_dir}"
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
        die 'could not inspect nftables tables'
    fi
    if grep -Eq '^[[:space:]]*table ip socks_vps[[:space:]]*$' "${tables_file}"; then
        cat "${stderr_file}" >&2
        die 'could not inspect the existing table ip socks_vps'
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
        [[ -r ${zone} ]] || die "missing IPdeny zone: ${zone}"
        render_args+=(--zone "${zone}")
    fi
    if [[ ${table_state} == present ]]; then
        render_args+=(--existing-table-json "${existing_json}")
    fi

    "${binary}" "${render_args[@]}"
}

render_remove_batch() {
    local blocked_ports=$1

    if [[ -n ${blocked_ports} ]]; then
        "${binary}" firewall-render \
            --remove \
            --existing-table-json "${existing_json}" \
            --output "${remove_file}"
        return
    fi

    "${binary}" firewall-render \
        --config-dir "${config_dir}" \
        --existing-table-json "${existing_json}" \
        --output "${remove_file}"
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
        die 'nft command is unavailable while one or more ports block CN sources'
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
        die 'owned nftables table still exists after CN blocking was disabled'
    fi
}

remove_rules() {
    local blocked_ports table_state

    blocked_ports=$(blocked_cn_ports)
    if ! nft_available; then
        [[ -z ${blocked_ports} ]] && return 0
        die 'nft command is unavailable while one or more ports block CN sources'
    fi

    table_state=$(capture_existing_table)
    if [[ ${table_state} == absent ]]; then
        return 0
    fi

    render_remove_batch "${blocked_ports}"
    if ! batch_has_commands "${remove_file}"; then
        return 0
    fi
    apply_batch "${remove_file}"

    if ! owned_table_is_absent; then
        die 'owned nftables table still exists after removal'
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
        die 'rule reload failed and the main service could not be queued for stop'
    fi
    printf 'socks-vps-firewall: rule reload failed; main service stop queued\n' >&2
    return "${status}"
}

main() {
    require_root
    require_runtime

    case ${1:-} in
        apply)
            apply_rules
            ;;
        reload)
            reload_rules
            ;;
        remove)
            remove_rules
            ;;
        *)
            die 'usage: firewall.sh {apply|reload|remove}'
            ;;
    esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
