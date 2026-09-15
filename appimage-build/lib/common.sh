# shellcheck shell=bash
#
# common.sh — shared helpers for the AppImage builders.
#
# Sourced by build.sh, check-versions.sh and the per-app modules in apps/<id>/.
# Entry point scripts own `set -euo pipefail`; this file only defines things.
#
# ---------------------------------------------------------------- app contract
#
# Every app lives in apps/<id>/app.sh and, when sourced, must set:
#
#   APP_ID       short id, matches the directory name (used in tags/filenames)
#   APP_NAME     human name, used in the AppImage filename (no spaces)
#   APP_ARCHES   space-separated list of supported arches (x86_64 / aarch64)
#
# and define these functions:
#
#   app_latest_version <arch>
#       Print the newest upstream version. MUST only read small metadata
#       (a version file, repodata, a manifest) — never the payload itself.
#
#   app_download <arch> <version> <dest_dir>
#       Download and checksum-verify the payload. Print the resulting path.
#
#   app_assemble <arch> <version> <payload> <appdir>
#       Populate <appdir> so it is a valid AppDir (AppRun, .desktop, icon).
#
# Optionally:
#
#   app_payload_glob <arch>
#       A find(1) name pattern used to auto-discover an already-downloaded
#       payload when build.sh runs with --no-download.

# ------------------------------------------------------------------- logging
log()  { printf '==> %s\n' "$*" >&2; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------------ platform
# Normalise an arch name to the two we build for.
normalize_arch() {
    case "$1" in
        x86_64|amd64|x64)   echo x86_64 ;;
        aarch64|arm64)      echo aarch64 ;;
        *) die "unsupported architecture: $1" ;;
    esac
}

host_arch() { normalize_arch "$(uname -m)"; }

require_cmds() {
    local missing=()
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    [ ${#missing[@]} -eq 0 ] || die "required command(s) not found: ${missing[*]}"
}

# ------------------------------------------------------------------ fetching
# fetch_to <url> <output>   — download, preserving the remote mtime.
# fetch_stdout <url>        — download to stdout.
#
# Both fail (non-zero) on HTTP errors rather than writing an error page.
fetch_to() {
    local url="$1" out="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -R -o "$out" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$out" "$url"
    else
        die "need curl or wget"
    fi
}

fetch_stdout() {
    local url="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O - "$url"
    else
        die "need curl or wget"
    fi
}

# verify_sha256 <file> <expected>
verify_sha256() {
    local file="$1" expected="$2" actual
    [[ "$expected" =~ ^[a-f0-9]{64}$ ]] || die "malformed sha256 for $file: $expected"
    actual="$(sha256sum "$file" | cut -d' ' -f1)"
    [ "$actual" = "$expected" ] || die "checksum mismatch for $file (got $actual, want $expected)"
}

# ------------------------------------------------------------------ versions
# validate_version <version>
#
# Upstream version strings end up in filenames, git tags and CI job matrices,
# so keep them to characters that are safe everywhere.
validate_version() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] \
        || die "refusing to use an implausible version string: $1"
    printf '%s\n' "$1"
}

# version_gt <a> <b> — true when a sorts strictly after b (dot-numeric aware).
version_gt() {
    [ "$1" = "$2" ] && return 1
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]
}

# ------------------------------------------------------------------ disk
# require_free_space <dir> <kb>
require_free_space() {
    local dir="$1" want="$2" avail
    avail="$(df -Pk "$dir" | awk 'NR==2 {print $4}')"
    if [ "${avail:-0}" -lt "$want" ]; then
        die "not enough free space at $dir (need ~$((want / 1024)) MiB, have $((${avail:-0} / 1024)) MiB)"
    fi
}

# ------------------------------------------------------------------ packaging
# appimagetool_path <arch> — path to a cached appimagetool, downloading once.
appimagetool_path() {
    local arch="$1" tool
    if [ -n "${APPIMAGETOOL:-}" ]; then
        [ -x "$APPIMAGETOOL" ] || die "APPIMAGETOOL=$APPIMAGETOOL is not executable"
        echo "$APPIMAGETOOL"
        return
    fi
    mkdir -p "$TOOLS_DIR"
    tool="$TOOLS_DIR/appimagetool-$arch.AppImage"
    if [ ! -x "$tool" ]; then
        log "downloading appimagetool-$arch (cached in $TOOLS_DIR)"
        fetch_to "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-$arch.AppImage" "$tool.tmp" \
            || die "failed to download appimagetool for $arch"
        chmod +x "$tool.tmp"
        mv -f "$tool.tmp" "$tool"
    fi
    echo "$tool"
}

# build_appimage <appdir> <outfile> <arch> [source_date_epoch]
#
# Builds to a temp file and atomically renames, so a rebuild works even while
# a previous copy of the AppImage is still running.
build_appimage() {
    local appdir="$1" out="$2" arch="$3" epoch="${4:-}" tool tmp
    tool="$(appimagetool_path "$arch")"
    tmp="$(dirname "$out")/.$(basename "$out").tmp"
    rm -f "$tmp"
    log "building AppImage ($arch)"
    # --appimage-extract-and-run avoids the libfuse2 dependency, which is
    # absent on immutable distros and on GitHub runners.
    env ${epoch:+SOURCE_DATE_EPOCH="$epoch"} ARCH="$arch" \
        "$tool" --appimage-extract-and-run "$appdir" "$tmp"
    mv -f "$tmp" "$out"
    ( cd "$(dirname "$out")" && sha256sum "$(basename "$out")" > "$(basename "$out").sha256" )
}

# ------------------------------------------------------------------ app loading
# Discover the app ids that have a module on disk.
list_apps() {
    local dir
    for dir in "$APPS_DIR"/*/; do
        [ -f "$dir/app.sh" ] && basename "$dir"
    done
}

# load_app <id> — source an app module and validate its contract.
load_app() {
    local id="$1"
    APP_DEF_DIR="$APPS_DIR/$id"
    [ -f "$APP_DEF_DIR/app.sh" ] || die "unknown app '$id' (known: $(list_apps | tr '\n' ' '))"
    # shellcheck source=/dev/null
    . "$APP_DEF_DIR/app.sh"
    [ "$APP_ID" = "$id" ] || die "apps/$id/app.sh declares APP_ID=$APP_ID"
    local fn
    for fn in app_latest_version app_download app_assemble; do
        declare -F "$fn" >/dev/null || die "apps/$id/app.sh does not define $fn()"
    done
}

# app_supports_arch <arch>
app_supports_arch() {
    local arch="$1" candidate
    for candidate in $APP_ARCHES; do
        [ "$candidate" = "$arch" ] && return 0
    done
    return 1
}

# appimage_filename <version> <arch>
appimage_filename() { printf '%s-%s-%s.AppImage' "$APP_NAME" "$1" "$2"; }

# release_tag <version>
release_tag() { printf '%s-v%s' "$APP_ID" "$1"; }
