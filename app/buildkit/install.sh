#!/bin/bash
set -e

cd $(dirname $0)
source ../../common.sh
source ../../parameter.sh
NS=buildkit
INSTALL_MODE="${1:-full}"
validate_install_mode "$INSTALL_MODE" buildkit

## initial
#####################################
log_header "initial"
kubectl create namespace $NS 2>/dev/null || true
load_configmap_vars "$NS" "buildkit" \
    image-repository=BUILDKIT_IMAGE_REPOSITORY \
    image-tag=BUILDKIT_IMAGE_TAG \
    load-balancer-ip=BUILDKIT_LOAD_BALANCER_IP
if install_mode_enabled "$INSTALL_MODE" buildkit; then
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
    apply_configmap_vars "$NS" "buildkit" \
        image-repository=BUILDKIT_IMAGE_REPOSITORY \
        image-tag=BUILDKIT_IMAGE_TAG \
        image=BUILDKIT_IMAGE \
        load-balancer-ip=BUILDKIT_LOAD_BALANCER_IP
fi
render_values_file_to_temp values-*.yaml
if install_mode_enabled "$INSTALL_MODE" buildkit && [ -z "$BUILDKIT_LOAD_BALANCER_IP" ]; then
    sed -i '/.*loadBalancerIP:.*/d' temp/values-buildkit.yaml
fi

## install buildkit
#####################################
if install_mode_enabled "$INSTALL_MODE" buildkit; then
    ensure_helm_repo_chart "bjw-s" "https://bjw-s-labs.github.io/helm-charts" "app-template" "$COMMON_CHART_VERSION"
    log_header "install buildkit"
    helm upgrade --install -n $NS buildkit temp/app-template --wait --timeout 600s -f temp/values-buildkit.yaml
fi

## done
#####################################
log_trace "install success!!!"
log_reminder "   load balancer ip: ${BUILDKIT_LOAD_BALANCER_IP:-auto assign}"
