#!/bin/bash

set -e
cd `dirname $0`
source common.sh
source parameter.sh

# install cert-manager
#####################################
echo -e "\033[42;30m install cert-manager\n\033[0m"
helm repo add jetstack "https://charts.jetstack.io"
[ -d temp/cert-manager ] || helm pull jetstack/cert-manager --untar --untardir temp 2>/dev/null || true
k3s kubectl create namespace cert-manager 2>/dev/null || true
METHOD=install
[ `app_is_exist cert-manager cert-manager` == true ] && METHOD=upgrade
helm $METHOD --namespace cert-manager cert-manager temp/cert-manager \
  --set crds.enabled=true \
  --set extraArgs={--enable-certificate-owner-ref}
k8s_wait cert-manager deployment cert-manager 50
k8s_wait cert-manager deployment cert-manager-cainjector 50
k8s_wait cert-manager deployment cert-manager-webhook 50