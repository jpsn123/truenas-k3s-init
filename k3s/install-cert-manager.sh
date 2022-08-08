#!/bin/bash

set -e
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../scripts/deploy/paths.sh"
source "$DEPLOY_LIB_DIR/liblog.sh"
source "$DEPLOY_LIB_DIR/libhelm.sh"
source "$DEPLOY_ROOT/parameter.sh"
cd "$SCRIPT_DIR"

INSTALL_MODE="$1"

# install cert-manager
#####################################
log_header "install cert-manager"
kubectl create namespace cert-manager 2>/dev/null || true
if [ "$INSTALL_MODE" == "reinstall" ]; then
    helm_ensure_chart "jetstack" "https://charts.jetstack.io" "cert-manager" "temp"
else
    VERSION_PAIR=$(helm_chart_versions "jetstack" "https://charts.jetstack.io" "cert-manager")
    read -r CHART_VERSION APP_VERSION <<<"$VERSION_PAIR"
    helm_ensure_chart "jetstack" "https://charts.jetstack.io" "cert-manager" "temp" "$CHART_VERSION"
fi
helm upgrade --install --namespace cert-manager cert-manager temp/cert-manager --wait --timeout 600s \
    --set crds.enabled=true \
    --set livenessProbe.initialDelaySeconds=120 \
    --set livenessProbe.periodSeconds=60 \
    --set webhook.livenessProbe.initialDelaySeconds=120 \
    --set webhook.livenessProbe.periodSeconds=60 \
    --set webhook.readinessProbe.periodSeconds=30

# done
log_trace "install cert-manager success!!!"
