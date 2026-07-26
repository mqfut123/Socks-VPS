#!/usr/bin/env bash

set -Eeuo pipefail

readonly test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly project_root=$(cd -- "${test_dir}/../.." && pwd -P)

# shellcheck source=../../scripts/install.sh
source "${project_root}/scripts/install.sh"

fixture=$(
    printf '%s\n' \
        'LISTEN 0 4096 0.0.0.0:1080 0.0.0.0:* users:(("socks-vps",pid=42,fd=3))' \
        'LISTEN 0 4096 [::]:1080 [::]:* users:(("socks-vps",pid=42,fd=4))' \
        'LISTEN 0 4096 0.0.0.0:2080 0.0.0.0:* users:(("other",pid=99,fd=3))'
)
ports=$(printf '%s\n' "${fixture}" | owned_wildcard_listener_ports 42)
[[ ${ports} == 1080 ]] || {
    printf 'listener_parser_test: parsed %q, want 1080\n' "${ports}" >&2
    exit 1
}
is_single_port_value "${ports}" || {
    printf 'listener_parser_test: one listener was not accepted\n' >&2
    exit 1
}

fixture+=$'\nLISTEN 0 4096 0.0.0.0:1081 0.0.0.0:* users:(("socks-vps",pid=42,fd=5))'
ports=$(printf '%s\n' "${fixture}" | owned_wildcard_listener_ports 42)
if is_single_port_value "${ports}"; then
    printf 'listener_parser_test: multiple listeners were accepted: %q\n' "${ports}" >&2
    exit 1
fi

printf 'Listener ownership parser passed\n'
