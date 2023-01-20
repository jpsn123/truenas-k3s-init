#!/bin/bash

set -e
cd `dirname $0`
source common.sh
source parameter.sh

# install ingress-nginx
#####################################
echo -e "\033[42;30m install ingress-nginx\n\033[0m"
sed -i -e "s/^\(.*\)10.0.0.1/\1${INGRESS_IP}/g" values-ingress.yaml

helm repo add ingress-nginx "https://kubernetes.github.io/ingress-nginx"
[ -d temp/ingress-nginx ] || helm pull ingress-nginx/ingress-nginx --untar --untardir temp 2>/dev/null || true
k3s kubectl create namespace ingress-nginx 2>/dev/null || true
METHOD=install
[ `app_is_exist ingress-nginx ingress-nginx` == true ] && METHOD=upgrade
helm $METHOD ingress-nginx temp/ingress-nginx -n ingress-nginx -f values-ingress.yaml
k8s_wait ingress-nginx daemonset ingress-nginx-controller 50
PATCH=`cat<<EOF
spec:
  ports:
  - name: https2
    port: 8443
    protocol: TCP
    targetPort: https
EOF
`
kubectl patch -n ingress-nginx svc ingress-nginx-controller --patch "$PATCH"
