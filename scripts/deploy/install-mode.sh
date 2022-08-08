#!/bin/bash
## scripts/deploy/install-mode.sh — jutze-deploy 安装模式规则。
## deploy_validate_mode <mode> [component...]
##   full/reinstall 或列出的组件模式合法;非法输出错误并返回 1(不 exit)。
## deploy_mode_enabled <mode> <component>
##   full/reinstall 恒执行,组件模式仅匹配自身;返回 0/1,无输出。
## source 无副作用。

if [[ -n "${_INSTALL_MODE_SOURCED:-}" ]]; then
    return 0
fi

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/paths.sh" || return 1
source "$DEPLOY_LIB_DIR/liblog.sh" || return 1

function deploy_validate_mode() {
    local INSTALL_MODE="${1:-}"
    local COMPONENT=""
    shift
    if [ "$INSTALL_MODE" == "full" ] || [ "$INSTALL_MODE" == "reinstall" ]; then
        return 0
    fi
    for COMPONENT in "$@"; do
        if [ "$INSTALL_MODE" == "$COMPONENT" ]; then
            return 0
        fi
    done
    log_error "unknown install mode: ${INSTALL_MODE:-<empty>}"
    log_reminder "supported install modes: full reinstall $*"
    return 1
}

function deploy_mode_enabled() {
    local INSTALL_MODE="${1:-}"
    local COMPONENT="${2:-}"
    [ "$INSTALL_MODE" == "full" ] || [ "$INSTALL_MODE" == "reinstall" ] || [ "$INSTALL_MODE" == "$COMPONENT" ]
}

_INSTALL_MODE_SOURCED=1
