#!/usr/bin/env bash
#
# check-versions.sh — compare the newest upstream version of each app with what
# has already been published as a GitHub release in this repository.
#
# The upstream side only ever reads small metadata (a version file, a yum
# repository's repodata, a JSON manifest) — never the multi-hundred-megabyte
# payload. Running this is cheap enough for a cron schedule.
#
# Usage:
#   ./check-versions.sh                       host arch, every known app
#   ./check-versions.sh chatgpt               one app
#   ./check-versions.sh -a x86_64 -a aarch64  several arches
#   ./check-versions.sh --json                machine-readable output
#
# Options:
#   -a, --arch ARCH        arch to check (repeatable; default: host arch)
#   -r, --repo OWNER/NAME  repository holding the releases
#                          (default: $GITHUB_REPOSITORY, else the git remote)
#   -f, --force            report every app as needing a build
#       --json             emit a JSON array instead of a table
#   -h, --help             this message
#
# A release is named <app>-v<version> and carries one .AppImage per arch, so an
# app needs building when the asset for the newest upstream version is missing.
#
# Authentication is optional for public repositories; set GH_TOKEN or
# GITHUB_TOKEN to raise the API rate limit or to read a private repository.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS_DIR="$SCRIPT_DIR/apps"
TOOLS_DIR="$SCRIPT_DIR/tools"

# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

usage() {
    awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "${BASH_SOURCE[0]}"
}

# ------------------------------------------------------------------ arguments
ARCHES=()
REPO="${GITHUB_REPOSITORY:-}"
FORCE=0
JSON=0
REQUESTED=()

while [ $# -gt 0 ]; do
    case "$1" in
        -a|--arch)  ARCHES+=("$(normalize_arch "$2")"); shift 2 ;;
        -r|--repo)  REPO="$2"; shift 2 ;;
        -f|--force) FORCE=1; shift ;;
        --json)     JSON=1; shift ;;
        -h|--help)  usage; exit 0 ;;
        -*)         die "unknown option: $1 (try --help)" ;;
        *)          REQUESTED+=("$1"); shift ;;
    esac
done

[ ${#ARCHES[@]} -gt 0 ] || ARCHES=("$(host_arch)")
[ ${#REQUESTED[@]} -gt 0 ] || mapfile -t REQUESTED < <(list_apps)
[ ${#REQUESTED[@]} -gt 0 ] || die "no apps found in $APPS_DIR"

require_cmds jq

# ---------------------------------------------------------------- release side
if [ -z "$REPO" ] && command -v git >/dev/null 2>&1; then
    REPO="$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null \
        | sed -E 's#^(git@github\.com:|(ssh|https)://[^/]*github\.com/)##; s#\.git$##' || true)"
    [[ "$REPO" == */* ]] || REPO=""
fi

RELEASES_JSON="$(mktemp)"
trap 'rm -f "$RELEASES_JSON"' EXIT
printf '[]' >"$RELEASES_JSON"

if [ -n "$REPO" ]; then
    api_args=(-fsSL -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28')
    token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
    [ -n "$token" ] && api_args+=(-H "Authorization: Bearer $token")
    # Releases come back newest first, so one page always contains the highest
    # version of every app; there is nothing to gain from paginating.
    if ! curl "${api_args[@]}" "https://api.github.com/repos/$REPO/releases?per_page=100" \
            >"$RELEASES_JSON" 2>/dev/null; then
        warn "could not list releases for $REPO; treating every app as unreleased"
        printf '[]' >"$RELEASES_JSON"
    fi
else
    warn "no repository known (pass --repo or set GITHUB_REPOSITORY); treating every app as unreleased"
fi

# released_version <app-id> — highest published version, or empty.
released_version() {
    jq -r --arg p "$1-v" '
        [ .[] | select(.tag_name | startswith($p)) | (.tag_name | sub("^" + $p; "")) ] | .[]
    ' "$RELEASES_JSON" 2>/dev/null | sort -Vr | head -n1
}

# asset_published <tag> <asset-name>
asset_published() {
    local count
    count="$(jq -r --arg tag "$1" --arg name "$2" '
        [ .[] | select(.tag_name == $tag) | .assets[]? | select(.name == $name) ] | length
    ' "$RELEASES_JSON" 2>/dev/null || echo 0)"
    [ "${count:-0}" -gt 0 ]
}

# ----------------------------------------------------------------------- check
rows=()
for app in "${REQUESTED[@]}"; do
    for arch in "${ARCHES[@]}"; do
        # A subshell per app keeps one module's variables out of the next one's.
        row="$(
            load_app "$app"
            app_supports_arch "$arch" || exit 0

            released="$(released_version "$app")"
            if ! upstream="$(app_latest_version "$arch")"; then
                # A transient upstream failure must not look like "up to date",
                # and must not take the other apps down with it.
                jq -cn --arg app "$app" --arg name "$APP_NAME" --arg arch "$arch" \
                    --arg released "${released:-}" \
                    '{app: $app, app_name: $name, arch: $arch, upstream: "",
                      released: $released, tag: "", asset: "",
                      status: "error", needs_build: false}'
                exit 0
            fi
            tag="$(release_tag "$upstream")"
            asset="$(appimage_filename "$upstream" "$arch")"

            if [ "$FORCE" -eq 1 ]; then
                needs=true; status='forced'
            elif asset_published "$tag" "$asset"; then
                needs=false; status='up-to-date'
            elif [ -z "$released" ]; then
                needs=true; status='new'
            elif version_gt "$upstream" "$released"; then
                needs=true; status='update'
            else
                # Upstream is not newer, but this arch's asset is missing.
                needs=true; status='missing-asset'
            fi

            jq -cn \
                --arg app "$app" --arg name "$APP_NAME" --arg arch "$arch" \
                --arg upstream "$upstream" --arg released "${released:-}" \
                --arg tag "$tag" --arg asset "$asset" --arg status "$status" \
                --argjson needs_build "$needs" \
                '{app: $app, app_name: $name, arch: $arch, upstream: $upstream,
                  released: $released, tag: $tag, asset: $asset,
                  status: $status, needs_build: $needs_build}'
        )"
        [ -n "$row" ] && rows+=("$row")
    done
done

[ ${#rows[@]} -gt 0 ] || die "nothing to check"

if [ "$JSON" -eq 1 ]; then
    printf '%s\n' "${rows[@]}" | jq -s '.'
else
    printf '%s\n' "${rows[@]}" | jq -rs '
        (["APP", "ARCH", "UPSTREAM", "RELEASED", "STATUS"]),
        (.[] | [.app, .arch, .upstream, (if .released == "" then "-" else .released end), .status])
        | @tsv
    ' | if command -v column >/dev/null 2>&1; then column -t -s $'\t'; else cat; fi
fi

# Exit 3 when an upstream feed could not be read, so a scheduled run notices.
# The output above is still complete for every app that did answer.
if printf '%s\n' "${rows[@]}" | jq -se 'any(.[]; .status == "error")' >/dev/null; then
    warn "at least one upstream version check failed"
    exit 3
fi
