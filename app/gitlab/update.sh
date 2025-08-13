#!/bin/bash

## function to update component.
## $1 ~ $*: component names; example: minio postgresql redis gitlab elasticsearch

cd $(dirname $0)
source ../../common.sh
source ../../parameter.sh
NS=gitlab

# initial
#####################################
# replace
sed -i "s/example.com/${DOMAIN}/g" values-*.yaml
sed -i "s/sc-shared-example-cachefs/${DEFAULT_SHARED_CACHEFS_STORAGE_CLASS}/g" values-*.yaml
sed -i "s/sc-shared-example/${DEFAULT_SHARED_STORAGE_CLASS}/g" values-*.yaml
sed -i "s/sc-large-example/${DEFAULT_LARGE_STORAGE_CLASS}/g" values-*.yaml
sed -i "s/sc-example/${DEFAULT_STORAGE_CLASS}/g" values-*.yaml

UPDATE_MINIO=false
UPDATE_PGHA=false
UPDATE_REDIS=false
UPDATE_GITLAB=false
UPDATE_ES=false

for i in $*; do
    if [ "$i" == "postgresql-ha" ]; then
        UPDATE_PGHA=true
    elif [ "$i" == "minio" ]; then
        UPDATE_MINIO=true
    elif [ "$i" == "redis" ]; then
        UPDATE_REDIS=true
    elif [ "$i" == "gitlab" ]; then
        UPDATE_GITLAB=true
    elif [ "$i" == "elasticsearch" ]; then
        UPDATE_ES=true
    fi
done

# update minio
#####################################
if [ $UPDATE_MINIO == true ]; then
    log_header "update minio"
    [ -d temp/minio ] || (helm repo update bitnami && helm pull bitnami/minio --untar --untardir temp)
    helm upgrade -n $NS minio temp/minio -f values-minio.yaml
fi

# update postgresql
#####################################
if [ $UPDATE_PGHA == true ]; then
    log_header "update postgresql"
    [ -d temp/postgresql ] || (helm repo update bitnami && helm pull bitnami/postgresql --untar --untardir temp)
    helm upgrade -n $NS postgresql temp/postgresql -f values-postgresql.yaml
fi

# udpate redis
#####################################
if [ $UPDATE_REDIS == true ]; then
    log_header "update redis"
    [ -d temp/redis ] || (helm repo update bitnami && helm pull bitnami/redis --untar --untardir temp)
    helm upgrade -n $NS redis temp/redis --reuse-values -f redis-values.yaml
fi

# waiting dependency servers
#####################################
log_header "waiting dependency servers"
k8s_wait $NS statefulset postgresql 100
k8s_wait $NS statefulset redis-master 100

# update gitlab
#####################################
if [ $UPDATE_GITLAB == true ]; then
    log_header "update gitlab"
    [ -d temp/gitlab ] || (helm repo update gitlab && helm pull gitlab/gitlab --untar --untardir temp)
    helm upgrade -n $NS gitlab temp/gitlab -f values-gitlab.yaml
    k8s_wait $NS statefulset gitlab-gitaly 200
    k8s_wait $NS deployment gitlab-webservice-default 200
    log_info "    self configuration"
    kubectl delete -n $NS configmap self-configuration 2>/dev/null
    kubectl create -n $NS configmap self-configuration \
        --from-file='license_key.pub'
    DEPLOYMENT_PATCH=$(
        cat <<EOF
spec:
  template:
    spec:
      containers:
      - name: webservice
        volumeMounts:
        - mountPath: /srv/gitlab/.license_encryption_key.pub
          subPath: license_key.pub
          name: self-configuration-files
      volumes:
      - configMap:
          defaultMode: 420
          name: self-configuration
        name: self-configuration-files
EOF
    )
    kubectl patch -n $NS deployment gitlab-webservice-default --patch "$DEPLOYMENT_PATCH"
fi

# udpate elasticsearch
#####################################
if [ $UPDATE_ES == true ]; then
    log_header "update elasticsearch"
    [ -d temp/elasticsearch ] || (helm repo update bitnami && helm pull bitnami/elasticsearch --untar --untardir temp)
    helm upgrade -n $NS elasticsearch temp/elasticsearch --reuse-values -f elasticsearch-values.yaml
fi
