#!/bin/bash

cd $(dirname $0)
source ../../common.sh
source ../../parameter.sh

NS=qbittorrent
APP_NAME=qbittorrent

# initial
#####################################
log_info "initial"
[ -d temp ] || mkdir temp
kubectl create namespace $NS 2>/dev/null
sed -i "s/example.com/${DOMAIN}/g" values.yaml
sed -i "s/sc-example/${DEFAULT_STORAGE_CLASS}/g" values.yaml

# install app
#####################################
log_info "install $APP_NAME"
helm repo add bjw-s https://bjw-s.github.io/helm-charts
[ -d temp/app-template ] || (helm repo update bjw-s && helm pull bjw-s/app-template --untar --untardir temp --version=$COMMON_CHART_VERSION)
helm upgrade --install -n $NS $APP_NAME temp/app-template --wait --timeout 600s -f values.yaml

## done
log_trace "init success!!!"
