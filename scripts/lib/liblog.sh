#!/bin/bash
## liblog.sh — stderr 日志库,可独立分发。
## log_error/log_warn/log_info/log_trace: 单行;log_header/log_reminder: 后跟空行。
## 颜色: LIBLOG_COLOR=auto(默认,TTY 检测)|always|never。source 无副作用。

if [[ -n "${_LIB_LOG_SOURCED:-}" ]]; then
    return 0
fi

## _liblog_use_color: 判断本次日志调用是否输出颜色。
function _liblog_use_color() {
    case "${LIBLOG_COLOR:-auto}" in
    always)
        return 0
        ;;
    never)
        return 1
        ;;
    *)
        [ -t 2 ]
        ;;
    esac
}

function log_error() {
    if _liblog_use_color; then
        printf '\033[31m%s\033[0m\n' "$*" >&2
    else
        printf '%s\n' "$*" >&2
    fi
}

function log_warn() {
    if _liblog_use_color; then
        printf '\033[33m%s\033[0m\n' "$*" >&2
    else
        printf '%s\n' "$*" >&2
    fi
}

function log_info() {
    if _liblog_use_color; then
        printf '\033[32m%s\033[0m\n' "$*" >&2
    else
        printf '%s\n' "$*" >&2
    fi
}

function log_trace() {
    if _liblog_use_color; then
        printf '\033[34m%s\033[0m\n' "$*" >&2
    else
        printf '%s\n' "$*" >&2
    fi
}

function log_header() {
    if _liblog_use_color; then
        printf '\033[42;30m%s\n\033[0m\n' "$*" >&2
    else
        printf '%s\n\n' "$*" >&2
    fi
}

function log_reminder() {
    if _liblog_use_color; then
        printf '\033[35m%s\n\033[0m\n' "$*" >&2
    else
        printf '%s\n\n' "$*" >&2
    fi
}

_LIB_LOG_SOURCED=1
