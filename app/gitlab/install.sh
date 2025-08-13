#!/bin/bash

cd $(dirname $0)
source ../../common.sh
source ../../parameter.sh
NS=gitlab

log_reminder "input password seed for setting gitlab."
read -p "password seed:"
MINIO_PW=$(echo -n "$REPLY@minio" | sha1sum | awk '{print $1}' | base64 | head -c 32)
REDIS_PW=$(echo -n $REPLY@redis | sha1sum | awk '{print $1}' | base64 | head -c 32)
DB_PW=$(echo -n $REPLY@pg | sha1sum | awk '{print $1}' | base64 | head -c 32)
ELASTICSEARCH_PW=$(echo -n $REPLY@elasticsearch | sha1sum | awk '{print $1}' | base64 | head -c 32)
GITLAB_PW=$(echo -n "$REPLY@gitlab" | sha1sum | awk '{print $1}' | base64 | head -c 32)

log_reminder "please input smtp password."
read -p "password:"
SMTP_PW=$REPLY

log_reminder "please input ldap password."
read -p "password:"
LDAP_PW=$REPLY

# initial
#####################################
log_header "initial"
[ -d temp ] || mkdir temp
kubectl create namespace $NS 2>/dev/null || true
kubectl -n $NS delete secret mail-password 2>/dev/null
kubectl -n $NS delete secret gitlab-rails-storage 2>/dev/null
kubectl -n $NS delete secret gitlab-toolbox-s3cmd 2>/dev/null
kubectl -n $NS delete secret gitlab-registry-storage 2>/dev/null
kubectl -n $NS delete secret gitlab-gitlab-initial-root-password 2>/dev/null
kubectl -n $NS delete secret ldap-password 2>/dev/null
kubectl -n $NS create secret generic mail-password --from-literal=password=$SMTP_PW
kubectl -n $NS create secret generic ldap-password --from-literal=password=$LDAP_PW
kubectl -n $NS create secret generic gitlab-rails-storage --from-file=connection=values-s3-rails.yaml
kubectl -n $NS create secret generic gitlab-toolbox-s3cmd --from-file=config='values-s3-backup.ini'
#kubectl -n $NS create secret generic gitlab-registry-storage --from-file=config=values-s3-registry.yaml
kubectl -n $NS create secret generic gitlab-gitlab-initial-root-password --from-literal=password=$GITLAB_PW
# replace
sed -i "s/example.com/${DOMAIN}/g" values-*.yaml
sed -i "s/sc-shared-example-cachefs/${DEFAULT_SHARED_CACHEFS_STORAGE_CLASS}/g" values-*.yaml
sed -i "s/sc-shared-example/${DEFAULT_SHARED_STORAGE_CLASS}/g" values-*.yaml
sed -i "s/sc-large-example/${DEFAULT_LARGE_STORAGE_CLASS}/g" values-*.yaml
sed -i "s/sc-example/${DEFAULT_STORAGE_CLASS}/g" values-*.yaml
# create certificates
kubectl apply -n $NS -f values-wildcard-tls.yaml
kubectl apply -n $NS -f values-pages-tls.yaml

# install minio
#####################################
log_header "install minio"
helm repo add bitnami https://charts.bitnami.com/bitnami
[ -d temp/minio ] || (helm repo update bitnami && helm pull bitnami/minio --untar --untardir temp --version=16.0.7)
helm upgrade --install -n $NS minio temp/minio -f values-minio.yaml \
    --set auth.rootPassword=$MINIO_PW
RES=$(cat values-s3-rails.yaml | grep aws_secret_access_key | sed -E "s/aws_secret_access_key:(.*)/\1/" | tr -d ' ')
if [ -z "$RES" ]; then
    log_reminder "please initial minio keys by web ui: https://s3.git.${DOMAIN}."
    exit 0
fi

# install postgresql
#####################################
log_header "install postgresql"
[ -d temp/postgresql ] || (helm repo update bitnami && helm pull bitnami/postgresql --untar --untardir temp --version=16.4.5)
helm upgrade --install -n $NS postgresql temp/postgresql -f values-postgresql.yaml \
    --set global.postgresql.auth.postgresPassword=$DB_PW \
    --set global.postgresql.auth.password=$DB_PW \
    --set auth.replicationPassword=$DB_PW
k8s_wait $NS statefulset postgresql 100
kubectl -n $NS exec postgresql-0 -- bash -c \
    'PGPASSWORD=${POSTGRES_PASSWORD} psql --dbname=gitlabhq_production --username=admin -c "CREATE EXTENSION IF NOT EXISTS pg_trgm; CREATE EXTENSION IF NOT EXISTS btree_gist; CREATE EXTENSION IF NOT EXISTS plpgsql;"'
kubectl -n $NS patch secret postgresql --type merge --patch \
    "{\"data\":{\"username\":\"$(echo -n admin | base64)\"}}"

# install redis
#####################################
log_header "install redis"
[ -d temp/redis ] || (helm repo update bitnami && helm pull bitnami/redis --untar --untardir temp --version=20.6.3)
helm upgrade --install -n $NS redis temp/redis -f values-redis.yaml \
    --set global.redis.password=$REDIS_PW
k8s_wait $NS statefulset redis-master 100

## install elasticsearch
#####################################
log_header "install elasticsearch"
[ -d temp/elasticsearch ] || (helm repo update bitnami && helm pull bitnami/elasticsearch --untar --untardir temp --version=21.6.0)
helm upgrade --install -n $NS elasticsearch temp/elasticsearch -f values-elasticsearch.yaml \
    --set security.elasticPassword=$ELASTICSEARCH_PW \
    --set kibana.elasticsearch.security.auth.kibanaPassword=$ELASTICSEARCH_PW
k8s_wait $NS statefulset elasticsearch-master 100

# install gitlab
#####################################
log_header "install gitlab"
helm repo add gitlab https://charts.gitlab.io
[ -d temp/gitlab ] || (helm repo update gitlab && helm pull gitlab/gitlab --untar --untardir temp)
helm upgrade --install -n $NS gitlab temp/gitlab -f values-gitlab.yaml
k8s_wait $NS statefulset gitlab-gitaly 200
k8s_wait $NS deployment gitlab-webservice-default 200

# self configuration and license
#####################################
log_header "self configuration"
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
