#!/bin/bash

cd `dirname $0`
source ../../common.sh
source ../../parameter.sh

# initial
#####################################
echo -e "\033[42;30m initial \n\033[0m"
NS=emby
[ -d temp ] || mkdir temp
k3s kubectl create namespace $NS 2>/dev/null
sed -i "s/example.com/${DOMAIN}/g" emby-values.yaml

# install emby
#####################################
echo -e "\033[42;30m install emby \n\033[0m"
helm repo add k8s-at-home https://k8s-at-home.com/charts/
[ -d temp/emby ] || helm pull k8s-at-home/emby --untar --untardir temp
METHOD=install
[ `app_is_exist $NS emby` == true ] && METHOD=upgrade
helm $METHOD -n $NS emby temp/emby -f emby-values.yaml