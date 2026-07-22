#!/bin/bash

set -e
cd $(dirname $0)
source ../common.sh
source ../parameter.sh

# install ingress-nginx
#####################################
log_header "install ingress-nginx"
NS=ingress-nginx
kubectl create namespace $NS 2>/dev/null || true
load_configmap_vars "$NS" "ingress-nginx" load-balancer-ip=INGRESS_IP
if [ -z "$INGRESS_IP" ]; then
    INGRESS_IP=$(prompt_with_default "please input ingress-nginx config." "ingress load balancer ip" "10.33.0.1")
fi
apply_configmap_vars "$NS" "ingress-nginx" load-balancer-ip=INGRESS_IP
render_values_file_to_temp values-ingress.yaml

read -r CHART_VERSION APP_VERSION <<<"$(get_helm_chart_versions "rke2-charts" "https://rancher.github.io/rke2-charts" "rke2-ingress-nginx")"
ensure_helm_repo_chart "rke2-charts" "https://rancher.github.io/rke2-charts" "rke2-ingress-nginx" "$CHART_VERSION"
helm upgrade --install rke2-ingress-nginx temp/rke2-ingress-nginx -n $NS --wait --timeout 600s -f temp/values-ingress.yaml

# done
log_trace "install ingress-nginx success!!!"
