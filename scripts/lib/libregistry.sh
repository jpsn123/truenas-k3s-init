#!/bin/bash
## libregistry.sh — Docker registry / 镜像名公共库。
## 依赖：curl、jq、sort（调用对应能力时才需要）、同目录 liblog.sh。
##
## 约定：
##   - 不内置任何默认账户（如 JFrog anonymous）；需要认证时由调用者显式传入。
##   - registry_write_auth 只替换 CONFIG_DIR/config.json，不递归删除目录，
##     目录内其他文件保持不动。
##
## 内部局部变量统一使用 _REG 前缀。

if [[ -n "${_LIB_REGISTRY_SOURCED:-}" ]]; then
    return 0
fi
if ! source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/liblog.sh"; then
    return 1
fi
_LIB_REGISTRY_SOURCED=1

## function registry_host. 规范化 registry url 为镜像 registry host。
## 支持输入带 scheme 或 path 的地址，例如：
##   https://harbor.example.com/project -> harbor.example.com
##   http://registry.example.com:5000 -> registry.example.com:5000
##   registry.example.com/library -> registry.example.com
## 只做字符串规范化，不验证 registry 是否可访问。
## $1: registry url 或 host
## stdout: 不带 scheme 和 path 的 registry host
function registry_host() {
    local _REG_URL="$1"
    local _REG_HOST=""

    _REG_HOST="${_REG_URL#http://}"
    _REG_HOST="${_REG_HOST#https://}"
    _REG_HOST="${_REG_HOST%%/*}"
    printf '%s' "$_REG_HOST"
}

