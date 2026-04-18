#!/bin/bash

set -e
cd $(dirname $0)
source ../../common.sh
source ../../parameter.sh

NS=rustdesk

# initial
#####################################
log_header "initial"
kubectl create namespace $NS 2>/dev/null || true
render_values_file_to_temp values-*.yaml
helm repo add bjw-s https://bjw-s-labs.github.io/helm-charts
[ -d temp/app-template ] || (helm repo update bjw-s && helm pull bjw-s/app-template --untar --untardir temp --version=$COMMON_CHART_VERSION)

# install rustdesk server
#####################################
log_header "install rustdesk server"
helm upgrade --install -n $NS rustdesk temp/app-template --wait --timeout 600s -f temp/values-rustdesk.yaml

## done
log_trace "install rustdesk success!!!"
log_reminder "   run command to get public key:"
log_reminder "   kubectl -n $NS exec -it deployment/rustdesk-hbbs -- cat /root/id_ed25519.pub"
