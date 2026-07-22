#!/bin/sh
# Workspace initialization script. Written into Debian-like workspace Pods by the
# Coder template. Installs code-server from a mirror and initializes
# code-server defaults and AI tool settings.
set -eu

# Defaults. Each may be overridden by the environment.
CODE_SERVER_MIRROR_URL="${CODE_SERVER_MIRROR_URL:-__CODE_SERVER_MIRROR_URL__}"
CODE_SERVER_MIRROR_URL="${CODE_SERVER_MIRROR_URL%/}"
CODE_SERVER_PREFIX_DIR="${CODE_SERVER_PREFIX_DIR:-$HOME/.local}"
# When non-empty, AI tool settings are initialized on first start.
AI_CONNECTOR_TOKEN="${AI_CONNECTOR_TOKEN:-}"

ARTIFACTORY_BASE="${CODE_SERVER_MIRROR_URL%%/artifactory/*}/artifactory"
ARTIFACTORY_REPO_PATH="${CODE_SERVER_MIRROR_URL#*/artifactory/}"

main() {
  check_debian_like
  check_jfrog_url

  CACHE_DIR="$(echo_cache_dir)"
  VERSION="$(echo_latest_version)"
  ARCH="$(arch)"

  install_standalone
  init_code_server_defaults
  init_claude_code_settings
  init_codex_settings
}

check_debian_like() {
  if [ ! -f /etc/os-release ]; then
    echoerr "Only Debian-like Linux is supported."
    exit 1
  fi

  (
    . /etc/os-release
    if [ "${ID-}" = debian ] || [ "${ID-}" = ubuntu ] || [ "${ID-}" = raspbian ]; then
      exit 0
    fi

    for id_like in ${ID_LIKE-}; do
      if [ "$id_like" = debian ]; then
        exit 0
      fi
    done

    exit 1
  ) || {
    echoerr "Only Debian-like Linux is supported."
    exit 1
  }
}

check_jfrog_url() {
  if [ "$ARTIFACTORY_REPO_PATH" = "$CODE_SERVER_MIRROR_URL" ]; then
    echoerr "CODE_SERVER_MIRROR_URL must contain /artifactory/: $CODE_SERVER_MIRROR_URL"
    exit 1
  fi
}

