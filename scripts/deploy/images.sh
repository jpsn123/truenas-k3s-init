#!/bin/bash
## scripts/deploy/images.sh — 本项目通过本机 K3s 运行时检查镜像可拉取性。
## 依赖：k3s CLI（调用时才需要）、paths.sh、liblog.sh。
##
## 内部局部变量统一使用 _K3S 前缀。

if [[ -n "${_JTZ_DEPLOY_IMAGES_SOURCED:-}" ]]; then
    return 0
fi
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/paths.sh" || return 1
source "$DEPLOY_LIB_DIR/liblog.sh" || return 1
_JTZ_DEPLOY_IMAGES_SOURCED=1

## function deploy_image_pull. 用本机 k3s 运行时检查镜像是否可拉取。
## 比本机 docker/crane 更贴近节点实际运行环境；传入用户名时使用
## `k3s crictl pull --creds username:password`。
## $1: full image name, including tag if needed
## $2: registry username, optional
## $3: registry password 或 token, optional
## stdout: none
## return: 0 镜像可拉取；非 0 k3s 缺失或拉取失败
function deploy_image_pull() {
    local _K3S_IMAGE="$1"
    local _K3S_USERNAME="${2:-}"
    local _K3S_PASSWORD="${3:-}"

    if ! command -v k3s >/dev/null 2>&1; then
        log_error "k3s is required to check image pullability: $_K3S_IMAGE"
        return 1
    fi

    if [[ -n "$_K3S_USERNAME" ]]; then
        k3s crictl pull --creds "$_K3S_USERNAME:$_K3S_PASSWORD" "$_K3S_IMAGE" >/dev/null 2>&1
    else
        k3s crictl pull "$_K3S_IMAGE" >/dev/null 2>&1
    fi
}
