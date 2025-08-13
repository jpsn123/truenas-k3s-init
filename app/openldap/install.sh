#!/bin/bash

set -e
cd $(dirname $0)
source ../../common.sh
source ../../parameter.sh

NS=openldap
APP_NAME=ldap

log_reminder "please input admin password seed."
read -p "password seed:"
PASSWD=$(echo -n "$REPLY@ldap" | sha1sum | awk '{print $1}' | base64 | head -c 32)
log_reminder "please input smtp password."
read -p "password:"
SMTP_PASSWD=$REPLY

# initial
#####################################
log_header "initial"
kubectl create namespace $NS 2>/dev/null || true
kubectl delete -n $NS configmap ssp-images 2>/dev/null || true
kubectl create -n $NS configmap ssp-images \
    --from-file='bk.jpg' \
    --from-file='logo.png'
kubectl delete -n $NS secret openldap-passwd 2>/dev/null || true
kubectl create -n $NS secret generic openldap-passwd \
    --from-literal SMTP_PASS=$SMTP_PASSWD \
    --from-literal LAM_ADMIN_PASSWORD=$PASSWD

# replace example.com and sc
sed -i "s/example.com/${DOMAIN}/g" values-*.yaml
sed -i "s/sc-shared-example-cachefs/${DEFAULT_SHARED_CACHEFS_STORAGE_CLASS}/g" values-*.yaml
sed -i "s/sc-shared-example/${DEFAULT_SHARED_STORAGE_CLASS}/g" values-*.yaml
sed -i "s/sc-large-example/${DEFAULT_LARGE_STORAGE_CLASS}/g" values-*.yaml
sed -i "s/sc-example/${DEFAULT_STORAGE_CLASS}/g" values-*.yaml
# replace dc=example,dc=com
IFS='.' && DOMAIN_ARR=($DOMAIN) && unset IFS
LDAP_BASE="dc=${DOMAIN_ARR[0]},dc=${DOMAIN_ARR[1]}"
sed -i "s/dc=example,dc=com/${LDAP_BASE}/g" values-*.yaml

# request ldap certificate
#####################################
kubectl apply -n $NS -f ldap-tls.yaml
for ((i = 0; i < 100; i++)); do
    RES=$(kubectl get -n $NS certificate ldap-tls -o=jsonpath='{.status.conditions[0].status}' 2>/dev/null || true)
    if [ "$RES" == 'True' ]; then
        log_trace "   certificate is ready!"
        break
    fi
    log_warn "   waiting certificate be ready..."
    sleep 5
done

# install ldap
#####################################
log_header "install $APP_NAME"
helm upgrade --install -n $NS ldap openldap-ha-chart -f values-ldap.yaml \
    --set global.adminPassword=$PASSWD \
    --set global.configPassword=$PASSWD
k8s_wait $NS statefulset ldap 60

# cronjob for refresh certs
kubectl delete -n $NS configmap restart-ldap 2>/dev/null || true
kubectl create -n $NS configmap restart-ldap --from-file='restart-ldap.sh'
kubectl apply -n $NS -f refresh-cert.yaml

# install ldap-web
#####################################
log_header "install ldap-web"
helm repo add bjw-s https://bjw-s-labs.github.io/helm-charts
[ -d temp/app-template ] || helm pull bjw-s/app-template --untar --untardir temp --version=$COMMON_CHART_VERSION
helm upgrade --install -n $NS ldap-web temp/app-template -f values-ldap-web.yaml

## done
log_trace "install success!!!"
log_trace "run command to get boostrap password:"
log_reminder "   kubectl get secret -n $NS ldap-ltb-passwd -o go-template='{{.data.LDAP_ADMIN_PASSWORD|base64decode}}{{ \"\\\n\" }}'"