echo_latest_version() {
  version="$(curl -fsSL "$ARTIFACTORY_BASE/api/storage/$ARTIFACTORY_REPO_PATH?properties" | tr -d '\n' | sed -n 's/.*"last_version"[[:space:]]*:[[:space:]]*\[[[:space:]]*"\([^"]*\)".*/\1/p')"
  if [ -z "$version" ]; then
    echoerr "JFrog property last_version is missing on $CODE_SERVER_MIRROR_URL"
    exit 1
  fi

  version="${version#v}"
  echo "$version"
}

install_standalone() {
  echoh "Installing code-server v$VERSION for linux-$ARCH from JFrog mirror."
  echoh

  sh_c mkdir -p "$CODE_SERVER_PREFIX_DIR" 2>/dev/null || true

  sh_c="sh_c"
  if [ ! -w "$CODE_SERVER_PREFIX_DIR" ]; then
    sh_c="sudo_sh_c"
  fi

  if [ -x "$CODE_SERVER_PREFIX_DIR/lib/code-server-$VERSION/bin/code-server" ]; then
    echoh "code-server v$VERSION is already installed at $CODE_SERVER_PREFIX_DIR/lib/code-server-$VERSION"
    echoh "Skip downloading and extracting."
    ensure_code_server_config
    ensure_code_server_link
    return
  fi

  fetch "$CODE_SERVER_MIRROR_URL/code-server-$VERSION-linux-$ARCH.tar.gz" \
    "$CACHE_DIR/code-server-$VERSION-linux-$ARCH.tar.gz"

  "$sh_c" mkdir -p "$CODE_SERVER_PREFIX_DIR/lib" "$HOME/.local/bin"
  "$sh_c" tar -C "$CODE_SERVER_PREFIX_DIR/lib" -xzf "$CACHE_DIR/code-server-$VERSION-linux-$ARCH.tar.gz"
  "$sh_c" mv -f "$CODE_SERVER_PREFIX_DIR/lib/code-server-$VERSION-linux-$ARCH" "$CODE_SERVER_PREFIX_DIR/lib/code-server-$VERSION"
  ensure_code_server_config
  ensure_code_server_link

  echoh
  echoh "code-server has been installed into $CODE_SERVER_PREFIX_DIR/lib/code-server-$VERSION"
  echoh "Run with: code-server"
}

ensure_code_server_config() {
  CODE_SERVER_LAUNCHER="$CODE_SERVER_PREFIX_DIR/lib/code-server-$VERSION/bin/code-server"
  REMOTE_CLI_CODE_SERVER="$CODE_SERVER_PREFIX_DIR/lib/code-server-$VERSION/lib/vscode/bin/remote-cli/code-server"

  if [ ! -f "$CODE_SERVER_LAUNCHER" ]; then
    echoerr "code-server launcher is missing: $CODE_SERVER_LAUNCHER"
    exit 1
  fi
  if [ ! -f "$REMOTE_CLI_CODE_SERVER" ]; then
    echoerr "code-server launcher is missing: $REMOTE_CLI_CODE_SERVER"
    exit 1
  fi

  CODE_SERVER_CONFIG="$CACHE_DIR/code-server-config.sh"
  sh_c mkdir -p "$CACHE_DIR"
  cat > "$CODE_SERVER_CONFIG" <<'EOF'
# private code-server defaults.
EXTENSIONS_GALLERY=${EXTENSIONS_GALLERY:-'{"serviceUrl":"https://marketplace.visualstudio.com/_apis/public/gallery","itemUrl":"https://marketplace.visualstudio.com/items","cacheUrl":"https://vscode.blob.core.windows.net/gallery/index","controlUrl":""}'}
export EXTENSIONS_GALLERY
EOF

  "$sh_c" "grep -q 'private code-server defaults' '$CODE_SERVER_LAUNCHER' || sed -i '1r $CODE_SERVER_CONFIG' '$CODE_SERVER_LAUNCHER'"
  "$sh_c" "grep -q 'private code-server defaults' '$REMOTE_CLI_CODE_SERVER' || sed -i '1r $CODE_SERVER_CONFIG' '$REMOTE_CLI_CODE_SERVER'"
}

ensure_code_server_link() {
  CODE_SERVER_ROOT="$CODE_SERVER_PREFIX_DIR/lib/code-server-$VERSION"
  REMOTE_CLI_DIR="$CODE_SERVER_ROOT/lib/vscode/bin/remote-cli"

  "$sh_c" mkdir -p "$HOME/.local/bin"
  "$sh_c" ln -sf "$CODE_SERVER_ROOT/bin/code-server" "$HOME/.local/bin/code-server"
  "$sh_c" ln -sf "$REMOTE_CLI_DIR/code-server" "$REMOTE_CLI_DIR/code"
}

init_code_server_defaults() {
  CODE_SERVER_DATA_DIR="$HOME/.local/share/code-server"
  CODE_SERVER_USER_DIR="$CODE_SERVER_DATA_DIR/User"
  DEFAULT_MARKER="$CODE_SERVER_DATA_DIR/.defaults-initialized"

  if [ -e "$DEFAULT_MARKER" ]; then
    return
  fi

  mkdir -p "$CODE_SERVER_USER_DIR"

  if [ ! -e "$CODE_SERVER_USER_DIR/settings.json" ]; then
    cat > "$CODE_SERVER_USER_DIR/settings.json" <<'EOF'
{
  "workbench.iconTheme": "material-icon-theme",
  "explorer.confirmDelete": false,
  "editor.formatOnType": true,
  "files.eol": "\n",
  "git.confirmSync": false,
  "editor.fontSize": 13,
  "workbench.statusBar.visible": true,
  "git.autofetch": true,
  "git.enableSmartCommit": true,
  "[json]": {
    "editor.defaultFormatter": "vscode.json-language-features"
  },
  "cmake.options.statusBarVisibility": "visible",
  "diffEditor.ignoreTrimWhitespace": false,
  "editor.codeActionsOnSave": {},
  "editor.formatOnSave": true,
  "diffEditor.maxComputationTime": 0,
  "editor.fontWeight": "normal",
  "claudeCode.allowDangerouslySkipPermissions": true,
  "claudeCode.initialPermissionMode": "bypassPermissions",
  "workbench.colorTheme": "Solarized Light",
  "workbench.startupEditor": "none"
}
EOF
  fi

  echoh "Installing default code-server extensions. This may take a while."
  for extension in \
    ginfuru.ginfuru-better-solarized-dark-theme \
    anthropic.claude-code \
    donjayamanne.githistory \
    eamodio.gitlens \
    pkief.material-icon-theme \
    foxundermoon.shell-format \
    redhat.vscode-yaml
  do
    echoh "+ Installing extension: $extension"
    if "$CODE_SERVER_PREFIX_DIR/bin/code-server" --install-extension "$extension" --force; then
      echoh "+ Installed extension: $extension"
    else
      echoerr "Failed to install extension, skip: $extension"
    fi
  done

  touch "$DEFAULT_MARKER"
}

init_claude_code_settings() {
  CLAUDE_DIR="$HOME/.claude"
  CLAUDE_SETTINGS="$CLAUDE_DIR/settings.json"

  if [ -z "${AI_CONNECTOR_TOKEN-}" ]; then
    return
  fi
  if [ -e "$CLAUDE_SETTINGS" ]; then
    return
  fi

  mkdir -p "$CLAUDE_DIR"
  cat > "$CLAUDE_SETTINGS" <<EOF
{
  "attribution": {
    "commit": "",
    "pr": ""
  },
  "env": {
    "ANTHROPIC_AUTH_TOKEN": "$AI_CONNECTOR_TOKEN",
    "ANTHROPIC_BASE_URL": "https://api.__DOMAIN__/v1",
    "ANTHROPIC_DEFAULT_FABLE_MODEL": "gpt-5.5-high[1M]",
    "ANTHROPIC_DEFAULT_FABLE_MODEL_NAME": "gpt-5.5-high",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "glm-5-turbo",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME": "glm-5-turbo",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "glm-5.2-max[1M]",
    "ANTHROPIC_DEFAULT_OPUS_MODEL_NAME": "glm-5.2-max",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "kimi-k3[1M]",
    "ANTHROPIC_DEFAULT_SONNET_MODEL_NAME": "kimi-k3",
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1",
    "ENABLE_TOOL_SEARCH": "true"
  },
  "model": "fable"
}
EOF
}

init_codex_settings() {
  CODEX_DIR="$HOME/.codex"
  CODEX_AUTH="$CODEX_DIR/auth.json"
  CODEX_CONFIG="$CODEX_DIR/config.toml"

  if [ -z "${AI_CONNECTOR_TOKEN-}" ]; then
    return
  fi
  if [ -e "$CODEX_AUTH" ] || [ -e "$CODEX_CONFIG" ]; then
    return
  fi

  mkdir -p "$CODEX_DIR"
  cat > "$CODEX_AUTH" <<EOF
{
  "OPENAI_API_KEY": "$AI_CONNECTOR_TOKEN"
}
EOF
  cat > "$CODEX_CONFIG" <<EOF
model = "gpt-5.5-high"
model_provider = "__BRAND_PREFIX__"

[model_providers.__BRAND_PREFIX__]
name = "__BRAND_DISPLAY_NAME__"
base_url = "https://api.__DOMAIN__/v1"
env_key = "OPENAI_API_KEY"
wire_api = "chat"
EOF
}

fetch() {
  URL="$1"
  FILE="$2"

  if [ -e "$FILE" ]; then
    echoh "+ Reusing $FILE"
    return
  fi

  sh_c mkdir -p "$CACHE_DIR"
  sh_c curl -#fL -o "$FILE.incomplete" -C - "$URL"
  sh_c mv "$FILE.incomplete" "$FILE"
}

arch() {
  uname_m="$(uname -m)"
  case "$uname_m" in
    aarch64) echo arm64 ;;
    x86_64) echo amd64 ;;
    *)
      echoerr "Unsupported architecture: $uname_m"
      exit 1
      ;;
  esac
}

command_exists() {
  command -v "$@" >/dev/null
}

sh_c() {
  echoh "+ $*"
  sh -c "$*"
}

sudo_sh_c() {
  if [ "$(id -u)" = 0 ]; then
    sh_c "$@"
  elif command_exists sudo; then
    sh_c "sudo $*"
  elif command_exists su; then
    sh_c "su root -c '$*'"
  else
    echoerr "This script needs to run the following command as root:"
    echoerr "  $*"
    echoerr "Please run as root or install sudo/su."
    exit 1
  fi
}

echo_cache_dir() {
  if [ "${XDG_CACHE_HOME-}" ]; then
    echo "$XDG_CACHE_HOME/code-server"
  elif [ "${HOME-}" ]; then
    echo "$HOME/.cache/code-server"
  else
    echo "/tmp/code-server-cache"
  fi
}

echoh() {
  echo "$@" | humanpath
}

echoerr() {
  echoh "$@" >&2
}

humanpath() {
  sed "s# $HOME# ~#g; s#\"$HOME#\"\$HOME#g"
}

main
