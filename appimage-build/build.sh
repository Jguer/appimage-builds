#!/usr/bin/env bash
#
# build.sh — build a standalone AppImage for one of the apps in ./apps.
#
# Usage:
#   ./build.sh                            build every app for the host arch
#   ./build.sh chatgpt                    build one app, newest upstream version
#   ./build.sh claude-desktop -a aarch64  build for another architecture
#   ./build.sh chatgpt -p ./chatgpt.x86_64.rpm   use a package you already have
#   ./build.sh ./chatgpt.x86_64.rpm       same thing, app inferred from the file
#
# Options:
#   -a, --arch ARCH        target architecture (x86_64 | aarch64; default: host)
#   -v, --version VERSION  build this version instead of the newest upstream
#   -p, --payload FILE     use this rpm/deb instead of downloading one
#       --keep-payload     keep the downloaded payload in ./downloads
#   -o, --output-dir DIR   where the .AppImage lands (default: ./out)
#   -l, --list             list the known apps and exit
#   -h, --help             this message
#
# Environment overrides:
#   APPIMAGETOOL=/path/to/appimagetool   use a specific appimagetool binary
#
# Dependencies: curl (or wget), sha256sum, mksquashfs; plus rpm2cpio and cpio
# for ChatGPT, and either dpkg-deb or ar + tar + xz for Claude Desktop.
# appimagetool is downloaded automatically on first run (cached in ./tools).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS_DIR="$SCRIPT_DIR/apps"
TOOLS_DIR="$SCRIPT_DIR/tools"
WORK_ROOT="$SCRIPT_DIR/build"
DOWNLOAD_DIR="$SCRIPT_DIR/downloads"

# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

# Print the header comment block, minus the shebang, as the help text.
usage() {
    awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "${BASH_SOURCE[0]}"
}

# ------------------------------------------------------------------ arguments
ARCH=""
VERSION=""
PAYLOAD=""
OUTPUT_DIR="$SCRIPT_DIR/out"
KEEP_PAYLOAD=0
REQUESTED=()

while [ $# -gt 0 ]; do
    case "$1" in
        -a|--arch)        ARCH="$(normalize_arch "$2")"; shift 2 ;;
        -v|--version)     VERSION="$2"; shift 2 ;;
        -p|--payload)     PAYLOAD="$2"; shift 2 ;;
        --keep-payload)   KEEP_PAYLOAD=1; shift ;;
        -o|--output-dir)  OUTPUT_DIR="$2"; shift 2 ;;
        -l|--list)        list_apps; exit 0 ;;
        -h|--help)        usage; exit 0 ;;
        -*)               die "unknown option: $1 (try --help)" ;;
        *)
            # A path to an existing package is accepted in place of an app name.
            if [ -f "$1" ]; then
                case "$1" in
                    *.rpm) REQUESTED+=(chatgpt); PAYLOAD="$1" ;;
                    *.deb) REQUESTED+=(claude-desktop); PAYLOAD="$1" ;;
                    *)     die "cannot tell which app '$1' belongs to; pass the app name and -p" ;;
                esac
            else
                REQUESTED+=("$1")
            fi
            shift ;;
    esac
done

[ ${#REQUESTED[@]} -gt 0 ] || mapfile -t REQUESTED < <(list_apps)
[ ${#REQUESTED[@]} -gt 0 ] || die "no apps found in $APPS_DIR"
[ -n "$ARCH" ] || ARCH="$(host_arch)"

if [ -n "$PAYLOAD" ] && [ ${#REQUESTED[@]} -ne 1 ]; then
    die "--payload only makes sense with exactly one app"
fi
if [ -n "$VERSION" ] && [ ${#REQUESTED[@]} -ne 1 ]; then
    die "--version only makes sense with exactly one app"
fi

require_cmds sha256sum mksquashfs
mkdir -p "$OUTPUT_DIR"

# ---------------------------------------------------------------------- build
build_one() {
    local id="$1" version="$2" payload="$3"
    local work appdir out epoch required downloaded=0

    load_app "$id"
    app_supports_arch "$ARCH" || die "$APP_NAME does not support $ARCH (has: $APP_ARCHES)"
    require_free_space "$SCRIPT_DIR" "${APP_MIN_FREE_KB:-2200000}"

    if [ -n "$payload" ]; then
        [ -f "$payload" ] || die "payload not found: $payload"
        payload="$(cd "$(dirname "$payload")" && printf '%s/%s' "$(pwd)" "$(basename "$payload")")"
        if [ -z "$version" ]; then
            if declare -F app_payload_version >/dev/null; then
                version="$(app_payload_version "$payload")"
            else
                die "pass --version when using --payload for $id"
            fi
        fi
    else
        [ -n "$version" ] || version="$(app_latest_version "$ARCH")"
    fi

    log "$APP_NAME $version ($ARCH)"

    work="$WORK_ROOT/$id-$ARCH"
    appdir="$work/AppDir"
    rm -rf "$work"
    mkdir -p "$appdir"

    if [ -z "$payload" ]; then
        mkdir -p "$DOWNLOAD_DIR"
        payload="$(app_download "$ARCH" "$version" "$DOWNLOAD_DIR")"
        downloaded=1
    fi
    log "payload:  $payload"

    app_assemble "$ARCH" "$version" "$payload" "$appdir"

    for required in AppRun '*.desktop'; do
        compgen -G "$appdir/$required" >/dev/null \
            || die "AppDir is missing $required — app_assemble() is incomplete"
    done

    # A stable timestamp keeps rebuilds of the same upstream release identical.
    epoch="$(stat -c %Y "$payload" 2>/dev/null || true)"

    out="$OUTPUT_DIR/$(appimage_filename "$version" "$ARCH")"
    build_appimage "$appdir" "$out" "$ARCH" "$epoch"

    rm -rf "$work"
    if [ "$downloaded" -eq 1 ] && [ "$KEEP_PAYLOAD" -eq 0 ]; then
        rm -f "$payload"
    fi

    log "done: $out"
    # Convenience for CI. The workflow builds one app per job; building several
    # in one step would leave only the last one's values readable.
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
        {
            printf 'appimage=%s\n' "$out"
            printf 'appimage_name=%s\n' "$(basename "$out")"
            printf 'version=%s\n' "$version"
            printf 'tag=%s\n' "$(release_tag "$version")"
        } >>"$GITHUB_OUTPUT"
    fi
}

for app in "${REQUESTED[@]}"; do
    # Each app runs in a subshell so its module's variables and functions
    # cannot leak into the next one.
    ( build_one "$app" "$VERSION" "$PAYLOAD" )
done
