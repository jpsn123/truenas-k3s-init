#!/bin/bash

## function to update component.
## $1 ~ $*: component names; example: minio postgresql redis gitlab elasticsearch

cd $(dirname $0)
source ../../common.sh
source ../../parameter.sh
NS=gitlab

# initial
#####################################
copy_and_replace_default_values values-*.yaml
copy_and_replace_default_values values-*.ini
kubectl -n $NS delete secret gitlab-rails-storage 2>/dev/null
kubectl -n $NS delete secret gitlab-toolbox-s3cmd 2>/dev/null
kubectl -n $NS delete secret gitlab-registry-storage 2>/dev/null
kubectl -n $NS create secret generic gitlab-rails-storage --from-file=connection=temp/values-s3-rails.yaml
kubectl -n $NS create secret generic gitlab-toolbox-s3cmd --from-file=config='temp/values-s3-backup.ini'
#kubectl -n $NS create secret generic gitlab-registry-storage --from-file=config=temp/values-s3-registry.yaml

UPDATE_MINIO=false
UPDATE_PG=false
UPDATE_REDIS=false
UPDATE_GITLAB=false
UPDATE_ES=false

for i in $*; do
    if [ "$i" == "postgresql" ]; then
        UPDATE_PG=true
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
    [ -d temp/minio ] || (helm pull oci://registry-1.docker.io/bitnamicharts/minio --untar --untardir temp)
    helm upgrade -n $NS minio temp/minio -f temp/values-minio.yaml
fi

# update postgresql
#####################################
if [ $UPDATE_PG == true ]; then
    log_header "update postgresql"
    [ -d temp/postgresql ] || (helm pull oci://registry-1.docker.io/bitnamicharts/postgresql --untar --untardir temp)
    helm upgrade -n $NS postgresql temp/postgresql -f temp/values-postgresql.yaml
fi

# udpate redis
#####################################
if [ $UPDATE_REDIS == true ]; then
    log_header "update redis"
    [ -d temp/redis ] || (helm pull oci://registry-1.docker.io/bitnamicharts/redis --untar --untardir temp)
    helm upgrade -n $NS redis temp/redis --reuse-values -f temp/values-redis.yaml
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
    helm upgrade -n $NS gitlab temp/gitlab -f temp/values-gitlab.yaml
    log_info "    self configuration"
    kubectl delete -n $NS configmap self-configuration 2>/dev/null
    kubectl create -n $NS configmap self-configuration \
        --from-file='license_key.pub'
    WEBSERVICE_PATCH=$(
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
    kubectl patch -n $NS deployment gitlab-webservice-default --patch "$WEBSERVICE_PATCH"

    TOOLBOX_PATCH=$(
        cat <<EOF
spec:
  template:
    spec:
      containers:
      - name: toolbox
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
    kubectl patch -n $NS deployment gitlab-toolbox --patch "$TOOLBOX_PATCH"

    SIDEKIQ_PATCH=$(
        cat <<EOF
spec:
  template:
    spec:
      containers:
      - name: sidekiq
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
    kubectl patch -n $NS deployment gitlab-sidekiq-all-in-1-v2 --patch "$SIDEKIQ_PATCH"
fi

# udpate elasticsearch
#####################################
if [ $UPDATE_ES == true ]; then
    log_header "update elasticsearch"
    [ -d temp/elasticsearch ] || (helm pull oci://registry-1.docker.io/bitnamicharts/elasticsearch --untar --untardir temp)
    helm upgrade -n $NS elasticsearch temp/elasticsearch --reuse-values -f temp/values-elasticsearch.yaml
fi
