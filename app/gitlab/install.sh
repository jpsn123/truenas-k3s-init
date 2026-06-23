#!/bin/bash

set -e
cd $(dirname $0)
source ../../common.sh
source ../../parameter.sh
NS=gitlab
INSTALL_MODE="${1:-full}"
validate_install_mode "$INSTALL_MODE" minio postgresql redis gitlab elasticsearch

# initial
#####################################
log_header "initial"
kubectl create namespace $NS 2>/dev/null || true
load_secret_vars "$NS" "minio" root-password=MINIO_PW
load_secret_vars "$NS" "redis" redis-password=REDIS_PW
load_secret_vars "$NS" "postgresql" password=DB_PW
load_secret_vars "$NS" "elasticsearch" elasticsearch-password=ELASTICSEARCH_PW
load_secret_vars "$NS" "gitlab-gitlab-initial-root-password" password=GITLAB_PW
load_secret_vars "$NS" "mail-password" password=SMTP_PW
load_secret_vars "$NS" "ldap-password" password=LDAP_PW
load_secret_vars "$NS" "gitlab-oidc" \
    client-id=OIDC_CLIENT_ID \
    client-secret=OIDC_CLIENT_SECRET \
    icon=OIDC_ICON \
    label=OIDC_LABEL
load_configmap_vars "$NS" "mail-config" \
    smtp-address=SMTP_ADDRESS \
    smtp-port=SMTP_PORT \
    smtp-user-name=SMTP_USER_NAME \
    email-from=EMAIL_FROM \
    email-reply-to=EMAIL_REPLY_TO
load_configmap_vars "$NS" "gitlab-shell" \
    load-balancer-ip=GITLAB_SHELL_LOAD_BALANCER_IP
load_configmap_vars "$NS" "gitlab-install-version" \
    gitlab-chart-version=GITLAB_CHART_VERSION \
    gitlab-app-version=GITLAB_APP_VERSION
if (install_mode_enabled "$INSTALL_MODE" minio && [ -z "$MINIO_PW" ]) \
    || (install_mode_enabled "$INSTALL_MODE" redis && [ -z "$REDIS_PW" ]) \
    || (install_mode_enabled "$INSTALL_MODE" postgresql && [ -z "$DB_PW" ]) \
    || (install_mode_enabled "$INSTALL_MODE" elasticsearch && [ -z "$ELASTICSEARCH_PW" ]) \
    || (install_mode_enabled "$INSTALL_MODE" gitlab && [ -z "$GITLAB_PW" ]); then
    PASSWORD_SEED=$(prompt_required "input password seed for setting gitlab." "password seed" "")
fi
if install_mode_enabled "$INSTALL_MODE" minio && [ -z "$MINIO_PW" ]; then
    MINIO_PW=$(derive_password_sha1 "$PASSWORD_SEED" "$NS@minio" 32)
fi
if install_mode_enabled "$INSTALL_MODE" redis && [ -z "$REDIS_PW" ]; then
    REDIS_PW=$(derive_password_sha1 "$PASSWORD_SEED" "$NS@redis" 32)
fi
if install_mode_enabled "$INSTALL_MODE" postgresql && [ -z "$DB_PW" ]; then
    DB_PW=$(derive_password_sha1 "$PASSWORD_SEED" "$NS@pg" 32)
fi
if install_mode_enabled "$INSTALL_MODE" elasticsearch && [ -z "$ELASTICSEARCH_PW" ]; then
    ELASTICSEARCH_PW=$(derive_password_sha1 "$PASSWORD_SEED" "$NS@elasticsearch" 32)
fi
if install_mode_enabled "$INSTALL_MODE" gitlab && [ -z "$GITLAB_PW" ]; then
    GITLAB_PW=$(derive_password_sha1 "$PASSWORD_SEED" "$NS@gitlab" 32)
