# shellcheck shell=bash
#
# ChatGPT desktop app → AppImage.
#
# Upstream ships .rpm/.deb packages plus a signed yum repository:
#   https://developers.openai.com/codex/linux/linux-app
#
# The version check reads only that repository's `repodata` (a couple of KiB),
# never the ~440 MiB package.

# These are read by build.sh and check-versions.sh after sourcing this module.
# shellcheck disable=SC2034
APP_ID="chatgpt"
# shellcheck disable=SC2034
APP_NAME="ChatGPT"
# shellcheck disable=SC2034
APP_ARCHES="x86_64 aarch64"
# ~440 MiB package + ~1.4 GiB installed payload + ~0.5 GiB squashfs output.
# shellcheck disable=SC2034
APP_MIN_FREE_KB=2600000

CHATGPT_REPO_BASE="${CHATGPT_REPO_BASE:-https://persistent.oaistatic.com/codex-app-prod/linux/rpm}"

# _chatgpt_repo_meta <arch>
#
# Prints `version<TAB>relative-href<TAB>sha256` for the newest package in the
# repository. Fetches repomd.xml and the (gzipped) primary metadata only.
_chatgpt_repo_meta() {
    local arch="$1" base repomd primary_href primary
    base="$CHATGPT_REPO_BASE/$arch"

    repomd="$(fetch_stdout "$base/repodata/repomd.xml")" \
        || die "cannot read $base/repodata/repomd.xml"

    # The <location> inside the <data type="primary"> block; primary_db and the
    # other blocks are deliberately skipped.
    primary_href="$(printf '%s' "$repomd" | tr '<' '\n' \
        | awk '
            /^data type="/              { want = ($0 ~ /^data type="primary"[ >]/); next }
            want && /^location href="/  { sub(/^location href="/, ""); sub(/".*$/, ""); print; exit }
        ')"
    [ -n "$primary_href" ] || die "no primary metadata in $base/repodata/repomd.xml"

    primary="$(fetch_stdout "$base/$primary_href" | gunzip)" \
        || die "cannot read $base/$primary_href"

    # One record per <package>, newest first.
    printf '%s' "$primary" | sed 's/</\n</g' | awk -v arch="$arch" '
        function attr(line, name,    v) {
            if (match(line, name "=\"[^\"]*\"")) {
                v = substr(line, RSTART, RLENGTH)
                sub(name "=\"", "", v)
                sub(/"$/, "", v)
                return v
            }
            return ""
        }
        function flush() {
            if (ver != "" && href != "" && sum != "" && (pkgarch == arch || pkgarch == "noarch"))
                printf "%s\t%s\t%s\n", ver, href, sum
            ver = ""; href = ""; sum = ""; pkgarch = ""
        }
        # sed put every tag on its own line, so a text node trails its own tag.
        /^<package[ >]/   { flush(); next }
        /^<\/package>/    { flush(); next }
        /^<version /      { ver = attr($0, "ver"); next }
        /^<checksum /     { sub(/^<checksum[^>]*>/, ""); sum = $0; next }
        /^<location /     { href = attr($0, "href"); next }
        /^<arch>/         { pkgarch = substr($0, 7); next }
        END               { flush() }
    ' | sort -Vr | head -n1
}

app_latest_version() {
    local arch="$1" meta
    meta="$(_chatgpt_repo_meta "$arch")"
    [ -n "$meta" ] || die "no chatgpt package found for $arch"
    validate_version "${meta%%$'\t'*}"
}

app_payload_glob() { printf 'chatgpt*.rpm\n'; }

app_payload_version() {
    local payload="$1" version=""
    if command -v rpm >/dev/null 2>&1; then
        version="$(rpm -qp --qf '%{VERSION}' "$payload" 2>/dev/null || true)"
    fi
    if [ -z "$version" ]; then
        # chatgpt-26.903.61454-1.x86_64.rpm
        version="$(basename "$payload" | sed -n 's/^chatgpt-\([^-]*\)-.*\.rpm$/\1/p')"
    fi
    [ -n "$version" ] || die "cannot determine version of $payload (pass --version)"
    validate_version "$version"
}

app_download() {
    local arch="$1" version="$2" dest="$3" meta repo_version href sum out
    meta="$(_chatgpt_repo_meta "$arch")"
    [ -n "$meta" ] || die "no chatgpt package found for $arch"

    IFS=$'\t' read -r repo_version href sum <<<"$meta"
    if [ "$repo_version" != "$version" ]; then
        die "repository now serves $repo_version, not the requested $version"
    fi

    out="$dest/$(basename "$href")"
    log "downloading $APP_NAME $version ($arch)"
    fetch_to "$CHATGPT_REPO_BASE/$arch/$href" "$out"
    verify_sha256 "$out" "$sum"
    printf '%s\n' "$out"
}

app_assemble() {
    local arch="$1" version="$2" payload="$3" appdir="$4" extract src

    require_cmds rpm2cpio cpio

    extract="$(dirname "$appdir")/extract"
    rm -rf "$extract"
    mkdir -p "$extract"
    log "extracting rpm"
    ( cd "$extract" && rpm2cpio "$payload" | cpio -idm --quiet )

    src="$extract/usr/lib/chatgpt"
    [ -d "$src" ] || die "unexpected rpm layout (usr/lib/chatgpt missing)"

    log "assembling AppDir"
    mkdir -p "$appdir/usr/lib" "$appdir/usr/bin" "$appdir/etc"
    mv "$src" "$appdir/usr/lib/chatgpt"
    if [ -d "$extract/etc/apparmor.d" ]; then
        mv "$extract/etc/apparmor.d" "$appdir/etc/"
    fi
    ln -sfn ../lib/chatgpt/codex-launcher "$appdir/usr/bin/chatgpt"

    cp "$extract/usr/share/applications/$APP_ID.desktop" "$appdir/"
    cp "$extract/usr/share/pixmaps/$APP_ID.png" "$appdir/$APP_ID.png"
    mkdir -p "$appdir/usr/share/icons/hicolor/0x0/apps"
    cp "$appdir/$APP_ID.png" "$appdir/usr/share/icons/hicolor/0x0/apps/$APP_ID.png"

    # AppRun is kept as a separate file in this repo so it can be tweaked freely.
    install -m 0755 "$APP_DEF_DIR/AppRun" "$appdir/AppRun"

    rm -rf "$extract"
}
