#!/usr/bin/env bash

set -Eeuo pipefail

readonly test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly project_root=$(cd -- "${test_dir}/../.." && pwd -P)

# shellcheck source=../../scripts/install.sh
source "${project_root}/scripts/install.sh"

fail() {
    printf 'account_boundary_test: %s\n' "$*" >&2
    exit 1
}

if ! (
    getent() {
        case "$1:$2" in
            passwd:socks-vps)
                printf 'socks-vps:x:991:991::/nonexistent:/usr/sbin/nologin\n'
                ;;
            group:socks-vps)
                printf 'socks-vps:x:991:\n'
                ;;
            *)
                return 2
                ;;
        esac
    }
    id() {
        case $1 in
            -gn | -Gn)
                printf 'socks-vps\n'
                ;;
            *)
                return 2
                ;;
        esac
    }
    validate_account
); then
    fail 'valid dedicated account was rejected'
fi

if (
    getent() {
        case "$1:$2" in
            passwd:socks-vps)
                printf 'socks-vps:x:991:991::/nonexistent:/usr/sbin/nologin\n'
                ;;
            group:socks-vps)
                printf 'socks-vps:x:991:alice\n'
                ;;
        esac
    }
    id() {
        printf 'socks-vps\n'
    }
    validate_account
) >/dev/null 2>&1; then
    fail 'supplemental group member was accepted'
fi

if (
    getent() {
        case "$1:$2" in
            passwd:socks-vps)
                printf 'socks-vps:x:991:991::/nonexistent:/usr/sbin/nologin\n'
                ;;
            group:socks-vps)
                printf 'socks-vps:x:991:\n'
                ;;
        esac
    }
    id() {
        case $1 in
            -gn)
                printf 'socks-vps\n'
                ;;
            -Gn)
                printf 'socks-vps wheel\n'
                ;;
        esac
    }
    validate_account
) >/dev/null 2>&1; then
    fail 'service user with supplemental groups was accepted'
fi

if (
    getent() {
        [[ $1 == passwd && $2 == socks-vps ]]
    }
    check_fresh_account_conflicts
) >/dev/null 2>&1; then
    fail 'fresh install reused an unowned service account'
fi

printf 'System account trust boundary passed\n'
