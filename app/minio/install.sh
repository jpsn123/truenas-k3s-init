#!/bin/bash

set -e
cd $(dirname $0)
source ../../common.sh
source ../../parameter.sh
NS=minio
APP_NAME=minio

# initial
#####################################
log_info "initial"
[ -d temp ] || mkdir temp
kubectl create namespace $NS 2>/dev/null || true
sed -i "s/example.com/${DOMAIN}/g" values.yaml
sed -i "s/sc-example/${DEFAULT_STORAGE_CLASS}/g" values.yaml
log_reminder "please input password seed for minio."
read -p "password seed:"
MINIO_PW=$(echo -n "$REPLY@minio" | sha1sum | awk '{print $1}' | base64 | head -c 32)

# install
#####################################
log_info "install $APP_NAME"
helm repo add bitnami https://charts.bitnami.com/bitnami
[ -d temp/minio ] || (helm repo update bitnami && helm pull bitnami/minio --untar --untardir temp)
helm upgrade --install -n $NS $APP_NAME temp/minio -f values.yaml \
    --set auth.rootPassword=$MINIO_PW

## done
log_trace "init success!!!"
