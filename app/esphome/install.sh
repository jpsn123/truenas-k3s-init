#!/bin/bash

set -e
cd $(dirname $0)
source ../../common.sh
source ../../parameter.sh

NS=esphome
APP_NAME=esphome

# initial
#####################################
log_info "initial"
[ -d temp ] || mkdir temp
kubectl create namespace $NS 2>/dev/null || true
render_values_file_to_temp values-*.yaml

# install app
#####################################
log_info "install $APP_NAME"
helm repo add bjw-s https://bjw-s.github.io/helm-charts
[ -d temp/app-template ] || (helm repo update bjw-s && helm pull bjw-s/app-template --untar --untardir temp --version=$COMMON_CHART_VERSION)
helm upgrade --install -n $NS $APP_NAME temp/app-template --wait --timeout 600s -f ./temp/values-esphome.yaml

## done
log_trace "init success!!!"
