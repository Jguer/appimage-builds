# AppImage builds

Unofficial AppImage packaging for two upstream Linux apps that don't ship one,
and that only publish packages for distributions they officially support:

| App | `id` | Upstream artifact | Officially supports | Arches |
| --- | --- | --- | --- | --- |
| ChatGPT desktop | `chatgpt` | `.rpm` from OpenAI's [signed yum repository](https://developers.openai.com/codex/linux/linux-app) | Fedora, Ubuntu, Debian | `x86_64`, `aarch64` |
| Claude Desktop | `claude-desktop` | `.deb` from Anthropic's [signed apt repository](https://code.claude.com/docs/en/desktop-linux) | Ubuntu, Debian only | `x86_64`, `aarch64` |

Nothing is patched or recompiled: the upstream payload is verified against its
published sha256 and repackaged into a squashfs image with an `AppRun` wrapper.
Both apps bundle their own Chromium/Electron runtime, so the AppImage runs on
distributions upstream doesn't package for — Claude Desktop on Fedora, RHEL or
Arch, for instance, where the docs otherwise send you to the CLI.

Everything runs the same way locally and in CI — the workflow in
`.github/workflows/appimage-release.yml` is a thin wrapper around the two
scripts below.

## Layout

```
appimage-build/
├── check-versions.sh        upstream vs. released comparison
├── build.sh                 download → AppDir → .AppImage
├── lib/common.sh            shared helpers + the app-module contract
└── apps/
    ├── chatgpt/             app.sh, AppRun
    └── claude-desktop/      app.sh, AppRun
```

## Checking for updates

```console
$ ./appimage-build/check-versions.sh
APP             ARCH    UPSTREAM      RELEASED      STATUS
chatgpt         x86_64  26.903.61454  26.901.51231  update
claude-desktop  x86_64  1.49585.0     1.49585.0     up-to-date
```

The upstream side reads only small metadata — the yum repository's `repodata`
for ChatGPT (a couple of KiB) and the apt repository's gzipped `Packages` index
for Claude Desktop (about 5 KiB). It never downloads a payload just to learn a
version number, so it is cheap enough to run on a schedule.

The released side is this repository's GitHub releases. A release is tagged
`<app>-v<version>` and carries one `.AppImage` per arch, so an app counts as
needing a build when the asset for the newest upstream version is missing.

```
-a, --arch ARCH        arch to check (repeatable; default: host arch)
-r, --repo OWNER/NAME  repository holding the releases
                       (default: $GITHUB_REPOSITORY, else the git remote)
-f, --force            report every app as needing a build
    --json             emit a JSON array instead of a table
```

Statuses are `up-to-date`, `new` (nothing released yet), `update` (upstream
moved), `missing-asset` (that arch never got built), `forced`, and `error`.
Exit status is `0` normally and `3` when an upstream feed could not be read —
the apps that did answer are still reported.

## Building

```console
$ ./appimage-build/build.sh claude-desktop        # newest upstream version
$ ./appimage-build/build.sh chatgpt claude-desktop  # both
$ ./appimage-build/build.sh claude-desktop -a aarch64
$ ./appimage-build/build.sh ./chatgpt.x86_64.rpm  # a package you already have
$ ./appimage-build/build.sh ./claude-desktop_1.49585.0_amd64.deb
```

The result lands in `appimage-build/out/` next to a `.sha256`:

```
appimage-build/out/Claude_Desktop-1.49585.0-x86_64.AppImage
appimage-build/out/ChatGPT-26.903.61454-x86_64.AppImage
```

Builds go to a temporary file and are renamed into place, so rebuilding works
even while a previous copy of the AppImage is still running.

`-v/--version` pins the build and fails loudly if upstream has moved on, which
is what CI uses so the version the check decided on is the version that gets
built. It cannot fetch an *older* ChatGPT release — OpenAI's repository only
carries the current package — but Anthropic's apt pool keeps every published
version, so `claude-desktop -v <older>` works. Otherwise use `-p` with a
package you kept.

