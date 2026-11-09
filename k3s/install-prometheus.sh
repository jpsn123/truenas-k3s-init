#!/bin/bash
set -e
set -o pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../scripts/deploy/paths.sh"
source "$DEPLOY_ROOT/scripts/deploy/install-mode.sh"
source "$DEPLOY_ROOT/scripts/deploy/values.sh"
source "$DEPLOY_LIB_DIR/liblog.sh"
source "$DEPLOY_LIB_DIR/libprompt.sh"
source "$DEPLOY_LIB_DIR/libhelm.sh"
source "$DEPLOY_ROOT/parameter.sh"
cd "$SCRIPT_DIR"

NS=cattle-monitoring-system
INSTALL_MODE="${1:-full}"
CHART_VERSION="${2:-}"
deploy_validate_mode "$INSTALL_MODE"
if [ "$#" -gt 2 ] || { [ "$INSTALL_MODE" == "reinstall" ] && [ -n "$CHART_VERSION" ]; }; then
    log_error "usage: bash install-prometheus.sh [full [chart-version] | reinstall]"
    exit 1
fi

# install Rancher Monitoring (Prometheus, Alertmanager, Grafana and exporters)
#####################################
log_header "install prometheus suite"
if [ "$INSTALL_MODE" == "reinstall" ]; then
    VERSION_PAIR=$(helm_chart_versions_local "temp/rancher-monitoring")
    read -r CHART_VERSION APP_VERSION <<<"$VERSION_PAIR"
elif [ -z "$CHART_VERSION" ]; then
    VERSION_PAIR=$(helm_chart_versions "rancher-charts" "https://charts.rancher.io" "rancher-monitoring")
    read -r CHART_VERSION APP_VERSION <<<"$VERSION_PAIR"
    CHART_VERSION=$(prompt_with_default "select a chart version compatible with your Rancher and Kubernetes versions." "monitoring chart version" "$CHART_VERSION")
fi
helm_ensure_chart "rancher-charts" "https://charts.rancher.io" "rancher-monitoring" "temp" "$CHART_VERSION"
helm_ensure_chart "rancher-charts" "https://charts.rancher.io" "rancher-monitoring-crd" "temp" "$CHART_VERSION"
deploy_render_values values-prometheus.yaml

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
# Use new chart defaults while retaining existing Rancher metadata and Alertmanager configuration.
helm upgrade --install -n "$NS" rancher-monitoring-crd temp/rancher-monitoring-crd \
    --reset-then-reuse-values --wait --timeout 600s
helm upgrade --install -n "$NS" rancher-monitoring temp/rancher-monitoring \
    --reset-then-reuse-values --wait --wait-for-jobs --timeout 4500s -f temp/values-prometheus.yaml
# Helm does not wait for StatefulSets created asynchronously by the Prometheus Operator.
PROMETHEUS_GENERATION=$(kubectl -n "$NS" get prometheus rancher-monitoring-prometheus -o jsonpath='{.metadata.generation}')
kubectl -n "$NS" wait prometheus/rancher-monitoring-prometheus --timeout=4500s \
    --for="jsonpath={.status.conditions[?(@.type==\"Reconciled\")].observedGeneration}=$PROMETHEUS_GENERATION"
kubectl -n "$NS" rollout status statefulset/prometheus-rancher-monitoring-prometheus --timeout=4500s
kubectl -n "$NS" wait --for=condition=Available prometheus/rancher-monitoring-prometheus --timeout=4500s

log_trace "install prometheus suite success!!!"
log_reminder "access Prometheus, Alertmanager and Grafana through Rancher: https://srv.${DOMAIN}"
