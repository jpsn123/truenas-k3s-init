#!/bin/bash
## libpassword.sh — 确定性密码派生与随机密码库,可独立分发。
## password_derive_sha1|password_derive_sha256 <input> <length>
##   字节级兼容旧规则:hex 文本(含结尾换行)base64 后取前 length 字节。
## password_derive_sha256_hex <input> <length>   纯 hex 截取,无 base64。
## password_random <length>                      openssl rand -base64 截取。
## input 为调用方拼好的原文;length 必须为正整数。source 无副作用。
## 哈希与 base64 阶段均先完整捕获并检查退出码,再截取,避免管道掩盖失败。

if [[ -n "${_LIB_PASSWORD_SOURCED:-}" ]]; then
    return 0
fi

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/liblog.sh" || return 1

function _libpassword_validate_length() {
    case "$1" in
    '' | *[!0-9]*)
        log_error "password length must be a positive integer: $1"
        return 1
        ;;
    esac
    if [ "$1" -lt 1 ]; then
        log_error "password length must be a positive integer: $1"
        return 1
    fi
}

## _libpassword_digest <algo> <input>: 输出哈希 hex,sha 工具失败时返回非 0。
function _libpassword_digest() {
    local ALGO="$1"
    local INPUT="$2"
    local RAW=""
    RAW=$(printf '%s' "$INPUT" | "$ALGO") || return 1
    RAW=${RAW%% *}
    if [ -z "$RAW" ]; then
        log_error "password derive: $ALGO failed."
        return 1
    fi
    printf '%s' "$RAW"
}

function password_derive_sha1() {
    local INPUT="${1:-}"
    local LENGTH="${2:-}"
    local HASH=""
    local ENCODED=""
    _libpassword_validate_length "$LENGTH" || return 1
    HASH=$(_libpassword_digest sha1sum "$INPUT") || return 1
    ENCODED=$(printf '%s\n' "$HASH" | base64) || return 1
    printf '%s\n' "$ENCODED" | head -c "$LENGTH"
}

function password_derive_sha256() {
    local INPUT="${1:-}"
    local LENGTH="${2:-}"
    local HASH=""
    local ENCODED=""
    _libpassword_validate_length "$LENGTH" || return 1
    HASH=$(_libpassword_digest sha256sum "$INPUT") || return 1
    ENCODED=$(printf '%s\n' "$HASH" | base64) || return 1
    printf '%s\n' "$ENCODED" | head -c "$LENGTH"
}

function password_derive_sha256_hex() {
    local INPUT="${1:-}"
    local LENGTH="${2:-}"
    local HASH=""
    _libpassword_validate_length "$LENGTH" || return 1
    HASH=$(_libpassword_digest sha256sum "$INPUT") || return 1
    printf '%s\n' "$HASH" | head -c "$LENGTH"
}

function password_random() {
    local LENGTH="${1:-}"
    local RANDOM_VALUE=""
    _libpassword_validate_length "$LENGTH" || return 1
    RANDOM_VALUE=$(openssl rand -base64 "$LENGTH" 2>/dev/null) || {
        log_error "password_random: openssl rand failed."
        return 1
    }
    RANDOM_VALUE=${RANDOM_VALUE//$'\n'/}
    printf '%s' "$RANDOM_VALUE" | head -c "$LENGTH"
}

_LIB_PASSWORD_SOURCED=1
