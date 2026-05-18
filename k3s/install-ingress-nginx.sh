#!/bin/bash

set -e
cd $(dirname $0)
source ../common.sh
source ../parameter.sh

# install ingress-nginx
#####################################
log_header "install ingress-nginx"
render_values_file_to_temp values-ingress.yaml

helm repo add rke2-charts "https://rancher.github.io/rke2-charts"
[ -d temp/rke2-ingress-nginx ] || (helm repo update rke2-charts && helm pull rke2-charts/rke2-ingress-nginx --untar --untardir temp)
kubectl create namespace ingress-nginx 2>/dev/null || true
helm upgrade --install rke2-ingress-nginx temp/rke2-ingress-nginx -n ingress-nginx --wait --timeout 600s -f temp/values-ingress.yaml

# done
log_trace "install ingress-nginx success!!!"
