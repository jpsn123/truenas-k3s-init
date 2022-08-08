#!/bin/bash

set -e
cd `dirname $0`
source common.sh
source parameter.sh

# install ingress-nginx
#####################################
echo -e "\033[42;30m install ingress-nginx\n\033[0m"
helm repo add ingress-nginx "https://kubernetes.github.io/ingress-nginx"
[ -d temp/ingress-nginx ] || helm pull ingress-nginx/ingress-nginx --untar --untardir temp 2>/dev/null || true
k3s kubectl create namespace ingress-nginx 2>/dev/null || true
METHOD=install
[ `app_is_exist ingress-nginx ingress-nginx` == true ] && METHOD=upgrade
helm $METHOD ingress-nginx temp/ingress-nginx -n ingress-nginx -f ingress-values.yaml
k8s_wait ingress-nginx daemonset ingress-nginx-controller 50