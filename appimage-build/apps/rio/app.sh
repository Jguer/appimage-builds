# shellcheck shell=bash
#
# Rio terminal (rioterm) → AppImage.
#
# Upstream publishes .rpm/.deb packages on GitHub releases, one per display
# backend:
#   https://github.com/raphamorim/rio/releases
#
# We package the *wayland* build, which is the point of an AppImage here: the
# binary carries no bundled runtime, so the app runs on distributions upstream
# doesn't ship an rpm for (Arch, Alpine, …) without pulling the system package.
#
# The version check reads only the GitHub releases API and the release's
# `checksums.txt` (~1 KiB), never the ~11 MiB package.

# These are read by build.sh and check-versions.sh after sourcing this module.
# shellcheck disable=SC2034
APP_ID="rio"
# shellcheck disable=SC2034
APP_NAME="Rio"
# shellcheck disable=SC2034
APP_ARCHES="x86_64 aarch64"
# ~11 MiB package + ~24 MiB installed payload + the squashfs output.
# shellcheck disable=SC2034
APP_MIN_FREE_KB=150000

RIO_REPO="${RIO_REPO:-raphamorim/rio}"
# Which upstream package flavor to package: `wayland` or `x11`.
RIO_VARIANT="${RIO_VARIANT:-wayland}"

# _rio_api <path> — GET a GitHub API URL, authenticating when a token is set.
# check-versions.sh already talks to the GitHub API; this reuses GH_TOKEN /
# GITHUB_TOKEN when present to stay well inside the rate limit.
_rio_api() {
    local path="$1" token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
    if command -v curl >/dev/null 2>&1; then
        if [ -n "$token" ]; then
            curl -fsSL -H 'Accept: application/vnd.github+json' \
                -H "Authorization: Bearer $token" "$path"
        else
            curl -fsSL -H 'Accept: application/vnd.github+json' "$path"
        fi
    elif command -v wget >/dev/null 2>&1; then
        if [ -n "$token" ]; then
            wget -q -O - --header='Accept: application/vnd.github+json' \
                --header="Authorization: Bearer $token" "$path"
        else
            wget -q -O - --header='Accept: application/vnd.github+json' "$path"
        fi
    else
        die "need curl or wget"
    fi
}

# _rio_latest_tag — the newest non-prerelease tag, e.g. `v0.5.27`.
_rio_latest_tag() {
    local json
    json="$(_rio_api "https://api.github.com/repos/$RIO_REPO/releases/latest")" ||
        die "cannot read the latest rio release"
    # The response is pretty-printed, so a line-wise match is enough here.
    printf '%s' "$json" |
        sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' |
        head -n1
}

# _rio_checksums <version> — the release's checksums.txt (sha256 + asset name).
_rio_checksums() {
    fetch_stdout "https://github.com/$RIO_REPO/releases/download/v$1/checksums.txt"
}

# _rio_asset <arch> <version> — prints `<sha256>  <asset-name>` for the
# variant/arch we want, read from checksums.txt so the release/build number in
# the filename (the `-1` in rioterm-0.5.27-1.…) never has to be hard-coded.
_rio_asset() {
    local arch="$1" version="$2" line
    line="$(_rio_checksums "$version" | awk -v v="$version" -v a="$arch" -v variant="$RIO_VARIANT" '
        {
            name = $2
            if (name !~ /^rioterm-/) next
            if (index(name, "-" v "-") == 0) next
            if (name !~ ("\\." a "_" variant "\\.rpm$")) next
            print; exit
        }
    ')"
    [ -n "$line" ] ||
        die "no rio $RIO_VARIANT rpm for $arch in release $version"
    printf '%s\n' "$line"
}

app_latest_version() {
    local arch="$1" tag version
    tag="$(_rio_latest_tag)"
    [ -n "$tag" ] || die "no rio release found"
    version="${tag#v}"

    # Fail here rather than in the build job when an arch/variant is missing.
    _rio_asset "$arch" "$version" >/dev/null
    validate_version "$version"
}

app_payload_glob() { printf 'rioterm-*.rpm\n'; }

app_payload_version() {
    local payload="$1" version
    # rioterm-0.5.27-1.x86_64_wayland.rpm
    version="$(basename "$payload" | sed -n 's/^rioterm-\([^-]*\)-.*\.rpm$/\1/p')"
    [ -n "$version" ] || die "cannot determine version of $payload (pass --version)"
    validate_version "$version"
}

app_download() {
    local arch="$1" version="$2" dest="$3" asset sum name url out
    asset="$(_rio_asset "$arch" "$version")"
    sum="${asset%% *}"
    name="${asset##* }"

    out="$dest/$name"
    url="https://github.com/$RIO_REPO/releases/download/v$version/$name"
    log "downloading $APP_NAME $version ($arch)"
    fetch_to "$url" "$out"
    verify_sha256 "$out" "$sum"
    printf '%s\n' "$out"
}

app_assemble() {
    local arch="$1" version="$2" payload="$3" appdir="$4" extract

    require_cmds rpm2cpio cpio

    extract="$(dirname "$appdir")/extract"
    rm -rf "$extract"
    mkdir -p "$extract"
    log "extracting rpm"
    (cd "$extract" && rpm2cpio "$payload" | cpio -idm --quiet)

    [ -x "$extract/usr/bin/rio" ] ||
        die "unexpected rpm layout (usr/bin/rio missing)"

    log "assembling AppDir"
    mkdir -p "$appdir/usr/bin" \
        "$appdir/usr/share/applications" \
        "$appdir/usr/share/icons/hicolor/scalable/apps" \
        "$appdir/usr/share/terminfo/r"

    mv "$extract/usr/bin/rio" "$appdir/usr/bin/rio"
    cp "$extract/usr/share/applications/rio.desktop" "$appdir/"
    cp "$extract/usr/share/icons/hicolor/scalable/apps/rio.svg" \
        "$appdir/usr/share/icons/hicolor/scalable/apps/rio.svg"
    # appimagetool wants the icon named after the .desktop's Icon= at the root.
    cp "$extract/usr/share/icons/hicolor/scalable/apps/rio.svg" "$appdir/$APP_ID.svg"
    # Rio defines its own terminfo entry; AppRun points TERMINFO_DIRS at it.
    cp "$extract/usr/share/terminfo/r/rio" "$appdir/usr/share/terminfo/r/rio"

    # AppRun is kept as a separate file in this repo so it can be tweaked freely.
    install -m 0755 "$APP_DEF_DIR/AppRun" "$appdir/AppRun"

    rm -rf "$extract"
}
