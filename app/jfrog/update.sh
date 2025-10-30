#!/bin/bash

## function to update component.
## $1 ~ $*: component names; example: jfrog

cd $(dirname $0)
source ../../common.sh
NS=jfrog

# initial
#####################################
UPDATE_JFROG=false

for i in $*; do
    if [ "$i" == "jfrog" ]; then
        UPDATE_JFROG=true
    fi
done

# update jfrog
#####################################
if [ $UPDATE_JFROG == true ]; then
    echo -e "\033[42;30m update jfrog-platform \n\033[0m"
    [ -d temp/jfrog-platform ] || (helm repo update jfrog && helm pull jfrog/jfrog-platform --untar --untardir temp)
    helm upgrade -n $NS jfrog-platform temp/jfrog-platform --reuse-values -f jfrog-values.yaml \
        --set gaUpgradeReady=true
fi
