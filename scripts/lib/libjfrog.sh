#!/bin/bash
## libjfrog.sh — Artifactory (JFrog) 客户端公共库。
## 依赖：curl、jq（调用对应能力时才需要）、同目录 liblog.sh。
##
## 约定：
##   - 公共函数全部使用显式参数：第一个参数是含 /artifactory 后缀的 endpoint
##     （例如 https://bin.example.test/artifactory），第二个是 bearer token，
##     第三个是仓库相对路径（repo/dir/file），之后是操作参数和可选的超时秒数
##     （默认 _JFROG_DEFAULT_TIMEOUT；目录 API 使用 --timeout）。不读取项目配置。
##   - 认证请求只发往校验过的 https endpoint，从不跟随重定向；token 只出现在
##     Authorization 头里，绝不进入日志输出。
##   - 仓库路径逐段 percent-encode；绝对路径、空段、`.`/`..` 穿越段、反斜杠、
##     双斜杠和控制字符在任何网络请求之前就被拒绝。
##   - 元数据（/api/storage）查询失败时（403/302/5xx、网络错误、非法 JSON）
##     上传和下载直接失败，绝不带着前序错误继续写远端；只有明确的 404 才表示
##     “远端尚无此文件”，允许继续上传。元数据成功但没有发布 checksum 时，
##     按“无法确认一致”处理，照常传输。
##   - checksum 只有在能确认一致时才允许跳过传输。下载先写入同目录临时文件，
##     校验通过后原子替换，失败时保留原有本地文件。空文件是合法制品，
##     是否拒绝空文件由调用方（业务层）决定。
##   - source 本文件只定义函数和常量：不改变 shell 选项、cwd、trap，不联网。
##
## 返回值：0 成功；非 0 失败（已经 log_error）。唯一的三态例外是
## jfrog_exists：0 存在、1 仅有 HTTP 404、2 其他错误（认证、权限、服务端、
## 重定向、网络或参数非法）；调用者必须显式区分三种状态。
##
## 内部局部变量统一使用 _JFROG 前缀。每次调用的请求上下文
## （_JFROG_ENDPOINT / _JFROG_ENCODED_PATH / _JFROG_TIMEOUT /
## _JFROG_HTTP_STATUS）由公共函数用 local 声明后借 Bash 动态作用域向下传递，
## 内部函数对它们的赋值只落在当次调用的局部变量上，模块不修改任何全局状态。

if [[ -n "${_LIB_JFROG_SOURCED:-}" ]]; then
    return 0
fi
if ! source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/liblog.sh"; then
    return 1
fi
_LIB_JFROG_SOURCED=1

## 未显式传超时时的默认请求超时（秒）。
_JFROG_DEFAULT_TIMEOUT=120
## /api/storage 响应的公共 jq 校验：必须是 repo/uri 都是字符串、且不含
## errors 字段的对象；`{}`、数组、字符串和 Artifactory 错误文档都不通过。
_JFROG_STAT_VALIDATOR='(.errors? // null) == null and (.repo | type == "string") and (.uri | type == "string")'

