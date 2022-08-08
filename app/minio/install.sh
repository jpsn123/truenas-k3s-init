#!/bin/bash

set -e
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../../scripts/deploy/paths.sh"
source "$DEPLOY_LIB_DIR/liblog.sh"
source "$DEPLOY_LIB_DIR/libprompt.sh"
source "$DEPLOY_LIB_DIR/libpassword.sh"
source "$DEPLOY_LIB_DIR/libkubernetes.sh"
source "$DEPLOY_LIB_DIR/libhelm.sh"
source "$DEPLOY_ROOT/scripts/deploy/values.sh"
source "$DEPLOY_ROOT/parameter.sh"
cd "$SCRIPT_DIR"
NS=minio
APP_NAME=minio

# initial
#####################################
log_info "initial"
[ -d temp ] || mkdir temp
kubectl create namespace $NS 2>/dev/null || true
deploy_render_values values-*.yaml
MINIO_PW=$(kube_secret_get "$NS" "minio" "root-password")
if [ -n "$MINIO_PW" ]; then
    log_info "reuse existing minio root-password."
else
    PASSWORD_SEED=$(prompt_required "please input password seed for minio." "password seed" "")
    MINIO_PW=$(password_derive_sha1 "$PASSWORD_SEED@$NS@minio" 32)
fi

# install
#####################################
log_info "install $APP_NAME"
helm_ensure_chart "bitnami" "oci://registry-1.docker.io/bitnamicharts" "minio" "temp" "16.0.10"
helm upgrade --install -n $NS $APP_NAME temp/minio -f temp/values-minio.yaml \
    --set "auth.rootPassword=$MINIO_PW"

## done
log_trace "init success!!!"
