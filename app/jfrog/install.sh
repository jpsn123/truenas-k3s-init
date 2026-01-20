#!/bin/bash

cd $(dirname $0)
source ../../common.sh
source ../../parameter.sh
NS=jfrog

# initial
#####################################
log_info "initial"
kubectl create namespace $NS 2>/dev/null || true
if kubectl get secret jfrog-platform-postgresql -n $NS >/dev/null 2>&1; then
    PG_PW=$(kubectl get secret jfrog-platform-postgresql -n $NS -ojsonpath='{.data.postgres-password}' | base64 --decode)
    log_info "reuse existing postgresql password."
fi
if kubectl get secret jfrog-platform-artifactory-unified-secret -n $NS >/dev/null 2>&1; then
    MASTER_PW=$(kubectl get secret jfrog-platform-artifactory-unified-secret -n $NS -ojsonpath='{.data.master-key}' | base64 --decode)
    JOIN_PW=$(kubectl get secret jfrog-platform-artifactory-unified-secret -n $NS -ojsonpath='{.data.join-key}' | base64 --decode)
    BOOTSTRAP_CREDS=$(kubectl get secret jfrog-platform-artifactory-unified-secret -n $NS -ojsonpath='{.data.bootstrap.creds}' | base64 --decode)
    ARTIFACTORY_PW=${BOOTSTRAP_CREDS#*=}
    log_info "reuse existing jfrog secret."
fi
if [ -z "$ARTIFACTORY_PW" ] || [ -z "$PG_PW" ] || [ -z "$MASTER_PW" ] || [ -z "$JOIN_PW" ]; then
    echo -e '\033[35mplease input password seed for setting jfrog. \033[0m'
    read -p "password seed:"
fi
if [ -z "$ARTIFACTORY_PW" ] || [ -z "$MASTER_PW" ] || [ -z "$JOIN_PW" ]; then
    ARTIFACTORY_PW=$(echo -n "$REPLY@$NS@jfrog" | sha1sum | awk '{print $1}' | base64 | head -c 32)
    MASTER_PW=$(echo -n "$REPLY@$NS@master" | sha1sum | awk '{print $1}' | base64 | head -c 64)
    JOIN_PW=$(echo -n "$REPLY@$NS@join" | sha1sum | awk '{print $1}' | base64 | head -c 32)
fi
if [ -z "$PG_PW" ]; then
    PG_PW=$(echo -n "$REPLY@$NS@pg" | sha1sum | awk '{print $1}' | base64 | head -c 32)
fi
copy_and_replace_default_values values-*.yaml

# install jfrog
#####################################
log_info "install jfrog"
helm repo add jfrog https://charts.jfrog.io
[ -d temp/jfrog-platform ] || (helm repo update jfrog && helm pull jfrog/jfrog-platform --untar --untardir temp --version=11.0.5)
if [ $(app_is_exist $NS jfrog-platform) != true ]; then
    helm install -n $NS jfrog-platform temp/jfrog-platform -f temp/values-jfrog.yaml \
        --set global.masterKey=$MASTER_PW \
        --set global.joinKey=$JOIN_PW \
        --set global.database.adminPassword=$PG_PW \
        --set postgresql.auth.postgresPassword=$PG_PW \
        --set artifactory.database.password=$PG_PW \
        --set artifactory.artifactory.admin.password=$ARTIFACTORY_PW \
        --set xray.database.password=$PG_PW \
        --set distribution.database.password=$PG_PW
else
    helm upgrade -n $NS jfrog-platform temp/jfrog-platform --reuse-values -f temp/values-jfrog.yaml \
        --set gaUpgradeReady=true
fi
kubectl apply -n $NS -f temp/values-ingress.yaml

## done
#####################################
log_trace "init success!!!"
log_trace "run command to get boostrap password:"
log_reminder "   kubectl get secret -n $NS jfrog-platform-artifactory-unified-secret -o go-template='{{ index .data \"bootstrap.creds\" | base64decode }}{{ \"\\\n\" }}'"
