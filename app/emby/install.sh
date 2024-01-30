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
helm repo add bjw-s https://bjw-s.github.io/helm-charts
[ -d temp/app-template ] || helm pull bjw-s/app-template --untar --untardir temp
METHOD=install
[ `app_is_exist $NS $APP_NAME` == true ] && METHOD=upgrade
helm $METHOD -n $NS $APP_NAME temp/app-template -f values-emby.yaml
k8s_wait $NS deployment $APP_NAME 100

# install MetaTube, copy MetaTube.dll to plugins dir
#####################################
echo -e "\033[42;30m install MetaTube, copy MetaTube.dll to plugins dir \n\033[0m"
kubectl apply -n $NS -f plugin-deploy.yaml
POD_NAME=`kubectl get pod -n $NS -l app.kubernetes.io/name=emby -o jsonpath="{.items[0].metadata.name}"`
kubectl cp MetaTube.dll $NS/$POD_NAME:/config/plugins -c emby
kubectl cp MetaTube.xml $NS/$POD_NAME:/config/plugins/configurations -c emby
kubectl delete -n $NS pod $POD_NAME
