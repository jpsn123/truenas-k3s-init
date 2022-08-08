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
NS=buildkit
INSTALL_MODE="${1:-full}"
deploy_validate_mode "$INSTALL_MODE" buildkit

## initial
#####################################
log_header "initial"
kubectl create namespace $NS 2>/dev/null || true
kube_configmap_load "$NS" "buildkit" \
    image-repository=BUILDKIT_IMAGE_REPOSITORY \
    image-tag=BUILDKIT_IMAGE_TAG \
    load-balancer-ip=BUILDKIT_LOAD_BALANCER_IP
if deploy_mode_enabled "$INSTALL_MODE" buildkit; then
    if [ -z "$BUILDKIT_IMAGE_REPOSITORY" ]; then
        BUILDKIT_IMAGE_REPOSITORY=$(prompt_with_default "please input buildkit config." "buildkit image repository" "moby/buildkit")
    fi
    if [ -z "$BUILDKIT_IMAGE_TAG" ]; then
        BUILDKIT_IMAGE_TAG=$(prompt_with_default "" "buildkit image tag" "rootless")
    fi
    BUILDKIT_LOAD_BALANCER_IP_CONFIGURED=$(kubectl -n "$NS" get configmap "buildkit" -o go-template='{{ range $key, $value := .data }}{{ if eq $key "load-balancer-ip" }}true{{ end }}{{ end }}' 2>/dev/null || true)
    if [ "$BUILDKIT_LOAD_BALANCER_IP_CONFIGURED" != "true" ]; then
        BUILDKIT_LOAD_BALANCER_IP=$(prompt_with_default "" "buildkit load balancer ip, empty for auto assign" "")
    fi
    BUILDKIT_IMAGE="$BUILDKIT_IMAGE_REPOSITORY:$BUILDKIT_IMAGE_TAG"
    kube_configmap_apply_vars "$NS" "buildkit" \
        image-repository=BUILDKIT_IMAGE_REPOSITORY \
        image-tag=BUILDKIT_IMAGE_TAG \
        image=BUILDKIT_IMAGE \
        load-balancer-ip=BUILDKIT_LOAD_BALANCER_IP
fi
deploy_render_values values-*.yaml
if deploy_mode_enabled "$INSTALL_MODE" buildkit && [ -z "$BUILDKIT_LOAD_BALANCER_IP" ]; then
    sed -i '/.*loadBalancerIP:.*/d' temp/values-buildkit.yaml
fi

## install buildkit
#####################################
if deploy_mode_enabled "$INSTALL_MODE" buildkit; then
    helm_ensure_chart "bjw-s" "https://bjw-s-labs.github.io/helm-charts" "app-template" "temp" "$COMMON_CHART_VERSION"
    log_header "install buildkit"
    helm upgrade --install -n $NS buildkit temp/app-template --wait --timeout 600s -f temp/values-buildkit.yaml
fi

## done
#####################################
log_trace "install success!!!"
log_reminder "   load balancer ip: ${BUILDKIT_LOAD_BALANCER_IP:-auto assign}"
