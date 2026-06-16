# ReaDLP

ReaDLP is a Windows-first ReaScript/ReaImGui tool for downloading organized sample-digging audio inside REAPER with `yt-dlp.exe` and `ffmpeg.exe`.

It is designed for YouTube, Samplette, and similar sample discovery workflows where musical metadata matters while downloading.

## Requirements

- Windows 10/11
- REAPER 7.x
- ReaImGui from ReaPack
- `yt-dlp.exe`
- `ffmpeg.exe`

## Features

- Single URL audio downloads.
- Playlist URL downloads into playlist-title subfolders.
- Queue mode with one URL per line.
- Optional insertion of downloaded audio onto the selected REAPER track.
- Queue insertion into fixed lanes when insertion is enabled.
- Metadata fields for Style, Region, Channel, Artist, Year, Key, and Tempo.
- Searchable saved histories for metadata fields.
- Saved download folders.
- Background downloads without distracting command windows.
- Copyable logs and diagnostics for troubleshooting.
- Local settings under `REAPER resource path\Data\ReaDLP\settings.ini`.

## ReaPack Package Layout

The package entry point is:

```text
Scripts/Downloads/ReaDLP.lua
```

ReaPack indexes package files only when they live in a subfolder. The `Scripts/Downloads` path is intentional: it becomes the package category shown in ReaPack.

The public package currently uses one main Lua file for maximum install compatibility. ReaPack can install multiple files with `@provides`, but helper libraries are not split out yet.

## Installation From ReaPack

In REAPER:

1. Open `Extensions > ReaPack > Import repositories...`.
2. Paste this URL:

```text
https://raw.githubusercontent.com/BigMack64/ReaDLP/main/index.xml
```

3. Synchronize packages.
4. Install `ReaDLP.lua` from the `Scripts/Downloads` category.

## Installation For Local Testing

1. Install ReaImGui from ReaPack.
2. Put `yt-dlp.exe` and `ffmpeg.exe` somewhere ReaDLP can find them:
   - next to the script,
   - under the REAPER resource path,
   - or on `PATH`.
3. In REAPER, open the Actions window.
4. Load `Scripts/Downloads/ReaDLP.lua`.
5. Run the action.

## ReaPack Repository Publishing

This repository uses GitHub Actions to validate the package and generate `index.xml` with `reapack-index` after pushes to `main`.

For manual local validation:

```powershell
gem install reapack-index
reapack-index --check "C:\path\to\ReaDLP Pub Release"
```

The ReaPack import URL is:

```text
https://raw.githubusercontent.com/BigMack64/ReaDLP/main/index.xml
```

## Notes

ReaDLP does not bundle yt-dlp or ffmpeg. This avoids shipping large third-party binaries and keeps the ReaPack package focused on the REAPER script.
