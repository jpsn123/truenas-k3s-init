#!/bin/bash
set -e

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../../scripts/deploy/paths.sh"
source "$DEPLOY_ROOT/scripts/deploy/install-mode.sh"
source "$DEPLOY_ROOT/scripts/deploy/values.sh"
source "$DEPLOY_LIB_DIR/liblog.sh"
source "$DEPLOY_LIB_DIR/libprompt.sh"
source "$DEPLOY_LIB_DIR/libpassword.sh"
source "$DEPLOY_LIB_DIR/libkubernetes.sh"
source "$DEPLOY_LIB_DIR/libhelm.sh"
source "$DEPLOY_LIB_DIR/libregistry.sh"
source "$DEPLOY_ROOT/parameter.sh"
cd "$SCRIPT_DIR"

NS=authentik
INSTALL_MODE="${1:-full}"
deploy_validate_mode "$INSTALL_MODE" postgresql authentik auth-mgr

# functions
function render_email_template_dir_to_temp() {
    local SOURCE_DIR="$1"
    local TARGET_DIR="temp/$SOURCE_DIR"
    local BRAND_NAME="${BRAND_PREFIX^}"
    local FILE=""
    local TEMP_FILE=""
    local LINE=""

    [ -d temp ] || mkdir temp
    rm -rf "$TARGET_DIR"
    mkdir -p "$TARGET_DIR"
    cp -a "$SOURCE_DIR/." "$TARGET_DIR/"
    while IFS= read -r -d '' FILE; do
        TEMP_FILE=$(mktemp) || return 1
        while IFS= read -r LINE; do
            printf '%s\n' "${LINE//\$\{BRAND_PREFIX\}/$BRAND_NAME}"
        done <"$FILE" >"$TEMP_FILE"
        mv "$TEMP_FILE" "$FILE"
    done < <(find "$TARGET_DIR" -type f -print0)
}

## initial
#####################################
log_header "initial"
kubectl create namespace $NS 2>/dev/null || true
kube_secret_load "$NS" "postgresql" password=DB_PW
kube_secret_load "$NS" "authentik-secret-key" secret-key=SECRET_KEY
kube_secret_load "$NS" "authentik-smtp" password=SMTP_PW
kube_configmap_load "$NS" "authentik-smtp-config" \
    host=SMTP_HOST \
    port=SMTP_PORT
kube_configmap_load "$NS" "auth-mgr" \
    image-repository=AUTH_MGR_IMAGE_REPOSITORY
if (deploy_mode_enabled "$INSTALL_MODE" postgresql && [ -z "$DB_PW" ]) \
    || (deploy_mode_enabled "$INSTALL_MODE" authentik && [ -z "$SECRET_KEY" ]); then
    PASSWORD_SEED=$(prompt_required "please input seed for password." "password seed" "")
fi
if deploy_mode_enabled "$INSTALL_MODE" authentik; then
    if [ -z "$SMTP_HOST" ]; then
        SMTP_HOST=$(prompt_required "please input smtp config." "smtp host" "")
    fi
    if [ -z "$SMTP_PORT" ]; then
        SMTP_PORT=$(prompt_required "" "smtp port" "")
    fi
    if [ -z "$SMTP_PW" ]; then
        SMTP_PW=$(prompt_required "" "smtp password" -s)
    fi
fi
if deploy_mode_enabled "$INSTALL_MODE" auth-mgr; then
    if [ -z "$AUTH_MGR_IMAGE_REPOSITORY" ]; then
        AUTH_MGR_IMAGE_REPOSITORY=$(prompt_with_default "please input auth-mgr image config." "auth-mgr image repository" "hub.bin.${DOMAIN}/${BRAND_PREFIX}/auth-mgr")
    fi
    AUTH_MGR_IMAGE_TAG=$(prompt_with_default "" "auth-mgr image tag" "$(registry_latest_tag "$AUTH_MGR_IMAGE_REPOSITORY" "" anonymous)")
    kube_configmap_apply_vars "$NS" "auth-mgr" \
        image-repository=AUTH_MGR_IMAGE_REPOSITORY
fi
if deploy_mode_enabled "$INSTALL_MODE" postgresql && [ -z "$DB_PW" ]; then
    DB_PW=$(password_derive_sha1 "$PASSWORD_SEED@$NS@db" 32)
