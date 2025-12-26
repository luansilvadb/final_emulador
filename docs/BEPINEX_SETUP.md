# BepInEx Pre-Generation Setup Guide

> **This guide explains how to generate BepInEx interoperability files on Windows for use on ARM64 servers.**

## Why Is This Required?

BepInEx uses a component called **Il2CppInterop** (formerly Unhollower) to create .NET assemblies that mirror V Rising's internal game classes. This process:

1. Reads `GameAssembly.dll` and metadata files
2. Analyzes thousands of game classes in parallel (multi-threaded)
3. Generates DLLs that allow mods to interact with the game

### The ARM64 Problem

Under Box64/Wine emulation on ARM64:

- **Thread synchronization** behaves differently than native x86
- **JIT compilation** of the generator can hit edge cases in translation
- **Memory model differences** cause race conditions

The result: **generation hangs, crashes, or produces corrupted files**.

### The Solution

Generate these files **once** on a native Windows system, then transfer them to your ARM64 server. The container will detect existing files and skip the problematic generation step.

---

## Step-by-Step Instructions

### Prerequisites

- Windows 10/11 (x86-64) machine
- SteamCMD installed
- BepInEx IL2CPP build

### Step 1: Download V Rising Dedicated Server

Open PowerShell or Command Prompt:

```powershell
# Navigate to your tools directory
cd C:\Games

# Download via SteamCMD
steamcmd +login anonymous +app_update 1829350 validate +quit

# Server files are now in:
# C:\Games\steamapps\common\VRisingDedicatedServer\
```

### Step 2: Download BepInEx IL2CPP Build

