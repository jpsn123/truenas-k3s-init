#!/bin/bash

set -e
cd $(dirname $0)
source ../../common.sh
source ../../parameter.sh

NS=openldap

# initial
#####################################
log_header "initial"
kubectl create namespace $NS 2>/dev/null || true
if kubectl get secret openldap-passwd -n $NS >/dev/null 2>&1; then
    PASSWD=$(kubectl get secret openldap-passwd -n $NS -ojsonpath='{.data.LAM_ADMIN_PASSWORD}' | base64 --decode)
    SMTP_PASSWD=$(kubectl get secret openldap-passwd -n $NS -ojsonpath='{.data.SMTP_PASS}' | base64 --decode)
    log_info "reuse existing openldap password."
fi
if [ -z "$PASSWD" ]; then
    log_reminder "please input admin password seed."
    read -p "password seed:"
    PASSWD=$(echo -n "$REPLY@$NS@ldap" | sha1sum | awk '{print $1}' | base64 | head -c 32)
fi
if [ -z "$SMTP_PASSWD" ]; then
    log_reminder "please input smtp password."
    read -p "password:"
    SMTP_PASSWD=$REPLY
fi
kubectl delete -n $NS configmap ssp-images 2>/dev/null || true
kubectl create -n $NS configmap ssp-images \
    --from-file='bk.jpg' \
    --from-file='logo.png'
kubectl delete -n $NS secret openldap-passwd 2>/dev/null || true
kubectl create -n $NS secret generic openldap-passwd \
    --from-literal SMTP_PASS=$SMTP_PASSWD \
    --from-literal LAM_ADMIN_PASSWORD=$PASSWD
copy_and_replace_default_values values-*.yaml
# replace dc=example,dc=com
IFS='.' && DOMAIN_ARR=($DOMAIN) && unset IFS
LDAP_BASE="dc=${DOMAIN_ARR[0]},dc=${DOMAIN_ARR[1]}"
sed -i "s/dc=example,dc=com/${LDAP_BASE}/g" temp/values-*.yaml

# request ldap certificate
#####################################
kubectl apply -n $NS -f temp/values-ldap-tls.yaml
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
log_header "install openldap"
helm upgrade --install -n $NS ldap openldap-ha-chart --wait --timeout 600s -f temp/values-ldap.yaml \
    --set global.adminPassword=$PASSWD \
    --set global.configPassword=$PASSWD

# cronjob for refresh certs
kubectl delete -n $NS configmap restart-ldap 2>/dev/null || true
kubectl create -n $NS configmap restart-ldap --from-file='restart-ldap.sh'
kubectl apply -n $NS -f refresh-cert.yaml

# install ldap-web
#####################################
log_header "install ldap-web"
helm repo add bjw-s https://bjw-s-labs.github.io/helm-charts
[ -d temp/app-template ] || helm pull bjw-s/app-template --untar --untardir temp --version=$COMMON_CHART_VERSION
helm upgrade --install -n $NS ldap-web temp/app-template -f temp/values-ldap-web.yaml

## done
log_trace "install success!!!"
log_trace "run command to get boostrap password:"
log_reminder "   kubectl get secret -n $NS ldap-ltb-passwd -o go-template='{{.data.LDAP_ADMIN_PASSWORD|base64decode}}{{ \"\\\n\" }}'"
