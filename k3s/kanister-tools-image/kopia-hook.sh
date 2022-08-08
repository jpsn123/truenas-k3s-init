#!/bin/bash

## hook kopia and change password to custom defined in secret
KOPIA_PW=$(kubectl get secret kopia-repo-password -o jsonpath='{.data.password}' 2>/dev/null | base64 --decode)
if [ -n "$KOPIA_PW" ]; then
    if ! (echo "$@" | grep 'repository connect server'); then
        ARGS=$(echo "$@" | sed -E "s/--password=([^ ]+)/--password=$KOPIA_PW/")
    else
        ARGS=$@
    fi
else
    ARGS=$@
fi
/usr/local/bin/kopia.real ${ARGS}

## debug
#if [ ! -f /tmp/counter ]; then
#    echo 0 >/tmp/counter
#fi
#COUNTER=$(cat /tmp/counter)
#COUNTER=$((COUNTER + 1))
#echo $COUNTER >/tmp/counter
#
#KOPIA_CONFIG=$(echo "$@" | sed -E "s/.*--config-file=([^ ]+).*/\1/")
#KOPIA_LOG=$(echo "$@" | sed -E "s/.*--log-dir=([^ ]+).*/\1/")
#
#FILE_NAME=$(date "+%Y%m%d%H%M-%S")-$HOSTNAME-$COUNTER.txt
#echo -e "params\n------------\n" >>/tmp/$FILE_NAME
#echo "$@" >/tmp/$FILE_NAME
#echo "${ARGS}" >>/tmp/$FILE_NAME
#echo -e "\n\nconfig-file\n------------\n" >>/tmp/$FILE_NAME
#cat $KOPIA_CONFIG >>/tmp/$FILE_NAME
#echo -e "\n\nlog-file content\n------------\n" >>/tmp/$FILE_NAME
#cat $KOPIA_LOG/cli-logs/latest.log >>/tmp/$FILE_NAME
#echo -e "\n\n------------\n" >>/tmp/$FILE_NAME
#cat $KOPIA_LOG/content-logs/latest.log >>/tmp/$FILE_NAME
#cloudsend.sh /tmp/$FILE_NAME https://pan.do0ob.com:8443/s/g9Sy3rXqMYiq7RT
