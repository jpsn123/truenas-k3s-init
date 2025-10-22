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
copy_and_replace_default_values values-*.yaml
log_reminder "please input password seed for minio."
read -p "password seed:"
MINIO_PW=$(echo -n "$REPLY@$NS@minio" | sha1sum | awk '{print $1}' | base64 | head -c 32)

# install
#####################################
log_info "install $APP_NAME"
[ -d temp/minio ] || (helm pull oci://registry-1.docker.io/bitnamicharts/minio --untar --untardir temp --version=16.0.10)
helm upgrade --install -n $NS $APP_NAME temp/minio -f temp/values.yaml \
    --set auth.rootPassword=$MINIO_PW

## done
log_trace "init success!!!"
