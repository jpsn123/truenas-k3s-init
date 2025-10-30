#!/bin/bash

cd $(dirname $0)
source ../../common.sh
source ../../parameter.sh
NS=nextcloud

# initial
#####################################
log_header "initial"
copy_and_replace_default_values values-*.yaml
kubectl -n $NS apply -f temp/values-configs.yaml

# update nextcloud
#####################################
log_header "update nextcloud"
[ -d temp/nextcloud ] || (git clone https://github.com/nextcloud/helm.git ./temp && mv -f ./temp/charts/nextcloud ./temp && helm dependency build ./temp/nextcloud)
helm upgrade -n $NS nextcloud temp/nextcloud --reuse-values -f temp/values-nextcloud.yaml
