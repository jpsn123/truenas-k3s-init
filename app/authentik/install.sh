#!/bin/bash
set -e

cd $(dirname $0)
source ../../common.sh
source ../../parameter.sh

NS=authentik
INSTALL_MODE="${1:-full}"
validate_install_mode "$INSTALL_MODE" postgresql authentik mgr-auth

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
load_secret_vars "$NS" "postgresql" password=DB_PW
load_secret_vars "$NS" "authentik-secret-key" secret-key=SECRET_KEY
load_secret_vars "$NS" "authentik-smtp" password=SMTP_PW
load_configmap_vars "$NS" "authentik-install-version" \
    chart-version=AUTHENTIK_CHART_VERSION \
    app-version=AUTHENTIK_APP_VERSION
load_secret_vars "$NS" "mgr-auth" \
    session-secret=MGR_AUTH_SESSION_SECRET \
    authentik-api-token=MGR_AUTH_AUTHENTIK_API_TOKEN \
    oauth-client-id=MGR_AUTH_OAUTH_CLIENT_ID \
    oauth-client-secret=MGR_AUTH_OAUTH_CLIENT_SECRET \
    oa-enabled=MGR_AUTH_OA_ENABLED \
    oa-app-key=MGR_AUTH_OA_APP_KEY \
    oa-app-secret=MGR_AUTH_OA_APP_SECRET
if (install_mode_enabled "$INSTALL_MODE" postgresql && [ -z "$DB_PW" ]) \
    || (install_mode_enabled "$INSTALL_MODE" authentik && [ -z "$SECRET_KEY" ]); then
    PASSWORD_SEED=$(prompt_required "please input seed for password." "password seed" "")
fi
if install_mode_enabled "$INSTALL_MODE" authentik && [ -z "$SMTP_PW" ]; then
    SMTP_PW=$(prompt_required "please input smtp password." "smtp password" -s)
fi
if install_mode_enabled "$INSTALL_MODE" mgr-auth; then
    if [ -z "$MGR_AUTH_SESSION_SECRET" ]; then
        MGR_AUTH_SESSION_SECRET=$(prompt_required "please input mgr-auth secret." "session secret" -s)
    fi
    if [ -z "$MGR_AUTH_AUTHENTIK_API_TOKEN" ]; then
        MGR_AUTH_AUTHENTIK_API_TOKEN=$(prompt_required "" "authentik api token" -s)
    fi
    if [ -z "$MGR_AUTH_OAUTH_CLIENT_ID" ]; then
        MGR_AUTH_OAUTH_CLIENT_ID=$(prompt_required "" "oauth client id" "")
    fi
    if [ -z "$MGR_AUTH_OAUTH_CLIENT_SECRET" ]; then
        MGR_AUTH_OAUTH_CLIENT_SECRET=$(prompt_required "" "oauth client secret" -s)
    fi
    if [ -z "$MGR_AUTH_OA_ENABLED" ]; then
        MGR_AUTH_OA_ENABLED=$(prompt_with_default "" "enable oa? (true/false)" "true")
    fi
    if [ -z "$MGR_AUTH_OA_APP_KEY" ]; then
        MGR_AUTH_OA_APP_KEY=$(prompt_required "" "oa app key" -s)
    fi
    if [ -z "$MGR_AUTH_OA_APP_SECRET" ]; then
        MGR_AUTH_OA_APP_SECRET=$(prompt_required "" "oa app secret" -s)
    fi
    apply_secret_vars "$NS" "mgr-auth" \
        session-secret=MGR_AUTH_SESSION_SECRET \
        authentik-api-token=MGR_AUTH_AUTHENTIK_API_TOKEN \
        oauth-client-id=MGR_AUTH_OAUTH_CLIENT_ID \
        oauth-client-secret=MGR_AUTH_OAUTH_CLIENT_SECRET \
        oa-enabled=MGR_AUTH_OA_ENABLED \
        oa-app-key=MGR_AUTH_OA_APP_KEY \
        oa-app-secret=MGR_AUTH_OA_APP_SECRET
fi
if install_mode_enabled "$INSTALL_MODE" postgresql && [ -z "$DB_PW" ]; then
    DB_PW=$(derive_password_sha1 "$PASSWORD_SEED" "$NS@db" 32)
