#!/bin/bash

set -e
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../../scripts/deploy/paths.sh"
source "$DEPLOY_LIB_DIR/liblog.sh"
source "$DEPLOY_LIB_DIR/libhelm.sh"
source "$DEPLOY_ROOT/scripts/deploy/values.sh"
source "$DEPLOY_ROOT/parameter.sh"
cd "$SCRIPT_DIR"

NS=emby
APP_NAME=emby

# initial
#####################################
log_info "initial"
[ -d temp ] || mkdir temp
kubectl create namespace $NS 2>/dev/null || true
deploy_render_values values-*.yaml

# install emby
#####################################
log_info "install $APP_NAME"
helm_ensure_chart bjw-s https://bjw-s-labs.github.io/helm-charts app-template temp "$COMMON_CHART_VERSION"
helm upgrade --install -n $NS $APP_NAME temp/app-template --wait --timeout 600s -f ./temp/values-emby.yaml
## done
log_trace "init success!!!"
