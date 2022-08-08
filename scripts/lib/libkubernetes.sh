#!/bin/bash
## libkubernetes.sh — Kubernetes Secret / ConfigMap 客户端公共库。
## 依赖：kubectl（调用对应能力时才需要）、同目录 liblog.sh。
##
## 返回值约定：
##   - 读取类函数：资源 NotFound 或 key 缺失时输出空且返回 0；
##     权限、网络等真实 kubectl 故障返回非 0，不会把错误吞成空值。
##   - 写入类函数：dry-run 或 apply 失败返回非 0；任何路径都不预先删除已有资源。
##
## 内部局部变量统一使用 _KUBE 前缀，避免 Bash 动态作用域遮蔽调用者变量；
## key=VARIABLE 映射的右侧变量名以 _KUBE 开头时会被拒绝（保留给模块内部）。

if [[ -n "${_LIB_KUBERNETES_SOURCED:-}" ]]; then
    return 0
fi
if ! source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/liblog.sh"; then
    return 1
fi
_LIB_KUBERNETES_SOURCED=1

## function kube_secret_get. 读取并解码 Secret 中单个 key。
## $1: namespace
## $2: secret name
## $3: key
## stdout: key 的解码值；资源或 key 不存在时为空
## return: 0 资源存在或 NotFound；非 0 权限、网络等 kubectl 故障
function kube_secret_get() {
    local _KUBE_NS="$1"
    local _KUBE_NAME="$2"
    local _KUBE_KEY="$3"
    local _KUBE_OUT=""

    if ! _KUBE_OUT=$(kubectl -n "$_KUBE_NS" get secret "$_KUBE_NAME" \
        --ignore-not-found \
        -o "go-template={{ with index .data \"$_KUBE_KEY\" }}{{ . | base64decode }}{{ end }}" 2>/dev/null); then
        log_error "failed to get secret $_KUBE_NS/$_KUBE_NAME key $_KUBE_KEY"
        return 1
    fi
    printf '%s' "$_KUBE_OUT"
}

## function kube_configmap_get. 读取 ConfigMap 中单个 key。
## $1: namespace
## $2: configmap name
## $3: key
## stdout: key 的值；资源或 key 不存在时为空
## return: 0 资源存在或 NotFound；非 0 权限、网络等 kubectl 故障
function kube_configmap_get() {
    local _KUBE_NS="$1"
    local _KUBE_NAME="$2"
    local _KUBE_KEY="$3"
    local _KUBE_OUT=""

    if ! _KUBE_OUT=$(kubectl -n "$_KUBE_NS" get configmap "$_KUBE_NAME" \
        --ignore-not-found \
        -o "go-template={{ with index .data \"$_KUBE_KEY\" }}{{ . }}{{ end }}" 2>/dev/null); then
        log_error "failed to get configmap $_KUBE_NS/$_KUBE_NAME key $_KUBE_KEY"
        return 1
    fi
    printf '%s' "$_KUBE_OUT"
}

