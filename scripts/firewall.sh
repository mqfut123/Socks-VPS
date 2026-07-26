#!/usr/bin/env bash

set +x
set -Eeuo pipefail

readonly binary=/usr/local/bin/socks-vps
readonly config=/etc/socks-vps/config.json
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
    local action=$1

    [[ -x ${binary} ]] || die "missing executable: ${binary}"
    command -v nft >/dev/null 2>&1 || die 'nft command is unavailable'
    if [[ ${action} == apply ]]; then
        [[ -r ${config} ]] || die "missing configuration: ${config}"
        [[ -r ${zone} ]] || die "missing IPdeny zone: ${zone}"
    fi
    install -d -m 0750 -o root -g root "${runtime_dir}"
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

apply_rules() {
    local table_state
    local -a render_args

    "${binary}" config-check --config "${config}"
    table_state=$(capture_existing_table)

    render_args=(
        firewall-render
        --config "${config}"
        --zone "${zone}"
        --output "${rules_file}"
    )
    if [[ ${table_state} == present ]]; then
        render_args+=(--existing-table-json "${existing_json}")
    fi

    "${binary}" "${render_args[@]}"
    nft --check --file "${rules_file}"
    nft --file "${rules_file}"
    nft --json list table ip socks_vps >"${existing_json}"
}

remove_rules() {
    local table_state

    table_state=$(capture_existing_table)
    if [[ ${table_state} == absent ]]; then
        return 0
    fi

    "${binary}" firewall-render \
        --remove \
        --existing-table-json "${existing_json}" \
        --output "${remove_file}"
    nft --check --file "${remove_file}"
    nft --file "${remove_file}"

    if nft list table ip socks_vps >/dev/null 2>&1; then
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

    case ${1:-} in
        apply)
            require_runtime apply
            apply_rules
            ;;
        reload)
            reload_rules
            ;;
        remove)
            require_runtime remove
            remove_rules
            ;;
        *)
            die 'usage: firewall.sh {apply|reload|remove}'
            ;;
    esac
}

main "$@"
