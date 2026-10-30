# StreamHaven releases

Public download host for the **StreamHaven** Windows app, used by the media-hub auto-updater.
This repo holds only release assets (a zip + a small version manifest) — **no source**. The
source lives in a private repo.

## Permanent URLs (no login, no token)

| What | URL |
|------|-----|
| Version manifest (poll this) | https://github.com/mattyjsherm/streamhaven-releases/releases/latest/download/streamhaven-version.json |
| Newest Windows zip | https://github.com/mattyjsherm/streamhaven-releases/releases/latest/download/streamhaven-windows-x64.zip |

## streamhaven-version.json

```json
{
  "version": "1.1.0+2",   // matches streamhaven.exe ProductVersion / FileVersion
  "zip": "https://github.com/mattyjsherm/streamhaven-releases/releases/download/v1.1.0-2/streamhaven-windows-x64.zip",
  "sha256": "<sha256 of the zip>",
  "size": 33424793,
  "published": "2026-10-29T00:00:00Z"
}
```

The manifest's `zip` is the **version-pinned** asset URL, so its `sha256` always matches those exact
bytes (no race if a newer release lands mid-update). Download the zip named in the manifest, then
verify its sha256 against the manifest before unpacking.

## Hub update check (sketch)

1. GET the version manifest (fixed `latest/download` URL above).
2. Compare `.version` to the installed `streamhaven.exe` ProductVersion.
3. If newer: download `.zip`, verify `sha256` == `.sha256`, unpack into a cleaned
   `C:\Hub\apps\StreamHaven`, then launch.

Settings/data live in `%APPDATA%\com.example\streamhaven\` — outside the app folder — so replacing
the app folder never disturbs logins, favourites, or resume positions.

_Published by `tools/release/publish-release.ps1` in the private source repo._