## function _kube_mapping_var. 解析并校验 key=VARIABLE 映射，输出变量名。
## $1: 形如 key=VARIABLE 的映射项
## stdout: 变量名
## return: 0 合法；1 格式非法或变量名保留
function _kube_mapping_var() {
    local _KUBE_ITEM="$1"
    local _KUBE_KEY=""
    local _KUBE_VAR=""

    if [[ "$_KUBE_ITEM" != *=* ]]; then
        log_error "invalid mapping '$_KUBE_ITEM', expected key=VARIABLE"
        return 1
    fi
    _KUBE_KEY="${_KUBE_ITEM%%=*}"
    _KUBE_VAR="${_KUBE_ITEM#*=}"
    if [[ -z "$_KUBE_KEY" || -z "$_KUBE_VAR" ]]; then
        log_error "invalid mapping '$_KUBE_ITEM', key and variable are required"
        return 1
    fi
    if [[ ! "$_KUBE_VAR" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        log_error "invalid variable name '$_KUBE_VAR' in mapping '$_KUBE_ITEM'"
        return 1
    fi
    if [[ "$_KUBE_VAR" == _KUBE* ]]; then
        log_error "variable name '$_KUBE_VAR' is reserved for libkubernetes"
        return 1
    fi
    printf '%s' "$_KUBE_VAR"
}

## function kube_secret_load. 批量读取 Secret key 到调用者 Bash 变量。
## 只有读到非空值时才赋值，保留调用者对未匹配项已有的默认值；
## 读取故障（权限、网络）返回非 0，调用者不得在失败后直接派生新密码。
## $1: namespace
## $2: secret name
## $@: key=VARIABLE 映射，右侧是调用者变量名
## return: 0 读取成功（含 NotFound）；非 0 映射非法或 kubectl 故障
function kube_secret_load() {
    local _KUBE_NS="$1"
    local _KUBE_NAME="$2"
    local _KUBE_ITEM=""
    local _KUBE_KEY=""
    local _KUBE_VAR=""
    local _KUBE_VALUE=""
    local _KUBE_LOADED=false
    shift 2

    for _KUBE_ITEM in "$@"; do
        _KUBE_KEY="${_KUBE_ITEM%%=*}"
        if ! _KUBE_VAR=$(_kube_mapping_var "$_KUBE_ITEM"); then
            return 1
        fi
        if ! _KUBE_VALUE=$(kube_secret_get "$_KUBE_NS" "$_KUBE_NAME" "$_KUBE_KEY"); then
            return 1
        fi
        if [[ -n "$_KUBE_VALUE" ]]; then
            printf -v "$_KUBE_VAR" '%s' "$_KUBE_VALUE" || return 1
            _KUBE_LOADED=true
        fi
    done
    if [[ "$_KUBE_LOADED" == true ]]; then
        log_info "reuse existing secret $_KUBE_NAME"
    fi
}

## function kube_configmap_load. 批量读取 ConfigMap key 到调用者 Bash 变量。
## 语义同 kube_secret_load。
## $1: namespace
## $2: configmap name
## $@: key=VARIABLE 映射
## return: 0 读取成功（含 NotFound）；非 0 映射非法或 kubectl 故障
function kube_configmap_load() {
    local _KUBE_NS="$1"
    local _KUBE_NAME="$2"
    local _KUBE_ITEM=""
    local _KUBE_KEY=""
    local _KUBE_VAR=""
    local _KUBE_VALUE=""
    local _KUBE_LOADED=false
    shift 2

    for _KUBE_ITEM in "$@"; do
        _KUBE_KEY="${_KUBE_ITEM%%=*}"
        if ! _KUBE_VAR=$(_kube_mapping_var "$_KUBE_ITEM"); then
            return 1
        fi
        if ! _KUBE_VALUE=$(kube_configmap_get "$_KUBE_NS" "$_KUBE_NAME" "$_KUBE_KEY"); then
            return 1
        fi
        if [[ -n "$_KUBE_VALUE" ]]; then
            printf -v "$_KUBE_VAR" '%s' "$_KUBE_VALUE" || return 1
            _KUBE_LOADED=true
        fi
    done
    if [[ "$_KUBE_LOADED" == true ]]; then
        log_info "reuse existing configmap $_KUBE_NAME"
    fi
}

## function kube_secret_apply_vars. 将调用者变量按 literal 写入 generic Secret。
## $1: namespace
## $2: secret name
## $@: key=VARIABLE 映射，右侧变量的值作为 key 的内容
## return: 同 kube_apply_secret
function kube_secret_apply_vars() {
    local _KUBE_NS="$1"
    local _KUBE_NAME="$2"
    local _KUBE_ITEM=""
    local _KUBE_KEY=""
    local _KUBE_VAR=""
    local _KUBE_VALUE=""
    local _KUBE_ARGS=()
    shift 2

    for _KUBE_ITEM in "$@"; do
        _KUBE_KEY="${_KUBE_ITEM%%=*}"
        if ! _KUBE_VAR=$(_kube_mapping_var "$_KUBE_ITEM"); then
            return 1
        fi
        _KUBE_VALUE="${!_KUBE_VAR}"
        _KUBE_ARGS+=("--from-literal=$_KUBE_KEY=$_KUBE_VALUE")
    done
    kube_apply_secret "$_KUBE_NS" "$_KUBE_NAME" "${_KUBE_ARGS[@]}"
}

## function kube_configmap_apply_vars. 将调用者变量按 literal 写入 ConfigMap。
## $1: namespace
## $2: configmap name
## $@: key=VARIABLE 映射
## return: 同 kube_apply_configmap
function kube_configmap_apply_vars() {
    local _KUBE_NS="$1"
    local _KUBE_NAME="$2"
    local _KUBE_ITEM=""
    local _KUBE_KEY=""
    local _KUBE_VAR=""
    local _KUBE_VALUE=""
    local _KUBE_ARGS=()
    shift 2

    for _KUBE_ITEM in "$@"; do
        _KUBE_KEY="${_KUBE_ITEM%%=*}"
        if ! _KUBE_VAR=$(_kube_mapping_var "$_KUBE_ITEM"); then
            return 1
        fi
        _KUBE_VALUE="${!_KUBE_VAR}"
        _KUBE_ARGS+=("--from-literal=$_KUBE_KEY=$_KUBE_VALUE")
    done
    kube_apply_configmap "$_KUBE_NS" "$_KUBE_NAME" "${_KUBE_ARGS[@]}"
}

## function kube_apply_secret. 安全创建或更新 generic Secret，不预先删除已有资源。
## 先用 dry-run 在权限受限（0600）的临时文件生成 manifest，成功后再 apply；
## dry-run 失败或 apply 失败都不影响集群中的既有资源。
## $1: namespace
## $2: secret name
## $@: 透传给 kubectl create secret generic 的参数
## return: 0 成功；1 mktemp、dry-run、chmod 或 apply 失败
function kube_apply_secret() {
    local _KUBE_NS="$1"
    local _KUBE_NAME="$2"
    local _KUBE_TEMP=""
    local _KUBE_RC=0
    shift 2

    _KUBE_TEMP=$(mktemp) || return 1
    if ! kubectl -n "$_KUBE_NS" create secret generic "$_KUBE_NAME" "$@" \
        --dry-run=client -o yaml >"$_KUBE_TEMP"; then
        rm -f "$_KUBE_TEMP"
        log_error "failed to render secret $_KUBE_NS/$_KUBE_NAME"
        return 1
    fi
    if ! chmod 600 "$_KUBE_TEMP"; then
        rm -f "$_KUBE_TEMP"
        log_error "failed to secure temp manifest for secret $_KUBE_NS/$_KUBE_NAME"
        return 1
    fi
    kubectl apply --server-side --force-conflicts -f "$_KUBE_TEMP" >/dev/null || _KUBE_RC=$?
    rm -f "$_KUBE_TEMP"
    if [[ "$_KUBE_RC" -ne 0 ]]; then
        log_error "failed to apply secret $_KUBE_NS/$_KUBE_NAME"
    fi
    return "$_KUBE_RC"
}

## function kube_apply_configmap. 安全创建或更新 ConfigMap，不预先删除已有资源。
## $1: namespace
## $2: configmap name
## $@: 透传给 kubectl create configmap 的参数
## return: 0 成功；1 mktemp、dry-run、chmod 或 apply 失败
function kube_apply_configmap() {
    local _KUBE_NS="$1"
    local _KUBE_NAME="$2"
    local _KUBE_TEMP=""
    local _KUBE_RC=0
    shift 2

    _KUBE_TEMP=$(mktemp) || return 1
    if ! kubectl -n "$_KUBE_NS" create configmap "$_KUBE_NAME" "$@" \
        --dry-run=client -o yaml >"$_KUBE_TEMP"; then
        rm -f "$_KUBE_TEMP"
        log_error "failed to render configmap $_KUBE_NS/$_KUBE_NAME"
        return 1
    fi
    if ! chmod 600 "$_KUBE_TEMP"; then
        rm -f "$_KUBE_TEMP"
        log_error "failed to secure temp manifest for configmap $_KUBE_NS/$_KUBE_NAME"
        return 1
    fi
    kubectl apply --server-side --force-conflicts -f "$_KUBE_TEMP" >/dev/null || _KUBE_RC=$?
    rm -f "$_KUBE_TEMP"
    if [[ "$_KUBE_RC" -ne 0 ]]; then
        log_error "failed to apply configmap $_KUBE_NS/$_KUBE_NAME"
    fi
    return "$_KUBE_RC"
}

## function kube_apply_registry_secret. 安全创建或更新 docker-registry Secret。
## $1: namespace
## $2: secret name
## $3: docker registry server
## $4: docker registry username
## $5: docker registry password 或 token
## return: 0 成功；1 渲染或 apply 失败
function kube_apply_registry_secret() {
    local _KUBE_NS="$1"
    local _KUBE_NAME="$2"
    local _KUBE_SERVER="$3"
    local _KUBE_USERNAME="$4"
    local _KUBE_PASSWORD="$5"
    local _KUBE_TEMP=""
    local _KUBE_RC=0

    _KUBE_TEMP=$(mktemp) || return 1
    if ! kubectl -n "$_KUBE_NS" create secret docker-registry "$_KUBE_NAME" \
        --docker-server="$_KUBE_SERVER" \
        --docker-username="$_KUBE_USERNAME" \
        --docker-password="$_KUBE_PASSWORD" \
        --dry-run=client -o yaml >"$_KUBE_TEMP"; then
        rm -f "$_KUBE_TEMP"
        log_error "failed to render registry secret $_KUBE_NS/$_KUBE_NAME"
        return 1
    fi
    if ! chmod 600 "$_KUBE_TEMP"; then
        rm -f "$_KUBE_TEMP"
        log_error "failed to secure temp manifest for registry secret $_KUBE_NS/$_KUBE_NAME"
        return 1
    fi
    kubectl apply --server-side --force-conflicts -f "$_KUBE_TEMP" >/dev/null || _KUBE_RC=$?
    rm -f "$_KUBE_TEMP"
    if [[ "$_KUBE_RC" -ne 0 ]]; then
        log_error "failed to apply registry secret $_KUBE_NS/$_KUBE_NAME"
    fi
    return "$_KUBE_RC"
}
