#!/bin/bash

cd $(dirname $0)
source ../../common.sh
source ../../parameter.sh

NS=esphome
APP_NAME=esphome

# initial
#####################################
log_info "initial"
[ -d temp ] || mkdir temp
kubectl create namespace $NS 2>/dev/null
sed -i "s/example.com/${DOMAIN}/g" values.yaml
sed -i "s/sc-example/${STORAGE_CLASS_NAME}/g" values.yaml

# install app
#####################################
log_info "install $APP_NAME"
helm repo add bjw-s https://bjw-s.github.io/helm-charts
[ -d temp/app-template ] || helm pull bjw-s/app-template --untar --untardir temp --version=$COMMON_CHART_VERSION
METHOD=install
[ $(app_is_exist $NS $APP_NAME) == true ] && METHOD=upgrade
helm $METHOD -n $NS $APP_NAME temp/app-template -f values.yaml
k8s_wait $NS deployment $APP_NAME 100

## done
log_trace "init success!!!"
