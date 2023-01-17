#!/bin/bash

set -e
cd `dirname $0`
source common.sh
source parameter.sh

# install aliyun-ddns, update random public ipv4 or ipv6 whice assigned by ISP to globle dns server.
#####################################
echo -e "\033[42;30m install alidns-webhook for geting certificate automatically\n\033[0m"
UPDATE_TYPE='A'
if $UPDATE_IPV4 && $UPDATE_IPV6 ; then
  UPDATE_TYPE='A,AAAA'
elif $UPDATE_IPV4 ; then
  UPDATE_TYPE='A'
elif $UPDATE_IPV6 ; then
  UPDATE_TYPE='AAAA'
fi
k3s kubectl create namespace ddns 2>/dev/null || true
ALIDNS_SECRET_YAML=`cat<<EOF
apiVersion: v1
kind: Secret
metadata:
  name: alidns-secret
  namespace: ddns
data:
  access-key: $(echo -n "$ALI_ACCESS_KEY" | base64)
  secret-key: $(echo -n "$ALI_SECRET_KEY" | base64)
EOF
`
echo "$ALIDNS_SECRET_YAML">./temp/alidns-secret.yaml
k3s kubectl apply -f ./temp/alidns-secret.yaml

DDNS_YAML=`cat<<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    my-app: aliyun-ddns
  name: aliyun-ddns
  namespace: ddns
spec:
  progressDeadlineSeconds: 600
  replicas: 1
  selector:
    matchLabels:
      my-app: aliyun-ddns
  template:
    metadata:
      labels:
        my-app: aliyun-ddns
    spec:
      containers:
      - env:
        - name: AKID
          valueFrom:
            secretKeyRef:
              key: access-key
              name: alidns-secret
              optional: false
        - name: AKSCT
          valueFrom:
            secretKeyRef:
              key: secret-key
              name: alidns-secret
              optional: false
        - name: DOMAIN
          value: "${UPDATE_HOSTS}"
        - name: REDO
          value: "300"
        - name: TTL
          value: "600"
        - name: TIMEZONE
          value: "8"
        - name: TYPE
          value: ${UPDATE_TYPE}
        image: sanjusss/aliyun-ddns:latest
        imagePullPolicy: IfNotPresent
        name: controller
        terminationMessagePath: /dev/termination-log
        terminationMessagePolicy: File
      dnsPolicy: ClusterFirstWithHostNet
      hostNetwork: true
      restartPolicy: Always
      schedulerName: default-scheduler
      terminationGracePeriodSeconds: 30
EOF
`
echo "$DDNS_YAML">./temp/alidns-deployment.yaml
k3s kubectl apply -f ./temp/alidns-deployment.yaml