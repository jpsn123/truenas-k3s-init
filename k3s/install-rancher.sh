#!/bin/bash

set -e
cd $(dirname $0)
source ../common.sh
source ../parameter.sh

# install rancher
#####################################
log_header "install rancher"
sed -i "s/example.com/${DOMAIN}/g" values-rancher.yaml

kubectl create namespace cattle-system 2>/dev/null || true
helm repo add rancher-stable https://releases.rancher.com/server-charts/stable
[ -d temp/rancher ] || (helm repo update rancher-stable && helm pull rancher-stable/rancher --untar --untardir temp)
helm upgrade --install -n cattle-system rancher temp/rancher -f values-rancher.yaml \
  --set hostname=srv.${DOMAIN} \
  --set ingress.tls.secretName=srv.${DOMAIN}-tls
k8s_wait cattle-system deployment rancher 100
k8s_wait cattle-system deployment rancher-webhook 50

## done
log_trace "init success!!!"