fi
if install_mode_enabled "$INSTALL_MODE" gitlab; then
    if [ -z "$LDAP_PW" ]; then
        LDAP_PW=$(prompt_required "please input ldap password." "password" "")
    fi
    if [ -z "$OIDC_CLIENT_ID" ]; then
        OIDC_CLIENT_ID=$(prompt_required "please input gitlab oauth config, redirect URI: https://git.${DOMAIN}/users/auth/openid_connect/callback." "oidc client id" "")
    fi
    if [ -z "$OIDC_CLIENT_SECRET" ]; then
        OIDC_CLIENT_SECRET=$(prompt_required "" "oidc client secret" -s)
    fi
    if [ -z "$OIDC_ICON" ]; then
        OIDC_ICON=$(prompt_with_default "" "oidc icon" "")
    fi
    if [ -z "$OIDC_LABEL" ]; then
        OIDC_LABEL=$(prompt_with_default "" "oidc label" "${BRAND_PREFIX^} Auth")
    fi
    if [ -z "$SMTP_PW" ]; then
        SMTP_PW=$(prompt_required "please input smtp password." "password" "")
    fi
    if [ -z "$SMTP_ADDRESS" ]; then
        SMTP_ADDRESS=$(prompt_with_default "" "smtp address" "smtp.qiye.163.com")
    fi
    if [ -z "$SMTP_PORT" ]; then
        SMTP_PORT=$(prompt_with_default "" "smtp port" "994")
    fi
    if [ -z "$SMTP_USER_NAME" ]; then
        SMTP_USER_NAME=$(prompt_with_default "" "smtp user name" "$EMAIL")
    fi
    if [ -z "$EMAIL_FROM" ]; then
        EMAIL_FROM=$(prompt_with_default "" "email from" "$SMTP_USER_NAME")
    fi
    if [ -z "$EMAIL_REPLY_TO" ]; then
        EMAIL_REPLY_TO=$(prompt_with_default "" "email reply_to" "$EMAIL")
    fi
    GITLAB_SHELL_LOAD_BALANCER_IP_CONFIGURED=$(kubectl -n "$NS" get configmap "gitlab-shell" -o go-template='{{ range $key, $value := .data }}{{ if eq $key "load-balancer-ip" }}true{{ end }}{{ end }}' 2>/dev/null || true)
    if [ "$GITLAB_SHELL_LOAD_BALANCER_IP_CONFIGURED" != "true" ]; then
        GITLAB_SHELL_LOAD_BALANCER_IP=$(prompt_with_default "" "gitlab shell load balancer ip" "10.33.0.5")
    fi
fi

render_values_file_to_temp values-*.yaml
render_values_file_to_temp values-*.ini
if install_mode_enabled "$INSTALL_MODE" gitlab; then
    apply_secret_vars "$NS" "mail-password" password=SMTP_PW
    apply_secret_vars "$NS" "ldap-password" password=LDAP_PW
    apply_configmap_vars "$NS" "mail-config" \
        smtp-address=SMTP_ADDRESS \
        smtp-port=SMTP_PORT \
        smtp-user-name=SMTP_USER_NAME \
        email-from=EMAIL_FROM \
        email-reply-to=EMAIL_REPLY_TO
    apply_configmap_vars "$NS" "gitlab-shell" \
        load-balancer-ip=GITLAB_SHELL_LOAD_BALANCER_IP
    apply_secret_generic "$NS" "gitlab-oidc" \
        --from-literal=client-id="$OIDC_CLIENT_ID" \
        --from-literal=client-secret="$OIDC_CLIENT_SECRET" \
        --from-literal=icon="$OIDC_ICON" \
        --from-literal=label="$OIDC_LABEL" \
        --from-file=provider=temp/values-oidc.yaml
    apply_secret_vars "$NS" "gitlab-gitlab-initial-root-password" password=GITLAB_PW
    # create certificates
    kubectl apply -n $NS -f temp/values-wildcard-tls.yaml
    kubectl apply -n $NS -f temp/values-pages-tls.yaml
fi

# install minio
#####################################
if install_mode_enabled "$INSTALL_MODE" minio; then
    log_header "install minio"
    ensure_helm_repo_chart "bitnami" "oci://registry-1.docker.io/bitnamicharts" "minio" "16.0.10"
    helm upgrade --install -n $NS minio temp/minio --wait --timeout 600s -f temp/values-minio.yaml \
        --set auth.rootPassword=$MINIO_PW
fi

# input object storage settings
#####################################
if install_mode_enabled "$INSTALL_MODE" gitlab; then
    log_header "input object storage settings"
    RAILS_STORAGE_CONFIG=$(get_secret_value "$NS" "gitlab-rails-storage" "connection")
    if [ -n "$RAILS_STORAGE_CONFIG" ]; then
        printf '%s' "$RAILS_STORAGE_CONFIG" >temp/values-s3-rails.yaml
        log_info "reuse existing gitlab rails storage."
    else
        RAILS_S3_ACCESS_KEY=$(prompt_required "please initial minio keys by web ui: https://s3.git.${DOMAIN}." "rails s3 access key" "")
        RAILS_S3_SECRET_KEY=$(prompt_required "" "rails s3 secret key" "")
        render_values_file_to_temp values-s3-rails.yaml
    fi
    TOOLBOX_S3CMD_CONFIG=$(get_secret_value "$NS" "gitlab-toolbox-s3cmd" "config")
    if [ -n "$TOOLBOX_S3CMD_CONFIG" ]; then
        printf '%s' "$TOOLBOX_S3CMD_CONFIG" >temp/values-s3-backup.ini
        log_info "reuse existing gitlab toolbox s3cmd."
    else
        BACKUP_S3_ACCESS_KEY=$(prompt_required "please initial backup minio keys by web ui: https://s3.git.${DOMAIN}." "backup s3 access key" "")
        BACKUP_S3_SECRET_KEY=$(prompt_required "" "backup s3 secret key" "")
        render_values_file_to_temp values-s3-backup.ini
    fi
    apply_secret_generic "$NS" "gitlab-rails-storage" --from-file=connection='temp/values-s3-rails.yaml'
    apply_secret_generic "$NS" "gitlab-toolbox-s3cmd" --from-file=config='temp/values-s3-backup.ini'
    #apply_secret_generic "$NS" "gitlab-registry-storage" --from-file=config=temp/values-s3-registry.yaml
