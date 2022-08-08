#!/bin/bash

set -e
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../../scripts/deploy/paths.sh"
source "$DEPLOY_ROOT/scripts/deploy/install-mode.sh"
source "$DEPLOY_ROOT/scripts/deploy/values.sh"
source "$DEPLOY_LIB_DIR/liblog.sh"
source "$DEPLOY_LIB_DIR/libprompt.sh"
source "$DEPLOY_LIB_DIR/libkubernetes.sh"
source "$DEPLOY_LIB_DIR/libhelm.sh"
source "$DEPLOY_ROOT/parameter.sh"
cd "$SCRIPT_DIR"

NS=rustdesk
INSTALL_MODE="${1:-full}"
deploy_validate_mode "$INSTALL_MODE" rustdesk-relay

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
kube_secret_load "$NS" "rustdesk-custom-image" \
    image-repository=RUSTDESK_IMAGE_REPOSITORY
if deploy_mode_enabled "$INSTALL_MODE" rustdesk-relay; then
    DEFAULT_RUSTDESK_IMAGE_VERSION=$(get_latest_rustdesk_server_pro_version)
    RUSTDESK_IMAGE_VERSION=$(prompt_with_default "" "rustdesk image version" "$DEFAULT_RUSTDESK_IMAGE_VERSION")
    [ -n "$RUSTDESK_IMAGE_REPOSITORY" ] || RUSTDESK_IMAGE_REPOSITORY="hub.bin.$DOMAIN/$BRAND_PREFIX/remote-desktop"
fi
deploy_render_values values-*.yaml

# install rustdesk server relay
#####################################
if deploy_mode_enabled "$INSTALL_MODE" rustdesk-relay; then
    log_header "install rustdesk server relay"
    helm_ensure_chart "bjw-s" "https://bjw-s-labs.github.io/helm-charts" "app-template" "temp" "$COMMON_CHART_VERSION"
    helm upgrade --install -n $NS rustdesk-relay temp/app-template --wait --timeout 600s -f temp/values-rustdesk-relay.yaml
fi

## done
log_trace "install rustdesk-relay success!!!"
