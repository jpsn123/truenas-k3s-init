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

INSTALL_MODE="$1"

# install ingress-nginx
#####################################
log_header "install ingress-nginx"
NS=ingress-nginx
kubectl create namespace $NS 2>/dev/null || true
kube_configmap_load "$NS" "ingress-nginx" load-balancer-ip=INGRESS_IP
if [ -z "$INGRESS_IP" ]; then
    INGRESS_IP=$(prompt_with_default "please input ingress-nginx config." "ingress load balancer ip" "10.33.0.1")
fi
kube_configmap_apply_vars "$NS" "ingress-nginx" load-balancer-ip=INGRESS_IP
deploy_render_values values-ingress.yaml

if [ "$INSTALL_MODE" == "reinstall" ]; then
    helm_ensure_chart "rke2-charts" "https://rancher.github.io/rke2-charts" "rke2-ingress-nginx" "temp"
else
    VERSION_PAIR=$(helm_chart_versions "rke2-charts" "https://rancher.github.io/rke2-charts" "rke2-ingress-nginx")
    read -r CHART_VERSION APP_VERSION <<<"$VERSION_PAIR"
    helm_ensure_chart "rke2-charts" "https://rancher.github.io/rke2-charts" "rke2-ingress-nginx" "temp" "$CHART_VERSION"
fi
helm upgrade --install rke2-ingress-nginx temp/rke2-ingress-nginx -n $NS --wait --timeout 600s -f temp/values-ingress.yaml

# done
log_trace "install ingress-nginx success!!!"
