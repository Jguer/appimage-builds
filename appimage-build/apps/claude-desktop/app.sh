# shellcheck shell=bash
#
# Claude Desktop → AppImage.
#
# Upstream ships a .deb through Anthropic's apt repository, and only supports
# Debian-based distributions:
#   https://code.claude.com/docs/en/desktop-linux
#
# Which is the point of this build: on Fedora, RHEL or Arch there is no
# supported package, and an AppImage carries the whole Electron runtime.
#
# The version check reads only the repository's Packages index (~5 KiB
# gzipped), never the ~170 MiB package.

# These are read by build.sh and check-versions.sh after sourcing this module.
# shellcheck disable=SC2034
APP_ID="claude-desktop"
# shellcheck disable=SC2034
APP_NAME="Claude_Desktop"
# shellcheck disable=SC2034
APP_ARCHES="x86_64 aarch64"
# ~170 MiB package + ~500 MiB unpacked payload + the squashfs output.
# shellcheck disable=SC2034
APP_MIN_FREE_KB=1600000

CLAUDE_DESKTOP_REPO_BASE="${CLAUDE_DESKTOP_REPO_BASE:-https://downloads.claude.ai/claude-desktop/apt/stable}"
CLAUDE_DESKTOP_SUITE="${CLAUDE_DESKTOP_SUITE:-stable}"

# Debian architecture name for one of our arches.
_claude_desktop_debarch() {
    case "$1" in
        x86_64)  echo amd64 ;;
        aarch64) echo arm64 ;;
        *) die "unsupported architecture: $1" ;;
    esac
}

# _claude_desktop_meta <arch> [version]
#
# Prints `version<TAB>pool-path<TAB>sha256`, for the given version or for the
# newest one when none is asked for. Fetches only the gzipped Packages index,
# which holds a stanza per published version — the pool keeps them all, so a
# specific older version is still fetchable.
_claude_desktop_meta() {
    local arch="$1" version="${2:-}" debarch index url
    debarch="$(_claude_desktop_debarch "$arch")"
    url="$CLAUDE_DESKTOP_REPO_BASE/dists/$CLAUDE_DESKTOP_SUITE/main/binary-$debarch/Packages.gz"

    index="$(fetch_stdout "$url" | gunzip)" || die "cannot read $url"

    # Stanzas are blank-line separated RFC822 blocks.
    printf '%s\n' "$index" | awk -v want='claude-desktop' -v pin="$version" '
        BEGIN { RS = ""; FS = "\n" }
        {
            pkg = ""; ver = ""; fn = ""; sum = ""
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^Package: /)  pkg = substr($i, 10)
                if ($i ~ /^Version: /)  ver = substr($i, 10)
                if ($i ~ /^Filename: /) fn  = substr($i, 11)
                if ($i ~ /^SHA256: /)   sum = substr($i, 9)
            }
            if (pkg != want || ver == "" || fn == "" || sum == "") next
            if (pin != "" && ver != pin) next
            printf "%s\t%s\t%s\n", ver, fn, sum
        }
    ' | sort -Vr | head -n1
}

app_latest_version() {
    local arch="$1" meta
    meta="$(_claude_desktop_meta "$arch")"
    [ -n "$meta" ] || die "no claude-desktop package found for $arch"
    validate_version "${meta%%$'\t'*}"
}

app_payload_glob() { printf 'claude-desktop_*.deb\n'; }

app_payload_version() {
    local payload="$1" version
    # claude-desktop_1.49585.0_amd64.deb
    version="$(basename "$payload" | sed -n 's/^claude-desktop_\([^_]*\)_.*\.deb$/\1/p')"
    [ -n "$version" ] || die "cannot determine version of $payload (pass --version)"
    validate_version "$version"
}

app_download() {
    local arch="$1" version="$2" dest="$3" meta path sum out
    meta="$(_claude_desktop_meta "$arch" "$version")"
    [ -n "$meta" ] \
        || die "version $version is not in the repository index for $arch"

    IFS=$'\t' read -r _ path sum <<<"$meta"

    out="$dest/$(basename "$path")"
    log "downloading $APP_NAME $version ($arch)"
    fetch_to "$CLAUDE_DESKTOP_REPO_BASE/$path" "$out"
    verify_sha256 "$out" "$sum"
    printf '%s\n' "$out"
}

# _extract_deb <deb> <dir> — unpack a .deb's data member into <dir>.
#
# dpkg-deb is the obvious tool but only exists on Debian-based systems, which
# are exactly the ones that don't need this AppImage; ar + tar covers the rest.
_extract_deb() {
    local deb="$1" dir="$2" member
    local -a decomp

    # A fixed umask makes the extracted modes deterministic instead of
    # inheriting whatever the caller's shell had.
    umask 022

    if command -v dpkg-deb >/dev/null 2>&1; then
        dpkg-deb -x "$deb" "$dir"
        return
    fi

    require_cmds ar tar
    member="$(ar t "$deb" | grep '^data\.tar' | head -n1)"
    [ -n "$member" ] || die "no data member in $deb"

    # Name the decompressor explicitly: tar's own detection does not kick in
    # for every build when the archive arrives on stdin.
    case "$member" in
        *.tar)  decomp=(cat) ;;
        *.xz)   decomp=(xz -dc) ;;
        *.zst)  decomp=(zstd -dc) ;;
        *.gz)   decomp=(gzip -dc) ;;
        *.bz2)  decomp=(bzip2 -dc) ;;
        *) die "unsupported data member in $deb: $member" ;;
    esac
    require_cmds "${decomp[0]}"

    ar p "$deb" "$member" | "${decomp[@]}" \
        | tar -xf - -C "$dir" --no-same-owner --no-same-permissions
}

app_assemble() {
    local arch="$1" version="$2" payload="$3" appdir="$4" extract src

    extract="$(dirname "$appdir")/extract"
    rm -rf "$extract"
    mkdir -p "$extract"
    log "extracting deb"
    _extract_deb "$payload" "$extract"

    src="$extract/usr/lib/claude-desktop"
    [ -d "$src" ] || die "unexpected deb layout (usr/lib/claude-desktop missing)"

    log "assembling AppDir"
    mkdir -p "$appdir/usr/lib" "$appdir/usr/bin"
    mv "$src" "$appdir/usr/lib/claude-desktop"
    ln -sfn ../lib/claude-desktop/claude-desktop "$appdir/usr/bin/claude-desktop"

    # The setuid bit on Chromium's SUID sandbox helper cannot survive a
    # squashfs that gets mounted nosuid. Drop it rather than ship a mode that
    # implies a privilege the bundle never has; Chromium prefers its
    # namespace sandbox anyway, and AppRun documents the fallback.
    if [ -f "$appdir/usr/lib/claude-desktop/chrome-sandbox" ]; then
        chmod 0755 "$appdir/usr/lib/claude-desktop/chrome-sandbox"
    fi

    # Upstream's desktop entry is named for the app id, not the package, and
    # its Icon= points at claude-desktop.
    cp "$extract/usr/share/applications/com.anthropic.Claude.desktop" "$appdir/"
    mkdir -p "$appdir/usr/share/icons"
    cp -r "$extract/usr/share/icons/hicolor" "$appdir/usr/share/icons/"
    cp "$extract/usr/share/icons/hicolor/256x256/apps/$APP_ID.png" "$appdir/$APP_ID.png"

    install -m 0755 "$APP_DEF_DIR/AppRun" "$appdir/AppRun"

    rm -rf "$extract"
}
