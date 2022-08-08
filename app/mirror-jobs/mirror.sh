#!/bin/bash
## mirror.sh — mirror 任务共享的业务策略层。
##
## 由 install.sh 在构建上下文里随各任务一并暂存（见 README.md）：
## /opt/mirror/mirror.sh 与 lib/liblog.sh、lib/libjfrog.sh、sync.sh 同级。
## 本文件只保留两个任务共同的业务规则：配置校验、发布属性布局、版本保留
## 候选计算及清理编排；HTTP 细节全部来自公共 libjfrog API。
##
## 所有函数使用显式参数（endpoint、token、目录路径、超时逐个传入），
## 不读取也不设置任何全局配置变量；工作目录、trap 和进程生命周期由入口
## sync.sh 拥有。函数不依赖调用方的 set -e：每一步失败都显式 return，
## 因此在 if 条件里调用也不会带着前序错误继续执行。

if [[ -n "${_APP_MIRROR_JOBS_MIRROR_SOURCED:-}" ]]; then
    return 0
fi
if ! source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/lib" && pwd)/liblog.sh"; then
    return 1
fi
if ! source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/lib" && pwd)/libjfrog.sh"; then
    return 1
fi
_APP_MIRROR_JOBS_MIRROR_SOURCED=1

## function mirror_validate_config. 校验任务配置值，不设置任何变量。
## 调用方从 CronJob 环境读取后显式传入；endpoint 的末尾 '/' 由调用方规范化。
## $1: endpoint（含 /artifactory）；$2: token；$3: 仓库内相对目录
## $4: KEEP_VERSIONS；$5: REQUEST_TIMEOUT
## return: 0 配置有效；1 缺失或非法
function mirror_validate_config() {
    if [[ $# -lt 5 || -z "$1" || -z "$2" || -z "$3" ]]; then
        log_error "endpoint, token and mirror path are required"
        return 1
    fi
    if [[ ! "$4" =~ ^[1-9][0-9]*$ ]] || [[ ! "$5" =~ ^[1-9][0-9]*$ ]]; then
        log_error "KEEP_VERSIONS and REQUEST_TIMEOUT must be positive integers"
        return 1
    fi
    if [[ ! "$1" =~ ^https://[a-zA-Z0-9.-]+(:[0-9]+)?/artifactory$ ]] ||
        [[ ! "$3" =~ ^[a-zA-Z0-9_-]+(/[a-zA-Z0-9_-]+)+$ ]]; then
        log_error "invalid Artifactory endpoint or mirror path (repository/subdirectory required)"
        return 1
    fi
    return 0
}

## function mirror_publish_properties. 发布同步完成后的属性布局。
## 制品属性 `<prefix>_version` / `<prefix>_checked_at`，目录属性
## `last_version` / `last_checked_at` —— 这是 Coder workspace 消费端读取的
## 数据契约，不得改变。第一个属性写失败时立即返回，不会继续发布目录属性。
## $1: endpoint；$2: token；$3: 仓库内相对目录；$4: 超时秒
## $5: 制品文件名；$6: 版本号；$7: 属性前缀（code_server / gitlens）
## return: 0 成功；1 任一属性写失败
function mirror_publish_properties() {
    local _MIRROR_ENDPOINT="$1"
    local _MIRROR_TOKEN="$2"
    local _MIRROR_DIR="$3"
    local _MIRROR_TIMEOUT="$4"
    local _MIRROR_FILE="$5"
    local _MIRROR_VERSION="$6"
    local _MIRROR_PREFIX="$7"
    local _MIRROR_CHECKED_AT=""
    _MIRROR_CHECKED_AT=$(date -u +%s) || return 1
    jfrog_set_properties "$_MIRROR_ENDPOINT" "$_MIRROR_TOKEN" "$_MIRROR_DIR/$_MIRROR_FILE" "$_MIRROR_TIMEOUT" \
        "${_MIRROR_PREFIX}_version=$_MIRROR_VERSION" "${_MIRROR_PREFIX}_checked_at=$_MIRROR_CHECKED_AT" || return 1
    jfrog_set_properties "$_MIRROR_ENDPOINT" "$_MIRROR_TOKEN" "$_MIRROR_DIR" "$_MIRROR_TIMEOUT" \
        "last_version=$_MIRROR_VERSION" "last_checked_at=$_MIRROR_CHECKED_AT" || return 1
}

## function mirror_cleanup_versions. 在同步完全发布后清理过期制品。
## 当前文件永不删除（上游回退时保留已固定版本）；此外只保留数字版本最高的
## KEEP-1 个匹配文件。MATCH 是 jq 正则，必须把数字版本捕获为 "version"；
## 不匹配的文件（其他平台、预发布、无关文件）一律不动。远端列表必须包含
## 当前文件，否则任何删除都不执行；列表、候选计算或任一删除失败都立即返回。
## $1: endpoint；$2: token；$3: 仓库内相对目录；$4: 超时秒；$5: KEEP
## $6: 当前制品文件名；$7: jq 文件名正则
## return: 0 成功；1 参数、列表或删除失败
function mirror_cleanup_versions() {
    local _MIRROR_ENDPOINT="$1"
    local _MIRROR_TOKEN="$2"
    local _MIRROR_DIR="$3"
    local _MIRROR_TIMEOUT="$4"
    local _MIRROR_KEEP="$5"
    local _MIRROR_CURRENT="$6"
    local _MIRROR_MATCH="$7"
    local _MIRROR_LISTING=""
    local _MIRROR_CANDIDATES=""
    local _MIRROR_OLD=""
    if [[ ! "$_MIRROR_KEEP" =~ ^[1-9][0-9]*$ ]]; then
        log_error "KEEP must be a positive integer"
        return 1
    fi
    _MIRROR_LISTING=$(jfrog_list "$_MIRROR_ENDPOINT" "$_MIRROR_TOKEN" "$_MIRROR_DIR" "$_MIRROR_TIMEOUT") || return 1
    _MIRROR_CANDIDATES=$(jq -r --arg pattern "$_MIRROR_MATCH" --arg current "$_MIRROR_CURRENT" \
        --argjson keep "$_MIRROR_KEEP" '
        [.[] | select(.folder == false) | .uri | ltrimstr("/") |
            select(test($pattern)) | {file: ., version: (capture($pattern).version | split(".") | map(tonumber))}] |
        if any(.[]; .file == $current) then . else error("current artifact missing from listing") end |
        map(select(.file != $current)) | sort_by(.version) | reverse | .[($keep - 1):][] | .file
    ' <<<"$_MIRROR_LISTING") || return 1
    while IFS= read -r _MIRROR_OLD; do
        [ -n "$_MIRROR_OLD" ] || continue
        log_info "deleting old artifact $_MIRROR_OLD"
        jfrog_delete "$_MIRROR_ENDPOINT" "$_MIRROR_TOKEN" "$_MIRROR_DIR/$_MIRROR_OLD" "$_MIRROR_TIMEOUT" || return 1
    done <<<"$_MIRROR_CANDIDATES"
    return 0
}
