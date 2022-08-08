#!/bin/bash

set -e
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../scripts/deploy/paths.sh"
source "$DEPLOY_ROOT/scripts/deploy/values.sh"
source "$DEPLOY_LIB_DIR/liblog.sh"
source "$DEPLOY_LIB_DIR/libprompt.sh"
source "$DEPLOY_LIB_DIR/libhelm.sh"
source "$DEPLOY_ROOT/parameter.sh"
cd "$SCRIPT_DIR"

NS=envoy-gateway-system
INSTALL_MODE="$1"

# install envoy gateway
#####################################
log_header "install envoy gateway"
kubectl create namespace $NS 2>/dev/null || true
if [ "$INSTALL_MODE" == "reinstall" ]; then
    helm_ensure_chart "envoyproxy" "oci://docker.io/envoyproxy" "gateway-helm" "temp"
    VERSION_PAIR=$(helm_chart_versions_local "temp/gateway-helm")
    read -r CHART_VERSION APP_VERSION <<<"$VERSION_PAIR"
    helm_ensure_chart "envoyproxy" "oci://docker.io/envoyproxy" "gateway-crds-helm" "temp" "$CHART_VERSION"
else
    DEFAULT_CHART_VERSION=$(helm show chart oci://docker.io/envoyproxy/gateway-helm | awk '/^version:/{print $2; exit}')
    if [ -z "$DEFAULT_CHART_VERSION" ]; then
        log_error "failed to get latest envoy gateway chart version."
        exit 1
    fi
    CHART_VERSION=$(prompt_with_default "please input envoy gateway version." "version" "$DEFAULT_CHART_VERSION")
    helm_ensure_chart "envoyproxy" "oci://docker.io/envoyproxy" "gateway-crds-helm" "temp" "$CHART_VERSION"
    helm_ensure_chart "envoyproxy" "oci://docker.io/envoyproxy" "gateway-helm" "temp" "$CHART_VERSION"
fi
deploy_render_values values-envoy-gateway.yaml

helm template eg-crds temp/gateway-crds-helm \
    --set crds.gatewayAPI.enabled=true \
    --set crds.gatewayAPI.channel=standard \
    --set crds.envoyGateway.enabled=true | kubectl apply --server-side -f -
helm upgrade --install -n $NS eg temp/gateway-helm --wait --timeout 600s --skip-crds -f temp/values-envoy-gateway.yaml

# done
log_trace "install envoy gateway success!!!"
