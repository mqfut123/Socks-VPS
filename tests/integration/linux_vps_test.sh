#!/usr/bin/env bash

set +x
set -Eeuo pipefail

readonly test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly project_root=$(cd -- "${test_dir}/../.." && pwd -P)

readonly config_dir=/etc/socks-vps
readonly config_file="${config_dir}/config.json"
readonly install_root=/usr/local/lib/socks-vps
readonly public_binary=/usr/local/bin/socks-vps
readonly main_unit=/etc/systemd/system/socks-vps.service
readonly firewall_unit=/etc/systemd/system/socks-vps-firewall.service
readonly backup_root=/var/backups/socks-vps

readonly netns_name="svpsit$$"
readonly host_link="svh$$"
readonly peer_link="svp$$"
readonly test_host=198.18.255.1
readonly non_cn_source=192.0.2.2

netns_created=false
veth_created=false
last_uninstall_backup=
last_update_backup=
verified_port=
install_package=
update_package=

die() {
    printf 'linux_vps_test: %s\n' "$*" >&2
    exit 1
}

note() {
    printf '==> %s\n' "$*"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 ||
        die "required command is unavailable: $1"
}

cleanup_network_resources() {
    local failed=false

    if [[ ${netns_created} == true ]] &&
       ip netns list | awk '{print $1}' | grep -Fxq "${netns_name}"; then
        if ! ip netns delete "${netns_name}"; then
            failed=true
        fi
    fi
    if [[ ${veth_created} == true ]] && ip link show "${host_link}" >/dev/null 2>&1; then
        if ! ip link delete "${host_link}"; then
            failed=true
        fi
    fi
    netns_created=false
    veth_created=false
    [[ ${failed} == false ]]
}

cleanup_on_exit() {
    local status=$?

    trap - EXIT
    if ! cleanup_network_resources && ((status == 0)); then
        status=1
    fi
    exit "${status}"
}

assert_fresh_host() {
    local path
    local -a owned_paths=(
        "${config_dir}"
        "${install_root}"
        "${public_binary}"
        "${main_unit}"
        "${firewall_unit}"
    )

    for path in "${owned_paths[@]}"; do
        [[ ! -e ${path} && ! -L ${path} ]] ||
            die "disposable host is not fresh; Socks-VPS path exists: ${path}"
    done
    ! systemctl is-active --quiet socks-vps.service ||
        die 'socks-vps.service is already active'
    ! systemctl is-active --quiet socks-vps-firewall.service ||
        die 'socks-vps-firewall.service is already active'
    if nft list table ip socks_vps >/dev/null 2>&1; then
        die 'table ip socks_vps already exists'
    fi
    if nft list tables | grep -Eq '^[[:space:]]*table ip socks_vps[[:space:]]*$'; then
        die 'table ip socks_vps exists but could not be inspected'
    fi
    if ip netns list | awk '{print $1}' | grep -Fxq "${netns_name}"; then
        die "test network namespace already exists: ${netns_name}"
    fi
    if ip link show "${host_link}" >/dev/null 2>&1; then
        die "test network link already exists: ${host_link}"
    fi
    ! getent passwd socks-vps >/dev/null ||
        die 'disposable host already has a socks-vps user'
    ! getent group socks-vps >/dev/null ||
        die 'disposable host already has a socks-vps group'
}

sha256_stream() {
    sha256sum | awk '{print $1}'
}

warp_table_state() {
    local state_var=$1
    local digest_var=$2
    local tables digest

    if nft --json --stateless list table inet warp_vps >/dev/null 2>&1; then
        digest=$(nft --json --stateless list table inet warp_vps | sha256_stream)
        printf -v "${state_var}" '%s' present
        printf -v "${digest_var}" '%s' "${digest}"
        return
    fi
    tables=$(nft list tables) || die 'could not inspect nftables tables'
    if grep -Eq '^[[:space:]]*table inet warp_vps[[:space:]]*$' <<<"${tables}"; then
        die 'table inet warp_vps exists but a stateless snapshot could not be read'
    fi
    printf -v "${state_var}" '%s' absent
    printf -v "${digest_var}" '%s' absent
}

assert_warp_table_unchanged() {
    local before_state=$1
    local before_digest=$2
    local after_state after_digest

    warp_table_state after_state after_digest
    [[ ${after_state} == "${before_state}" ]] ||
        die "table inet warp_vps presence changed: ${before_state} -> ${after_state}"
    [[ ${after_digest} == "${before_digest}" ]] ||
        die 'table inet warp_vps stateless ruleset changed'
}