## function registry_strip_host. 去掉镜像名中的 registry host 前缀。
## 仅当第一个路径段看起来像 registry host 时才移除：包含 .、包含 :，
## 或等于 localhost。
## 示例：
##   harbor.example.com/library/curl -> library/curl
##   localhost:5000/library/curl -> library/curl
##   library/curl -> library/curl
## $1: image repository，建议不带 tag
## stdout: 去掉 registry host 后的 image repository
function registry_strip_host() {
    local _REG_IMAGE="$1"
    local _REG_FIRST="${_REG_IMAGE%%/*}"

    if [[ "$_REG_IMAGE" == */* && ( "$_REG_FIRST" == *.* || "$_REG_FIRST" == *:* || "$_REG_FIRST" == "localhost" ) ]]; then
        printf '%s' "${_REG_IMAGE#*/}"
    else
        printf '%s' "$_REG_IMAGE"
    fi
}

## function registry_latest_tag. 通过 Docker Registry HTTP API v2 查询最新匹配 tag。
## 默认 tag 模式匹配以数字开头的版本样式 tag；认证凭据可选，
## 不传用户名时不做隐式匿名认证。
## $1: full image repository without tag, e.g. hub.example.com/ns/app
## $2: tag regex, optional, 默认 ^[0-9][0-9A-Za-z._-]*$
## $3: registry username, optional
## $4: registry password 或 token, optional
## stdout: 按 sort -V 排序后的最新 tag
## return: 0 成功；1 仓库地址非法、请求失败、响应非法或没有匹配 tag
function registry_latest_tag() {
    local _REG_REPOSITORY="$1"
    local _REG_PATTERN="${2:-}"
    local _REG_USERNAME="${3:-}"
    local _REG_PASSWORD="${4:-}"
    local _REG_HOST=""
    local _REG_PATH=""
    local _REG_RESPONSE=""
    local _REG_TAG_LIST=""
    local _REG_TAGS=""
    local _REG_CURL_ARGS=()

    if [[ -z "$_REG_PATTERN" ]]; then
        _REG_PATTERN='^[0-9][0-9A-Za-z._-]*$'
    fi
    _REG_HOST=$(registry_host "$_REG_REPOSITORY")
    _REG_PATH="${_REG_REPOSITORY#http://}"
    _REG_PATH="${_REG_PATH#https://}"
    _REG_PATH="${_REG_PATH#"$_REG_HOST"/}"
    _REG_PATH="${_REG_PATH%:*}"
    if [[ -z "$_REG_HOST" || -z "$_REG_PATH" || "$_REG_HOST" == "$_REG_PATH" ]]; then
        log_error "invalid image repository: $_REG_REPOSITORY"
        return 1
    fi

    if [[ -n "$_REG_USERNAME" ]]; then
        _REG_CURL_ARGS+=(-u "$_REG_USERNAME:$_REG_PASSWORD")
    fi
    if ! _REG_RESPONSE=$(curl -fsSL "${_REG_CURL_ARGS[@]}" "https://$_REG_HOST/v2/$_REG_PATH/tags/list"); then
        log_error "failed to get image tags: $_REG_REPOSITORY"
        return 1
    fi
    if ! _REG_TAG_LIST=$(printf '%s' "$_REG_RESPONSE" | jq -r '.tags[]?'); then
        log_error "failed to parse image tags: $_REG_REPOSITORY"
        return 1
    fi
    _REG_TAGS=$(printf '%s\n' "$_REG_TAG_LIST" | grep -E "$_REG_PATTERN" || true)
    if [[ -z "$_REG_TAGS" ]]; then
        log_error "failed to match image tags: $_REG_REPOSITORY"
        return 1
    fi
    printf '%s\n' "$_REG_TAGS" | sort -V | tail -n 1
}

## function registry_write_auth. 写入 Docker CLI 兼容的 registry 认证配置。
## 供 buildctl / docker / crane 等客户端通过 DOCKER_CONFIG 读取凭据。
## 用 jq 编码，正确处理用户名、密码中的特殊字符；先写同目录临时文件，
## 再原子替换 CONFIG_DIR/config.json，目录内其他文件不受影响。
## 注意：本函数整体替换 config.json，不适合需要保留其他 registry
## 登录项的共享配置；REGISTRY_HOST 不要带 scheme 或 path。
## $1: docker config dir
## $2: registry host
## $3: registry username
## $4: registry password 或 token
## return: 0 成功；1 参数非法、目录创建或写入失败
function registry_write_auth() {
    local _REG_DIR="$1"
    local _REG_HOST="$2"
    local _REG_USERNAME="$3"
    local _REG_PASSWORD="$4"
    local _REG_AUTH=""
    local _REG_TEMP=""

    if [[ -z "$_REG_DIR" || -z "$_REG_HOST" ]]; then
        log_error "config dir and registry host are required"
        return 1
    fi
    if [[ "$_REG_HOST" == *"://"* || "$_REG_HOST" == */* ]]; then
        log_error "registry host must not contain scheme or path: $_REG_HOST"
        return 1
    fi
    mkdir -p "$_REG_DIR" || return 1

    if ! _REG_AUTH=$(printf '%s:%s' "$_REG_USERNAME" "$_REG_PASSWORD" | base64 | tr -d '\n'); then
        log_error "failed to encode registry credentials: $_REG_HOST"
        return 1
    fi
    _REG_TEMP=$(mktemp "$_REG_DIR/config.json.XXXXXX") || return 1
    if ! jq -n \
        --arg host "$_REG_HOST" \
        --arg username "$_REG_USERNAME" \
        --arg password "$_REG_PASSWORD" \
        --arg auth "$_REG_AUTH" \
        '{auths: {($host): {username: $username, password: $password, auth: $auth}}}' \
        >"$_REG_TEMP"; then
        rm -f "$_REG_TEMP"
        log_error "failed to render registry auth config: $_REG_DIR/config.json"
        return 1
    fi
    if ! chmod 600 "$_REG_TEMP"; then
        rm -f "$_REG_TEMP"
        log_error "failed to secure registry auth config: $_REG_DIR/config.json"
        return 1
    fi
    if ! mv -f "$_REG_TEMP" "$_REG_DIR/config.json"; then
        rm -f "$_REG_TEMP"
        log_error "failed to write registry auth config: $_REG_DIR/config.json"
        return 1
    fi
}
