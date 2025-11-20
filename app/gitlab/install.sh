#!/bin/bash

cd $(dirname $0)
source ../../common.sh
source ../../parameter.sh
NS=gitlab

log_reminder "input password seed for setting gitlab."
read -p "password seed:"
MINIO_PW=$(echo -n "$REPLY@$NS@minio" | sha1sum | awk '{print $1}' | base64 | head -c 32)
REDIS_PW=$(echo -n "$REPLY@$NS@redis" | sha1sum | awk '{print $1}' | base64 | head -c 32)
DB_PW=$(echo -n "$REPLY@$NS@pg" | sha1sum | awk '{print $1}' | base64 | head -c 32)
ELASTICSEARCH_PW=$(echo -n "$REPLY@$NS@elasticsearch" | sha1sum | awk '{print $1}' | base64 | head -c 32)
GITLAB_PW=$(echo -n "$REPLY@$NS@gitlab" | sha1sum | awk '{print $1}' | base64 | head -c 32)

log_reminder "please input smtp password."
read -p "password:"
SMTP_PW=$REPLY

log_reminder "please input ldap password."
read -p "password:"
LDAP_PW=$REPLY

# initial
#####################################
log_header "initial"
kubectl create namespace $NS 2>/dev/null || true
copy_and_replace_default_values values-*.yaml
copy_and_replace_default_values values-*.ini
kubectl -n $NS delete secret mail-password 2>/dev/null
kubectl -n $NS delete secret gitlab-rails-storage 2>/dev/null
kubectl -n $NS delete secret gitlab-toolbox-s3cmd 2>/dev/null
kubectl -n $NS delete secret gitlab-registry-storage 2>/dev/null
kubectl -n $NS delete secret gitlab-gitlab-initial-root-password 2>/dev/null
kubectl -n $NS delete secret ldap-password 2>/dev/null
kubectl -n $NS create secret generic mail-password --from-literal=password=$SMTP_PW
kubectl -n $NS create secret generic ldap-password --from-literal=password=$LDAP_PW
kubectl -n $NS create secret generic gitlab-rails-storage --from-file=connection=temp/values-s3-rails.yaml
kubectl -n $NS create secret generic gitlab-toolbox-s3cmd --from-file=config='temp/values-s3-backup.ini'
#kubectl -n $NS create secret generic gitlab-registry-storage --from-file=config=temp/values-s3-registry.yaml
kubectl -n $NS create secret generic gitlab-gitlab-initial-root-password --from-literal=password=$GITLAB_PW
# create certificates
kubectl apply -n $NS -f temp/values-wildcard-tls.yaml
kubectl apply -n $NS -f temp/values-pages-tls.yaml

# install minio
#####################################
log_header "install minio"
[ -d temp/minio ] || (helm pull oci://registry-1.docker.io/bitnamicharts/minio --untar --untardir temp --version=16.0.10)
helm upgrade --install -n $NS minio temp/minio -f temp/values-minio.yaml \
    --set auth.rootPassword=$MINIO_PW
RES=$(cat values-s3-rails.yaml | grep aws_secret_access_key | sed -E "s/aws_secret_access_key:(.*)/\1/" | tr -d ' ')
if [ -z "$RES" ]; then
    log_reminder "please initial minio keys by web ui: https://s3.git.${DOMAIN}."
    exit 0
fi

# install postgresql
#####################################
log_header "install postgresql"
[ -d temp/postgresql ] || (helm pull oci://registry-1.docker.io/bitnamicharts/postgresql --untar --untardir temp --version=16.7.27)
helm upgrade --install -n $NS postgresql temp/postgresql --wait --timeout 600s -f temp/values-postgresql.yaml \
    --set global.postgresql.auth.postgresPassword=$DB_PW \
    --set global.postgresql.auth.password=$DB_PW \
    --set auth.replicationPassword=$DB_PW
kubectl -n $NS exec postgresql-0 -- bash -c \
    'PGPASSWORD=$(cat ${POSTGRES_POSTGRES_PASSWORD_FILE}) psql --dbname=gitlabhq_production --username=admin -c "CREATE EXTENSION IF NOT EXISTS pg_trgm; CREATE EXTENSION IF NOT EXISTS btree_gist; CREATE EXTENSION IF NOT EXISTS plpgsql;"'
kubectl -n $NS patch secret postgresql --type merge --patch \
    "{\"data\":{\"username\":\"$(echo -n admin | base64)\"}}"

# install redis
#####################################
log_header "install redis"
[ -d temp/redis ] || (helm pull oci://registry-1.docker.io/bitnamicharts/redis --untar --untardir temp --version=22.0.7)
helm upgrade --install -n $NS redis temp/redis --wait --timeout 600s -f temp/values-redis.yaml \
    --set global.redis.password=$REDIS_PW

## install elasticsearch
#####################################
log_header "install elasticsearch"
[ -d temp/elasticsearch ] || (helm pull oci://registry-1.docker.io/bitnamicharts/elasticsearch --untar --untardir temp --version=22.1.6)
helm upgrade --install -n $NS elasticsearch temp/elasticsearch --wait --timeout 600s -f temp/values-elasticsearch.yaml \
    --set security.elasticPassword=$ELASTICSEARCH_PW \
    --set kibana.elasticsearch.security.auth.kibanaPassword=$ELASTICSEARCH_PW

# install gitlab
#####################################
log_header "install gitlab"
helm repo add gitlab https://charts.gitlab.io
[ -d temp/gitlab ] || (helm repo update gitlab && helm pull gitlab/gitlab --untar --untardir temp)
helm upgrade --install -n $NS gitlab temp/gitlab -f temp/values-gitlab.yaml

# self configuration and license
#####################################
log_header "self configuration"
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