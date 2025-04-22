#!/bin/bash

set -e
cd $(dirname $0)
source ../../common.sh
source ../../parameter.sh
NS=nextcloud
APP_NAME=nextcloud

log_reminder "please input password seed for setting nextcloud."
read -p "password seed:"
REDIS_PW=$(echo -n $REPLY@redis | sha1sum | awk '{print $1}' | base64 | head -c 32)
DB_PW=$(echo -n $REPLY@pg | sha1sum | awk '{print $1}' | base64 | head -c 32)
NEXTCLOUD_PW=$(echo -n "$REPLY@nextcloud" | sha1sum | awk '{print $1}' | base64 | head -c 32)

# initial
#####################################
log_info "initial"
[ -d temp ] || mkdir temp
kubectl create namespace $NS 2>/dev/null || true
kubectl -n $NS delete secret nextcloud 2>/dev/null || true
kubectl -n $NS create secret generic nextcloud \
    --from-literal=nextcloud-username=admin \
    --from-literal=nextcloud-password=$NEXTCLOUD_PW
sed -i "s/example.com/${DOMAIN}/g" values-nextcloud.yaml
sed -i "s/example.com/${DOMAIN}/g" values-office.yaml
sed -i "s/sc-example/${DEFAULT_STORAGE_CLASS}/g" values-*.yaml
sed -i "s/sc-shared-example/${DEFAULT_SHARED_STORAGE_CLASS}/g" values-*.yaml
kubectl -n $NS delete -f configs.yaml 2>/dev/null || true
kubectl -n $NS apply -f configs.yaml

# install nextcloud
#####################################
log_info "install $APP_NAME"
helm repo add nextcloud https://nextcloud.github.io/helm/
[ -d temp/nextcloud ] || (helm repo update nextcloud && helm pull nextcloud/nextcloud --untar --untardir temp)
helm upgrade --install -n $NS nextcloud temp/nextcloud -f values-nextcloud.yaml \
    --set mariadb.auth.rootPassword=$DB_PW \
    --set mariadb.auth.password=$DB_PW \
    --set redis.auth.password=$REDIS_PW

# install office
#####################################
log_info "install office plugin"
helm repo add bjw-s https://bjw-s.github.io/helm-charts
[ -d temp/app-template ] || (helm repo update bjw-s && helm pull bjw-s/app-template --untar --untardir temp --version=$COMMON_CHART_VERSION)
helm upgrade --install -n $NS office temp/app-template -f values-office.yaml
k8s_wait $NS deployment office-documentserver 100
k8s_wait $NS deployment office-draw 100

## done
log_trace "install success!!!"
log_trace "run command to get boostrap password:"
log_reminder "   kubectl get secret -n $NS nextcloud -o go-template='{{ index .data \"nextcloud-password\" | base64decode }}{{ \"\\\n\" }}'"
