#!/usr/bin/env bash

set -Eeuo pipefail

readonly test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly project_root=$(cd -- "${test_dir}/../.." && pwd -P)
readonly main_unit="${project_root}/packaging/systemd/socks-vps.service"
readonly firewall_unit="${project_root}/packaging/systemd/socks-vps-firewall.service"

fail() {
    printf 'contracts_test: %s\n' "$*" >&2
    exit 1
}

grep -Fxq 'Requires=socks-vps-firewall.service' "${main_unit}" ||
    fail 'main service does not require the firewall service'
grep -Fxq 'After=network-online.target socks-vps-firewall.service' "${main_unit}" ||
    fail 'main service is not ordered after the firewall'
grep -Fxq 'PartOf=socks-vps.service' "${firewall_unit}" ||
    fail 'stopping or restarting the main service will not propagate to the firewall'
grep -Fxq 'BindsTo=socks-vps.service' "${firewall_unit}" ||
    fail 'unexpected main-service loss will leave the firewall active'
grep -Fxq 'After=nftables.service firewalld.service ufw.service' "${firewall_unit}" ||
    fail 'firewall service ordering is incomplete'
grep -Fxq 'RestartPreventExitStatus=64 78' "${main_unit}" ||
    fail 'configuration and bind failures are not excluded from restart'
if grep -Fq 'ExecStartPre=' "${main_unit}"; then
    fail 'main unit has a pre-start failure outside RestartPreventExitStatus'
fi
grep -Fq '"${package_root}/MANIFEST.sha256"' "${project_root}/scripts/install.sh" ||
    fail 'installed release tree omits its manifest'
grep -Fq 'nft --check --file -' "${project_root}/scripts/install.sh" ||
    fail 'installer does not preflight the complete nftables batch'
grep -Fq '"${public_binary}" config-port --config "${config_file}"' \
    "${project_root}/scripts/install.sh" ||
    fail 'listener ownership is not compared with the authoritative config port'
grep -Fq 'systemctl stop socks-vps.service' "${project_root}/scripts/install.sh" ||
    fail 'lifecycle does not explicitly stop the main service'
grep -Fq 'systemctl stop socks-vps-firewall.service' "${project_root}/scripts/install.sh" ||
    fail 'lifecycle does not explicitly stop the firewall service'
grep -Fq "printf 'snapshot" \
    "${project_root}/scripts/install.sh" ||
    fail 'update backup has no explicit kind marker'
grep -Fq 'cp -a "${current_target}" "${destination}/release"' \
    "${project_root}/scripts/install.sh" ||
    fail 'update backup does not preserve the complete release tree'
grep -Fq "printf 'uninstall" \
    "${project_root}/scripts/install.sh" ||
    fail 'uninstall backup has no explicit kind marker'
grep -Fq '"${backup_dir}/restore.sh"' "${project_root}/scripts/install.sh" ||
    fail 'backup does not preserve an independent restore entry'
grep -Fq 'go run ./cmd/socks-vps firewall-render' \
    "${project_root}/scripts/update-ipdeny.sh" ||
    fail 'IPdeny maintenance does not render staged nftables rules'
grep -Fq 'nft --check --file "${stage}/socks-vps.nft"' \
    "${project_root}/scripts/update-ipdeny.sh" ||
    fail 'IPdeny maintenance does not syntax-check staged nftables rules when available'
grep -Fq 'go mod verify' "${project_root}/scripts/build-release.sh" ||
    fail 'release build does not verify downloaded Go modules'
grep -Fq 'go test -mod=readonly ./...' "${project_root}/scripts/build-release.sh" ||
    fail 'release build does not run locked tests before creating dist'
grep -Fq 'packaged binary does not match a locked rebuild' \
    "${project_root}/scripts/check-release.sh" ||
    fail 'release validation does not bind the binary to the current source'

if grep -R -E '(^|[;&|[:space:]])(rm|rmdir)([[:space:]]|$)' \
    "${project_root}/scripts" \
    "${project_root}/packaging/systemd"; then
    fail 'permanent deletion command found'
fi

if grep -R -E 'systemctl[[:space:]]+(stop|disable|restart)[[:space:]]+warp-vps|nft[[:space:]].*(delete|flush).*(warp_vps|warp-vps)' \
    "${project_root}/scripts" \
    "${project_root}/packaging/systemd"; then
    fail 'WARP VPS Manager mutation found'
fi

if grep -R -F 'ipdeny.com' \
    "${project_root}/scripts/bootstrap.sh" \
    "${project_root}/scripts/install.sh" \
    "${project_root}/scripts/firewall.sh"; then
    fail 'runtime installation path downloads or contacts IPdeny'
fi

if grep -R -F -- '--expect-owned-by-service' \
    "${project_root}/scripts" \
    "${project_root}/packaging/systemd"; then
    fail 'installer calls an unsupported port-check option'
fi

printf 'Static lifecycle contracts passed\n'
