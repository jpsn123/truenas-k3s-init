#!/bin/bash

set -e
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../scripts/deploy/paths.sh"
source "$DEPLOY_ROOT/scripts/deploy/values.sh"
source "$DEPLOY_LIB_DIR/liblog.sh"
source "$DEPLOY_LIB_DIR/libhelm.sh"
source "$DEPLOY_ROOT/parameter.sh"
cd "$SCRIPT_DIR"

INSTALL_MODE="$1"

# install rancher
#####################################
log_header "install rancher"
deploy_render_values values-rancher.yaml

kubectl create namespace cattle-system 2>/dev/null || true
if [ "$INSTALL_MODE" == "reinstall" ]; then
    helm_ensure_chart "rancher-stable" "https://releases.rancher.com/server-charts/stable" "rancher" "temp"
else
    VERSION_PAIR=$(helm_chart_versions "rancher-stable" "https://releases.rancher.com/server-charts/stable" "rancher")
    read -r CHART_VERSION APP_VERSION <<<"$VERSION_PAIR"
    helm_ensure_chart "rancher-stable" "https://releases.rancher.com/server-charts/stable" "rancher" "temp" "$CHART_VERSION"
fi
helm upgrade --install -n cattle-system rancher temp/rancher --wait --timeout 1200s -f temp/values-rancher.yaml
# done
log_trace "install rancher success!!!"
