#!/bin/bash

cd `dirname $0`
source ../../common.sh
source ../../parameter.sh
NS=nextcloud

echo -e '\033[35mplease input password for setting nextcloud. \033[0m'
read -p "password:"
REDIS_PW=`echo -n $REPLY@redis | md5sum | head -c 16`
DB_PW=`echo -n $REPLY@pg | md5sum | head -c 16`
NEXTCLOUD_PW=$REPLY

# initial
#####################################
echo -e "\033[42;30m initial \n\033[0m"
[ -d temp ] || mkdir temp
k3s kubectl create namespace $NS 2>/dev/null
k3s kubectl -n $NS delete secret nextcloud 2>/dev/null
k3s kubectl -n $NS create secret generic nextcloud \
    --from-literal=nextcloud-username=admin \
    --from-literal=nextcloud-password=$NEXTCLOUD_PW
sed -i "s/example.com/${DOMAIN}/g" values-nextcloud.yaml

# install nextcloud
#####################################
echo -e "\033[42;30m install nextcloud \n\033[0m"
[ -d temp/nextcloud ] || (git clone https://github.com/nextcloud/helm.git ./temp && mv -f ./temp/charts/nextcloud ./temp && helm dependency build ./temp/nextcloud)
METHOD=install
[ `app_is_exist $NS nextcloud` == true ] && METHOD=upgrade
helm $METHOD -n $NS nextcloud temp/nextcloud -f values-nextcloud.yaml \
    --set mariadb.auth.rootPassword=$DB_PW \
    --set mariadb.auth.password=$DB_PW \
    --set redis.auth.password=$REDIS_PW