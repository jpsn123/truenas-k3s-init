#!/bin/sh
set -eu

CODE_SERVER_MIRROR_URL="${CODE_SERVER_MIRROR_URL:?CODE_SERVER_MIRROR_URL is required}"
JFROG_TOKEN="${JFROG_TOKEN:?JFROG_TOKEN is required}"
CODE_SERVER_OS="${CODE_SERVER_OS:-linux}"
CODE_SERVER_ARCH="${CODE_SERVER_ARCH:-amd64}"
CODE_SERVER_KEEP_VERSIONS="${CODE_SERVER_KEEP_VERSIONS:-6}"
CODE_SERVER_MIRROR_URL="${CODE_SERVER_MIRROR_URL%/}"

ARTIFACTORY_BASE="${CODE_SERVER_MIRROR_URL%%/artifactory/*}/artifactory"
ARTIFACTORY_REPO_PATH="${CODE_SERVER_MIRROR_URL#*/artifactory/}"
if [ "$ARTIFACTORY_REPO_PATH" = "$CODE_SERVER_MIRROR_URL" ]; then
  echo "CODE_SERVER_MIRROR_URL must contain /artifactory/: $CODE_SERVER_MIRROR_URL" >&2
  exit 1
fi

cleanup_old_versions() {
  FILES=$(curl -fsSL -H "Authorization: Bearer $JFROG_TOKEN" "$ARTIFACTORY_BASE/api/storage/$ARTIFACTORY_REPO_PATH" |
    jq -r --arg os "$CODE_SERVER_OS" --arg arch "$CODE_SERVER_ARCH" '
      .children[]?.uri
      | ltrimstr("/")
      | select(test("^code-server-[0-9].*-" + $os + "-" + $arch + "\\.tar\\.gz$"))
    ')

  if [ -z "$FILES" ]; then
    echo "No code-server artifacts found for cleanup."
    return
  fi

  printf '%s\n' "$FILES" |
    awk -v os="$CODE_SERVER_OS" -v arch="$CODE_SERVER_ARCH" '
      {
        file = $0
        version = file
        sub(/^code-server-/, "", version)
        suffix = "-" os "-" arch ".tar.gz"
        sub(suffix "$", "", version)
        split(version, parts, ".")
        printf "%09d.%09d.%09d %s\n", parts[1], parts[2], parts[3], file
      }
    ' |
    sort -r |
    awk -v keep="$CODE_SERVER_KEEP_VERSIONS" 'NR > keep { print $2 }' |
    while IFS= read -r OLD_FILE; do
      if [ -n "$OLD_FILE" ]; then
        echo "Deleting old code-server artifact $OLD_FILE"
        curl -fsSL -X DELETE -H "Authorization: Bearer $JFROG_TOKEN" "$CODE_SERVER_MIRROR_URL/$OLD_FILE" >/dev/null
      fi
    done
}

LATEST_URL=$(curl -fsSLI -o /dev/null -w "%{url_effective}" https://github.com/coder/code-server/releases/latest)
VERSION="${LATEST_URL#https://github.com/coder/code-server/releases/tag/}"
VERSION="${VERSION#v}"
if [ -z "$VERSION" ] || [ "$VERSION" = "$LATEST_URL" ]; then
  echo "Failed to parse latest code-server version from $LATEST_URL" >&2
  exit 1
fi

FILE="code-server-$VERSION-$CODE_SERVER_OS-$CODE_SERVER_ARCH.tar.gz"
ARTIFACT_URL="$CODE_SERVER_MIRROR_URL/$FILE"
GITHUB_URL="https://github.com/coder/code-server/releases/download/v$VERSION/$FILE"
TEMP_FILE="/tmp/$FILE"
CHECKED_AT=$(date -u +%s)

if curl -fsSLI -H "Authorization: Bearer $JFROG_TOKEN" "$ARTIFACT_URL" >/dev/null; then
  echo "$FILE already exists in JFrog."
else
  echo "Downloading $GITHUB_URL"
  curl -fL -o "$TEMP_FILE" "$GITHUB_URL"

  echo "Uploading $ARTIFACT_URL"
  curl -fL -H "Authorization: Bearer $JFROG_TOKEN" -T "$TEMP_FILE" "$ARTIFACT_URL"
fi

ARTIFACT_PROPERTY_URL="$ARTIFACTORY_BASE/api/storage/$ARTIFACTORY_REPO_PATH/$FILE?properties=code_server_version=$VERSION;code_server_checked_at=$CHECKED_AT"
curl -fsSL -X PUT -H "Authorization: Bearer $JFROG_TOKEN" "$ARTIFACT_PROPERTY_URL" >/dev/null

MIRROR_PROPERTY_URL="$ARTIFACTORY_BASE/api/storage/$ARTIFACTORY_REPO_PATH?properties=last_version=$VERSION;last_checked_at=$CHECKED_AT"
curl -fsSL -X PUT -H "Authorization: Bearer $JFROG_TOKEN" "$MIRROR_PROPERTY_URL" >/dev/null

cleanup_old_versions

echo "code-server v$VERSION is ready in JFrog."
