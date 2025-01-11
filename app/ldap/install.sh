#!/bin/bash

cd $(dirname $0)
source ../../common.sh
source ../../parameter.sh

NS=ldap
APP_NAME=ldap

# initial
#####################################
log_info "initial"
kubectl create namespace $NS 2>/dev/null || true
kubectl delete -n $NS configmap ssp-images 2>/dev/null
kubectl create -n $NS configmap ssp-images \
    --from-file='bk.jpg' \
    --from-file='logo.png'

# replace example.com
sed -i "s/example.com/${DOMAIN}/g" values-ldap.yaml
sed -i "s/example.com/${DOMAIN}/g" values-ldap-web.yaml
# replace sc
sed -i "s/sc-example/${STORAGE_CLASS_NAME}/g" values-ldap.yaml
sed -i "s/sc-example/${STORAGE_CLASS_NAME}/g" values-ldap-web.yaml
# replace dc=example,dc=com
IFS='.' && DOMAIN_ARR=($DOMAIN) && unset IFS
LDAP_BASE="dc=${DOMAIN_ARR[0]},dc=${DOMAIN_ARR[1]}"
sed -i "s/dc=example,dc=com/${LDAP_BASE}/g" values-ldap.yaml
sed -i "s/dc=example,dc=com/${LDAP_BASE}/g" values-ldap-web.yaml
# replace tls
sed -i "s/example.com/${DOMAIN}/g" ldap-tls.yaml

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
log_info "install $APP_NAME"
helm upgrade --install -n $NS ldap openldap-ha-chart -f values-ldap.yaml
k8s_wait $NS statefulset ldap 60

# cronjob for refresh certs
kubectl delete -n $NS configmap restart-ldap 2>/dev/null
kubectl create -n $NS configmap restart-ldap --from-file='restart-ldap.sh'
kubectl apply -n $NS -f refresh-cert.yaml

# install ldap-web
#####################################
log_info "install ldap-web"
helm repo add bjw-s https://bjw-s.github.io/helm-charts
[ -d temp/app-template ] || helm pull bjw-s/app-template --untar --untardir temp --version=$COMMON_CHART_VERSION
helm upgrade --install -n $NS ldap-web temp/app-template -f values-ldap-web.yaml

## done
log_trace "init success!!!"
