#!/bin/bash

cd `dirname $0`
source ../../common.sh
source ../../parameter.sh

NS=fivem
APP_NAME=fivem

echo -e '\033[35mplease input password for database. \033[0m'
read -p "password:"
DB_PW=`echo -n $REPLY@mysql | md5sum | head -c 16`

# initial
#####################################
echo -e "\033[42;30m initial \n\033[0m"
[ -d temp ] || mkdir temp
k3s kubectl create namespace $NS 2>/dev/null
sed -i "s/example.com/${DOMAIN}/g" values-fivem.yaml
sed -i "s/sc-example/${STORAGE_CLASS_NAME}/g" values-fivem.yaml

# install mysql for fivem
#####################################
echo -e "\033[42;30m install mysql \n\033[0m"
helm repo add bitnami https://charts.bitnami.com/bitnami 
[ -d temp/mysql ] || helm pull bitnami/mysql --untar --untardir temp --version=$COMMON_CHART_VERSION
METHOD=install
[ `app_is_exist $NS mysql` == true ] && METHOD=upgrade
helm $METHOD -n $NS mysql temp/mysql -f values-mysql.yaml \
    --set auth.rootPassword=$DB_PW \
    --set auth.password=$DB_PW \
    --set auth.replicationPassword=$DB_PW 

# install fivem
#####################################
echo -e "\033[42;30m install fivem \n\033[0m"
helm repo add bjw-s https://bjw-s.github.io/helm-charts
[ -d temp/app-template ] || helm pull bjw-s/app-template --untar --untardir temp --version=$COMMON_CHART_VERSION
METHOD=install
[ `app_is_exist $NS $APP_NAME` == true ] && METHOD=upgrade
helm $METHOD -n $NS $APP_NAME temp/app-template -f values-fivem.yaml
k8s_wait $NS deployment $APP_NAME 100
