#!/bin/bash

set -e
cd $(dirname $0)
source ../../common.sh
source ../../parameter.sh
NS=nextcloud

# initial
#####################################
log_header "initial"
kubectl create namespace $NS 2>/dev/null || true
if kubectl get secret redis -n $NS >/dev/null 2>&1; then
    REDIS_PW=$(kubectl get secret redis -n $NS -ojsonpath='{.data.redis-password}' | base64 --decode)
    log_info "reuse existing redis password."
fi
if kubectl get secret postgresql -n $NS >/dev/null 2>&1; then
    DB_PW=$(kubectl get secret postgresql -n $NS -ojsonpath='{.data.password}' | base64 --decode)
    log_info "reuse existing postgresql password."
fi
if kubectl get secret nextcloud -n $NS >/dev/null 2>&1; then
    NEXTCLOUD_PW=$(kubectl get secret nextcloud -n $NS -ojsonpath='{.data.nextcloud-password}' | base64 --decode)
    log_info "reuse existing nextcloud password."
fi
if [ -z "$REDIS_PW" ] || [ -z "$DB_PW" ] || [ -z "$NEXTCLOUD_PW" ]; then
    log_reminder "please input password seed for setting nextcloud."
    read -p "password seed:"
fi
if [ -z "$REDIS_PW" ]; then
    REDIS_PW=$(echo -n "$REPLY@$NS@redis" | sha1sum | awk '{print $1}' | base64 | head -c 32)
fi
if [ -z "$DB_PW" ]; then
    DB_PW=$(echo -n "$REPLY@$NS@pg" | sha1sum | awk '{print $1}' | base64 | head -c 32)
fi
if [ -z "$NEXTCLOUD_PW" ]; then
    NEXTCLOUD_PW=$(echo -n "$REPLY@$NS@nextcloud" | sha1sum | awk '{print $1}' | base64 | head -c 32)
fi
kubectl -n $NS delete secret nextcloud 2>/dev/null || true
kubectl -n $NS create secret generic nextcloud \
    --from-literal=nextcloud-username=admin \
    --from-literal=nextcloud-password=$NEXTCLOUD_PW
render_values_file_to_temp values-*.yaml
kubectl -n $NS apply -f temp/values-configs.yaml
kubectl -n $NS apply -f temp/values-important-pvc.yaml

# install postgresql
#####################################
log_header "install postgresql"
[ -d temp/postgresql ] || (helm pull oci://registry-1.docker.io/bitnamicharts/postgresql --untar --untardir temp --version=16.7.27)
helm upgrade --install -n $NS postgresql temp/postgresql --wait --timeout 600s -f temp/values-postgresql.yaml \
    --set global.postgresql.auth.postgresPassword=$DB_PW \
    --set global.postgresql.auth.password=$DB_PW \
    --set auth.replicationPassword=$DB_PW
kubectl -n $NS patch secret postgresql --type merge --patch \
    "{\"data\":{\"username\":\"$(echo -n nextcloud | base64)\"}}"

# install redis
#####################################
log_header "install redis"
[ -d temp/redis ] || (helm pull oci://registry-1.docker.io/bitnamicharts/redis --untar --untardir temp --version=22.0.7)
helm upgrade --install -n $NS redis temp/redis --wait --timeout 600s -f temp/values-redis.yaml \
    --set global.redis.password=$REDIS_PW

# install nextcloud
#####################################
log_header "install nextcloud"
helm repo add nextcloud https://nextcloud.github.io/helm/
[ -d temp/nextcloud ] || (helm repo update nextcloud && helm pull nextcloud/nextcloud --untar --untardir temp)
helm upgrade --install -n $NS nextcloud temp/nextcloud --wait --timeout 1200s -f temp/values-nextcloud.yaml --set replicaCount=1

# install office
#####################################
log_header "install office plugin"
helm repo add bjw-s https://bjw-s-labs.github.io/helm-charts
[ -d temp/app-template ] || (helm repo update bjw-s && helm pull bjw-s/app-template --untar --untardir temp --version=$COMMON_CHART_VERSION)
helm upgrade --install -n $NS office temp/app-template --wait --timeout 600s -f temp/values-office.yaml

## done
log_trace "install success!!!"
log_trace "run command to get boostrap password:"
log_reminder "   kubectl get secret -n $NS nextcloud -o go-template='{{ index .data \"nextcloud-password\" | base64decode }}{{ \"\\\n\" }}'"
