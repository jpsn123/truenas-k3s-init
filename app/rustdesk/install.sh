#!/bin/bash

set -e
cd $(dirname $0)
source ../../common.sh
source ../../parameter.sh

NS=rustdesk
INSTALL_MODE="${1:-full}"
validate_install_mode "$INSTALL_MODE" rustdesk
trap 'rm -rf temp/rustdesk-docker-config' EXIT

# functions
function get_latest_rustdesk_server_pro_version() {
    local LATEST_VERSION=""

    LATEST_VERSION=$(curl -fsSL "https://api.github.com/repos/rustdesk/rustdesk-server-pro/tags?per_page=1" | grep '"name":' | head -n 1 | cut -d '"' -f 4)
    if [ -z "$LATEST_VERSION" ]; then
        log_error "failed to get latest rustdesk server pro version."
        return 1
    fi
    printf '%s' "$LATEST_VERSION"
}

# initial
#####################################
log_header "initial"
kubectl create namespace $NS 2>/dev/null || true
load_secret_vars "$NS" "rustdesk-custom-image" \
    use-custom-registry=RUSTDESK_USE_CUSTOM_REGISTRY \
    registry-url=RUSTDESK_REGISTRY_URL \
    registry-username=RUSTDESK_REGISTRY_USERNAME \
    registry-token=RUSTDESK_REGISTRY_TOKEN \
    buildkit-addr=RUSTDESK_BUILDKIT_ADDR \
    image-repository=RUSTDESK_IMAGE_REPOSITORY

if install_mode_enabled "$INSTALL_MODE" rustdesk; then
    if [ -z "$RUSTDESK_USE_CUSTOM_REGISTRY" ]; then
        RUSTDESK_USE_CUSTOM_REGISTRY=$(prompt_with_default "please select rustdesk custom registry config." "use custom registry? (y/n)" "n")
    fi
    if [[ "$RUSTDESK_USE_CUSTOM_REGISTRY" =~ ^[Yy]$ ]]; then
        RUSTDESK_USE_CUSTOM_REGISTRY=y
    else
        RUSTDESK_USE_CUSTOM_REGISTRY=n
    fi

    if [ "$RUSTDESK_USE_CUSTOM_REGISTRY" == "y" ]; then
        [ -n "$RUSTDESK_REGISTRY_URL" ] || RUSTDESK_REGISTRY_URL=$(prompt_with_default "please input rustdesk custom registry config." "registry url" "hub.bin.$DOMAIN")
        [ -n "$RUSTDESK_REGISTRY_USERNAME" ] || RUSTDESK_REGISTRY_USERNAME=$(prompt_required "" "registry username" "")
        [ -n "$RUSTDESK_REGISTRY_TOKEN" ] || RUSTDESK_REGISTRY_TOKEN=$(prompt_required "" "registry token" -s)
        [ -n "$RUSTDESK_BUILDKIT_ADDR" ] || RUSTDESK_BUILDKIT_ADDR=$(prompt_with_default "" "buildkit address" "tcp://buildkit.buildkit.svc.cluster.local:1234")
    else
        [ -n "$RUSTDESK_REGISTRY_URL" ] || RUSTDESK_REGISTRY_URL=$(prompt_with_default "please input rustdesk registry config." "registry url" "hub.bin.$DOMAIN")
        RUSTDESK_REGISTRY_USERNAME=""
        RUSTDESK_REGISTRY_TOKEN=""
        RUSTDESK_BUILDKIT_ADDR=""
    fi
    RUSTDESK_REGISTRY_HOST=$(normalize_registry_host "$RUSTDESK_REGISTRY_URL")

    RUSTDESK_IMAGE_PATH=$(strip_image_registry "$RUSTDESK_IMAGE_REPOSITORY")
    if [ -z "$RUSTDESK_IMAGE_PATH" ]; then
        RUSTDESK_IMAGE_PATH=$(prompt_with_default "please input rustdesk image config." "rustdesk image name" "$BRAND_PREFIX/remote-desktop")
    fi
    DEFAULT_RUSTDESK_IMAGE_VERSION=$(get_latest_rustdesk_server_pro_version)
    RUSTDESK_IMAGE_VERSION=$(prompt_with_default "" "rustdesk image version" "$DEFAULT_RUSTDESK_IMAGE_VERSION")
    RUSTDESK_IMAGE_REPOSITORY="$RUSTDESK_REGISTRY_HOST/${RUSTDESK_IMAGE_PATH#/}"
    RUSTDESK_FULL_IMAGE="$RUSTDESK_IMAGE_REPOSITORY:$RUSTDESK_IMAGE_VERSION"

    apply_secret_vars "$NS" "rustdesk-custom-image" \
        use-custom-registry=RUSTDESK_USE_CUSTOM_REGISTRY \
        registry-url=RUSTDESK_REGISTRY_URL \
        registry-username=RUSTDESK_REGISTRY_USERNAME \
        registry-token=RUSTDESK_REGISTRY_TOKEN \
        buildkit-addr=RUSTDESK_BUILDKIT_ADDR \
        image-repository=RUSTDESK_IMAGE_REPOSITORY
    if [ "$RUSTDESK_USE_CUSTOM_REGISTRY" == "y" ]; then
        apply_docker_registry_secret "$NS" "rustdesk-custom-registry" "$RUSTDESK_REGISTRY_HOST" "$RUSTDESK_REGISTRY_USERNAME" "$RUSTDESK_REGISTRY_TOKEN"
        write_docker_registry_auth_config "temp/rustdesk-docker-config" "$RUSTDESK_REGISTRY_HOST" "$RUSTDESK_REGISTRY_USERNAME" "$RUSTDESK_REGISTRY_TOKEN"
    fi
    if [ "$RUSTDESK_USE_CUSTOM_REGISTRY" == "y" ]; then
        if k3s_crictl_pull_image "$RUSTDESK_FULL_IMAGE" "$RUSTDESK_REGISTRY_USERNAME" "$RUSTDESK_REGISTRY_TOKEN"; then
            log_info "image is pullable: $RUSTDESK_FULL_IMAGE"
        else
            build_image_with_buildkit "image" "$RUSTDESK_FULL_IMAGE" "$RUSTDESK_BUILDKIT_ADDR" "temp/rustdesk-docker-config" "rustdesk/rustdesk-server-pro:$RUSTDESK_IMAGE_VERSION"
        fi
    elif k3s_crictl_pull_image "$RUSTDESK_FULL_IMAGE"; then
        log_info "image is pullable: $RUSTDESK_FULL_IMAGE"
    else
        log_error "image $RUSTDESK_FULL_IMAGE does not exist. please build it manually, then rerun this script."
        exit 1
    fi
fi
render_values_file_to_temp values-*.yaml

# install rustdesk server
#####################################
if install_mode_enabled "$INSTALL_MODE" rustdesk; then
    log_header "install rustdesk server"
    ensure_helm_repo_chart "bjw-s" "https://bjw-s-labs.github.io/helm-charts" "app-template" "$COMMON_CHART_VERSION"
    helm upgrade --install -n $NS rustdesk temp/app-template --wait --timeout 600s -f temp/values-rustdesk.yaml
fi

## done
log_trace "install rustdesk success!!!"
log_reminder "   run command to get public key:"
log_reminder "   kubectl -n $NS exec -it deployment/rustdesk-hbbs -- cat /root/id_ed25519.pub"
