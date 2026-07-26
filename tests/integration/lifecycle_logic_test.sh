#!/usr/bin/env bash

set -Eeuo pipefail

readonly test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly project_root=$(cd -- "${test_dir}/../.." && pwd -P)

# shellcheck source=../../scripts/install.sh
source "${project_root}/scripts/install.sh"

fail() {
    printf 'lifecycle_logic_test: %s\n' "$*" >&2
    exit 1
}

[[ $(start_attempt_decision automatic 0 0 0) == success ]] ||
    fail 'successful start attempt was not accepted'
[[ $(start_attempt_decision automatic 0 1 78) == retry ]] ||
    fail 'Type=simple bind race was not classified for automatic retry'
[[ $(start_attempt_decision manual 0 1 78) == fail ]] ||
    fail 'manual port was changed after a bind race'
[[ $(start_attempt_decision automatic 1 1 1) == fail ]] ||
    fail 'non-bind startup failure was retried'

recovery_dir=/var/backups/socks-vps/test-recovery
expected_command="sudo ${recovery_dir}/restore.sh --restore ${recovery_dir}"

if output=$(
    (
        active_recovery_dir=${recovery_dir}
        die 'simulated guarded failure'
    ) 2>&1
); then
    fail 'die simulation unexpectedly succeeded'
fi
[[ ${output} == *"Restore with: ${expected_command}"* ]] ||
    fail 'die did not print the executable recovery command'

if output=$(
    (
        enable_recovery_error "${recovery_dir}"
        false
        printf 'unexpected continuation\n'
    ) 2>&1
); then
    fail 'ERR trap simulation unexpectedly succeeded'
fi
[[ ${output} == *'Socks-VPS change failed with exit status 1.'* ]] ||
    fail 'ERR trap did not report the failing status'
[[ ${output} == *"Restore with: ${expected_command}"* ]] ||
    fail 'ERR trap did not print the executable recovery command'

printf 'Lifecycle decision and recovery hints passed\n'
