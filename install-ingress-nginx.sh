#!/bin/bash

set -e
cd $(dirname $0)
source common.sh
source parameter.sh

# install ingress-nginx
#####################################
log_header "install ingress-nginx"
sed -i -e "s/^\(.*\)10.0.0.1/\1${INGRESS_IP}/g" values-ingress.yaml

helm repo add ingress-nginx "https://kubernetes.github.io/ingress-nginx"
[ -d temp/ingress-nginx ] || helm pull ingress-nginx/ingress-nginx --untar --untardir temp 2>/dev/null || true
kubectl create namespace ingress-nginx 2>/dev/null || true
helm upgrade --install ingress-nginx temp/ingress-nginx -n ingress-nginx -f values-ingress.yaml
k8s_wait ingress-nginx daemonset ingress-nginx-controller 50

## done
log_trace "init success!!!"
