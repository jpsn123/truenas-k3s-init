#!/bin/bash
## libhelm.sh — Helm chart 版本查询与本地缓存公共库。
## 依赖：helm、jq（调用对应能力时才需要）、同目录 liblog.sh。
##
## 缓存约定：chart 解压后缓存在 CACHE_DIR/<chart>/，版本判断依据缓存内
## Chart.yaml 的顶层 version 字段。缓存目录由调用者显式传入，不固定 temp。
##
## 内部局部变量统一使用 _HELM 前缀。

if [[ -n "${_LIB_HELM_SOURCED:-}" ]]; then
    return 0
fi
if ! source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/liblog.sh"; then
    return 1
fi
_LIB_HELM_SOURCED=1

## function helm_chart_versions. 从 Helm repo 查询 chart version 与 appVersion。
## 使用 `helm search -o json` 后按完整 chart 引用精确匹配，避免同名前缀的
## 其他 chart 混入结果。传入 appVersion 时返回该 appVersion 对应的第一条
## chart version；否则返回最新 chart 的版本对。
## $1: helm repo name, e.g. kasten
## $2: helm repo url, e.g. https://charts.kasten.io/
## $3: chart name in this repo, e.g. k10
## $4: appVersion to match, optional
## stdout: "<chartVersion> <appVersion>"
## return: 0 成功；1 repo 添加/更新、查询失败或未找到匹配版本
function helm_chart_versions() {
    local _HELM_REPO="$1"
    local _HELM_URL="$2"
    local _HELM_CHART="$3"
    local _HELM_APP_VERSION="${4:-}"
    local _HELM_SEARCH=""
    local _HELM_PAIR=""

    if ! helm repo add "$_HELM_REPO" "$_HELM_URL" --force-update >/dev/null 2>&1; then
        log_error "failed to add helm repo: $_HELM_REPO $_HELM_URL"
        return 1
    fi
    if ! helm repo update "$_HELM_REPO" >/dev/null; then
        log_error "failed to update helm repo: $_HELM_REPO"
        return 1
    fi
    if ! _HELM_SEARCH=$(helm search repo "$_HELM_REPO/$_HELM_CHART" --versions -o json); then
        log_error "failed to search helm repo: $_HELM_REPO/$_HELM_CHART"
        return 1
    fi
    _HELM_PAIR=$(printf '%s' "$_HELM_SEARCH" | jq -r \
        --arg ref "$_HELM_REPO/$_HELM_CHART" \
        --arg app_version "$_HELM_APP_VERSION" '
        def app_version_field: (.app_version // .appVersion // "");
        map(select(.name == $ref)) as $rows
        | if $app_version == "" then $rows[0]
          else ($rows | map(select(app_version_field == $app_version)))[0]
          end
        | if . then "\(.version) \(app_version_field)" else empty end
        ') || return 1
    if [[ -z "$_HELM_PAIR" ]]; then
        log_error "failed to get helm chart versions: $_HELM_REPO/$_HELM_CHART ${_HELM_APP_VERSION:+app version $_HELM_APP_VERSION}"
        return 1
    fi
    printf '%s' "$_HELM_PAIR"
}

## function _helm_chart_yaml_field. 从 Chart.yaml 读取顶层标量字段并去掉包裹引号。
## 仅匹配行首顶层字段，忽略缩进的依赖项等同名字段；同时剥离单引号和双引号。
## $1: chart 目录
## $2: field name
## stdout: 字段值
function _helm_chart_yaml_field() {
    local _HELM_CHART_DIR="$1"
    local _HELM_FIELD="$2"

    awk -v field="$_HELM_FIELD" -v sq="'" -v dq='"' '
        $0 ~ "^" field ":[[:space:]]" {
            val = $2
            sub("^" dq, "", val)
            sub(dq "$", "", val)
            sub("^" sq, "", val)
            sub(sq "$", "", val)
            print val
            exit
        }
    ' "$_HELM_CHART_DIR/Chart.yaml"
}

## function helm_chart_versions_local. 从本地缓存的 chart 读取版本对。
## 用于 reinstall 等不查询 repo 的场景；缓存缺失或字段缺失（读不到
## chart version / appVersion）时返回失败，不输出残缺版本对。
## $1: chart 目录（包含 Chart.yaml）
## stdout: "<chartVersion> <appVersion>"
## return: 0 成功；1 缓存缺失或版本字段不完整
function helm_chart_versions_local() {
    local _HELM_CHART_DIR="$1"
    local _HELM_VERSION=""
    local _HELM_APP_VERSION=""

    if [[ ! -f "$_HELM_CHART_DIR/Chart.yaml" ]]; then
        log_error "cached chart not found, please run full mode first: $_HELM_CHART_DIR"
        return 1
    fi
    if ! _HELM_VERSION=$(_helm_chart_yaml_field "$_HELM_CHART_DIR" version) ||
        ! _HELM_APP_VERSION=$(_helm_chart_yaml_field "$_HELM_CHART_DIR" appVersion); then
        log_error "failed to read cached chart versions: $_HELM_CHART_DIR"
        return 1
    fi
    if [[ -z "$_HELM_VERSION" || -z "$_HELM_APP_VERSION" ]]; then
        log_error "incomplete cached chart versions: $_HELM_CHART_DIR"
        return 1
    fi
    printf '%s %s' "$_HELM_VERSION" "$_HELM_APP_VERSION"
}

## function helm_ensure_chart. 拉取 chart 到缓存目录，尽量复用本地缓存。
## chart version 可选：
##   - 未指定版本：缓存存在则直接复用；否则拉取最新版本。
##   - 指定版本：缓存版本一致则复用；不一致才重新拉取。
## 拉取先写入缓存目录下的临时 staging 目录，校验 staging 内 Chart.yaml
## 完整（指定版本时还校验版本一致）后才用“备份旧缓存、移入新缓存、失败
## 回滚”的方式替换，拉取或发布失败都不会破坏已有的可用缓存。
## $1: helm repo name，OCI chart 忽略
## $2: helm repo url 或 OCI registry url
## $3: chart name，不能包含 /，不能是 . 或 ..
## $4: cache dir
## $5: chart version，可选
## return: 0 缓存可用或拉取成功；1 参数、拉取校验或发布失败
function helm_ensure_chart() {
    local _HELM_REPO="$1"
    local _HELM_URL="$2"
    local _HELM_CHART="$3"
    local _HELM_CACHE_DIR="$4"
    local _HELM_VERSION="${5:-}"
    local _HELM_CACHED_VERSION=""
    local _HELM_STAGING=""
    local _HELM_STAGED_CHART=""
    local _HELM_BACKUP=""
    local _HELM_VERSION_FLAG=()

    if [[ -z "$_HELM_CACHE_DIR" ]]; then
        log_error "cache dir is required for helm chart: $_HELM_CHART"
        return 1
    fi
    if [[ -z "$_HELM_CHART" || "$_HELM_CHART" == */* || "$_HELM_CHART" == "." || "$_HELM_CHART" == ".." ]]; then
        log_error "invalid chart name: $_HELM_CHART"
        return 1
    fi
    if [[ -f "$_HELM_CACHE_DIR/$_HELM_CHART/Chart.yaml" ]]; then
        if [[ -z "$_HELM_VERSION" ]]; then
            log_info "reuse cached chart $_HELM_CHART"
            return 0
        fi
        _HELM_CACHED_VERSION=$(_helm_chart_yaml_field "$_HELM_CACHE_DIR/$_HELM_CHART" version)
        if [[ "$_HELM_CACHED_VERSION" == "$_HELM_VERSION" ]]; then
            log_info "reuse cached chart $_HELM_CHART $_HELM_VERSION"
            return 0
        fi
    fi

    mkdir -p "$_HELM_CACHE_DIR" || return 1
    _HELM_STAGING=$(mktemp -d "$_HELM_CACHE_DIR/.helm-staging.XXXXXX") || return 1
    _HELM_STAGED_CHART="$_HELM_STAGING/$_HELM_CHART"
    _HELM_BACKUP="$_HELM_STAGING/.previous"
    if [[ -n "$_HELM_VERSION" ]]; then
        _HELM_VERSION_FLAG=(--version="$_HELM_VERSION")
    fi
    if [[ "$_HELM_URL" == oci://* ]]; then
        if ! helm pull "$_HELM_URL/$_HELM_CHART" --untar --untardir "$_HELM_STAGING" "${_HELM_VERSION_FLAG[@]}"; then
            rm -rf "$_HELM_STAGING"
            log_error "failed to pull helm chart: $_HELM_URL/$_HELM_CHART"
            return 1
        fi
    else
        if ! helm repo add "$_HELM_REPO" "$_HELM_URL" --force-update >/dev/null 2>&1; then
            rm -rf "$_HELM_STAGING"
            log_error "failed to add helm repo: $_HELM_REPO $_HELM_URL"
            return 1
        fi
        if ! helm repo update "$_HELM_REPO" >/dev/null; then
            rm -rf "$_HELM_STAGING"
            log_error "failed to update helm repo: $_HELM_REPO"
            return 1
        fi
        if ! helm pull "$_HELM_REPO/$_HELM_CHART" --untar --untardir "$_HELM_STAGING" "${_HELM_VERSION_FLAG[@]}"; then
            rm -rf "$_HELM_STAGING"
            log_error "failed to pull helm chart: $_HELM_REPO/$_HELM_CHART"
            return 1
        fi
    fi

    if [[ ! -f "$_HELM_STAGED_CHART/Chart.yaml" ]]; then
        rm -rf "$_HELM_STAGING"
        log_error "pulled chart is incomplete: $_HELM_CHART"
        return 1
    fi
    if [[ -n "$_HELM_VERSION" && "$(_helm_chart_yaml_field "$_HELM_STAGED_CHART" version)" != "$_HELM_VERSION" ]]; then
        rm -rf "$_HELM_STAGING"
        log_error "pulled chart version mismatch: $_HELM_CHART $_HELM_VERSION"
        return 1
    fi
    if [[ -e "$_HELM_CACHE_DIR/$_HELM_CHART" ]]; then
        if ! mv "$_HELM_CACHE_DIR/$_HELM_CHART" "$_HELM_BACKUP"; then
            rm -rf "$_HELM_STAGING"
            log_error "failed to stage old chart cache: $_HELM_CACHE_DIR/$_HELM_CHART"
            return 1
        fi
    fi
    if ! mv "$_HELM_STAGED_CHART" "$_HELM_CACHE_DIR/$_HELM_CHART"; then
        if [[ -e "$_HELM_BACKUP" ]] && ! mv "$_HELM_BACKUP" "$_HELM_CACHE_DIR/$_HELM_CHART"; then
            log_error "failed to restore chart cache; previous chart preserved at $_HELM_BACKUP"
            return 1
        fi
        rm -rf "$_HELM_STAGING"
        log_error "failed to publish cached chart: $_HELM_CACHE_DIR/$_HELM_CHART"
        return 1
    fi
    rm -rf "$_HELM_STAGING"
}
