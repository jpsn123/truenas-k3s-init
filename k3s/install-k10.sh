#!/bin/bash

set -e
cd $(dirname $0)
source ../common.sh
source ../parameter.sh

NS=kasten-io
VERSION=8.5.0

# install k10 for backup
#####################################
log_header "install k10 for backup"
# init
kubectl create namespace $NS 2>/dev/null || true
if kubectl get secret k10-cluster-passphrase -n $NS >/dev/null 2>&1; then
    PASSWD=$(kubectl get secret k10-cluster-passphrase -n $NS -ojsonpath='{.data.passphrase}' | base64 --decode)
    log_info "reuse existing k10-cluster-passphrase."
else
    log_reminder "please input admin password seed for k10."
    read -p "password seed:"
    PASSWD=$(echo -n "$REPLY@k10" | sha1sum | awk '{print $1}' | base64 | head -c 32)
fi
copy_and_replace_default_values values-k10.yaml

# init
kubectl create namespace $NS 2>/dev/null || true
kubectl delete secret k10-cluster-passphrase -n $NS 2>/dev/null || true
kubectl create secret generic k10-cluster-passphrase --namespace $NS \
    --from-literal passphrase=$PASSWD
kubectl delete secret k10-dr-secret -n $NS 2>/dev/null || true
kubectl create secret generic k10-dr-secret --namespace $NS \
    --from-literal key=$PASSWD
kubectl delete secret kopia-repo-password -n $NS 2>/dev/null || true
kubectl create secret generic kopia-repo-password --namespace $NS \
    --from-literal password=$PASSWD
kubectl annotate volumesnapshotclass \
    $(kubectl get volumesnapshotclass -o=jsonpath='{.items[?(@.metadata.annotations.snapshot\.storage\.kubernetes\.io\/is-default-class=="true")].metadata.name}') \
    k10.kasten.io/is-snapshot-class=true

# install
helm repo add kasten https://charts.kasten.io/
[ -d temp/k10 ] || (helm repo update kasten && helm pull kasten/k10 --untar --untardir temp --version=$VERSION)
helm upgrade --install -n $NS k10 temp/k10 -f temp/values-k10.yaml

# change config excludedApps
RANCHER_NS_ARR=$(kubectl get ns -o=jsonpath='{.items[*].metadata.name}' | tr " " "\n" | grep -E 'cattle-|fleet-|local|p-[a-z0-9]+|user-|u-[a-z0-9]+')
IGRORE_STR=$(kubectl -n kasten-io get configmaps k10-config -o=jsonpath='{.data.excludedApps}')
NS_IGRORE_ARR=(${IGRORE_STR//,/ })
IGRORE_STR=($(echo "${RANCHER_NS_ARR[@]}" "${NS_IGRORE_ARR[@]}" | tr ' ' '\n' | sort -u | tr '\n' ','))
kubectl -n $NS patch configmap k10-config --type merge --patch \
    "{\"data\":{\"excludedApps\":\"${IGRORE_STR:0:-1}\"}}"

# optional, customize tool-images for self-defined kopia repo password
kubectl -n $NS patch configmap k10-config --type merge --patch \
    "{\"data\":{\"KanisterToolsImage\":\"jutze/kanister-tools:$VERSION\"}}"

# optional, use custom metering image, for node > 5
PATCH=$(
    cat <<EOF
spec:
  template:
    spec:
      containers:
      - name: metering-svc
        image: jutze/metering:$VERSION
EOF
)
kubectl patch -n $NS deployment metering-svc --patch "$PATCH"

# kill all k10 pods to reload config
kubectl -n $NS delete pod -l app.kubernetes.io/instance=k10

# create k10 admin token
#####################################
log_header "create k10 admin token"
kubectl --namespace kasten-io create serviceaccount my-k10-admin 2>/dev/null || true
kubectl apply --namespace=kasten-io --filename=- <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  labels:
    app.kubernetes.io/instance: k10
    app.kubernetes.io/name: k10
  name: kasten-my-k10-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: my-k10-admin
    namespace: kasten-io
EOF
kubectl apply --namespace=kasten-io --filename=- <<EOF
apiVersion: v1
kind: Secret
type: kubernetes.io/service-account-token
metadata:
  name: my-k10-admin
  annotations:
    kubernetes.io/service-account.name: "my-k10-admin"
EOF
TOKEN=$(kubectl get secret my-k10-admin --namespace kasten-io -ojsonpath="{.data.token}" | base64 --decode)
log_trace "\nk10 admin token: \n"
log_reminder "$TOKEN \n"

# done
log_trace "install k10 success!!!"