archive_root_name() {
    local archive=$1
    local name

    name=$(basename "${archive}")
    [[ ${name} =~ ^(socks-vps-v.+-linux-(amd64|arm64))\.tar\.gz$ ]] ||
        die "invalid release archive name: ${name}"
    printf '%s\n' "${BASH_REMATCH[1]}"
}

extract_release() {
    local archive=$1
    local work_dir=$2
    local root_name

    root_name=$(archive_root_name "${archive}")
    tar -xzf "${archive}" -C "${work_dir}"
    [[ -x ${work_dir}/${root_name}/scripts/install.sh ]] ||
        die "extracted release has no executable installer: ${root_name}"
    [[ -x ${work_dir}/${root_name}/bin/socks-vps ]] ||
        die "extracted release has no executable binary: ${root_name}"
    printf '%s\n' "${work_dir}/${root_name}"
}

credential_digest() {
    local count

    count=$(sed -n \
        -e '/^[[:space:]]*"username":[[:space:]]/p' \
        -e '/^[[:space:]]*"password":[[:space:]]/p' \
        "${config_file}" |
        wc -l |
        tr -d '[:space:]')
    [[ ${count} == 2 ]] || die 'could not identify both credential fields in config.json'
    sed -n \
        -e '/^[[:space:]]*"username":[[:space:]]/p' \
        -e '/^[[:space:]]*"password":[[:space:]]/p' \
        "${config_file}" |
        sha256_stream
}

assert_runtime() {
    local expected_port=${1:-}
    local expected_version=${2:-}
    local port pid listeners config_metadata release_version config_version

    systemctl is-active --quiet socks-vps-firewall.service ||
        die 'socks-vps-firewall.service is not active'
    systemctl is-active --quiet socks-vps.service ||
        die 'socks-vps.service is not active'
    [[ -x ${public_binary} ]] || die "missing installed binary: ${public_binary}"
    [[ -r ${config_file} ]] || die "missing installed configuration: ${config_file}"

    port=$("${public_binary}" config-port --config "${config_file}")
    [[ ${port} =~ ^[0-9]+$ ]] || die "configured port is invalid: ${port}"
    if [[ -n ${expected_port} && ${port} != "${expected_port}" ]]; then
        die "configured port changed: ${expected_port} -> ${port}"
    fi
    pid=$(systemctl show socks-vps.service --property=MainPID --value)
    [[ ${pid} =~ ^[1-9][0-9]*$ ]] || die "invalid socks-vps.service MainPID: ${pid}"
    listeners=$(ss -H -ltnp "sport = :${port}") ||
        die "could not inspect configured listener port ${port}"
    grep -Fq "0.0.0.0:${port}" <<<"${listeners}" ||
        die "configured port ${port} is not listening on IPv4 wildcard"
    grep -Eq "pid=${pid}[,)]" <<<"${listeners}" ||
        die "socks-vps.service PID ${pid} does not own TCP port ${port}"
    if ss -H -ltnp6 | grep -Eq "pid=${pid}[,)]"; then
        die "socks-vps.service PID ${pid} owns an IPv6 listener"
    fi

    config_metadata=$(stat -c '%a %U %G' "${config_file}")
    [[ ${config_metadata} == '640 root socks-vps' ]] ||
        die "config metadata is ${config_metadata}, want 640 root socks-vps"
    release_version=$(<"${install_root}/current/VERSION")
    config_version=$(sed -n \
        's/^[[:space:]]*"version":[[:space:]]*"\([^"]*\)"[[:space:]]*$/\1/p' \
        "${config_file}")
    [[ -n ${config_version} && ${config_version} != *$'\n'* ]] ||
        die 'could not read one installed version from config.json'
    [[ ${config_version} == "${release_version}" ]] ||
        die "config version ${config_version} does not match release ${release_version}"
    if [[ -n ${expected_version} && ${release_version} != "${expected_version}" ]]; then
        die "active release is ${release_version}, want ${expected_version}"
    fi
    "${public_binary}" self-check --config "${config_file}"
    nft --json list table ip socks_vps >/dev/null ||
        die 'table ip socks_vps is not loaded'
    nft list chain ip socks_vps input |
        grep -Fq "tcp dport ${port}" ||
        die "nftables input chain does not match configured port ${port}"
    verified_port=${port}
}

