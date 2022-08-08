#!/bin/bash
## libos.sh — 内核模块与 sysctl 配置库,可独立分发。
## os_load_kernel_modules <conf_path> <module>...
##   模块列表原子写入 conf_path(绝对路径,如 /etc/modules-load.d/k3s.conf,0644),
##   modprobe 失败返回 1。
## os_apply_sysctl <conf_path> <key=value>...
##   在 conf_path(绝对路径,如 /etc/sysctl.d/69-k3s.conf)的 "## PATCH" 区块内
##   幂等更新键值,区块外既有行不动;完成后执行 sysctl -p 并传播其退出码。
## source 无副作用。

if [[ -n "${_LIB_OS_SOURCED:-}" ]]; then
    return 0
fi

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/liblog.sh" || return 1

function _libos_validate_conf_path() {
    if [ -z "$1" ]; then
        log_error "conf path is empty"
        return 1
    fi
    if [[ "$1" != /* ]]; then
        log_error "conf path must be absolute: $1"
        return 1
    fi
}

function os_load_kernel_modules() {
    local CONF_PATH="${1:-}"
    local MODULE=""
    local CONF_DIR=""
    local TMP_FILE=""
    shift
    _libos_validate_conf_path "$CONF_PATH" || return 1
    CONF_DIR=$(dirname -- "$CONF_PATH")
    install -d "$CONF_DIR" || {
        log_error "os_load_kernel_modules: cannot create directory: $CONF_DIR"
        return 1
    }
    TMP_FILE=$(mktemp "$CONF_DIR/.modules-load.XXXXXX") || {
        log_error "os_load_kernel_modules: cannot create temp file in $CONF_DIR"
        return 1
    }
    for MODULE in "$@"; do
        printf '%s\n' "$MODULE"
    done >"$TMP_FILE"
    chmod 0644 "$TMP_FILE" || {
        rm -f "$TMP_FILE"
        return 1
    }
    if ! mv -f "$TMP_FILE" "$CONF_PATH"; then
        log_error "os_load_kernel_modules: failed to write config: $CONF_PATH"
        rm -f "$TMP_FILE"
        return 1
    fi
    for MODULE in "$@"; do
        if modprobe "$MODULE"; then
            log_info "modprobe ok: $MODULE"
        else
            log_error "os_load_kernel_modules: modprobe failed: $MODULE"
            return 1
        fi
    done
}

function os_apply_sysctl() {
    local CONF_PATH="${1:-}"
    local KV=""
    local KEY=""
    local CONF_DIR=""
    local TMP_FILE=""
    shift
    _libos_validate_conf_path "$CONF_PATH" || return 1
    CONF_DIR=$(dirname -- "$CONF_PATH")
    install -d "$CONF_DIR" || {
        log_error "os_apply_sysctl: cannot create directory: $CONF_DIR"
        return 1
    }
    touch "$CONF_PATH" || {
        log_error "os_apply_sysctl: failed to create config file: $CONF_PATH"
        return 1
    }
    for KV in "$@"; do
        KEY="${KV%%=*}"
        if [ -z "$KEY" ] || [[ "$KV" != *=* ]]; then
            log_error "os_apply_sysctl: bad key=value: $KV"
            return 1
        fi
        TMP_FILE=$(mktemp "$CONF_DIR/.sysctl-patch.XXXXXX") || {
            log_error "os_apply_sysctl: cannot create temp file in $CONF_DIR"
            return 1
        }
        awk -v marker="## PATCH" -v key="$KEY" -v kv="$KV" '
            BEGIN { inpatch=0; seen_marker=0 }
            {
                if ($0 == marker) { inpatch=1; seen_marker=1; print; next }
                if (inpatch && $0 ~ "^[[:space:]]*" key "[[:space:]]*=") next
                print
            }
            END {
                if (!seen_marker) { print ""; print marker }
                print kv
            }
        ' "$CONF_PATH" >"$TMP_FILE" && chmod 0644 "$TMP_FILE" && mv -f "$TMP_FILE" "$CONF_PATH" || {
            rm -f "$TMP_FILE"
            log_error "os_apply_sysctl: failed to update config: $CONF_PATH"
            return 1
        }
    done
    sysctl -p "$CONF_PATH"
}

_LIB_OS_SOURCED=1
