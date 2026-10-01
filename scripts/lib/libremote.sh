#!/bin/bash
## libremote.sh — 单主机 SSH/SCP 远程执行库,可独立分发。
## remote_run  <user> <host> <command>
##   命令脚本经 stdin 传给远端 bash -s,本地与远端 bash 语义一致,
##   不经远端登录 shell 词法重解析;返回 ssh 退出码。
## remote_copy <user> <host> <source> <dest>   返回 scp 退出码。
## 用户、主机、路径显式传入;不记录命令内容,避免敏感信息泄漏。source 无副作用。

if [[ -n "${_LIB_REMOTE_SOURCED:-}" ]]; then
    return 0
fi

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/liblog.sh" || return 1

function remote_run() {
    local REMOTE_USER="${1:-}"
    local REMOTE_HOST="${2:-}"
    local REMOTE_COMMAND="${3:-}"
    if [ "$#" -lt 3 ] || [ -z "$REMOTE_USER" ] || [ -z "$REMOTE_HOST" ] || [ -z "$REMOTE_COMMAND" ]; then
        log_error "remote_run: user, host and command are required."
        return 1
    fi
    ssh "$REMOTE_USER@$REMOTE_HOST" bash -s <<<"$REMOTE_COMMAND"
}

function remote_copy() {
    local REMOTE_USER="${1:-}"
    local REMOTE_HOST="${2:-}"
    local SOURCE_PATH="${3:-}"
    local DEST_PATH="${4:-}"
    if [ "$#" -lt 4 ] || [ -z "$REMOTE_USER" ] || [ -z "$REMOTE_HOST" ] || [ -z "$SOURCE_PATH" ] || [ -z "$DEST_PATH" ]; then
        log_error "remote_copy: user, host, source and destination are required."
        return 1
    fi
    if [ ! -e "$SOURCE_PATH" ]; then
        log_error "remote_copy: source file not found: $SOURCE_PATH"
        return 1
    fi
    scp "$SOURCE_PATH" "$REMOTE_USER@$REMOTE_HOST:$DEST_PATH"
}

_LIB_REMOTE_SOURCED=1