assert_stopped_and_backed_up() {
    local port=$1

    ! systemctl is-active --quiet socks-vps.service ||
        die 'socks-vps.service remained active after uninstall'
    ! systemctl is-active --quiet socks-vps-firewall.service ||
        die 'socks-vps-firewall.service remained active after uninstall'
    if nft list table ip socks_vps >/dev/null 2>&1; then
        die 'table ip socks_vps remained after uninstall'
    fi
    [[ ! -e ${config_dir} && ! -L ${config_dir} ]] ||
        die "${config_dir} remained after uninstall"
    [[ ! -e ${install_root} && ! -L ${install_root} ]] ||
        die "${install_root} remained after uninstall"
    [[ ! -e ${public_binary} && ! -L ${public_binary} ]] ||
        die "${public_binary} remained after uninstall"
    [[ ! -e ${main_unit} && ! -L ${main_unit} ]] ||
        die "${main_unit} remained after uninstall"
    [[ ! -e ${firewall_unit} && ! -L ${firewall_unit} ]] ||
        die "${firewall_unit} remained after uninstall"
    "${update_package}/bin/socks-vps" port-check --port "${port}" >/dev/null ||
        die "TCP port ${port} was not released after uninstall"
}

run_uninstall() {
    local package=$1
    local version=$2
    local output backup

    if ! output=$(
        printf '\0\0' |
            "${package}/scripts/install.sh" \
                --privileged-apply uninstall preserve 0 "${version}"
    ); then
        printf '%s\n' "${output}" >&2
        die 'uninstall failed'
    fi
    printf '%s\n' "${output}"
    backup=$(sed -n \
        's|^Socks-VPS was stopped and moved to \(/var/backups/socks-vps/.*\)$|\1|p' \
        <<<"${output}")
    [[ -n ${backup} && ${backup} != *$'\n'* && -d ${backup} ]] ||
        die 'uninstall did not report one valid recoverable backup'
    last_uninstall_backup=${backup}
}

run_update() {
    local package=$1
    local version=$2
    local output backup

    if ! output=$(
        printf '\0\0' |
            "${package}/scripts/install.sh" \
                --privileged-apply update preserve 0 "${version}"
    ); then
        printf '%s\n' "${output}" >&2
        die 'update failed'
    fi
    printf '%s\n' "${output}"
    backup=$(sed -n \
        's|^Socks-VPS snapshot saved to \(/var/backups/socks-vps/.*\)$|\1|p' \
        <<<"${output}")
    [[ -n ${backup} && ${backup} != *$'\n'* && -d ${backup} ]] ||
        die 'update did not report one valid recovery snapshot'
    [[ -x ${backup}/restore.sh ]] ||
        die "update snapshot has no independent restore entry: ${backup}/restore.sh"
    last_update_backup=${backup}
}

drop_packet_count() {
    local port=$1

    nft list chain ip socks_vps input |
        awk -v port="${port}" '
            index($0, "tcp dport " port) && /counter packets/ && !found {
                for (field = 1; field <= NF; field++) {
                    if ($field == "packets" && $(field + 1) ~ /^[0-9]+$/) {
                        packets = $(field + 1)
                        found = 1
                    }
                }
            }
            END {
                if (found) {
                    print packets
                }
            }
        '
}

select_cn_source() {
    local zone=$1

    awk -F '[./]' '
        NF == 5 && $5 <= 30 && $4 <= 253 {
            printf "%s.%s.%s.%d\n", $1, $2, $3, $4 + 1
            exit
        }
    ' "${zone}"
}

