#!/bin/bash

set -e
cd $(dirname $0)
source ../../common.sh
source ../../parameter.sh

NS=rustdesk

# initial
#####################################
log_header "initial"
kubectl create namespace $NS 2>/dev/null || true
render_values_file_to_temp values-*.yaml
helm repo add bjw-s https://bjw-s-labs.github.io/helm-charts
[ -d temp/app-template ] || (helm repo update bjw-s && helm pull bjw-s/app-template --untar --untardir temp --version=$COMMON_CHART_VERSION)

# install rustdesk server relay
#####################################
log_header "install rustdesk server relay"
helm upgrade --install -n $NS rustdesk-relay temp/app-template --wait --timeout 600s -f temp/values-rustdesk-relay.yaml

## done
log_trace "install rustdesk-relay success!!!"