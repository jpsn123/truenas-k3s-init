#!/bin/bash

cd `dirname $0`
source ../../common.sh
source ../../parameter.sh

NS=ldap

# initial
#####################################
echo -e "\033[42;30m initial \n\033[0m"
kubectl create namespace $NS 2>/dev/null || true
kubectl delete -n $NS configmap ssp-images 2>/dev/null
kubectl create -n $NS configmap ssp-images \
  --from-file='bk.jpg' \
  --from-file='logo.png'

# replace example.com
sed -i "s/example.com/${DOMAIN}/g" values-ldap.yaml
sed -i "s/example.com/${DOMAIN}/g" values-ldap-web.yaml
# replace dc=example,dc=com
IFS='.'; DOMAIN_ARR=($DOMAIN); unset IFS;
LDAP_BASE="dc=${DOMAIN_ARR[0]},dc=${DOMAIN_ARR[1]}"
sed -i "s/dc=example,dc=com/${LDAP_BASE}/g" values-ldap.yaml
sed -i "s/dc=example,dc=com/${LDAP_BASE}/g" values-ldap-web.yaml
# replace tls
sed -i "s/example.com/${DOMAIN}/g" ldap-tls.yaml

# request ldap certificate
#####################################
kubectl apply -n $NS -f ldap-tls.yaml
for ((i=0;i<100;i++))
do
    RES=`kubectl get -n $NS certificate ldap-tls -o=jsonpath='{.status.conditions[0].status}' 2>/dev/null || true`
    if [ "$RES" == 'True'  ]; then
        echo -e "\033[34m   certificate is ready!  \033[0m"
        break
    fi
    echo -e "\033[33m   waiting certificate be ready...  \033[0m"
    sleep 5
done

# install ldap
#####################################
echo -e "\033[42;30m install ldap \n\033[0m"
METHOD=install
[ `app_is_exist $NS ldap` == true ] && METHOD=upgrade
helm $METHOD -n $NS ldap openldap-ha-chart -f values-ldap.yaml
k8s_wait $NS statefulset ldap 60

# cronjob for refresh certs
kubectl delete -n $NS configmap restart-ldap 2>/dev/null
kubectl create -n $NS configmap restart-ldap --from-file='restart-ldap.sh'
kubectl apply -n $NS -f refresh-cert.yaml

# install ldap-web
#####################################
echo -e "\033[42;30m install ldap-web \n\033[0m"
helm repo add bjw-s https://bjw-s.github.io/helm-charts
[ -d temp/app-template ] || helm pull bjw-s/app-template --untar --untardir temp --version=$COMMON_CHART_VERSION
METHOD=install
[ `app_is_exist $NS ldap-web` == true ] && METHOD=upgrade
helm $METHOD -n $NS ldap-web temp/app-template -f values-ldap-web.yaml