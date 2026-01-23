#!/bin/bash

set -e
cd $(dirname $0)
source ../common.sh
source ../parameter.sh

# install ingress-nginx
#####################################
log_header "install ingress-nginx"
render_values_file_to_temp values-ingress.yaml

helm repo add ingress-nginx "https://kubernetes.github.io/ingress-nginx"
[ -d temp/ingress-nginx ] || (helm repo update ingress-nginx && helm pull ingress-nginx/ingress-nginx --untar --untardir temp)
kubectl create namespace ingress-nginx 2>/dev/null || true
helm upgrade --install ingress-nginx temp/ingress-nginx -n ingress-nginx --wait --timeout 600s -f ./temp/values-ingress.yaml

## done
log_trace "init success!!!"
