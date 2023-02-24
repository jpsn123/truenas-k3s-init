#!/bin/bash

cd `dirname $0`
source ../../common.sh
source ../../parameter.sh
NS=nextcloud

# initial
#####################################
echo -e "\033[42;30m initial \n\033[0m"
[ -d temp ] || mkdir temp
sed -i "s/example.com/${DOMAIN}/g" values-nextcloud.yaml

# update nextcloud
#####################################
echo -e "\033[42;30m update nextcloud \n\033[0m"
[ -d temp/nextcloud ] || (git clone https://github.com/jpsn123/helm.git ./temp && mv -f ./temp/charts/nextcloud ./temp && helm dependency build ./temp/nextcloud)
helm upgrade -n $NS nextcloud temp/nextcloud --reuse-values -f values-nextcloud.yaml