## function _jfrog_url_encode. 对单个路径段或属性键值做 percent-encode。
## RFC 3986 未保留集合 [A-Za-z0-9._~-] 之外的每个字符（按字节，LC_ALL=C）
## 都编码为 %XX，路径段无法夹带 '/'、'?'、'#'、'%' 等 URL 结构字符。
## $1: 待编码字符串
## stdout: 编码结果
function _jfrog_url_encode() {
    local LC_ALL=C
    local _JFROG_VALUE="$1"
    local _JFROG_RESULT=""
    local _JFROG_INDEX
    local _JFROG_CHAR
    local _JFROG_CODE
    for ((_JFROG_INDEX = 0; _JFROG_INDEX < ${#_JFROG_VALUE}; _JFROG_INDEX++)); do
        _JFROG_CHAR="${_JFROG_VALUE:_JFROG_INDEX:1}"
        if [[ "$_JFROG_CHAR" =~ ^[A-Za-z0-9._~-]$ ]]; then
            _JFROG_RESULT+="$_JFROG_CHAR"
        else
            _JFROG_CODE=$(printf '%02X' "'$_JFROG_CHAR")
            _JFROG_RESULT+="%$_JFROG_CODE"
        fi
    done
    printf '%s' "$_JFROG_RESULT"
}

## function _jfrog_validate_endpoint. 校验 endpoint 并输出规范化结果。
## 去掉末尾 '/'；只接受 https://host[:port]/artifactory。认证请求只会
## 发往这个精确地址。
## $1: endpoint
## stdout: 规范化后的 endpoint
## return: 0 合法；1 非法
function _jfrog_validate_endpoint() {
    local _JFROG_ENDPOINT="${1%/}"
    if [[ ! "$_JFROG_ENDPOINT" =~ ^https://[a-zA-Z0-9.-]+(:[0-9]+)?/artifactory$ ]]; then
        log_error "invalid Artifactory endpoint, expected https://host[:port]/artifactory"
        return 1
    fi
    printf '%s' "$_JFROG_ENDPOINT"
}

## function _jfrog_encode_repo_path. 校验仓库相对路径并输出编码后的 URL 路径。
## 拒绝空路径、首尾 '/'、空段（含双斜杠）、`.`/`..` 段、反斜杠和控制字符。
## $1: repo/dir/file 形式的路径
## stdout: 逐段 percent-encode 后的路径
## return: 0 合法；1 非法
function _jfrog_encode_repo_path() {
    local _JFROG_PATH="$1"
    local _JFROG_OLD_IFS="$IFS"
    local -a _JFROG_SEGMENTS=()
    local _JFROG_SEGMENT
    local _JFROG_RESULT=""
    if [[ -z "$_JFROG_PATH" || "$_JFROG_PATH" == /* || "$_JFROG_PATH" == */ ||
        "$_JFROG_PATH" == *//* || "$_JFROG_PATH" =~ [[:cntrl:]] || "$_JFROG_PATH" =~ \\ ]]; then
        log_error "invalid repository path: $_JFROG_PATH"
        return 1
    fi
    IFS='/'
    read -r -a _JFROG_SEGMENTS <<<"$_JFROG_PATH"
    IFS="$_JFROG_OLD_IFS"
    for _JFROG_SEGMENT in "${_JFROG_SEGMENTS[@]}"; do
        if [[ -z "$_JFROG_SEGMENT" || "$_JFROG_SEGMENT" == "." || "$_JFROG_SEGMENT" == ".." ]]; then
            log_error "invalid repository path segment in: $_JFROG_PATH"
            return 1
        fi
        _JFROG_RESULT+="${_JFROG_RESULT:+/}$(_jfrog_url_encode "$_JFROG_SEGMENT")"
    done
    printf '%s' "$_JFROG_RESULT"
}

## function _jfrog_prepare. 公共函数共用的参数准备：$1 endpoint、$2 仓库路径、
## 可选 $3 超时。结果写入调用方用 local 声明的动态作用域变量
## _JFROG_ENDPOINT / _JFROG_ENCODED_PATH / _JFROG_TIMEOUT（见文件头说明）；
## 任何参数非法都在联网前失败。
function _jfrog_prepare() {
    _JFROG_ENDPOINT=$(_jfrog_validate_endpoint "$1") || return 1
    _JFROG_ENCODED_PATH=$(_jfrog_encode_repo_path "$2") || return 1
    _JFROG_TIMEOUT="${3:-$_JFROG_DEFAULT_TIMEOUT}"
    if [[ ! "$_JFROG_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
        log_error "timeout must be a positive integer, got: $_JFROG_TIMEOUT"
        return 1
    fi
}

## function _jfrog_request. 内部统一的单次认证请求。
## 不跟随重定向：3xx 按非 2xx 处理，凭据永远不会离开配置的 endpoint。
## HTTP 状态写入调用链的动态局部变量 _JFROG_HTTP_STATUS（请求前先清空，
## 网络失败不会残留上一次的状态）。
## $1: 响应输出文件；$2: HTTP 方法；$3: 超时秒；$4: token；$5: URL
## $@: 透传给 curl 的额外参数
## return: 0 HTTP 2xx；1 服务端返回非 2xx；2 网络或传输失败
function _jfrog_request() {
    local _JFROG_OUTPUT="$1"
    local _JFROG_METHOD="$2"
    local _JFROG_REQ_TIMEOUT="$3"
    local _JFROG_TOKEN="$4"
    local _JFROG_URL="$5"
    shift 5
    local _JFROG_STATUS=""
    local -a _JFROG_CURL_ARGS=(--silent --show-error --max-time "$_JFROG_REQ_TIMEOUT")
    if [[ "$_JFROG_METHOD" == "HEAD" ]]; then
        _JFROG_CURL_ARGS+=(--head)
    else
        _JFROG_CURL_ARGS+=(-X "$_JFROG_METHOD")
    fi
    _JFROG_CURL_ARGS+=(-H "Authorization: Bearer $_JFROG_TOKEN" -o "$_JFROG_OUTPUT" -w '%{http_code}' "$@")
    _JFROG_CURL_ARGS+=("$_JFROG_URL")
    _JFROG_HTTP_STATUS=""
    _JFROG_STATUS=$(curl "${_JFROG_CURL_ARGS[@]}") || return 2
    _JFROG_HTTP_STATUS="$_JFROG_STATUS"
    [[ "$_JFROG_STATUS" =~ ^2[0-9][0-9]$ ]] || return 1
    return 0
}

## function _jfrog_log_failure. 记录请求失败，绝不包含凭据。
## $1: 失败描述
function _jfrog_log_failure() {
    local _JFROG_WHAT="$1"
    if [[ "$_JFROG_HTTP_STATUS" =~ ^3 ]]; then
        log_error "$_JFROG_WHAT failed: HTTP $_JFROG_HTTP_STATUS, redirect refused (credentials never follow redirects)"
    elif [[ -n "$_JFROG_HTTP_STATUS" ]]; then
        log_error "$_JFROG_WHAT failed: HTTP $_JFROG_HTTP_STATUS"
    else
        log_error "$_JFROG_WHAT failed: network or transfer error"
    fi
}

## function _jfrog_request_json. GET 一份 /api/storage JSON，用 $2 的 jq
## 表达式校验后输出。非 2xx、非法 JSON、Artifactory 错误文档都是失败，
## 绝不把错误响应当成空结果。
## $1: URL；$2: jq 校验表达式；$3: token；[$4: true 时明确 404 返回 3]
## stdout: 校验通过的 JSON 文档
function _jfrog_request_json() {
    local _JFROG_URL="$1"
    local _JFROG_VALIDATOR="$2"
    local _JFROG_TOKEN="$3"
    local _JFROG_BODY_FILE=""
    local _JFROG_BODY=""
    _JFROG_BODY_FILE=$(mktemp) || return 1
    if ! _jfrog_request "$_JFROG_BODY_FILE" GET "$_JFROG_TIMEOUT" "$_JFROG_TOKEN" "$_JFROG_URL"; then
        rm -f "$_JFROG_BODY_FILE"
        if [ "${4:-false}" = true ] && [ "$_JFROG_HTTP_STATUS" = 404 ]; then
            return 3
        fi
        _jfrog_log_failure "metadata request for $_JFROG_ENCODED_PATH"
        return 1
    fi
    if ! jq -e "$_JFROG_VALIDATOR" "$_JFROG_BODY_FILE" >/dev/null; then
        log_error "Artifactory returned invalid metadata JSON for $_JFROG_ENCODED_PATH"
        rm -f "$_JFROG_BODY_FILE"
        return 1
    fi
    _JFROG_BODY=$(cat "$_JFROG_BODY_FILE")
    rm -f "$_JFROG_BODY_FILE"
    printf '%s\n' "$_JFROG_BODY"
}

## function jfrog_exists. 检查制品是否存在。
## $1: endpoint；$2: token；$3: 仓库相对路径；[$4: 超时秒]
## return: 0 存在；1 仅有 HTTP 404；2 其他错误（认证、权限、服务端、
##         重定向、网络或参数非法）
function jfrog_exists() {
    local _JFROG_ENDPOINT="" _JFROG_ENCODED_PATH="" _JFROG_TIMEOUT="" _JFROG_HTTP_STATUS=""
    if [[ $# -lt 3 ]]; then
        log_error "usage: jfrog_exists ENDPOINT TOKEN PATH [TIMEOUT]"
        return 2
    fi
    _jfrog_prepare "$1" "$3" "${4:-}" || return 2
    local _JFROG_RC=0
    _jfrog_request /dev/null HEAD "$_JFROG_TIMEOUT" "$2" "$_JFROG_ENDPOINT/$_JFROG_ENCODED_PATH" || _JFROG_RC=$?
    if [[ "$_JFROG_RC" -eq 0 ]]; then
        return 0
    fi
    if [[ "$_JFROG_RC" -eq 1 && "$_JFROG_HTTP_STATUS" == "404" ]]; then
        return 1
    fi
    _jfrog_log_failure "existence check for $_JFROG_ENCODED_PATH"
    return 2
}

## function jfrog_stat. 查询文件或目录的存储元数据。
## $1: endpoint；$2: token；$3: 仓库相对路径；[$4: 超时秒]
## stdout: 校验通过的元数据 JSON
## return: 0 成功；1 请求失败或响应非法
function jfrog_stat() {
    local _JFROG_ENDPOINT="" _JFROG_ENCODED_PATH="" _JFROG_TIMEOUT="" _JFROG_HTTP_STATUS=""
    if [[ $# -lt 3 ]]; then
        log_error "usage: jfrog_stat ENDPOINT TOKEN PATH [TIMEOUT]"
        return 1
    fi
    _jfrog_prepare "$1" "$3" "${4:-}" || return 1
    _jfrog_request_json "$_JFROG_ENDPOINT/api/storage/$_JFROG_ENCODED_PATH" "$_JFROG_STAT_VALIDATOR" "$2"
}

## function jfrog_list. 列出目录的直接子条目。
## 输出是 Artifactory child 对象的 JSON 数组（{uri, folder, ...}），文件名
## 不会被按空格拆分，消费方继续按 JSON 解析。每个条目的 uri 必须是字符串、
## folder 必须是布尔值；文件路径、错误响应或非法 JSON 都是失败，不是空目录。
## $1: endpoint；$2: token；$3: 仓库相对目录路径；[$4: 超时秒]
## stdout: child 对象 JSON 数组
## return: 0 成功；1 路径不是目录或请求失败
function jfrog_list() {
    local _JFROG_ENDPOINT="" _JFROG_ENCODED_PATH="" _JFROG_TIMEOUT="" _JFROG_HTTP_STATUS=""
    if [[ $# -lt 3 ]]; then
        log_error "usage: jfrog_list ENDPOINT TOKEN PATH [TIMEOUT]"
        return 1
    fi
    _jfrog_prepare "$1" "$3" "${4:-}" || return 1
    local _JFROG_DOC=""
    local _JFROG_CHILDREN=""
    _JFROG_DOC=$(_jfrog_request_json "$_JFROG_ENDPOINT/api/storage/$_JFROG_ENCODED_PATH" "$_JFROG_STAT_VALIDATOR" "$2") || return 1
    if ! _JFROG_CHILDREN=$(jq -c '
        if (.children | type) != "array" then error("path is not a folder")
        elif (all(.children[]; (.uri | type == "string") and (.folder | type == "boolean")) | not) then error("invalid child entries")
        else .children end' <<<"$_JFROG_DOC" 2>/dev/null); then
        log_error "Artifactory path has no valid folder listing: $_JFROG_ENCODED_PATH"
        return 1
    fi
    printf '%s\n' "$_JFROG_CHILDREN"
}

## function _jfrog_local_sha1. 计算本地文件 sha1。
function _jfrog_local_sha1() {
    sha1sum "$1" | awk '{print $1}'
}

## function _jfrog_remote_sha1. 从存储元数据读取远端 sha1。
## 直接调用 _jfrog_request（不经命令替换），这样 404 判断能读到请求链上
## 的动态局部 _JFROG_HTTP_STATUS。
## $1: token
## stdout: 远端 sha1；条目未发布 checksum 时为空
## return: 0 元数据可用；1 明确 HTTP 404（远端没有该条目）；
##         2 其他元数据错误（非 404 的已经 log_error）
function _jfrog_remote_sha1() {
    local _JFROG_TOKEN="$1"
    local _JFROG_BODY_FILE=""
    local _JFROG_SHA1=""
    _JFROG_BODY_FILE=$(mktemp) || return 2
    if ! _jfrog_request "$_JFROG_BODY_FILE" GET "$_JFROG_TIMEOUT" "$_JFROG_TOKEN" \
        "$_JFROG_ENDPOINT/api/storage/$_JFROG_ENCODED_PATH"; then
        rm -f "$_JFROG_BODY_FILE"
        if [[ "$_JFROG_HTTP_STATUS" == "404" ]]; then
            return 1
        fi
        _jfrog_log_failure "metadata request for $_JFROG_ENCODED_PATH"
        return 2
    fi
    if ! jq -e "$_JFROG_STAT_VALIDATOR" "$_JFROG_BODY_FILE" >/dev/null; then
        log_error "Artifactory returned invalid metadata JSON for $_JFROG_ENCODED_PATH"
        rm -f "$_JFROG_BODY_FILE"
        return 2
    fi
    _JFROG_SHA1=$(jq -r '.checksums.sha1 // ""' "$_JFROG_BODY_FILE")
    rm -f "$_JFROG_BODY_FILE"
    printf '%s' "$_JFROG_SHA1"
}

## function jfrog_upload. 上传本地文件到指定路径。
## 远端已存在且 sha1 一致时跳过传输；明确 404 时照常上传；其他元数据错误
## （403/302/5xx、网络、非法 JSON）直接失败，不带着前序错误写远端。
## 元数据成功但没有 checksum 时按无法确认处理，照常上传。空文件是合法制品。
## 普通 PUT 携带本地 SHA-1 / SHA-256 摘要供服务端校验；调用者须保证源文件
## 从计算摘要到上传结束保持不变。摘要相同时仍跳过，不回填历史制品的上传者摘要。
## $1: endpoint；$2: token；$3: 目标仓库路径；$4: 本地文件；[$5: 超时秒]
## return: 0 上传成功或确认已一致；1 参数、源文件或请求失败
function jfrog_upload() {
    local _JFROG_ENDPOINT="" _JFROG_ENCODED_PATH="" _JFROG_TIMEOUT="" _JFROG_HTTP_STATUS=""
    if [[ $# -lt 4 ]]; then
        log_error "usage: jfrog_upload ENDPOINT TOKEN PATH LOCAL_FILE [TIMEOUT]"
        return 1
    fi
    local _JFROG_LOCAL_FILE="$4"
    _jfrog_prepare "$1" "$3" "${5:-}" || return 1
    if [[ ! -f "$_JFROG_LOCAL_FILE" ]]; then
        log_error "upload source does not exist: $_JFROG_LOCAL_FILE"
        return 1
    fi
    local _JFROG_REMOTE_SHA1=""
    local _JFROG_STAT_RC=0
    _JFROG_REMOTE_SHA1=$(_jfrog_remote_sha1 "$2") || _JFROG_STAT_RC=$?
    if [[ "$_JFROG_STAT_RC" -eq 2 ]]; then
        return 1
    fi
    local _JFROG_SHA1=""
    local _JFROG_SHA256=""
    if ! _JFROG_SHA1=$(sha1sum <"$_JFROG_LOCAL_FILE"); then
        log_error "failed to calculate upload SHA-1: $_JFROG_LOCAL_FILE"
        return 1
    fi
    _JFROG_SHA1="${_JFROG_SHA1%% *}"
    if [[ ! "$_JFROG_SHA1" =~ ^[0-9a-f]{40}$ ]]; then
        log_error "invalid upload SHA-1: $_JFROG_LOCAL_FILE"
        return 1
    fi
    if [[ "$_JFROG_STAT_RC" -eq 0 && -n "$_JFROG_REMOTE_SHA1" ]] &&
        [[ "$_JFROG_SHA1" == "${_JFROG_REMOTE_SHA1,,}" ]]; then
        log_trace "remote checksum matches, skip upload: $_JFROG_ENCODED_PATH"
        return 0
    fi
    if ! _JFROG_SHA256=$(sha256sum <"$_JFROG_LOCAL_FILE"); then
        log_error "failed to calculate upload SHA-256: $_JFROG_LOCAL_FILE"
        return 1
    fi
    _JFROG_SHA256="${_JFROG_SHA256%% *}"
    if [[ ! "$_JFROG_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
        log_error "invalid upload SHA-256: $_JFROG_LOCAL_FILE"
        return 1
    fi
    if ! _jfrog_request /dev/null PUT "$_JFROG_TIMEOUT" "$2" \
        "$_JFROG_ENDPOINT/$_JFROG_ENCODED_PATH" \
        -H "X-Checksum-Sha1: $_JFROG_SHA1" \
        -H "X-Checksum-Sha256: $_JFROG_SHA256" \
        --upload-file "$_JFROG_LOCAL_FILE"; then
        _jfrog_log_failure "upload of $_JFROG_ENCODED_PATH"
        return 1
    fi
}

## function jfrog_download. 下载远端制品到本地文件。
## 本地文件已与远端发布的 sha1 一致时跳过传输。元数据查询失败（含 404）
## 直接失败；传输先写入同目录临时文件，成功且（服务端发布过 checksum 时）
## 校验一致后原子替换目标文件；任何失败都保留原有本地文件并清理临时文件。
## 目标目录必须已存在；空文件是合法制品。
## $1: endpoint；$2: token；$3: 仓库相对路径；$4: 本地文件；[$5: 超时秒]
## return: 0 下载成功或确认已一致；1 参数或请求失败
function jfrog_download() {
    local _JFROG_ENDPOINT="" _JFROG_ENCODED_PATH="" _JFROG_TIMEOUT="" _JFROG_HTTP_STATUS=""
    if [[ $# -lt 4 ]]; then
        log_error "usage: jfrog_download ENDPOINT TOKEN PATH LOCAL_FILE [TIMEOUT]"
        return 1
    fi
    local _JFROG_LOCAL_FILE="$4"
    _jfrog_prepare "$1" "$3" "${5:-}" || return 1
    local _JFROG_REMOTE_SHA1=""
    local _JFROG_STAT_RC=0
    _JFROG_REMOTE_SHA1=$(_jfrog_remote_sha1 "$2") || _JFROG_STAT_RC=$?
    if [[ "$_JFROG_STAT_RC" -eq 1 ]]; then
        log_error "remote item does not exist: $_JFROG_ENCODED_PATH"
        return 1
    fi
    if [[ "$_JFROG_STAT_RC" -eq 2 ]]; then
        return 1
    fi
    if [[ -n "$_JFROG_REMOTE_SHA1" ]] && [[ -f "$_JFROG_LOCAL_FILE" ]] &&
        [[ "$(_jfrog_local_sha1 "$_JFROG_LOCAL_FILE")" == "${_JFROG_REMOTE_SHA1,,}" ]]; then
        log_trace "local checksum matches remote, skip download: $_JFROG_LOCAL_FILE"
        return 0
    fi
    local _JFROG_TMP_FILE=""
    _JFROG_TMP_FILE=$(mktemp "${_JFROG_LOCAL_FILE}.jfrog-download.XXXXXX") || return 1
    if ! _jfrog_request "$_JFROG_TMP_FILE" GET "$_JFROG_TIMEOUT" "$2" \
        "$_JFROG_ENDPOINT/$_JFROG_ENCODED_PATH"; then
        _jfrog_log_failure "download of $_JFROG_ENCODED_PATH"
        rm -f "$_JFROG_TMP_FILE"
        return 1
    fi
    if [[ -n "$_JFROG_REMOTE_SHA1" ]] &&
        [[ "$(_jfrog_local_sha1 "$_JFROG_TMP_FILE")" != "${_JFROG_REMOTE_SHA1,,}" ]]; then
        log_error "checksum mismatch after downloading $_JFROG_ENCODED_PATH"
        rm -f "$_JFROG_TMP_FILE"
        return 1
    fi
    if ! mv -f "$_JFROG_TMP_FILE" "$_JFROG_LOCAL_FILE"; then
        rm -f "$_JFROG_TMP_FILE"
        return 1
    fi
}

## 目录操作的清单格式：类型（f/d）、TAB、相对路径。路径先验证，禁止控制
## 字符，所以可以安全按行读取；不按空格拆分，不通过 eval 解析。
## $1: 本地绝对路径；$2: 期望类型 f/d；$3: 是否允许尚不存在
function _jfrog_dir_check_local() {
    local _JFROG_CHECK_PATH="$1"
    local _JFROG_CHECK_TYPE="$2"
    local _JFROG_CHECK_MISSING="$3"
    local _JFROG_CHECK_PART="" _JFROG_CHECK_CURRENT=""
    local -a _JFROG_CHECK_PARTS=()
    IFS=/ read -r -a _JFROG_CHECK_PARTS <<<"${_JFROG_CHECK_PATH#/}"
    for _JFROG_CHECK_PART in "${_JFROG_CHECK_PARTS[@]}"; do
        _JFROG_CHECK_CURRENT+="/$_JFROG_CHECK_PART"
        if [ -L "$_JFROG_CHECK_CURRENT" ]; then
            log_error "directory transfer refuses symlink: $_JFROG_CHECK_CURRENT"
            return 1
        fi
        if [ ! -e "$_JFROG_CHECK_CURRENT" ]; then
            if [ "$_JFROG_CHECK_MISSING" = true ]; then
                continue
            fi
        elif [[ "$_JFROG_CHECK_CURRENT" != "$_JFROG_CHECK_PATH" || "$_JFROG_CHECK_TYPE" == d ]]; then
            [ -d "$_JFROG_CHECK_CURRENT" ] && continue
        elif [ -f "$_JFROG_CHECK_CURRENT" ]; then
            continue
        fi
        log_error "missing or incompatible local path: $_JFROG_CHECK_CURRENT"
        return 1
    done
}

## find 不跟随链接，枚举状态先检查，再读取 NUL 分隔结果。目录及文件都进
## 清单，用于在传输前发现类型冲突；过滤只作用于传输和清理，不隐藏扫描错误。
## $1: 本地根目录；$2: 是否递归
function _jfrog_dir_scan_local() {
    local _JFROG_SCAN_ROOT="$1" _JFROG_SCAN_RECURSIVE="$2"
    local _JFROG_SCAN_FILE="" _JFROG_SCAN_ENTRY="" _JFROG_SCAN_REL=""
    local _JFROG_SCAN_RC=0
    local -a _JFROG_FIND_ARGS=("$_JFROG_SCAN_ROOT" -mindepth 1)
    [ -d "$_JFROG_SCAN_ROOT" ] || return 0
    if [ "$_JFROG_SCAN_RECURSIVE" != true ]; then
        _JFROG_FIND_ARGS+=(-maxdepth 1)
    fi
    _JFROG_SCAN_FILE=$(mktemp) || return 1
    if ! find "${_JFROG_FIND_ARGS[@]}" -print0 >"$_JFROG_SCAN_FILE"; then
        log_error "failed to scan local directory: $_JFROG_SCAN_ROOT"
        rm -f -- "$_JFROG_SCAN_FILE"
        return 1
    fi
    while IFS= read -r -d '' _JFROG_SCAN_ENTRY; do
        _JFROG_SCAN_REL="${_JFROG_SCAN_ENTRY#"$_JFROG_SCAN_ROOT"/}"
        if ! _jfrog_encode_repo_path "$_JFROG_SCAN_REL" >/dev/null; then
            _JFROG_SCAN_RC=1
            break
        fi
        if [ -L "$_JFROG_SCAN_ENTRY" ]; then
            log_error "directory transfer refuses symlink: $_JFROG_SCAN_ENTRY"
            _JFROG_SCAN_RC=1
            break
        elif [ -d "$_JFROG_SCAN_ENTRY" ]; then
            printf 'd\t%s\n' "$_JFROG_SCAN_REL"
        elif [ -f "$_JFROG_SCAN_ENTRY" ]; then
            printf 'f\t%s\n' "$_JFROG_SCAN_REL"
        else
            log_error "directory transfer requires regular files: $_JFROG_SCAN_ENTRY"
            _JFROG_SCAN_RC=1
            break
        fi
    done <"$_JFROG_SCAN_FILE"
    rm -f -- "$_JFROG_SCAN_FILE"
    return "$_JFROG_SCAN_RC"
}

## $1 endpoint；$2 token；$3 远端目录；$4 是否递归；$5 超时；
## $6 是否允许根目录 404；$7 清单相对路径前缀（递归内部参数）。
function _jfrog_dir_scan_remote() {
    local _JFROG_ENDPOINT="" _JFROG_ENCODED_PATH="" _JFROG_TIMEOUT="" _JFROG_HTTP_STATUS=""
    local _JFROG_SCAN_DOC="" _JFROG_SCAN_ROWS="" _JFROG_SCAN_TYPE="" _JFROG_SCAN_NAME=""
    local _JFROG_SCAN_PREFIX="${7:-}" _JFROG_SCAN_RC=0
    _jfrog_prepare "$1" "$3" "$5" || return 1
    _JFROG_SCAN_DOC=$(_jfrog_request_json "$_JFROG_ENDPOINT/api/storage/$_JFROG_ENCODED_PATH" \
        "$_JFROG_STAT_VALIDATOR" "$2" "$6") || _JFROG_SCAN_RC=$?
    if [ "$_JFROG_SCAN_RC" -eq 3 ]; then
        return 0
    elif [ "$_JFROG_SCAN_RC" -ne 0 ]; then
        return 1
    fi
    if ! _JFROG_SCAN_ROWS=$(jq -sr '
        (if length == 1 then .[0] else error("expected one listing document") end) |
        if (.children | type) != "array" then error("not a directory")
        elif (all(.children[];
            (.uri | type == "string") and (.folder | type == "boolean") and
            (.uri | startswith("/")) and
            (.uri[1:] | length > 0 and (contains("/") | not) and
                (contains("\\") | not) and . != "." and . != ".." and
                (explode | all(. >= 32 and . != 127)))) | not)
            then error("invalid child path")
        elif ([.children[].uri] | length != (unique | length)) then error("duplicate child")
        else .children[] | (if .folder then "d" else "f" end) + "\t" + .uri[1:] end
        ' <<<"$_JFROG_SCAN_DOC" 2>/dev/null); then
        log_error "invalid directory listing: $_JFROG_ENCODED_PATH"
        return 1
    fi
    while IFS=$'\t' read -r _JFROG_SCAN_TYPE _JFROG_SCAN_NAME; do
        [ -n "$_JFROG_SCAN_TYPE" ] || continue
        _jfrog_encode_repo_path "$_JFROG_SCAN_NAME" >/dev/null || return 1
        printf '%s\t%s%s\n' "$_JFROG_SCAN_TYPE" "$_JFROG_SCAN_PREFIX" "$_JFROG_SCAN_NAME"
        if [[ "$_JFROG_SCAN_TYPE" == d && "$4" == true ]]; then
            _jfrog_dir_scan_remote "$1" "$2" "$3/$_JFROG_SCAN_NAME" "$4" "$5" false \
                "$_JFROG_SCAN_PREFIX$_JFROG_SCAN_NAME/" || return 1
        fi
    done <<<"$_JFROG_SCAN_ROWS"
}

## 两个公开目录 API 共用的编排。先完成全部扫描/冲突检查，再传输，最后
## （仅 --delete）清理多余文件。失败不回滚已完成文件，但不继续清理。
function _jfrog_dir_transfer() {
    local _JFROG_DIRECTION="$1"
    shift
    if [ "$#" -lt 4 ]; then
        log_error "usage: jfrog_${_JFROG_DIRECTION}_dir ENDPOINT TOKEN REMOTE_DIR LOCAL_DIR [--recursive] [--delete] [--pattern GLOB] [--timeout SECONDS]"
        return 1
    fi
    local _JFROG_ENDPOINT="" _JFROG_ENCODED_PATH="" _JFROG_TIMEOUT="" _JFROG_HTTP_STATUS=""
    local _JFROG_DIR_ENDPOINT="$1" _JFROG_DIR_TOKEN="$2" _JFROG_DIR_REMOTE="$3" _JFROG_DIR_LOCAL="$4"
    local _JFROG_DIR_RECURSIVE=false _JFROG_DIR_DELETE=false _JFROG_DIR_PATTERN='*'
    local _JFROG_DIR_TIMEOUT="$_JFROG_DEFAULT_TIMEOUT"
    shift 4
    while [ "$#" -gt 0 ]; do
        case "$1" in
        --recursive) _JFROG_DIR_RECURSIVE=true; shift ;;
        --delete) _JFROG_DIR_DELETE=true; shift ;;
        --pattern | --timeout)
            if [[ "$#" -lt 2 || -z "$2" ]]; then
                log_error "missing value for directory transfer option: $1"
                return 1
            fi
            if [ "$1" = --pattern ]; then
                _JFROG_DIR_PATTERN="$2"
            else
                _JFROG_DIR_TIMEOUT="$2"
            fi
            shift 2
            ;;
        *) log_error "unknown directory transfer option: $1"; return 1 ;;
        esac
    done
    _jfrog_prepare "$_JFROG_DIR_ENDPOINT" "$_JFROG_DIR_REMOTE" "$_JFROG_DIR_TIMEOUT" || return 1
    if [[ "$_JFROG_DIR_PATTERN" == */* || "$_JFROG_DIR_PATTERN" =~ [[:cntrl:]] ||
        -z "$_JFROG_DIR_LOCAL" || "$_JFROG_DIR_LOCAL" =~ [[:cntrl:]] ]]; then
        log_error "invalid directory transfer pattern or local root"
        return 1
    fi
    # 逐分量检查根路径，不能先 realpath 消去 symlink 或 .. 后再检查。
    local _JFROG_DIR_ROOT="" _JFROG_DIR_PART=""
    local -a _JFROG_DIR_PARTS=()
    [[ "$_JFROG_DIR_LOCAL" == /* ]] || _JFROG_DIR_LOCAL="$PWD/$_JFROG_DIR_LOCAL"
    IFS=/ read -r -a _JFROG_DIR_PARTS <<<"$_JFROG_DIR_LOCAL"
    for _JFROG_DIR_PART in "${_JFROG_DIR_PARTS[@]}"; do
        [[ -z "$_JFROG_DIR_PART" || "$_JFROG_DIR_PART" == . ]] && continue
        if [ "$_JFROG_DIR_PART" = .. ]; then
            log_error "local directory root must not contain .."
            return 1
        fi
        _JFROG_DIR_ROOT+="/$_JFROG_DIR_PART"
    done
    if [ -z "$_JFROG_DIR_ROOT" ]; then
        log_error "filesystem root is not a directory transfer target"
        return 1
    fi
    _jfrog_dir_check_local "$_JFROG_DIR_ROOT" d "$([ "$_JFROG_DIRECTION" = download ] && printf true || printf false)" || return 1

    local _JFROG_DIR_LOCAL_ROWS="" _JFROG_DIR_REMOTE_ROWS=""
    _JFROG_DIR_LOCAL_ROWS=$(_jfrog_dir_scan_local "$_JFROG_DIR_ROOT" "$_JFROG_DIR_RECURSIVE") || return 1
    _JFROG_DIR_REMOTE_ROWS=$(_jfrog_dir_scan_remote "$_JFROG_DIR_ENDPOINT" "$_JFROG_DIR_TOKEN" \
        "$_JFROG_DIR_REMOTE" "$_JFROG_DIR_RECURSIVE" "$_JFROG_DIR_TIMEOUT" \
        "$([ "$_JFROG_DIRECTION" = upload ] && printf true || printf false)") || return 1
    local _JFROG_DIR_SOURCE_ROWS="$_JFROG_DIR_LOCAL_ROWS" _JFROG_DIR_TARGET_ROWS="$_JFROG_DIR_REMOTE_ROWS"
    if [ "$_JFROG_DIRECTION" = download ]; then
        _JFROG_DIR_SOURCE_ROWS="$_JFROG_DIR_REMOTE_ROWS"
        _JFROG_DIR_TARGET_ROWS="$_JFROG_DIR_LOCAL_ROWS"
    fi
    local -A _JFROG_DIR_SOURCE=()
    local _JFROG_DIR_TYPE="" _JFROG_DIR_REL="" _JFROG_DIR_BASE="" _JFROG_DIR_FILE=""
    while IFS=$'\t' read -r _JFROG_DIR_TYPE _JFROG_DIR_REL; do
        [ -n "$_JFROG_DIR_TYPE" ] || continue
        _JFROG_DIR_SOURCE["$_JFROG_DIR_REL"]="$_JFROG_DIR_TYPE"
    done <<<"$_JFROG_DIR_SOURCE_ROWS"
    while IFS=$'\t' read -r _JFROG_DIR_TYPE _JFROG_DIR_REL; do
        [ -n "$_JFROG_DIR_TYPE" ] || continue
        if [[ -n "${_JFROG_DIR_SOURCE["$_JFROG_DIR_REL"]:-}" &&
            "${_JFROG_DIR_SOURCE["$_JFROG_DIR_REL"]}" != "$_JFROG_DIR_TYPE" ]]; then
            log_error "file/directory conflict: $_JFROG_DIR_REL"
            return 1
        fi
    done <<<"$_JFROG_DIR_TARGET_ROWS"

    if [ "$_JFROG_DIRECTION" = download ]; then
        mkdir -p -- "$_JFROG_DIR_ROOT" || return 1
    fi
    while IFS=$'\t' read -r _JFROG_DIR_TYPE _JFROG_DIR_REL; do
        [ -n "$_JFROG_DIR_TYPE" ] || continue
        _JFROG_DIR_FILE="$_JFROG_DIR_ROOT/$_JFROG_DIR_REL"
        if [ "$_JFROG_DIR_TYPE" = d ]; then
            if [[ "$_JFROG_DIRECTION" == download && "$_JFROG_DIR_RECURSIVE" == true ]]; then
                _jfrog_dir_check_local "$_JFROG_DIR_FILE" d true || return 1
                mkdir -p -- "$_JFROG_DIR_FILE" || return 1
            fi
            continue
        fi
        _JFROG_DIR_BASE="${_JFROG_DIR_REL##*/}"
        # 右侧有意作为 glob，而非字面字符串。
        # shellcheck disable=SC2053
        [[ "${_JFROG_DIR_BASE,,}" == ${_JFROG_DIR_PATTERN,,} ]] || continue
        if [ "$_JFROG_DIRECTION" = download ]; then
            _jfrog_dir_check_local "$_JFROG_DIR_FILE" f true || return 1
            mkdir -p -- "${_JFROG_DIR_FILE%/*}" || return 1
            jfrog_download "$_JFROG_DIR_ENDPOINT" "$_JFROG_DIR_TOKEN" "$_JFROG_DIR_REMOTE/$_JFROG_DIR_REL" \
                "$_JFROG_DIR_FILE" "$_JFROG_DIR_TIMEOUT" || return 1
        else
            _jfrog_dir_check_local "$_JFROG_DIR_FILE" f false || return 1
            jfrog_upload "$_JFROG_DIR_ENDPOINT" "$_JFROG_DIR_TOKEN" "$_JFROG_DIR_REMOTE/$_JFROG_DIR_REL" \
                "$_JFROG_DIR_FILE" "$_JFROG_DIR_TIMEOUT" || return 1
        fi
    done <<<"$_JFROG_DIR_SOURCE_ROWS"

    [ "$_JFROG_DIR_DELETE" = true ] || return 0
    local _JFROG_DIR_STAT=""
    while IFS=$'\t' read -r _JFROG_DIR_TYPE _JFROG_DIR_REL; do
        [ "$_JFROG_DIR_TYPE" = f ] || continue
        [ -z "${_JFROG_DIR_SOURCE["$_JFROG_DIR_REL"]:-}" ] || continue
        _JFROG_DIR_BASE="${_JFROG_DIR_REL##*/}"
        # 右侧有意作为 glob，而非字面字符串。
        # shellcheck disable=SC2053
        [[ "${_JFROG_DIR_BASE,,}" == ${_JFROG_DIR_PATTERN,,} ]] || continue
        if [ "$_JFROG_DIRECTION" = download ]; then
            _jfrog_dir_check_local "$_JFROG_DIR_ROOT/$_JFROG_DIR_REL" f false || return 1
            rm -- "$_JFROG_DIR_ROOT/$_JFROG_DIR_REL" || return 1
        else
            # 删除前复查类型，避免已变成目录的路径触发远端递归删除。
            _JFROG_DIR_STAT=$(jfrog_stat "$_JFROG_DIR_ENDPOINT" "$_JFROG_DIR_TOKEN" \
                "$_JFROG_DIR_REMOTE/$_JFROG_DIR_REL" "$_JFROG_DIR_TIMEOUT") || return 1
            if ! jq -e 'has("children") | not' <<<"$_JFROG_DIR_STAT" >/dev/null; then
                log_error "refuse to delete changed remote directory: $_JFROG_DIR_REL"
                return 1
            fi
            jfrog_delete "$_JFROG_DIR_ENDPOINT" "$_JFROG_DIR_TOKEN" \
                "$_JFROG_DIR_REMOTE/$_JFROG_DIR_REL" "$_JFROG_DIR_TIMEOUT" || return 1
        fi
    done <<<"$_JFROG_DIR_TARGET_ROWS"
    return 0
}

## function jfrog_download_dir / jfrog_upload_dir.
## $1 endpoint；$2 token；$3 远端目录；$4 本地目录；其后为可选 flags：
## --recursive 保留目录树；--delete 完成后清理多余文件（不删目录）；
## --pattern GLOB 按 basename 忽略大小写匹配；--timeout SECONDS 每次请求超时。
## 默认只传输直接子文件、不删除。返回 0 成功、1 失败；无 stdout 数据。
## 调用期间源/目标目录须保持稳定；不提供整批事务或并发写入保护。
function jfrog_download_dir() {
    _jfrog_dir_transfer download "$@"
}

function jfrog_upload_dir() {
    _jfrog_dir_transfer upload "$@"
}

## function jfrog_get_properties. 读取条目属性，值保持 Artifactory 的字符串数组格式。
## properties API 的 404 可能表示没有属性，也可能是条目不存在，均输出空对象；
## 需要区分的调用方应先用 jfrog_exists 确认条目存在。其他请求/元数据错误失败。
## $1: endpoint；$2: token；$3: 仓库相对路径；[$4: 超时秒]
## stdout: 属性对象（无属性时为 {}）；return: 0 成功；1 参数、请求或响应非法
function jfrog_get_properties() {
    local _JFROG_ENDPOINT="" _JFROG_ENCODED_PATH="" _JFROG_TIMEOUT="" _JFROG_HTTP_STATUS=""
    if [[ $# -lt 3 ]]; then
        log_error "usage: jfrog_get_properties ENDPOINT TOKEN PATH [TIMEOUT]"
        return 1
    fi
    _jfrog_prepare "$1" "$3" "${4:-}" || return 1
    local _JFROG_DOC="" _JFROG_RC=0
    _JFROG_DOC=$(_jfrog_request_json "$_JFROG_ENDPOINT/api/storage/$_JFROG_ENCODED_PATH?properties" '
        type == "object" and (.errors? == null) and
        (.properties | type == "object" and all(.[]; type == "array" and all(.[]; type == "string")))
    ' "$2" true) || _JFROG_RC=$?
    if [ "$_JFROG_RC" -eq 3 ]; then
        printf '{}\n'
    elif [ "$_JFROG_RC" -ne 0 ]; then
        return 1
    else
        jq -c '.properties' <<<"$_JFROG_DOC" || return 1
    fi
}

## function jfrog_set_properties. 给指定条目设置属性。
## 键和值分别 percent-encode；Artifactory 的结构分隔符保持字面量：
## 键值对之间用 ';'，同一键的多个值才用 ','。因为尾部是 key=value 列表，
## 超时参数是必需的。
## $1: endpoint；$2: token；$3: 仓库相对路径；$4: 超时秒；$@: key=value...
## return: 0 成功；1 参数、映射或请求失败
function jfrog_set_properties() {
    local _JFROG_ENDPOINT="" _JFROG_ENCODED_PATH="" _JFROG_TIMEOUT="" _JFROG_HTTP_STATUS=""
    if [[ $# -lt 5 ]]; then
        log_error "usage: jfrog_set_properties ENDPOINT TOKEN PATH TIMEOUT key=value..."
        return 1
    fi
    local _JFROG_TOKEN="$2"
    _jfrog_prepare "$1" "$3" "$4" || return 1
    shift 4
    local _JFROG_PAIR
    local _JFROG_KEY
    local _JFROG_VALUE
    local _JFROG_PROPS=""
    for _JFROG_PAIR in "$@"; do
        _JFROG_KEY="${_JFROG_PAIR%%=*}"
        _JFROG_VALUE="${_JFROG_PAIR#*=}"
        if [[ "$_JFROG_PAIR" != *=* || -z "$_JFROG_KEY" ]]; then
            log_error "invalid property pair, expected key=value: $_JFROG_PAIR"
            return 1
        fi
        _JFROG_PROPS+="${_JFROG_PROPS:+;}$(_jfrog_url_encode "$_JFROG_KEY")=$(_jfrog_url_encode "$_JFROG_VALUE")"
    done
    if ! _jfrog_request /dev/null PUT "$_JFROG_TIMEOUT" "$_JFROG_TOKEN" \
        "$_JFROG_ENDPOINT/api/storage/$_JFROG_ENCODED_PATH?properties=$_JFROG_PROPS"; then
        _jfrog_log_failure "property update on $_JFROG_ENCODED_PATH"
        return 1
    fi
}

## function jfrog_move. 在 Artifactory 服务端移动条目，不下载/重新上传内容。
## 源、目标均为包含仓库名的完整条目路径，不带首尾 '/'；目标作为 to 查询值
## 编码一次。只执行 Move Item，不预删目标、不生成归档名、不清理其他条目；
## 已有目标的处理取决于服务端规则，需确定性覆盖时由调用者显式处理。
## 非 2xx、非法 JSON、空消息或非 INFO 消息均失败；失败不自动回滚或重试，
## 网络中断或部分移动后须由调用者检查服务端状态。
## $1: endpoint；$2: token；$3: 源仓库路径；$4: 目标仓库路径；[$5: 超时秒]
## return: 0 成功；1 参数、请求或响应校验失败；无 stdout 数据
function jfrog_move() {
    local _JFROG_ENDPOINT="" _JFROG_ENCODED_PATH="" _JFROG_TIMEOUT="" _JFROG_HTTP_STATUS=""
    if [[ $# -lt 4 ]]; then
        log_error "usage: jfrog_move ENDPOINT TOKEN SOURCE_PATH TARGET_PATH [TIMEOUT]"
        return 1
    fi
    local _JFROG_DESTINATION="" _JFROG_RESPONSE=""
    _jfrog_prepare "$1" "$3" "${5:-}" || return 1
    _jfrog_encode_repo_path "$4" >/dev/null || return 1
    _JFROG_DESTINATION=$(_jfrog_url_encode "/$4") || return 1
    _JFROG_RESPONSE=$(mktemp) || return 1
    if ! _jfrog_request "$_JFROG_RESPONSE" POST "$_JFROG_TIMEOUT" "$2" \
        "$_JFROG_ENDPOINT/api/move/$_JFROG_ENCODED_PATH?to=$_JFROG_DESTINATION&failFast=1"; then
        _jfrog_log_failure "move of $_JFROG_ENCODED_PATH"
        rm -f -- "$_JFROG_RESPONSE"
        return 1
    fi
    if ! jq -se 'length == 1 and (.[0] |
        type == "object" and (.errors? == null) and
        (.messages | type == "array" and length > 0 and
            all(.[]; .level == "INFO" and (.message | type == "string"))))' "$_JFROG_RESPONSE" >/dev/null; then
        log_error "Artifactory returned invalid or unsuccessful move response for $_JFROG_ENCODED_PATH"
        rm -f -- "$_JFROG_RESPONSE"
        return 1
    fi
    rm -f -- "$_JFROG_RESPONSE" || return 1
}

## function jfrog_delete. 删除指定路径的条目。
## 只删除显式传入的路径，不隐含目录同步或版本清理；任何非 2xx（含 404）
## 都是错误，调用方必须显式处理。
## $1: endpoint；$2: token；$3: 仓库相对路径；[$4: 超时秒]
## return: 0 成功；1 参数或请求失败
function jfrog_delete() {
    local _JFROG_ENDPOINT="" _JFROG_ENCODED_PATH="" _JFROG_TIMEOUT="" _JFROG_HTTP_STATUS=""
    if [[ $# -lt 3 ]]; then
        log_error "usage: jfrog_delete ENDPOINT TOKEN PATH [TIMEOUT]"
        return 1
    fi
    _jfrog_prepare "$1" "$3" "${4:-}" || return 1
    if ! _jfrog_request /dev/null DELETE "$_JFROG_TIMEOUT" "$2" "$_JFROG_ENDPOINT/$_JFROG_ENCODED_PATH"; then
        _jfrog_log_failure "delete of $_JFROG_ENCODED_PATH"
        return 1
    fi
}
