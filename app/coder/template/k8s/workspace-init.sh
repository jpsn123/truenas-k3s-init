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

DEFAULT_EXTENSIONS_GALLERY='{"serviceUrl":"https://marketplace.visualstudio.com/_apis/public/gallery","itemUrl":"https://marketplace.visualstudio.com/items","cacheUrl":"https://vscode.blob.core.windows.net/gallery/index","controlUrl":""}'
GITLENS_EXTENSION_ID="eamodio.gitlens"
GITLENS_PINNED_VERSION="18.3.0"

ARTIFACTORY_BASE="${CODE_SERVER_MIRROR_URL%%/artifactory/*}/artifactory"
ARTIFACTORY_REPO_PATH="${CODE_SERVER_MIRROR_URL#*/artifactory/}"

main() {
  check_debian_like
  check_jfrog_url

  CACHE_DIR="$(echo_cache_dir)"
  VERSION="$(echo_latest_version)"
  ARCH="$(arch)"
  CODE_SERVER_ROOT="$CODE_SERVER_PREFIX_DIR/lib/code-server-$VERSION"

  install_standalone
  init_code_server_defaults
  pin_extension "$GITLENS_EXTENSION_ID" "$GITLENS_PINNED_VERSION"
  mark_extension_resource "$GITLENS_EXTENSION_ID"
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

  if [ -x "$CODE_SERVER_ROOT/bin/code-server" ]; then
    echoh "code-server v$VERSION is already installed at $CODE_SERVER_ROOT"
    echoh "Skip downloading and extracting."
    ensure_code_server_config
    ensure_code_server_link
    return
  fi

  fetch "$CODE_SERVER_MIRROR_URL/code-server-$VERSION-linux-$ARCH.tar.gz" \
    "$CACHE_DIR/code-server-$VERSION-linux-$ARCH.tar.gz"

  "$sh_c" mkdir -p "$CODE_SERVER_PREFIX_DIR/lib" "$HOME/.local/bin"
  "$sh_c" tar -C "$CODE_SERVER_PREFIX_DIR/lib" -xzf "$CACHE_DIR/code-server-$VERSION-linux-$ARCH.tar.gz"
  "$sh_c" mv -f "$CODE_SERVER_PREFIX_DIR/lib/code-server-$VERSION-linux-$ARCH" "$CODE_SERVER_ROOT"
  ensure_code_server_config
  ensure_code_server_link

  echoh
  echoh "code-server has been installed into $CODE_SERVER_ROOT"
  echoh "Run with: code-server"
}

ensure_code_server_config() {
  CODE_SERVER_LAUNCHER="$CODE_SERVER_ROOT/bin/code-server"
  REMOTE_CLI_CODE_SERVER="$CODE_SERVER_ROOT/lib/vscode/bin/remote-cli/code-server"

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
  cat > "$CODE_SERVER_CONFIG" <<EOF
# private code-server defaults.
EXTENSIONS_GALLERY=\${EXTENSIONS_GALLERY:-'$DEFAULT_EXTENSIONS_GALLERY'}
export EXTENSIONS_GALLERY
EOF

  "$sh_c" "grep -q 'private code-server defaults' '$CODE_SERVER_LAUNCHER' || sed -i '1r $CODE_SERVER_CONFIG' '$CODE_SERVER_LAUNCHER'"
  "$sh_c" "grep -q 'private code-server defaults' '$REMOTE_CLI_CODE_SERVER' || sed -i '1r $CODE_SERVER_CONFIG' '$REMOTE_CLI_CODE_SERVER'"
}

ensure_code_server_link() {
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
    "$GITLENS_EXTENSION_ID@$GITLENS_PINNED_VERSION" \
    pkief.material-icon-theme \
    foxundermoon.shell-format \
    redhat.vscode-yaml
  do
    echoh "+ Installing extension: $extension"
    if code_cli --install-extension "$extension" --force; then
      echoh "+ Installed extension: $extension"
    else
      echoerr "Failed to install extension, skip: $extension"
    fi
  done

  touch "$DEFAULT_MARKER"
}

# Run VS Code extension CLI commands directly against the persistent data
# directory instead of relying on a running code-server instance.
code_cli() {
  ensure_code_cli_bootstrap

  EXTENSIONS_GALLERY="${EXTENSIONS_GALLERY:-$DEFAULT_EXTENSIONS_GALLERY}" \
    "$CODE_SERVER_ROOT/lib/node" "$CACHE_DIR/vscode-cli.mjs" "$CODE_SERVER_ROOT/lib/vscode" \
    --user-data-dir "$CODE_SERVER_DATA_DIR" \
    "$@"
}

