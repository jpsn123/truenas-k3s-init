#!/bin/bash

set -e
cd $(dirname $0)
source ../common.sh
source ../parameter.sh

# install cert-manager
#####################################
log_header "install cert-manager"
kubectl create namespace cert-manager 2>/dev/null || true
read CHART_VERSION APP_VERSION < <(get_helm_chart_versions "jetstack" "https://charts.jetstack.io" "cert-manager")
ensure_helm_repo_chart "jetstack" "https://charts.jetstack.io" "cert-manager" "$CHART_VERSION"
helm upgrade --install --namespace cert-manager cert-manager temp/cert-manager --wait --timeout 600s \
    --set crds.enabled=true \
    --set livenessProbe.initialDelaySeconds=120 \
    --set livenessProbe.periodSeconds=60 \
    --set webhook.livenessProbe.initialDelaySeconds=120 \
    --set webhook.livenessProbe.periodSeconds=60 \
    --set webhook.readinessProbe.periodSeconds=30

# done
log_trace "install cert-manager success!!!"
