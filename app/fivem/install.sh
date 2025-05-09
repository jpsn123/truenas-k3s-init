#!/bin/bash

set -e
cd $(dirname $0)
source ../../common.sh
source ../../parameter.sh

NS=fivem
APP_NAME=fivem

log_reminder "please input password for database."
read -p "password:"
DB_PW=$(echo -n $REPLY@mysql | md5sum | head -c 16)

# initial
#####################################
log_info "initial"
[ -d temp ] || mkdir temp
kubectl create namespace $NS 2>/dev/null
sed -i "s/example.com/${DOMAIN}/g" values-fivem.yaml
sed -i "s/sc-example/${DEFAULT_STORAGE_CLASS}/g" values-fivem.yaml

# install mysql for fivem
#####################################
log_info "install $APP_NAME"
helm repo add bitnami https://charts.bitnami.com/bitnami
[ -d temp/mysql ] || (helm repo update bitnami && helm pull bitnami/mysql --untar --untardir temp --version=$COMMON_CHART_VERSION)
helm upgrade --install -n $NS mysql temp/mysql -f values-mysql.yaml \
    --set auth.rootPassword=$DB_PW \
    --set auth.password=$DB_PW \
    --set auth.replicationPassword=$DB_PW

# install fivem
#####################################
log_info "install $APP_NAME"
helm repo add bjw-s https://bjw-s.github.io/helm-charts
[ -d temp/app-template ] || (helm repo update bjw-s && helm pull bjw-s/app-template --untar --untardir temp --version=$COMMON_CHART_VERSION)
helm upgrade --install -n $NS $APP_NAME temp/app-template -f values-fivem.yaml
k8s_wait $NS deployment $APP_NAME 100

## done
log_trace "init success!!!"