ensure_code_cli_bootstrap() {
  if [ "${CODE_CLI_BOOTSTRAPPED-}" ]; then
    return
  fi

  CODE_CLI_BOOTSTRAP="$CACHE_DIR/vscode-cli.mjs"
  sh_c mkdir -p "$CACHE_DIR"
  cat > "$CODE_CLI_BOOTSTRAP" <<'EOF'
const vscodeRoot = process.argv[2];
const args = { _: [] };
const LIST_FLAGS = new Set(["install-extension", "uninstall-extension", "locate-extension"]);
const flags = process.argv.slice(3);
for (let i = 0; i < flags.length; i++) {
  if (!flags[i].startsWith("--")) {
    continue;
  }
  const key = flags[i].slice(2);
  if (LIST_FLAGS.has(key)) {
    (args[key] ??= []).push(flags[++i]);
  } else {
    args[key] = flags[i + 1] && !flags[i + 1].startsWith("--") ? flags[++i] : true;
  }
}
const mod = await import(`${vscodeRoot}/out/server-main.js`);
const serverModule = await mod.loadCodeWithNls();
await serverModule.spawnCli(args);
setTimeout(() => process.exit(0), 1000);
EOF
  CODE_CLI_BOOTSTRAPPED=1
}

pin_extension() {
  EXTENSION_ID="$1"
  PINNED_VERSION="$2"
  ACTIVE_VERSION=""

  for extension_dir in "$CODE_SERVER_DATA_DIR/extensions/$EXTENSION_ID"-*; do
    if [ -d "$extension_dir" ]; then
      ACTIVE_VERSION="${extension_dir##*/"$EXTENSION_ID"-}"
      break
    fi
  done

  if [ "$ACTIVE_VERSION" != "$PINNED_VERSION" ]; then
    if [ -n "$ACTIVE_VERSION" ]; then
      echoh "$EXTENSION_ID v$ACTIVE_VERSION is installed, forcing pinned v$PINNED_VERSION."
    fi
    if code_cli --install-extension "$EXTENSION_ID@$PINNED_VERSION" --force; then
      echoh "$EXTENSION_ID pinned to v$PINNED_VERSION."
    else
      echoerr "Failed to pin $EXTENSION_ID to v$PINNED_VERSION."
    fi
  fi

  for stale in "$CODE_SERVER_DATA_DIR/extensions/$EXTENSION_ID"-*; do
    if [ ! -d "$stale" ]; then
      continue
    fi
    if [ "$stale" = "$CODE_SERVER_DATA_DIR/extensions/$EXTENSION_ID-$PINNED_VERSION" ]; then
      continue
    fi
    echoh "Removing stale extension directory: $stale"
    rm -rf "$stale"
  done
}

# Resource extensions are excluded from marketplace update checks. Remove the
# gallery identity as well so the marketplace cannot attach another version.
mark_extension_resource() {
  EXTENSION_ID="$1"
  EXTENSIONS_JSON="$CODE_SERVER_DATA_DIR/extensions/extensions.json"

  if [ ! -f "$EXTENSIONS_JSON" ]; then
    return
  fi

  if ! "$CODE_SERVER_ROOT/lib/node" -e '
    const fs = require("fs");
    const file = process.argv[1];
    const extensionId = process.argv[2];
    let entries;
    try {
      entries = JSON.parse(fs.readFileSync(file, "utf8"));
    } catch (error) {
      console.error(String(error));
      process.exit(1);
    }
    if (!Array.isArray(entries)) {
      process.exit(0);
    }
    let changed = false;
    for (const entry of entries) {
      if (entry?.identifier?.id !== extensionId) {
        continue;
      }
      if (entry.identifier.uuid !== undefined) {
        delete entry.identifier.uuid;
        changed = true;
      }
      const metadata = (entry.metadata ??= {});
      if (metadata.id !== undefined) {
        delete metadata.id;
        changed = true;
      }
      if (metadata.source !== "resource") {
        metadata.source = "resource";
        changed = true;
      }
      if (metadata.pinned !== true) {
        metadata.pinned = true;
        changed = true;
      }
    }
    if (changed) {
      fs.writeFileSync(file, JSON.stringify(entries));
    }
  ' "$EXTENSIONS_JSON" "$EXTENSION_ID"; then
    echoerr "Failed to mark $EXTENSION_ID as a resource extension in $EXTENSIONS_JSON, skip."
  fi
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
    "ANTHROPIC_BASE_URL": "https://llm.__DOMAIN__/v1",
    "ANTHROPIC_DEFAULT_FABLE_MODEL": "gpt-5.6-sol",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "glm-5-turbo",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "glm-5.3",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "gpt-5.5-high",
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
model = "gpt-5.6-sol"
model_provider = "__BRAND_PREFIX__"

[model_providers.__BRAND_PREFIX__]
name = "__BRAND_DISPLAY_NAME__"
base_url = "https://llm.__DOMAIN__/v1"
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