exercise_source_firewall() {
    local port=$1
    local zone="${install_root}/current/assets/ipdeny/cn-aggregated.zone"
    local cn_source route output status before after

    cn_source=$(select_cn_source "${zone}")
    [[ ${cn_source} =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
        die 'could not select a synthetic source from the bundled CN zone'
    nft get element ip socks_vps cn_ipv4 "{ ${cn_source} }" >/dev/null ||
        die "selected CN test source is not present in nftables set: ${cn_source}"
    if nft get element ip socks_vps cn_ipv4 "{ ${non_cn_source} }" >/dev/null 2>&1; then
        die "synthetic non-CN source unexpectedly belongs to cn_ipv4: ${non_cn_source}"
    fi
    [[ -z $(ip -4 route show exact "${cn_source}/32") ]] ||
        die "host already has an exact route for CN test source ${cn_source}"
    [[ -z $(ip -4 route show exact "${non_cn_source}/32") ]] ||
        die "host already has an exact route for non-CN test source ${non_cn_source}"

    note "Creating isolated namespace ${netns_name}; this is rule simulation, not real CN/GFW acceptance"
    ip netns add "${netns_name}"
    netns_created=true
    ip link add "${host_link}" type veth peer name "${peer_link}"
    veth_created=true
    ip link set "${peer_link}" netns "${netns_name}"
    ip address add "${test_host}/32" dev "${host_link}"
    ip link set "${host_link}" up
    ip -n "${netns_name}" link set lo up
    ip -n "${netns_name}" address add "${cn_source}/32" dev "${peer_link}"
    ip -n "${netns_name}" address add "${non_cn_source}/32" dev "${peer_link}"
    ip -n "${netns_name}" link set "${peer_link}" up
    ip route add "${cn_source}/32" dev "${host_link}"
    ip route add "${non_cn_source}/32" dev "${host_link}"
    ip -n "${netns_name}" route add \
        "${test_host}/32" dev "${peer_link}" src "${cn_source}"
    route=$(ip -n "${netns_name}" route get "${test_host}")
    grep -Fq "src ${cn_source}" <<<"${route}" ||
        die "namespace route did not select CN source ${cn_source}"

    before=$(drop_packet_count "${port}")
    [[ ${before} =~ ^[0-9]+$ ]] || die 'could not read nftables drop counter'
    if ip netns exec "${netns_name}" \
        env SOCKS_TEST_HOST="${test_host}" SOCKS_TEST_PORT="${port}" \
        timeout 3 bash -c \
        'exec 3<>/dev/tcp/${SOCKS_TEST_HOST}/${SOCKS_TEST_PORT}'; then
        die 'synthetic CN source completed a TCP handshake'
    else
        status=$?
    fi
    [[ ${status} == 124 ]] ||
        die "synthetic CN probe failed with ${status}, want timeout exit 124"
    after=$(drop_packet_count "${port}")
    [[ ${after} =~ ^[0-9]+$ && ${after} -gt ${before} ]] ||
        die "CN drop counter did not increase: ${before} -> ${after}"
    systemctl is-active --quiet socks-vps.service ||
        die 'main service stopped during the CN source probe'

    ip -n "${netns_name}" route replace \
        "${test_host}/32" dev "${peer_link}" src "${non_cn_source}"
    route=$(ip -n "${netns_name}" route get "${test_host}")
    grep -Fq "src ${non_cn_source}" <<<"${route}" ||
        die "namespace route did not select non-CN source ${non_cn_source}"
    if ! output=$(
        ip netns exec "${netns_name}" \
            env SOCKS_TEST_HOST="${test_host}" SOCKS_TEST_PORT="${port}" \
            timeout 5 bash -c '
                exec 3<>/dev/tcp/${SOCKS_TEST_HOST}/${SOCKS_TEST_PORT}
                printf "\005\001\002" >&3
                dd bs=1 count=2 <&3 2>/dev/null
            ' |
            od -An -tx1 |
            tr -d '[:space:]'
    ); then
        die 'synthetic non-CN source did not reach SOCKS authentication'
    fi
    [[ ${output} == 0502 ]] ||
        die "non-CN SOCKS method reply is ${output}, want 0502"

    cleanup_network_resources ||
        die 'could not remove the synthetic test network namespace'
}

main() {
    local install_archive=${1:-}
    local update_archive=${2:-}
    local work_dir install_version update_version candidate
    local credentials_before credentials_after
    local warp_before_state warp_before_digest
    local installed_port update_backup first_uninstall_backup

    [[ ${SOCKS_VPS_DISPOSABLE_TEST:-} == 1 ]] ||
        die 'set SOCKS_VPS_DISPOSABLE_TEST=1 only on a disposable Linux VPS'
    [[ ${EUID} -eq 0 ]] || die 'root is required'
    [[ $(uname -s) == Linux ]] || die 'Linux is required'
    [[ $# -eq 2 && -f ${install_archive} && -f ${update_archive} ]] ||
        die 'usage: linux_vps_test.sh INSTALL_ARCHIVE UPDATE_ARCHIVE'
    [[ ${install_archive} != "${update_archive}" ]] ||
        die 'two local release archives with different versions are required for update testing'

    for command in \
        awk \
        bash \
        dd \
        file \
        getent \
        go \
        grep \
        ip \
        nft \
        od \
        sed \
        sha256sum \
        ss \
        stat \
        systemctl \
        tar \
        timeout \
        tr; do
        require_command "${command}"
    done
    [[ -d /run/systemd/system ]] || die 'systemd is not running'

    install_archive=$(readlink -f "${install_archive}")
    update_archive=$(readlink -f "${update_archive}")
    assert_fresh_host
    warp_table_state warp_before_state warp_before_digest

    note 'Validating both local release packages against this source tree'
    "${project_root}/scripts/check-release.sh" "${install_archive}" "${project_root}"
    "${project_root}/scripts/check-release.sh" "${update_archive}" "${project_root}"
    work_dir=$(mktemp -d /var/tmp/socks-vps-integration.XXXXXXXX)
    install_package=$(extract_release "${install_archive}" "${work_dir}")
    update_package=$(extract_release "${update_archive}" "${work_dir}")
    install_version=$(<"${install_package}/VERSION")
    update_version=$(<"${update_package}/VERSION")
    [[ ${install_version} != "${update_version}" ]] ||
        die "install and update package versions are both ${install_version}"

    printf 'This gated test will modify only a disposable host:\n'
    printf '  %s\n' \
        "${config_dir}" \
        "${install_root}" \
        "${public_binary}" \
        "${main_unit}" \
        "${firewall_unit}" \
        'systemd units socks-vps.service and socks-vps-firewall.service' \
        'nftables table ip socks_vps' \
        "temporary network namespace ${netns_name} and veth pair" \
        "recoverable backups under ${backup_root}"
    if systemctl is-active --quiet firewalld.service; then
        require_command firewall-cmd
        printf '  one active firewalld reload\n'
    fi
    printf 'Test extraction is retained at %s for evidence.\n' "${work_dir}"

    trap cleanup_on_exit EXIT

    candidate=$("${install_package}/bin/socks-vps" port-select)
    note "Fresh automatic-port install of ${install_version}"
    printf '%s\0%s\0' \
        "socks-vps-it-$$" \
        "SocksVpsIt-$$-Password" |
        "${install_package}/scripts/install.sh" \
            --privileged-apply install automatic "${candidate}" "${install_version}"
    assert_runtime '' "${install_version}"
    installed_port=${verified_port}
    credentials_before=$(credential_digest)

    note 'Applying the owned firewall batch twice'
    systemctl reload socks-vps-firewall.service
    systemctl reload socks-vps-firewall.service
    assert_runtime "${installed_port}" "${install_version}"

    exercise_source_firewall "${installed_port}"

    if systemctl is-active --quiet firewalld.service; then
        note 'Reloading active firewalld and verifying the independent table'
        firewall-cmd --reload
        nft --json list table ip socks_vps >/dev/null ||
            die 'firewalld reload removed table ip socks_vps'
        assert_runtime "${installed_port}" "${install_version}"
    fi

    note "Updating to ${update_version} while preserving port and credentials"
    run_update "${update_package}" "${update_version}"
    update_backup=${last_update_backup}
    assert_runtime "${installed_port}" "${update_version}"
    credentials_after=$(credential_digest)
    [[ ${credentials_after} == "${credentials_before}" ]] ||
        die 'credentials changed during update'

    note "Restoring the pre-update snapshot ${update_backup}"
    "${update_backup}/restore.sh" --restore "${update_backup}"
    assert_runtime "${installed_port}" "${install_version}"
    credentials_after=$(credential_digest)
    [[ ${credentials_after} == "${credentials_before}" ]] ||
        die 'credentials changed during update snapshot restore'

    note 'Uninstalling to a recoverable backup'
    run_uninstall "${install_package}" "${install_version}"
    first_uninstall_backup=${last_uninstall_backup}
    assert_stopped_and_backed_up "${installed_port}"

    note "Restoring the uninstall backup ${first_uninstall_backup}"
    "${first_uninstall_backup}/restore.sh" --restore "${first_uninstall_backup}"
    assert_runtime "${installed_port}" "${install_version}"
    credentials_after=$(credential_digest)
    [[ ${credentials_after} == "${credentials_before}" ]] ||
        die 'credentials changed during uninstall restore'

    note 'Performing the final uninstall'
    run_uninstall "${install_package}" "${install_version}"
    assert_stopped_and_backed_up "${installed_port}"
    assert_warp_table_unchanged "${warp_before_state}" "${warp_before_digest}"

    printf 'Linux VPS lifecycle harness passed.\n'
    printf 'Network namespace checks were synthetic rule tests, not real CN/GFW acceptance.\n'
    printf 'Pre-update recovery snapshot: %s\n' "${update_backup}"
    printf 'First recoverable uninstall backup: %s\n' "${first_uninstall_backup}"
    printf 'Final recoverable uninstall backup: %s\n' "${last_uninstall_backup}"
    printf 'Retained test evidence: %s\n' "${work_dir}"
}

main "$@"
