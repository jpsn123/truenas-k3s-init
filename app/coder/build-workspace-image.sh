#!/bin/bash
set -e

cd "$(dirname "$0")"
source ../../common.sh
source ../../parameter.sh

NS=coder
DOCKER_CONFIG_DIR="temp/workspace-image-docker-config"
trap 'rm -rf "$DOCKER_CONFIG_DIR"' EXIT

function build_and_push_image() {
    local IMAGE="$1"
    local DOCKERFILE="$2"
    shift 2

    local BUILD_ARGS=()
    local PLATFORM_ARGS=()

    while [ "$#" -gt 0 ]; do
        BUILD_ARGS+=("--opt=build-arg:$1")
        shift
    done
    if [ -n "$PLATFORMS" ]; then
        PLATFORM_ARGS+=("--opt=platform=$PLATFORMS")
    fi

    ensure_buildctl_installed
    log_info "build image with buildkit: $IMAGE"
    DOCKER_CONFIG="$DOCKER_CONFIG_DIR" buildctl --addr="$BUILDKIT_ADDR" build \
        --progress=plain \
        --frontend=dockerfile.v0 \
        --local=context="workspace-image" \
        --local=dockerfile="workspace-image" \
        --opt=filename="$DOCKERFILE" \
        "${PLATFORM_ARGS[@]}" \
        "${BUILD_ARGS[@]}" \
        --output=type=image,name="$IMAGE",push=true
}

log_header "build coder workspace images"
kubectl create namespace "$NS" 2>/dev/null || true
load_secret_vars "$NS" "coder-workspace-image-registry" \
    registry-url=WORKSPACE_REGISTRY_URL \
    registry-username=WORKSPACE_REGISTRY_USERNAME \
    registry-token=WORKSPACE_REGISTRY_TOKEN
load_secret_vars "$NS" "coder-workspace-image-build" \
    config-version=BUILD_CONFIG_VERSION \
    buildkit-addr=BUILDKIT_ADDR \
    image-path=WORKSPACE_IMAGE_PATH \
    ubuntu-version=UBUNTU_VERSION \
    apt-mirror=APT_MIRROR \
    basic-tag=BASIC_TAG \
    cpp-tag=CPP_TAG \
    web-tag=WEB_TAG \
    platforms=PLATFORMS

[ -n "$WORKSPACE_REGISTRY_URL" ] || WORKSPACE_REGISTRY_URL=$(prompt_with_default "please input coder workspace image build config." "registry url" "hub.bin.$DOMAIN")
[ -n "$WORKSPACE_IMAGE_PATH" ] || WORKSPACE_IMAGE_PATH=$(prompt_with_default "" "image repository path" "$BRAND_PREFIX/coder-workspace")
[ -n "$WORKSPACE_REGISTRY_USERNAME" ] || WORKSPACE_REGISTRY_USERNAME=$(prompt_required "" "registry username" "")
[ -n "$WORKSPACE_REGISTRY_TOKEN" ] || WORKSPACE_REGISTRY_TOKEN=$(prompt_required "" "registry token" -s)
[ -n "$BUILDKIT_ADDR" ] || BUILDKIT_ADDR=$(prompt_with_default "" "buildkit address" "tcp://buildkit.$DOMAIN:1234")
if [ -z "$BUILD_CONFIG_VERSION" ]; then
    [ -n "$UBUNTU_VERSION" ] || UBUNTU_VERSION=$(prompt_with_default "" "ubuntu version" "24.04")
    [ -n "$APT_MIRROR" ] || APT_MIRROR=$(prompt_with_default "" "apt mirror, empty for Dockerfile default" "")
    [ -n "$BASIC_TAG" ] || BASIC_TAG=$(prompt_with_default "" "basic image tag" "basic")
    [ -n "$CPP_TAG" ] || CPP_TAG=$(prompt_with_default "" "cpp image tag" "cpp")
    [ -n "$WEB_TAG" ] || WEB_TAG=$(prompt_with_default "" "web image tag" "web")
    [ -n "$PLATFORMS" ] || PLATFORMS=$(prompt_with_default "" "platforms, empty for BuildKit default" "")
else
    [ -n "$UBUNTU_VERSION" ] || UBUNTU_VERSION=24.04
    [ -n "$BASIC_TAG" ] || BASIC_TAG=basic
    [ -n "$CPP_TAG" ] || CPP_TAG=cpp
    [ -n "$WEB_TAG" ] || WEB_TAG=web
fi
BUILD_CONFIG_VERSION=1

WORKSPACE_REGISTRY_HOST=$(normalize_registry_host "$WORKSPACE_REGISTRY_URL")
WORKSPACE_IMAGE_PATH=$(strip_image_registry "$WORKSPACE_IMAGE_PATH")
IMAGE_REPO="$WORKSPACE_REGISTRY_HOST/${WORKSPACE_IMAGE_PATH#/}"
BASIC_IMAGE="$IMAGE_REPO:$BASIC_TAG"
CPP_IMAGE="$IMAGE_REPO:$CPP_TAG"
WEB_IMAGE="$IMAGE_REPO:$WEB_TAG"

apply_secret_vars "$NS" "coder-workspace-image-registry" \
    registry-url=WORKSPACE_REGISTRY_URL \
    registry-username=WORKSPACE_REGISTRY_USERNAME \
    registry-token=WORKSPACE_REGISTRY_TOKEN
apply_secret_vars "$NS" "coder-workspace-image-build" \
    config-version=BUILD_CONFIG_VERSION \
    buildkit-addr=BUILDKIT_ADDR \
    image-path=WORKSPACE_IMAGE_PATH \
    ubuntu-version=UBUNTU_VERSION \
    apt-mirror=APT_MIRROR \
    basic-tag=BASIC_TAG \
    cpp-tag=CPP_TAG \
    web-tag=WEB_TAG \
    platforms=PLATFORMS
write_docker_registry_auth_config "$DOCKER_CONFIG_DIR" "$WORKSPACE_REGISTRY_HOST" "$WORKSPACE_REGISTRY_USERNAME" "$WORKSPACE_REGISTRY_TOKEN"

build_and_push_image "$BASIC_IMAGE" Dockerfile.basic \
    "UBUNTU_VERSION=$UBUNTU_VERSION" \
    "APT_MIRROR=$APT_MIRROR"

build_and_push_image "$CPP_IMAGE" Dockerfile.cpp \
    "BASIC_IMAGE=$BASIC_IMAGE"

build_and_push_image "$WEB_IMAGE" Dockerfile.web \
    "BASIC_IMAGE=$BASIC_IMAGE"

log_trace "workspace image build success."
log_reminder "   basic: $BASIC_IMAGE\n   cpp:   $CPP_IMAGE\n   web:   $WEB_IMAGE"
