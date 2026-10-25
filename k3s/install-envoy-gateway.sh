#!/bin/bash

set -e
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../scripts/deploy/paths.sh"
source "$DEPLOY_ROOT/scripts/deploy/values.sh"
source "$DEPLOY_LIB_DIR/liblog.sh"
source "$DEPLOY_LIB_DIR/libprompt.sh"
source "$DEPLOY_LIB_DIR/libkubernetes.sh"
source "$DEPLOY_LIB_DIR/libhelm.sh"
source "$DEPLOY_ROOT/parameter.sh"
cd "$SCRIPT_DIR"

NS=envoy-gateway-system
INSTALL_MODE="$1"

# install envoy gateway
#####################################
log_header "install envoy gateway"
kubectl create namespace $NS 2>/dev/null || true
kube_configmap_load "$NS" "shared-edge" \
    load-balancer-ip=GATEWAY_IP \
    replicas=GATEWAY_REPLICAS
if [ -z "$GATEWAY_IP" ]; then
    GATEWAY_IP=$(prompt_required "please select an unused IP from the Cilium load balancer pool; do not reuse the active ingress VIP." "shared gateway load balancer ip")
fi
if [ -z "$GATEWAY_REPLICAS" ]; then
    GATEWAY_REPLICAS=$(prompt_with_default "how many Kubernetes nodes should serve external traffic for the shared gateway? usually this equals the total number of cluster nodes." "shared gateway node count" "3")
fi
if [[ ! "$GATEWAY_REPLICAS" =~ ^[1-9][0-9]*$ ]]; then
    log_error "shared gateway node count must be a positive integer."
    exit 1
fi
kube_configmap_apply_vars "$NS" "shared-edge" \
    load-balancer-ip=GATEWAY_IP \
    replicas=GATEWAY_REPLICAS

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
deploy_render_values values-envoy-gateway.yaml values-envoy-proxy.yaml

helm template eg-crds temp/gateway-crds-helm \
    --set crds.gatewayAPI.enabled=true \
    --set crds.gatewayAPI.channel=standard \
    --set crds.envoyGateway.enabled=true | kubectl apply --server-side -f -
helm upgrade --install -n $NS eg temp/gateway-helm --wait --timeout 600s --skip-crds -f temp/values-envoy-gateway.yaml
kubectl apply -f temp/values-envoy-proxy.yaml

# done
log_trace "install envoy gateway success!!!"
