# Pre-configured BepInEx Files (Windows-Generated)

> **This folder contains BepInEx files that must be generated on Windows first.**

## Purpose

Due to ARM64 emulation limitations, BepInEx's interop assembly generation fails under Box64.
This folder is the source for pre-configured files that are automatically copied to the server on container startup.

## Required Files

After running the V Rising server with BepInEx on Windows, copy these files/folders here:

```
mods/
├── BepInEx/
│   ├── interop/        ← Generated DLLs (required!)
│   ├── unity-libs/     ← Unity libraries (required!)
│   ├── plugins/        ← Your mod DLLs
│   ├── config/         ← Mod configurations
│   ├── core/           ← BepInEx core files
│   └── patchers/       ← Optional patchers
├── dotnet/             ← .NET runtime (required for BepInEx IL2CPP)
├── winhttp.dll         ← Doorstop proxy DLL (required!)
├── doorstop_config.ini ← Doorstop configuration (required!)
└── README.md           ← This file
```

## How to Generate on Windows

1. Download V Rising Dedicated Server via SteamCMD
2. Install BepInEx IL2CPP build
3. Run the server once (wait for interop generation)
4. Copy the files listed above to this folder

See `docs/BEPINEX_SETUP.md` for detailed step-by-step instructions.

## What Happens on Container Startup

The `start.sh` script will:
1. Detect files in this folder (mounted to `/mods-source`)
2. Copy BepInEx, dotnet, and doorstop files to `/data/server/`
3. Sync plugins on every restart (allows easy mod updates)

## Updating Mods

To update mods:
1. Replace/add DLLs in `BepInEx/plugins/`
2. Restart the container
3. Plugins are automatically synced!

## Current Contents

This folder should contain your pre-generated files from Windows.
The `.gitignore` is configured to ignore binary files but track the structure.
