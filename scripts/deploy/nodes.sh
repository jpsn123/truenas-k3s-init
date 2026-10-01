#!/bin/bash
## scripts/deploy/nodes.sh — jutze-deploy 节点遍历与本机识别策略。
## deploy_nodes_local_ip <node_list>
##   node_list 为空白分隔地址字符串;stdout 输出本机持有的节点地址(精确匹配)。
##   return: 0 找到,1 无本机地址,2 本机地址查询失败。
## deploy_nodes_run <node_list> <command> [include_local]
##   本机以 bash -c、其余节点经 root SSH 由远端 bash 执行,两端语义一致;
##   include_local 默认 true;任一节点失败立即返回 1。日志不打印命令内容。
## deploy_nodes_copy <node_list> <file> [dest]
##   复制到非本机节点的 dest(默认与 file 相同);本机跳过。
## 不通过全局变量传递状态;远程操作由 libremote.sh 完成。source 无副作用。

if [[ -n "${_NODES_SOURCED:-}" ]]; then
    return 0
fi

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/paths.sh" || return 1
source "$DEPLOY_LIB_DIR/liblog.sh" || return 1
source "$DEPLOY_LIB_DIR/libremote.sh" || return 1

function deploy_nodes_local_ip() {
    local NODE_LIST="${1:-}"
    local NODE=""
    local ADDR_OUTPUT=""
    ADDR_OUTPUT=$(ip -o -4 addr show 2>/dev/null) || {
        log_error "deploy_nodes_local_ip: failed to query local addresses."
        return 2
    }
    for NODE in $NODE_LIST; do
        if printf '%s\n' "$ADDR_OUTPUT" | awk '{print $4}' | cut -d/ -f1 | grep -qxF "$NODE"; then
            printf '%s' "$NODE"
            return 0
        fi
    done
    return 1
}

function deploy_nodes_run() {
    local NODE_LIST="${1:-}"
    local COMMAND="${2:-}"
    local INCLUDE_LOCAL="${3:-true}"
    local NODE=""
    local LOCAL_NODE=""
    local DETECT_RC=0
    if [ -z "$COMMAND" ]; then
        log_error "deploy_nodes_run: command is required."
        return 1
    fi
    LOCAL_NODE=$(deploy_nodes_local_ip "$NODE_LIST") || DETECT_RC=$?
    if [ "$DETECT_RC" -eq 2 ]; then
        return 1
    fi
    for NODE in $NODE_LIST; do
        if [ "$NODE" == "$LOCAL_NODE" ]; then
            if [ "$INCLUDE_LOCAL" != false ]; then
                log_info "   running command at local...  "
                bash -c "$COMMAND" || {
                    log_error "deploy_nodes_run: command failed at local."
                    return 1
                }
            fi
        else
            log_info "   running command at remote node: $NODE...  "
            remote_run root "$NODE" "$COMMAND" || {
                log_error "deploy_nodes_run: command failed on root@$NODE."
                return 1
            }
        fi
    done
}

function deploy_nodes_copy() {
    local NODE_LIST="${1:-}"
    local SOURCE_FILE="${2:-}"
    local DEST_PATH="${3:-$2}"
    local NODE=""
    local LOCAL_NODE=""
    local DETECT_RC=0
    if [ -z "$SOURCE_FILE" ]; then
        log_error "deploy_nodes_copy: file is required."
        return 1
    fi
    if [ ! -e "$SOURCE_FILE" ]; then
        log_error "deploy_nodes_copy: file not found: $SOURCE_FILE"
        return 1
    fi
    LOCAL_NODE=$(deploy_nodes_local_ip "$NODE_LIST") || DETECT_RC=$?
    if [ "$DETECT_RC" -eq 2 ]; then
        return 1
    fi
    for NODE in $NODE_LIST; do
        if [ "$NODE" == "$LOCAL_NODE" ]; then
            continue
        fi
        log_info "   copying file $SOURCE_FILE to remote node: $NODE...  "
        remote_copy root "$NODE" "$SOURCE_FILE" "$DEST_PATH" || {
            log_error "deploy_nodes_copy: copy to root@$NODE failed."
            return 1
        }
    done
}

_NODES_SOURCED=1
