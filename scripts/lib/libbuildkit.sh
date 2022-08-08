#!/bin/bash
## libbuildkit.sh — BuildKit 客户端安装与镜像构建公共库。
## 依赖：安装函数需要 curl、tar、install（Linux amd64/arm64）；
## 构建函数只需要 buildctl 与远端 BuildKit daemon，且不会隐式安装任何工具。
## 依赖：同目录 liblog.sh。
##
## 内部局部变量统一使用 _BUILDKIT 前缀。

if [[ -n "${_LIB_BUILDKIT_SOURCED:-}" ]]; then
    return 0
fi
if ! source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/liblog.sh"; then
    return 1
fi
_LIB_BUILDKIT_SOURCED=1

## function buildkit_ensure_client. 确保本机存在 buildctl 客户端，缺失时安装。
## 从 GitHub moby/buildkit release 下载（支持 linux amd64/arm64），
## 安装到 INSTALL_DIR/buildctl，需要调用者对安装目录有写权限。
## 这是显式的软件安装操作，不隐式修改 PATH。
## 已存在的 buildctl（PATH 上或 INSTALL_DIR 内）直接复用，不校验其版本；
## VERSION 只在需要安装时生效，接受 0.16.0 或 v0.16.0，缺省取 latest。
## $1: install dir, e.g. /usr/local/bin
## $2: buildkit version, optional
## return: 0 buildctl 已存在或安装成功；1 参数、架构、下载或安装失败
function buildkit_ensure_client() {
    local _BUILDKIT_INSTALL_DIR="$1"
    local _BUILDKIT_VERSION="${2:-}"
    local _BUILDKIT_ARCH=""
    local _BUILDKIT_API_URL=""
    local _BUILDKIT_RELEASE_JSON=""
    local _BUILDKIT_URL=""
    local _BUILDKIT_TEMP_DIR=""

    if [[ -z "$_BUILDKIT_INSTALL_DIR" ]]; then
        log_error "install dir is required for buildctl"
        return 1
    fi
    if command -v buildctl >/dev/null 2>&1 || [[ -x "$_BUILDKIT_INSTALL_DIR/buildctl" ]]; then
        return 0
    fi

    case "$(uname -m)" in
    x86_64)
        _BUILDKIT_ARCH=amd64
        ;;
    aarch64 | arm64)
        _BUILDKIT_ARCH=arm64
        ;;
    *)
        log_error "unsupported buildctl architecture: $(uname -m)"
        return 1
        ;;
    esac

    if [[ -n "$_BUILDKIT_VERSION" ]]; then
        _BUILDKIT_VERSION="${_BUILDKIT_VERSION#v}"
        _BUILDKIT_API_URL="https://api.github.com/repos/moby/buildkit/releases/tags/v$_BUILDKIT_VERSION"
    else
        _BUILDKIT_API_URL="https://api.github.com/repos/moby/buildkit/releases/latest"
    fi
    log_info "buildctl does not exist, install buildctl to $_BUILDKIT_INSTALL_DIR"
    if ! _BUILDKIT_RELEASE_JSON=$(curl -fsSL "$_BUILDKIT_API_URL"); then
        log_error "failed to query buildkit release: $_BUILDKIT_API_URL"
        return 1
    fi
    _BUILDKIT_URL=$(printf '%s' "$_BUILDKIT_RELEASE_JSON" | grep "browser_download_url.*linux-$_BUILDKIT_ARCH.tar.gz" | head -n 1 | cut -d '"' -f 4)
    if [[ -z "$_BUILDKIT_URL" ]]; then
        log_error "failed to get buildctl download url"
        return 1
    fi

    _BUILDKIT_TEMP_DIR=$(mktemp -d) || return 1
    if ! curl -fsSL "$_BUILDKIT_URL" -o "$_BUILDKIT_TEMP_DIR/buildkit.tar.gz"; then
        rm -rf "$_BUILDKIT_TEMP_DIR"
        log_error "failed to download buildctl: $_BUILDKIT_URL"
        return 1
    fi
    if ! tar -xzf "$_BUILDKIT_TEMP_DIR/buildkit.tar.gz" -C "$_BUILDKIT_TEMP_DIR" bin/buildctl; then
        rm -rf "$_BUILDKIT_TEMP_DIR"
        log_error "failed to extract buildctl"
        return 1
    fi
    if ! mkdir -p "$_BUILDKIT_INSTALL_DIR" || ! install -m 0755 "$_BUILDKIT_TEMP_DIR/bin/buildctl" "$_BUILDKIT_INSTALL_DIR/buildctl"; then
        rm -rf "$_BUILDKIT_TEMP_DIR"
        log_error "failed to install buildctl to $_BUILDKIT_INSTALL_DIR"
        return 1
    fi
    rm -rf "$_BUILDKIT_TEMP_DIR"
}

## function buildkit_build. 通过 buildctl 构建并推送镜像。
## 本函数只调用 buildctl，不安装客户端；调用者需先确保 buildctl 存在
## （例如 buildkit_ensure_client）。AUTH_DIR 作为 DOCKER_CONFIG 传给
## buildctl，用于向目标 registry 推送；可由 registry_write_auth 生成。
## $1: build context dir, 同时作为 dockerfile dir
## $2: full image name to push, including tag
## $3: buildkit address, e.g. tcp://buildkit.buildkit.svc.cluster.local:1234
## $4: docker config dir
## $5: BASE_IMAGE build arg, optional
## return: buildctl 的返回码；buildctl 缺失时返回 1
function buildkit_build() {
    local _BUILDKIT_CONTEXT="$1"
    local _BUILDKIT_IMAGE="$2"
    local _BUILDKIT_ADDR="$3"
    local _BUILDKIT_AUTH_DIR="$4"
    local _BUILDKIT_BASE_IMAGE="${5:-}"
    local _BUILDKIT_ARGS=()

    if ! command -v buildctl >/dev/null 2>&1; then
        log_error "buildctl not found, run buildkit_ensure_client first: $_BUILDKIT_IMAGE"
        return 1
    fi
    if [[ -n "$_BUILDKIT_BASE_IMAGE" ]]; then
        _BUILDKIT_ARGS+=(--opt=build-arg:BASE_IMAGE="$_BUILDKIT_BASE_IMAGE")
    fi

    log_info "build image with buildkit: $_BUILDKIT_IMAGE"
    DOCKER_CONFIG="$_BUILDKIT_AUTH_DIR" buildctl --addr="$_BUILDKIT_ADDR" build \
        --progress=plain \
        --frontend=dockerfile.v0 \
        --local=context="$_BUILDKIT_CONTEXT" \
        --local=dockerfile="$_BUILDKIT_CONTEXT" \
        "${_BUILDKIT_ARGS[@]}" \
        --output=type=image,name="$_BUILDKIT_IMAGE",push=true
}