```
-a, --arch ARCH        target architecture (default: host)
-v, --version VERSION  build this version instead of the newest upstream
-p, --payload FILE     use this rpm/deb instead of downloading one
    --keep-payload     keep the download in appimage-build/downloads
-o, --output-dir DIR   default: appimage-build/out
-l, --list             list the known apps
```

### Dependencies

`curl` (or `wget`), `sha256sum` and `mksquashfs`, plus `rpm2cpio` and `cpio`
for ChatGPT, and for Claude Desktop either `dpkg-deb` or — on distributions
that don't have it — `ar`, `tar` and `xz`. `check-versions.sh` also needs `jq`.
`appimagetool` is fetched on first use and cached in `appimage-build/tools/`.

Building ChatGPT needs ~2.5 GiB free: a 440 MiB package that unpacks to 1.4 GiB
plus the ~500 MiB output. Claude Desktop needs about 1.5 GiB for a 170 MiB
package and a ~215 MiB output.

### Notes on the wrappers

- **ChatGPT** picks native Wayland when it detects a Wayland session; override
  with `CHATGPT_OZONE=x11|wayland|auto`. On hosts that restrict unprivileged
  user namespaces, either install the bundled AppArmor profile from
  `etc/apparmor.d/chatgpt` inside the image or set `CHATGPT_NO_SANDBOX=1`.
- **Claude Desktop** lets Electron choose its platform (X11, or XWayland under
  Wayland), matching upstream; force one with
  `CLAUDE_DESKTOP_OZONE=x11|wayland|auto`. The `.deb` ships an AppArmor profile
  so Chromium's namespace sandbox works on Ubuntu 24.04+, but a profile matches
  on the binary's path and an AppImage runs from a fresh `/tmp` mount every
  time, so it can't apply here — on a host that restricts user namespaces, set
  `CLAUDE_DESKTOP_NO_SANDBOX=1`. The setuid bit on Chromium's SUID sandbox
  helper is dropped during assembly, since a squashfs that gets mounted
  `nosuid` can never honour it.
- Neither app self-updates from an AppImage. Build a new one, or use
  `check-versions.sh` to find out when it's worth doing.
- Claude Desktop's **Cowork** tab needs QEMU/KVM host packages
  (`qemu-system-x86`, `ovmf`, `virtiofsd`) and membership of the `kvm` group.
  Those are host dependencies the `.deb` pulls in as recommends and an
  AppImage cannot carry; install them through your own package manager.

## Automation

`.github/workflows/appimage-release.yml` runs daily:

1. **check** — `check-versions.sh --json` against the app list, turning
   everything that needs a build into a job matrix. Metadata only, so this
   costs a handful of HTTP requests whether or not anything changed.
2. **build** — one job per app/arch, on `ubuntu-24.04` or `ubuntu-24.04-arm`.
   Only jobs that reached this point download a payload.
3. **publish** — creates the `<app>-v<version>` release if it doesn't exist and
   uploads the `.AppImage` and its `.sha256`.

Run it by hand from the Actions tab to pick specific apps, add `aarch64`, or
force a rebuild. It needs no secrets beyond the built-in `GITHUB_TOKEN`.

`aarch64` is not in the default matrix: GitHub's arm runners are free on public
repositories but billed on private ones. Add it via the `arches` input, or
change the default in the workflow.

`.github/workflows/lint.yml` runs shellcheck over every script on push and PR,
plus a live metadata-only version check.

## Adding another app

Create `appimage-build/apps/<id>/app.sh` declaring `APP_ID`, `APP_NAME` and
`APP_ARCHES`, and defining `app_latest_version`, `app_download` and
`app_assemble`. The full contract is documented at the top of
`appimage-build/lib/common.sh`. Both scripts discover apps from the directory,
so nothing else needs editing.

The one rule that matters: `app_latest_version` must answer from metadata
alone. If an upstream only publishes the version inside its payload, the daily
check stops being cheap.
