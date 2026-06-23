#!/bin/bash

set -e
cd $(dirname $0)
source ../../common.sh
source ../../parameter.sh

NS=rustdesk
INSTALL_MODE="${1:-full}"
validate_install_mode "$INSTALL_MODE" rustdesk-relay

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
    image-repository=RUSTDESK_IMAGE_REPOSITORY
load_configmap_vars "$NS" "rustdesk-install-version" \
    image-version=RUSTDESK_IMAGE_VERSION
if install_mode_enabled "$INSTALL_MODE" rustdesk-relay; then
    if [ "$INSTALL_MODE" == "reinstall" ]; then
        if [ -z "$RUSTDESK_IMAGE_VERSION" ]; then
            log_error "missing rustdesk version configmap, please run full or rustdesk-relay mode first."
            exit 1
        fi
    else
        DEFAULT_RUSTDESK_IMAGE_VERSION=$(get_latest_rustdesk_server_pro_version)
        RUSTDESK_IMAGE_VERSION=$(prompt_with_default "" "rustdesk image version" "$DEFAULT_RUSTDESK_IMAGE_VERSION")
        apply_configmap_vars "$NS" "rustdesk-install-version" \
            image-version=RUSTDESK_IMAGE_VERSION
    fi
    [ -n "$RUSTDESK_IMAGE_REPOSITORY" ] || RUSTDESK_IMAGE_REPOSITORY="hub.bin.$DOMAIN/$BRAND_PREFIX/remote-desktop"
fi
render_values_file_to_temp values-*.yaml

# install rustdesk server relay
#####################################
if install_mode_enabled "$INSTALL_MODE" rustdesk-relay; then
    log_header "install rustdesk server relay"
    ensure_helm_repo_chart "bjw-s" "https://bjw-s-labs.github.io/helm-charts" "app-template" "$COMMON_CHART_VERSION"
    helm upgrade --install -n $NS rustdesk-relay temp/app-template --wait --timeout 600s -f temp/values-rustdesk-relay.yaml
fi

## done
log_trace "install rustdesk-relay success!!!"
