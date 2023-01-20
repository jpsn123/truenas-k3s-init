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
sed -i "s/example.com/${DOMAIN}/g" values-emby.yaml

# install emby
#####################################
echo -e "\033[42;30m install emby \n\033[0m"
helm repo add k8s-at-home https://k8s-at-home.com/charts/
[ -d temp/emby ] || helm pull k8s-at-home/emby --untar --untardir temp
METHOD=install
[ `app_is_exist $NS emby` == true ] && METHOD=upgrade
helm $METHOD -n $NS emby temp/emby -f values-emby.yaml
k8s_wait $NS deployment emby 100

# install MetaTube, copy MetaTube.dll to plugins dir
#####################################
echo -e "\033[42;30m install MetaTube, copy MetaTube.dll to plugins dir \n\033[0m"
kubectl apply -n $NS -f plugin-deploy.yaml
POD_NAME=`kubectl get pod -n $NS -l app.kubernetes.io/name=emby -o jsonpath="{.items[0].metadata.name}"`
kubectl cp MetaTube.dll $NS/$POD_NAME:/config/plugins -c emby
kubectl cp MetaTube.xml $NS/$POD_NAME:/config/plugins/configurations -c emby
kubectl delete -n $NS pod $POD_NAME