fi
if install_mode_enabled "$INSTALL_MODE" authentik && [ -z "$SECRET_KEY" ]; then
    SECRET_KEY=$(derive_password_sha256 "$PASSWORD_SEED" "$NS@secret" 50)
fi
if install_mode_enabled "$INSTALL_MODE" authentik; then
    if [ "$INSTALL_MODE" == "reinstall" ]; then
        if [ -z "$AUTHENTIK_CHART_VERSION" ] || [ -z "$AUTHENTIK_APP_VERSION" ]; then
            log_error "missing authentik version configmap, please run full or authentik mode first."
            exit 1
        fi
    else
        read -r AUTHENTIK_CHART_VERSION DEFAULT_AUTHENTIK_APP_VERSION <<<"$(get_helm_chart_versions "authentik" "https://charts.goauthentik.io" "authentik")"
        AUTHENTIK_APP_VERSION=$(prompt_with_default "" "authentik app version" "$DEFAULT_AUTHENTIK_APP_VERSION")
        if [ "$AUTHENTIK_APP_VERSION" != "$DEFAULT_AUTHENTIK_APP_VERSION" ]; then
            read -r AUTHENTIK_CHART_VERSION _ <<<"$(get_helm_chart_versions "authentik" "https://charts.goauthentik.io" "authentik" "$AUTHENTIK_APP_VERSION")"
        fi
        apply_configmap_vars "$NS" "authentik-install-version" \
            chart-version=AUTHENTIK_CHART_VERSION \
            app-version=AUTHENTIK_APP_VERSION
    fi
    apply_secret_vars "$NS" "authentik-secret-key" secret-key=SECRET_KEY
    apply_secret_vars "$NS" "authentik-db" password=DB_PW
    apply_secret_vars "$NS" "authentik-smtp" password=SMTP_PW
    render_email_template_dir_to_temp email-templates/authentik/stages/email/templates/email
    render_email_template_dir_to_temp email-templates/authentik/stages/authenticator_email/templates/email
    apply_configmap "$NS" "authentik-cert" --from-file=public.pem=public.pem
    apply_configmap "$NS" "authentik-email-templates" --from-file=temp/email-templates/authentik/stages/email/templates/email
    apply_configmap "$NS" "authentik-email-otp-templates" --from-file=temp/email-templates/authentik/stages/authenticator_email/templates/email
    apply_configmap "$NS" "authentik-icons" --from-file=email-templates/web/dist/assets/icons
fi
render_values_file_to_temp values-*.yaml

## install postgresql
#####################################
if install_mode_enabled "$INSTALL_MODE" postgresql; then
    log_header "install postgresql"
    ensure_helm_repo_chart "bitnami" "oci://registry-1.docker.io/bitnamicharts" "postgresql" "16.7.27"
    helm upgrade --install -n $NS postgresql temp/postgresql --wait --timeout 600s -f temp/values-postgresql.yaml \
        --set global.postgresql.auth.postgresPassword=$DB_PW \
        --set global.postgresql.auth.password=$DB_PW \
        --set auth.replicationPassword=$DB_PW
fi

## install authentik
#####################################
if install_mode_enabled "$INSTALL_MODE" authentik; then
    log_header "install authentik"
    ensure_helm_repo_chart "authentik" "https://charts.goauthentik.io" "authentik" "$AUTHENTIK_CHART_VERSION"
    helm upgrade --install -n $NS authentik temp/authentik --wait --timeout 600s -f temp/values-authentik.yaml \
        --set-string authentik.secret_key=$SECRET_KEY \
        --set-string authentik.postgresql.password=$DB_PW \
        --set-string authentik.email.password=$SMTP_PW
fi

## install mgr-auth
#####################################
if install_mode_enabled "$INSTALL_MODE" mgr-auth; then
    log_header "install mgr-auth"
    ensure_helm_repo_chart "bjw-s" "https://bjw-s-labs.github.io/helm-charts" "app-template" "$COMMON_CHART_VERSION"
    helm upgrade --install -n $NS mgr-auth temp/app-template --wait --timeout 600s -f temp/values-mgr.yaml
fi

## done
#####################################
log_trace "install success!!!"
log_reminder "   access: https://auth.${DOMAIN}"
log_reminder "   initial setup: https://auth.${DOMAIN}/if/flow/initial-setup/"
