#!/bin/bash

set -e
cd $(dirname $0)
source ../common.sh
source ../parameter.sh

# install cert-manager
#####################################
log_header "install cert-manager"
helm repo add jetstack "https://charts.jetstack.io"
[ -d temp/cert-manager ] || (helm repo update jetstack && helm pull jetstack/cert-manager --untar --untardir temp 2>/dev/null)
kubectl create namespace cert-manager 2>/dev/null || true
helm upgrade --install -n cert-manager cert-manager temp/cert-manager \
  --set crds.enabled=true \
  --set extraArgs={--enable-certificate-owner-ref}
k8s_wait cert-manager deployment cert-manager 50
k8s_wait cert-manager deployment cert-manager-cainjector 50
k8s_wait cert-manager deployment cert-manager-webhook 50

## done
log_trace "init success!!!"
