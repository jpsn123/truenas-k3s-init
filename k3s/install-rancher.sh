#!/bin/bash

set -e
cd $(dirname $0)
source ../common.sh
source ../parameter.sh

# install rancher
#####################################
log_header "install rancher"
render_values_file_to_temp values-rancher.yaml

kubectl create namespace cattle-system 2>/dev/null || true
helm repo add rancher-stable https://releases.rancher.com/server-charts/stable
[ -d temp/rancher ] || (helm repo update rancher-stable && helm pull rancher-stable/rancher --untar --untardir temp)
helm upgrade --install -n cattle-system rancher temp/rancher --wait --timeout 1200s -f temp/values-rancher.yaml
# done
log_trace "install rancher success!!!"
