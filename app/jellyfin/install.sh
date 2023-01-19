#!/bin/bash

cd `dirname $0`
source ../../common.sh
source ../../parameter.sh

# initial
#####################################
echo -e "\033[42;30m initial \n\033[0m"
NS=jellyfin
[ -d temp ] || mkdir temp
k3s kubectl create namespace $NS 2>/dev/null
sed -i "s/example.com/${DOMAIN}/g" jellyfin-values.yaml

# install jellyfin
#####################################
echo -e "\033[42;30m install jellyfin \n\033[0m"
helm repo add k8s-at-home https://k8s-at-home.com/charts/
[ -d temp/jellyfin ] || helm pull k8s-at-home/jellyfin --untar --untardir temp
METHOD=install
[ `app_is_exist $NS jellyfin` == true ] && METHOD=upgrade
helm $METHOD -n $NS jellyfin temp/jellyfin -f jellyfin-values.yaml