1. Go to [BepInEx Releases](https://github.com/BepInEx/BepInEx/releases)
2. Download the **IL2CPP x64** version (e.g., `BepInEx_UnityIL2CPP_x64_6.0.0-be.xxx.zip`)
3. Extract to the server folder:

```
VRisingDedicatedServer/
├── VRisingServer.exe
├── BepInEx/              ← Extracted here
│   ├── core/
│   ├── config/
│   ├── plugins/          ← Your mods go here later
│   └── ...
├── doorstop_config.ini   ← Also extracted
├── winhttp.dll           ← Also extracted (the doorstop proxy)
└── ...
```

### Step 3: Configure BepInEx

Edit `doorstop_config.ini`:

```ini
[General]
enabled=true
targetAssembly=BepInEx\core\BepInEx.IL2CPP.dll
```

### Step 4: Run the Server (Generation Phase)

```powershell
cd "C:\Games\steamapps\common\VRisingDedicatedServer"

# Run the server
.\VRisingServer.exe

# Wait for BepInEx to generate interop files
# You'll see console output like:
# [BepInEx] Generating interop assemblies...
# [BepInEx] Processing Il2CppInterop...
# This takes 2-5 minutes depending on your CPU
```

**Important**: Wait until you see the server fully start (world loading, etc.), then close it with `Ctrl+C`.

### Step 5: Verify Generation Success

Check that these directories exist and contain DLL files:

```
BepInEx/
├── interop/              ← Should contain ~100+ DLL files
│   ├── Assembly-CSharp.dll
│   ├── mscorlib.dll
│   ├── Unity.*.dll
│   └── ...
├── unity-libs/           ← Should contain Unity DLLs
│   ├── UnityEngine.dll
│   └── ...
└── LogOutput.log         ← Should show successful loading
```

If these folders are **empty** or missing, the generation failed. Try:
- Reinstalling BepInEx
- Checking for antivirus interference
- Running as Administrator

### Step 6: Add Your Mods (Optional)

Place mod DLLs in the `BepInEx/plugins/` folder:

```
BepInEx/
├── plugins/
│   ├── MyMod.dll
│   ├── AnotherMod.dll
│   └── ...
```

### Step 7: Transfer to ARM64 Server

#### Option A: Local `mods/` Folder (Recommended - Automatic!)

Copy files to the `mods/` folder in the project directory. They will be automatically copied on container startup:

```powershell
# On Windows, copy to the project's mods folder
$ProjectPath = "C:\path\to\vrising-arm64"
$ServerPath = "C:\Games\steamapps\common\VRisingDedicatedServer"

Copy-Item -Recurse "$ServerPath\BepInEx" "$ProjectPath\mods\"
Copy-Item "$ServerPath\doorstop_config.ini" "$ProjectPath\mods\"
Copy-Item "$ServerPath\winhttp.dll" "$ProjectPath\mods\"
Copy-Item -Recurse "$ServerPath\dotnet" "$ProjectPath\mods\"  # If present
```

Then just restart the container - files are copied automatically!

#### Option B: Full Server Transfer

Transfer the entire server directory:

```powershell
# Create archive
Compress-Archive -Path "C:\Games\steamapps\common\VRisingDedicatedServer\*" `
                 -DestinationPath "vrising-server.zip"
```

Then upload to your server's `/data/server/` directory.

#### Option C: Minimal BepInEx Transfer (Manual)

If server files are already on ARM64, transfer only BepInEx:

**Required files:**
- `BepInEx/` (entire folder)
- `doorstop_config.ini`
- `winhttp.dll`
- `dotnet/` (optional, for .NET runtime)

```bash
# On ARM64 server
scp -r user@windows-machine:"/path/to/BepInEx" /data/server/
scp user@windows-machine:"/path/to/doorstop_config.ini" /data/server/
scp user@windows-machine:"/path/to/winhttp.dll" /data/server/
```

### Step 8: Verify on ARM64

Start the container and check logs:

```bash
docker compose logs -f
```

You should see:

```
[INFO] BepInEx directory detected.
[INFO] BepInEx interop files validated successfully.
[INFO] Wine DLL overrides configured: WINEDLLOVERRIDES=winhttp=n,b
```

If you see warnings about missing interop files, the transfer was incomplete.

---

## Updating Mods

When updating mods:

1. Stop the container
2. Transfer new mod DLLs to `BepInEx/plugins/`
3. Restart the container

**Do NOT delete the `interop/` or `unity-libs/` folders** - these only change when the game updates.

## After Game Updates

When V Rising updates:

1. **On Windows**: Delete `BepInEx/interop/` and `BepInEx/unity-libs/`
2. Run the server once to regenerate
3. Transfer fresh interop files to ARM64
4. Update server files on ARM64

---

## Troubleshooting

### Generation Hangs on Windows

- Disable real-time antivirus scanning for the server folder
- Try running as Administrator
- Ensure no other instance is running

### "Assembly failed to load" Errors

- Verify BepInEx version matches game version
- Re-download fresh BepInEx release
- Delete and regenerate interop files

### Mods Don't Load on ARM64

1. Check `BepInEx/LogOutput.log` for errors
2. Verify `winhttp.dll` is in server root
3. Confirm `WINEDLLOVERRIDES=winhttp=n,b` in logs

---

## Quick Reference Script

Save this as `prepare-bepinex.ps1` on Windows:

```powershell
# V Rising BepInEx Preparation Script
$ServerPath = "C:\Games\steamapps\common\VRisingDedicatedServer"

# Check for server
if (-not (Test-Path "$ServerPath\VRisingServer.exe")) {
    Write-Error "Server not found at $ServerPath"
    exit 1
}

# Run server to generate interop
Write-Host "Starting server for interop generation..."
Write-Host "Wait for full startup, then press Ctrl+C"
Push-Location $ServerPath
& .\VRisingServer.exe
Pop-Location

# Verify generation
$InteropFiles = Get-ChildItem "$ServerPath\BepInEx\interop\*.dll" -ErrorAction SilentlyContinue
if ($InteropFiles.Count -gt 50) {
    Write-Host "SUCCESS: $($InteropFiles.Count) interop files generated!" -ForegroundColor Green
} else {
    Write-Host "WARNING: Only $($InteropFiles.Count) interop files found" -ForegroundColor Yellow
}

# Create archive for transfer
Write-Host "Creating transfer archive..."
$ArchivePath = "$env:USERPROFILE\Desktop\vrising-bepinex-transfer.zip"
Compress-Archive -Path "$ServerPath\BepInEx", "$ServerPath\doorstop_config.ini", "$ServerPath\winhttp.dll" `
                 -DestinationPath $ArchivePath -Force

Write-Host "Archive created at: $ArchivePath" -ForegroundColor Cyan
Write-Host "Transfer this to your ARM64 server's /data/server/ directory."
```

---

**For more help, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md)**
