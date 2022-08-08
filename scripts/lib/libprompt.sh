#!/bin/bash
## libprompt.sh — 交互输入库,可独立分发。
## prompt_with_default <reminder> <prompt> [default]
## prompt_required <reminder> <prompt> [-s]          仅支持 -s
## prompt_yes_no_with_default <reminder> <prompt> [default]  归一化 true/false
## 值经 stdout 返回;stdin 读到 EOF 返回 1,不进入死循环。source 无副作用。

if [[ -n "${_LIB_PROMPT_SOURCED:-}" ]]; then
    return 0
fi

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/liblog.sh" || return 1

function prompt_with_default() {
    local REMINDER_TEXT="${1:-}"
    local PROMPT_TEXT="${2:-}"
    local DEFAULT_VALUE="${3:-}"
    local INPUT_VALUE=""
    if [ -n "$REMINDER_TEXT" ]; then
        log_reminder "$REMINDER_TEXT"
    fi
    if [ -n "$DEFAULT_VALUE" ]; then
        read -r -p "$PROMPT_TEXT [$DEFAULT_VALUE]: " INPUT_VALUE || {
            log_error "prompt_with_default: end of input."
            return 1
        }
        if [ -z "$INPUT_VALUE" ]; then
            INPUT_VALUE="$DEFAULT_VALUE"
        fi
    else
        read -r -p "$PROMPT_TEXT: " INPUT_VALUE || {
            log_error "prompt_with_default: end of input."
            return 1
        }
    fi
    printf '%s' "$INPUT_VALUE"
}

function prompt_required() {
    local REMINDER_TEXT="${1:-}"
    local PROMPT_TEXT="${2:-}"
    local READ_OPT="${3:-}"
    local INPUT_VALUE=""
    if [ -n "$READ_OPT" ] && [ "$READ_OPT" != "-s" ]; then
        log_error "prompt_required: unsupported read option: $READ_OPT"
        return 1
    fi
    if [ -n "$REMINDER_TEXT" ]; then
        log_reminder "$REMINDER_TEXT"
    fi
    while [ -z "$INPUT_VALUE" ]; do
        if [ "$READ_OPT" == "-s" ]; then
            read -r -s -p "$PROMPT_TEXT: " INPUT_VALUE || {
                log_error "prompt_required: end of input."
                return 1
            }
            printf '\n' >&2
        else
            read -r -p "$PROMPT_TEXT: " INPUT_VALUE || {
                log_error "prompt_required: end of input."
                return 1
            }
        fi
    done
    printf '%s' "$INPUT_VALUE"
}

function prompt_yes_no_with_default() {
    local INPUT_VALUE=""
    INPUT_VALUE=$(prompt_with_default "${1:-}" "${2:-}" "${3:-}") || return 1
    if [[ "$INPUT_VALUE" =~ ^([Yy]|[Yy][Ee][Ss]|[Tt][Rr][Uu][Ee])$ ]]; then
        printf 'true'
    elif [[ "$INPUT_VALUE" =~ ^([Nn]|[Nn][Oo]|[Ff][Aa][Ll][Ss][Ee])$ ]]; then
        printf 'false'
    else
        printf '%s' "$INPUT_VALUE"
    fi
}

_LIB_PROMPT_SOURCED=1
