# StreamHaven releases

Public download channel for the **StreamHaven** Windows app. Release builds only — no source, and
no hub-side code (the hubs are maintained separately).

Hubs poll one fixed link and install only when the version is higher:

    https://github.com/mattyjsherm/streamhaven-releases/releases/latest/download/streamhaven-version.json

Each release is marked **Latest**, tagged `v<version>` (with `+` written as `-`), and holds exactly
two files — `streamhaven-windows-x64.zip` and `streamhaven-version.json`:

```json
{
  "app": "streamhaven",
  "version": "1.2.0+3",
  "zip": "https://github.com/mattyjsherm/streamhaven-releases/releases/download/v1.2.0-3/streamhaven-windows-x64.zip",
  "sha256": "<lowercase hex SHA-256 of the zip>",
  "size": 0,
  "published": "<ISO 8601 with offset>",
  "notes": "<one line, <= 60 chars>"
}
```

`version` equals the exe's Windows Product version. `zip` is that release's own link (never a
"latest" link). Published from the StreamHaven project with `tools/release/publish-hubs.ps1`.
Versions only ever increase; published releases are never edited — a fix ships as a higher version.