#!/bin/bash

cd $(dirname $0)
source ../../common.sh
source ../../parameter.sh
NS=minio
APP_NAME=minio

# initial
#####################################
log_info "initial"
[ -d temp ] || mkdir temp
kubectl create namespace $NS 2>/dev/null
sed -i "s/example.com/${DOMAIN}/g" values.yaml
sed -i "s/sc-example/${DEFAULT_STORAGE_CLASS}/g" values.yaml
log_reminder "please input password for minio."
read -p "password:"

# install
#####################################
log_info "install $APP_NAME"
helm repo add bitnami https://charts.bitnami.com/bitnami
[ -d temp/minio ] || helm pull bitnami/minio --untar --untardir temp
helm upgrade --install -n $NS $APP_NAME temp/minio -f values.yaml \
    --set auth.rootPassword=$REPLY

## done
log_trace "init success!!!"
