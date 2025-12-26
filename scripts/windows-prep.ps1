# =============================================================================
# V Rising Dedicated Server - Windows Preparation Script
# =============================================================================
# This script automates the preparation of V Rising server files with BepInEx
# for deployment on ARM64 servers.
#
# Usage: Run in PowerShell as Administrator
#        .\windows-prep.ps1 [-ServerPath <path>] [-OutputPath <path>]
# =============================================================================

param(
    [string]$ServerPath = "C:\Games\steamapps\common\VRisingDedicatedServer",
    [string]$OutputPath = "$env:USERPROFILE\Desktop\vrising-arm64-transfer",
    [switch]$SkipServerDownload,
    [switch]$SkipBepInEx,
    [switch]$Force
)

# Color output functions
function Write-Success { param($Message) Write-Host "[OK] $Message" -ForegroundColor Green }
function Write-Info { param($Message) Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Write-Warn { param($Message) Write-Host "[WARN] $Message" -ForegroundColor Yellow }
function Write-Err { param($Message) Write-Host "[ERROR] $Message" -ForegroundColor Red }

# Banner
Write-Host ""
Write-Host "================================================================" -ForegroundColor Blue
Write-Host "  V Rising ARM64 - Windows Preparation Script" -ForegroundColor Blue
Write-Host "================================================================" -ForegroundColor Blue
Write-Host ""

# =============================================================================
# STEP 1: Check SteamCMD
# =============================================================================
Write-Info "Checking for SteamCMD..."

$SteamCMD = Get-Command steamcmd -ErrorAction SilentlyContinue
if (-not $SteamCMD -and -not $SkipServerDownload) {
    Write-Warn "SteamCMD not found in PATH."
    Write-Info "Please install SteamCMD from: https://developer.valvesoftware.com/wiki/SteamCMD"
    Write-Info "Or add steamcmd.exe to your PATH environment variable."
    Write-Info ""
    Write-Info "Alternatively, run with -SkipServerDownload if you already have server files."
    exit 1
}

# =============================================================================
# STEP 2: Download/Update Server Files
# =============================================================================
if (-not $SkipServerDownload) {
    Write-Info "Downloading/Updating V Rising Dedicated Server..."
    Write-Info "App ID: 1829350"
    
    # Create parent directory if needed
    $ParentPath = Split-Path $ServerPath -Parent
    if (-not (Test-Path $ParentPath)) {
        New-Item -ItemType Directory -Path $ParentPath -Force | Out-Null
    }
    
    # Run SteamCMD
    try {
        $SteamCMDPath = "steamcmd"
        & $SteamCMDPath +force_install_dir "$ServerPath" +login anonymous +app_update 1829350 validate +quit
        
        if ($LASTEXITCODE -ne 0) {
            Write-Err "SteamCMD exited with code $LASTEXITCODE"
            exit 1
        }
        Write-Success "Server files downloaded/updated."
    }
    catch {
        Write-Err "Failed to run SteamCMD: $_"
        exit 1
    }
}
else {
    Write-Info "Skipping server download (using existing files at $ServerPath)"
}

# Verify server exists
if (-not (Test-Path "$ServerPath\VRisingServer.exe")) {
    Write-Err "VRisingServer.exe not found at: $ServerPath"
    Write-Err "Please ensure the server is properly installed."
    exit 1
}
Write-Success "Server files verified."

# =============================================================================
# STEP 3: Download and Install BepInEx
# =============================================================================
if (-not $SkipBepInEx) {
    Write-Info "Checking for BepInEx..."
    
    $BepInExPath = "$ServerPath\BepInEx"
    $DoorstopConfig = "$ServerPath\doorstop_config.ini"
    $WinHttpDll = "$ServerPath\winhttp.dll"
    
    if ((Test-Path $BepInExPath) -and -not $Force) {
        Write-Info "BepInEx folder already exists. Use -Force to reinstall."
    }
    else {
        Write-Info "Downloading BepInEx (Unity IL2CPP x64)..."
        
        # Get latest release URL from GitHub API
        try {
            $Releases = Invoke-RestMethod -Uri "https://api.github.com/repos/BepInEx/BepInEx/releases" -Headers @{ "User-Agent" = "PowerShell" }
            
            # Find latest IL2CPP x64 build
            $LatestAsset = $null
            foreach ($Release in $Releases) {
                $Asset = $Release.assets | Where-Object { $_.name -match "BepInEx.*IL2CPP.*x64.*\.zip$" } | Select-Object -First 1
                if ($Asset) {
                    $LatestAsset = $Asset
                    $ReleaseName = $Release.name
                    break
                }
            }
            
            if (-not $LatestAsset) {
                Write-Err "Could not find BepInEx IL2CPP x64 release."
                Write-Info "Please download manually from: https://github.com/BepInEx/BepInEx/releases"
                exit 1
            }
            
            Write-Info "Found: $($LatestAsset.name) from release $ReleaseName"
            
            # Download
            $TempZip = "$env:TEMP\bepinex.zip"
            Invoke-WebRequest -Uri $LatestAsset.browser_download_url -OutFile $TempZip
            
            # Extract
            Write-Info "Extracting BepInEx..."
            if (Test-Path $BepInExPath) {
                Remove-Item $BepInExPath -Recurse -Force
            }
            Expand-Archive -Path $TempZip -DestinationPath $ServerPath -Force
            
            # Cleanup
            Remove-Item $TempZip -Force
            
            Write-Success "BepInEx installed successfully."
        }
        catch {
            Write-Err "Failed to download/install BepInEx: $_"
            Write-Info "Please download manually from: https://github.com/BepInEx/BepInEx/releases"
            exit 1
        }
    }
    
    # Verify BepInEx installation
    if (-not (Test-Path $DoorstopConfig) -or -not (Test-Path $WinHttpDll)) {
        Write-Err "BepInEx installation incomplete. Missing doorstep files."
        exit 1
    }
    Write-Success "BepInEx installation verified."
}
else {
    Write-Info "Skipping BepInEx installation."
}

# =============================================================================
# STEP 4: Generate Interop Files
# =============================================================================
Write-Host ""
Write-Info "================================================================"
Write-Info "  INTEROP FILE GENERATION"
Write-Info "================================================================"
Write-Host ""

$InteropPath = "$ServerPath\BepInEx\interop"
$UnityLibsPath = "$ServerPath\BepInEx\unity-libs"

$InteropExists = (Test-Path $InteropPath) -and ((Get-ChildItem $InteropPath -Filter "*.dll" -ErrorAction SilentlyContinue).Count -gt 50)
$UnityLibsExists = (Test-Path $UnityLibsPath) -and ((Get-ChildItem $UnityLibsPath -Filter "*.dll" -ErrorAction SilentlyContinue).Count -gt 0)

if ($InteropExists -and $UnityLibsExists -and -not $Force) {
    Write-Success "Interop files already exist. Skipping generation."
    Write-Info "Use -Force to regenerate."
}
else {
    Write-Info "Interop files need to be generated."
    Write-Host ""
    Write-Host "  The server will now start to generate BepInEx interop files." -ForegroundColor Yellow
    Write-Host "  This process takes 2-5 minutes." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  INSTRUCTIONS:" -ForegroundColor Cyan
    Write-Host "  1. Wait for the server to fully start (you'll see 'Server Started')" -ForegroundColor White
    Write-Host "  2. Once started, press Ctrl+C to stop the server" -ForegroundColor White
    Write-Host "  3. This script will then verify and package the files" -ForegroundColor White
    Write-Host ""
    Read-Host "Press ENTER to start the server..."
    
    # Store current location
    Push-Location $ServerPath
    
    try {
        # Run server
        & .\VRisingServer.exe -persistentDataPath "$ServerPath\temp-data" -saveName "temp" -batchmode -nographics
    }
    catch {
        Write-Warn "Server process ended (this is expected after Ctrl+C)"
    }
    finally {
        Pop-Location
    }
    
    Write-Host ""
    
    # Verify generation
    $InteropCount = (Get-ChildItem "$ServerPath\BepInEx\interop" -Filter "*.dll" -ErrorAction SilentlyContinue).Count
    $UnityLibsCount = (Get-ChildItem "$ServerPath\BepInEx\unity-libs" -Filter "*.dll" -ErrorAction SilentlyContinue).Count
    
    if ($InteropCount -gt 50 -and $UnityLibsCount -gt 0) {
        Write-Success "Interop generation successful!"
        Write-Info "  - interop/: $InteropCount DLLs"
        Write-Info "  - unity-libs/: $UnityLibsCount DLLs"
    }
    else {
        Write-Err "Interop generation may have failed."
        Write-Info "  - interop/: $InteropCount DLLs (expected >50)"
        Write-Info "  - unity-libs/: $UnityLibsCount DLLs (expected >0)"
        Write-Warn "Check BepInEx/LogOutput.log for errors."
        Read-Host "Press ENTER to continue anyway, or Ctrl+C to abort..."
    }
    
    # Cleanup temp data
    if (Test-Path "$ServerPath\temp-data") {
        Remove-Item "$ServerPath\temp-data" -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# =============================================================================
# STEP 5: Create Transfer Package
# =============================================================================
Write-Host ""
Write-Info "================================================================"
Write-Info "  CREATING TRANSFER PACKAGE"
Write-Info "================================================================"
Write-Host ""

# Create output directory
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

# Option A: Full server package
$FullPackagePath = "$OutputPath\vrising-server-full.zip"
Write-Info "Creating full server package..."
Write-Info "This may take a few minutes..."

try {
    # Exclude unnecessary files to reduce size
    $ExcludePatterns = @(
        "$ServerPath\temp-data",
        "$ServerPath\*.log"
    )
    
    Compress-Archive -Path "$ServerPath\*" -DestinationPath $FullPackagePath -Force
    $FullSize = (Get-Item $FullPackagePath).Length / 1MB
    Write-Success "Full package created: $FullPackagePath ($([math]::Round($FullSize, 2)) MB)"
}
catch {
    Write-Err "Failed to create full package: $_"
}

# Option B: BepInEx-only package (smaller, for updates)
$BepInExPackagePath = "$OutputPath\vrising-bepinex-only.zip"
Write-Info "Creating BepInEx-only package..."

try {
    $BepInExFiles = @(
        "$ServerPath\BepInEx",
        "$ServerPath\doorstop_config.ini",
        "$ServerPath\winhttp.dll"
    )
    
    Compress-Archive -Path $BepInExFiles -DestinationPath $BepInExPackagePath -Force
    $BepSize = (Get-Item $BepInExPackagePath).Length / 1MB
    Write-Success "BepInEx package created: $BepInExPackagePath ($([math]::Round($BepSize, 2)) MB)"
}
catch {
    Write-Err "Failed to create BepInEx package: $_"
}

# =============================================================================
# SUMMARY
# =============================================================================
Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host "  PREPARATION COMPLETE" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Transfer packages created at:" -ForegroundColor Cyan
Write-Host "  - Full server: $FullPackagePath" -ForegroundColor White
Write-Host "  - BepInEx only: $BepInExPackagePath" -ForegroundColor White
Write-Host ""
Write-Host "NEXT STEPS:" -ForegroundColor Yellow
Write-Host "  1. Transfer the appropriate package to your ARM64 server" -ForegroundColor White
Write-Host "  2. Extract to /data/server/ in the Docker container" -ForegroundColor White
Write-Host "  3. Restart the container" -ForegroundColor White
Write-Host ""
Write-Host "For full server transfer:" -ForegroundColor Cyan
Write-Host "  scp $FullPackagePath user@server:~/" -ForegroundColor Gray
Write-Host "  docker compose exec vrising unzip ~/vrising-server-full.zip -d /data/server/" -ForegroundColor Gray
Write-Host ""
Write-Host "For BepInEx update only:" -ForegroundColor Cyan  
Write-Host "  scp $BepInExPackagePath user@server:~/" -ForegroundColor Gray
Write-Host "  docker compose exec vrising unzip -o ~/vrising-bepinex-only.zip -d /data/server/" -ForegroundColor Gray
Write-Host ""

# Open output folder
$OpenFolder = Read-Host "Open output folder? (Y/N)"
if ($OpenFolder -eq "Y" -or $OpenFolder -eq "y") {
    Start-Process "explorer.exe" -ArgumentList $OutputPath
}

Write-Host "Done!" -ForegroundColor Green