fi

# install postgresql
#####################################
if install_mode_enabled "$INSTALL_MODE" postgresql; then
    log_header "install postgresql"
    ensure_helm_repo_chart "bitnami" "oci://registry-1.docker.io/bitnamicharts" "postgresql" "16.7.27"
    helm upgrade --install -n $NS postgresql temp/postgresql --wait --timeout 600s -f temp/values-postgresql.yaml \
        --set global.postgresql.auth.postgresPassword=$DB_PW \
        --set global.postgresql.auth.password=$DB_PW \
        --set auth.replicationPassword=$DB_PW
    kubectl -n $NS exec postgresql-0 -- bash -c \
        'PGPASSWORD=$(cat ${POSTGRES_POSTGRES_PASSWORD_FILE}) psql --dbname=gitlabhq_production --username=admin -c "CREATE EXTENSION IF NOT EXISTS pg_trgm; CREATE EXTENSION IF NOT EXISTS btree_gist; CREATE EXTENSION IF NOT EXISTS plpgsql;"'
    kubectl -n $NS patch secret postgresql --type merge --patch \
        "{\"data\":{\"username\":\"$(echo -n admin | base64)\"}}"
fi

# install redis
#####################################
if install_mode_enabled "$INSTALL_MODE" redis; then
    log_header "install redis"
    ensure_helm_repo_chart "bitnami" "oci://registry-1.docker.io/bitnamicharts" "redis" "22.0.7"
    helm upgrade --install -n $NS redis temp/redis --wait --timeout 600s -f temp/values-redis.yaml \
        --set global.redis.password=$REDIS_PW
fi

# install elasticsearch
#####################################
if install_mode_enabled "$INSTALL_MODE" elasticsearch; then
    log_header "install elasticsearch"
    ensure_helm_repo_chart "bitnami" "oci://registry-1.docker.io/bitnamicharts" "elasticsearch" "22.1.6"
    helm upgrade --install -n $NS elasticsearch temp/elasticsearch --wait --timeout 600s -f temp/values-elasticsearch.yaml \
        --set security.elasticPassword=$ELASTICSEARCH_PW \
        --set kibana.elasticsearch.security.auth.kibanaPassword=$ELASTICSEARCH_PW
fi

# install gitlab
#####################################
if install_mode_enabled "$INSTALL_MODE" gitlab; then
    log_header "install gitlab"
    if [ "$INSTALL_MODE" == "reinstall" ]; then
        if [ -z "$GITLAB_CHART_VERSION" ] || [ -z "$GITLAB_APP_VERSION" ]; then
            log_error "missing gitlab version configmap, please run full or gitlab mode first."
            exit 1
        fi
    else
        read -r GITLAB_CHART_VERSION DEFAULT_GITLAB_APP_VERSION <<<"$(get_helm_chart_versions "gitlab" "https://charts.gitlab.io" "gitlab")"
        GITLAB_APP_VERSION=$(prompt_with_default "" "gitlab app version" "$DEFAULT_GITLAB_APP_VERSION")
        if [ "$GITLAB_APP_VERSION" != "$DEFAULT_GITLAB_APP_VERSION" ]; then
            read -r GITLAB_CHART_VERSION _ <<<"$(get_helm_chart_versions "gitlab" "https://charts.gitlab.io" "gitlab" "$GITLAB_APP_VERSION")"
        fi
        apply_configmap_vars "$NS" "gitlab-install-version" \
            gitlab-chart-version=GITLAB_CHART_VERSION \
            gitlab-app-version=GITLAB_APP_VERSION
    fi
    ensure_helm_repo_chart "gitlab" "https://charts.gitlab.io" "gitlab" "$GITLAB_CHART_VERSION"
    helm upgrade --install -n $NS gitlab temp/gitlab -f temp/values-gitlab.yaml
fi

# self configuration and license
#####################################
if install_mode_enabled "$INSTALL_MODE" gitlab; then
    log_header "self configuration"
    apply_configmap "$NS" "self-configuration" \
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