fi
if deploy_mode_enabled "$INSTALL_MODE" authentik && [ -z "$SECRET_KEY" ]; then
    SECRET_KEY=$(password_derive_sha256 "$PASSWORD_SEED@$NS@secret" 50)
fi
if deploy_mode_enabled "$INSTALL_MODE" authentik; then
    if [ "$INSTALL_MODE" == "reinstall" ]; then
        helm_ensure_chart "authentik" "https://charts.goauthentik.io" "authentik" "temp"
    else
        VERSION_PAIR=$(helm_chart_versions "authentik" "https://charts.goauthentik.io" "authentik")
        read -r AUTHENTIK_CHART_VERSION DEFAULT_AUTHENTIK_APP_VERSION <<<"$VERSION_PAIR"
        AUTHENTIK_APP_VERSION=$(prompt_with_default "" "authentik app version" "$DEFAULT_AUTHENTIK_APP_VERSION")
        if [ "$AUTHENTIK_APP_VERSION" != "$DEFAULT_AUTHENTIK_APP_VERSION" ]; then
            VERSION_PAIR=$(helm_chart_versions "authentik" "https://charts.goauthentik.io" "authentik" "$AUTHENTIK_APP_VERSION")
            read -r AUTHENTIK_CHART_VERSION AUTHENTIK_APP_VERSION <<<"$VERSION_PAIR"
        fi
        helm_ensure_chart "authentik" "https://charts.goauthentik.io" "authentik" "temp" "$AUTHENTIK_CHART_VERSION"
    fi
    kube_secret_apply_vars "$NS" "authentik-secret-key" secret-key=SECRET_KEY
    kube_secret_apply_vars "$NS" "authentik-db" password=DB_PW
    kube_secret_apply_vars "$NS" "authentik-smtp" password=SMTP_PW
    kube_configmap_apply_vars "$NS" "authentik-smtp-config" \
        host=SMTP_HOST \
        port=SMTP_PORT
    render_email_template_dir_to_temp email-templates/authentik/stages/email/templates/email
    render_email_template_dir_to_temp email-templates/authentik/stages/authenticator_email/templates/email
    kube_apply_configmap "$NS" "authentik-cert" --from-file=public.pem=public.pem
    kube_apply_configmap "$NS" "authentik-email-templates" --from-file=temp/email-templates/authentik/stages/email/templates/email
    kube_apply_configmap "$NS" "authentik-email-otp-templates" --from-file=temp/email-templates/authentik/stages/authenticator_email/templates/email
    kube_apply_configmap "$NS" "authentik-icons" --from-file=email-templates/web/dist/assets/icons
fi
deploy_render_values values-*.yaml

## install postgresql
#####################################
if deploy_mode_enabled "$INSTALL_MODE" postgresql; then
    log_header "install postgresql"
    helm_ensure_chart "bitnami" "oci://registry-1.docker.io/bitnamicharts" "postgresql" "temp" "16.7.27"
    helm upgrade --install -n $NS postgresql temp/postgresql --wait --timeout 600s -f temp/values-postgresql.yaml \
        --set global.postgresql.auth.postgresPassword=$DB_PW \
        --set global.postgresql.auth.password=$DB_PW \
        --set auth.replicationPassword=$DB_PW
fi

## install authentik
#####################################
if deploy_mode_enabled "$INSTALL_MODE" authentik; then
    log_header "install authentik"
    helm upgrade --install -n $NS authentik temp/authentik --wait --timeout 600s -f temp/values-authentik.yaml \
        --set-string authentik.secret_key=$SECRET_KEY \
        --set-string authentik.postgresql.password=$DB_PW \
        --set-string authentik.email.password=$SMTP_PW
fi

## install auth-mgr
#####################################
if deploy_mode_enabled "$INSTALL_MODE" auth-mgr; then
    log_header "install auth-mgr"
    helm_ensure_chart "bjw-s" "https://bjw-s-labs.github.io/helm-charts" "app-template" "temp" "$COMMON_CHART_VERSION"
    helm upgrade --install -n $NS auth-mgr temp/app-template --wait --timeout 600s -f temp/values-auth-mgr.yaml
fi

## done
#####################################
log_trace "install success!!!"
log_reminder "   access: https://auth.${DOMAIN}"
log_reminder "   initial setup: https://auth.${DOMAIN}/if/flow/initial-setup/"
