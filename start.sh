#!/bin/bash
# =============================================================================
# V Rising Dedicated Server - Startup Script (ARM64/Box64/Wine)
# =============================================================================
# This script manages the complete server lifecycle:
# 1. Permission correction for mounted volumes
# 2. Wine prefix initialization
# 3. BepInEx integration and validation
# 4. Workarounds for known Unity/Wine compatibility issues
# 5. Virtual display setup (Xvfb)
# 6. Server process management with graceful shutdown
# =============================================================================

set -e  # Exit on error
set -o pipefail  # Pipe failures propagate

# =============================================================================
# LOGGING UTILITIES
# =============================================================================
# Color codes for readable console output (visible in Easypanel/Docker logs)
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'  # No Color

# Logging functions with timestamps and prefixes
log_info() {
    echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*"
}

log_debug() {
    if [[ "${DEBUG:-0}" == "1" ]]; then
        echo -e "${CYAN}[DEBUG]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*"
    fi
}

log_section() {
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  $*${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# =============================================================================
# STARTUP BANNER
# =============================================================================
log_section "V Rising Dedicated Server (ARM64/Box64)"
log_info "Starting initialization sequence..."
log_info "Container Time: $(date)"
log_info "Wine Prefix: ${WINEPREFIX}"
log_info "Install Directory: ${INSTALL_DIR}"

# =============================================================================
# SECTION 1: PERMISSION HANDLING
# =============================================================================
# Easypanel and Docker may mount volumes as root, which prevents the vrising
# user from accessing files. This section fixes ownership and drops privileges.
log_section "Permission Management"

if [ "$(id -u)" = '0' ]; then
    log_info "Running as root - adjusting permissions..."
    
    # Ensure target directories exist
    mkdir -p "${WINEPREFIX}" "${INSTALL_DIR}" /data/save-data /data/logs
    
    # Recursively change ownership of /data to vrising user
    log_info "Setting ownership of /data to vrising:vrising (PUID=${PUID}, PGID=${PGID})..."
    chown -R vrising:vrising /data
    
    # Also ensure vrising owns its home directory
    chown vrising:vrising /data
    
    log_info "Permissions adjusted. Dropping privileges to user 'vrising'..."
    
    # Re-execute this script as the vrising user
    # gosu is preferred over su/sudo for containers (no TTY required)
    exec gosu vrising "$0" "$@"
fi

# At this point, we're running as the vrising user
log_info "Running as user: $(whoami) (UID=$(id -u), GID=$(id -g))"

# =============================================================================
# SECTION 2: ENVIRONMENT VARIABLE VALIDATION
# =============================================================================
log_section "Environment Configuration"

# Set defaults for optional variables
SERVER_NAME="${SERVER_NAME:-V Rising Docker ARM64}"
SAVE_NAME="${SAVE_NAME:-world_main}"
GAME_PORT="${GAME_PORT:-9876}"
QUERY_PORT="${QUERY_PORT:-9877}"

log_info "Server Name: ${SERVER_NAME}"
log_info "Save Name: ${SAVE_NAME}"
log_info "Game Port: ${GAME_PORT}/udp"
log_info "Query Port: ${QUERY_PORT}/udp"
log_info "BOX64_DYNAREC_STRONGMEM: ${BOX64_DYNAREC_STRONGMEM:-not set}"
log_info "BOX64_DYNAREC_BIGBLOCK: ${BOX64_DYNAREC_BIGBLOCK:-not set}"
log_info "BOX64_LOG: ${BOX64_LOG:-0}"

# =============================================================================
# SECTION 3: WINE PREFIX INITIALIZATION
# =============================================================================
log_section "Wine Configuration"

# Check if Wine prefix exists and is properly initialized
# The system.reg file is a reliable indicator of a complete Wine prefix
if [ ! -f "${WINEPREFIX}/system.reg" ]; then
    log_info "Wine prefix not found. Initializing 64-bit prefix at ${WINEPREFIX}..."
    
    # wineboot -i: Initialize Wine prefix (creates registry, system folders)
    # Redirect output to prevent noise in container logs
    WINEARCH=win64 wineboot -i > /dev/null 2>&1 || {
        log_error "Wine prefix initialization failed!"
        exit 1
    }
    
    # Wait for Wine server to stabilize before proceeding
    wineserver -w
    
    log_info "Wine prefix initialized successfully."
else
    log_info "Existing Wine prefix found at ${WINEPREFIX}"
fi

# Display Wine version for debugging purposes
WINE_VERSION=$(wine64 --version 2>/dev/null || echo "unknown")
log_info "Wine version: ${WINE_VERSION}"

# =============================================================================
# SECTION 4: SERVER FILES VALIDATION
# =============================================================================
log_section "Server Files Validation"

# Navigate to installation directory
cd "${INSTALL_DIR}" || {
    log_error "Cannot access install directory: ${INSTALL_DIR}"
    log_error "Please upload server files via SFTP or mount them as a volume."
    exit 1
}

# Check for the main server executable
if [ ! -f "VRisingServer.exe" ]; then
    log_error "VRisingServer.exe not found in ${INSTALL_DIR}"
    log_error ""
    log_error "═══════════════════════════════════════════════════════════════════"
    log_error " SERVER FILES MISSING - MANUAL UPLOAD REQUIRED"
    log_error "═══════════════════════════════════════════════════════════════════"
    log_error ""
    log_error " Due to limitations in ARM64 emulation, server files must be"
    log_error " uploaded manually. Please follow these steps:"
    log_error ""
    log_error " 1. On a Windows machine, use SteamCMD to download V Rising Server:"
    log_error "    steamcmd +login anonymous +app_update 1829350 validate +quit"
    log_error ""
    log_error " 2. Transfer the server files to: ${INSTALL_DIR}"
    log_error "    (Use SFTP, SCP, or your Easypanel file manager)"
    log_error ""
    log_error " 3. Restart this container."
    log_error ""
    log_error "═══════════════════════════════════════════════════════════════════"
    exit 1
fi

log_info "VRisingServer.exe found."

# =============================================================================
# SECTION 4.5: PRE-CONFIGURED MODS INSTALLATION
# =============================================================================
# This section handles automatic copying of pre-generated BepInEx files
# from the /mods-source volume (mounted from ./mods on host)
log_section "Pre-configured Mods Installation"

MODS_SOURCE="/mods-source"

if [ -d "${MODS_SOURCE}" ] && [ -n "$(ls -A ${MODS_SOURCE} 2>/dev/null)" ]; then
    log_info "Pre-configured mods source detected at ${MODS_SOURCE}"
    
    # -------------------------------------------------------------------------
    # Copy BepInEx folder if not already present
    # -------------------------------------------------------------------------
    if [ -d "${MODS_SOURCE}/BepInEx" ]; then
        if [ ! -d "${INSTALL_DIR}/BepInEx" ]; then
            log_info "Copying BepInEx folder from pre-configured source..."
            cp -r "${MODS_SOURCE}/BepInEx" "${INSTALL_DIR}/"
            log_info "BepInEx folder copied successfully."
        else
            # Check if interop is missing and copy only that
            if [ ! -d "${INSTALL_DIR}/BepInEx/interop" ] || [ -z "$(ls -A ${INSTALL_DIR}/BepInEx/interop 2>/dev/null)" ]; then
                log_info "BepInEx exists but interop is missing. Copying interop files..."
                cp -r "${MODS_SOURCE}/BepInEx/interop" "${INSTALL_DIR}/BepInEx/"
                log_info "Interop files copied."
            fi
            if [ ! -d "${INSTALL_DIR}/BepInEx/unity-libs" ] || [ -z "$(ls -A ${INSTALL_DIR}/BepInEx/unity-libs 2>/dev/null)" ]; then
                log_info "Copying unity-libs files..."
                cp -r "${MODS_SOURCE}/BepInEx/unity-libs" "${INSTALL_DIR}/BepInEx/"
                log_info "Unity-libs files copied."
            fi
            # Always sync plugins (allows easy mod updates)
            if [ -d "${MODS_SOURCE}/BepInEx/plugins" ] && [ -n "$(ls -A ${MODS_SOURCE}/BepInEx/plugins 2>/dev/null)" ]; then
                log_info "Syncing plugins from pre-configured source..."
                cp -r "${MODS_SOURCE}/BepInEx/plugins/"* "${INSTALL_DIR}/BepInEx/plugins/" 2>/dev/null || true
                log_info "Plugins synced."
            fi
        fi
    fi
    
    # -------------------------------------------------------------------------
    # Copy doorstop files (winhttp.dll and doorstop_config.ini)
    # -------------------------------------------------------------------------
    if [ -f "${MODS_SOURCE}/winhttp.dll" ] && [ ! -f "${INSTALL_DIR}/winhttp.dll" ]; then
        log_info "Copying winhttp.dll (BepInEx doorstop)..."
        cp "${MODS_SOURCE}/winhttp.dll" "${INSTALL_DIR}/"
    fi
    
    if [ -f "${MODS_SOURCE}/doorstop_config.ini" ] && [ ! -f "${INSTALL_DIR}/doorstop_config.ini" ]; then
        log_info "Copying doorstop_config.ini..."
        cp "${MODS_SOURCE}/doorstop_config.ini" "${INSTALL_DIR}/"
    fi
    
    # -------------------------------------------------------------------------
    # Copy .NET runtime if present (required for BepInEx IL2CPP)
    # -------------------------------------------------------------------------
    if [ -d "${MODS_SOURCE}/dotnet" ] && [ ! -d "${INSTALL_DIR}/dotnet" ]; then
        log_info "Copying .NET runtime..."
        cp -r "${MODS_SOURCE}/dotnet" "${INSTALL_DIR}/"
        log_info ".NET runtime copied."
    fi
    
    log_info "Pre-configured mods installation complete."
else
    log_info "No pre-configured mods found at ${MODS_SOURCE}."
    log_info "To use pre-configured BepInEx, mount the mods folder to /mods-source"
fi

# =============================================================================
# SECTION 5: BEPINEX INTEGRATION
# =============================================================================
log_section "BepInEx Modding Framework"

BEPINEX_ENABLED=false
BEPINEX_DIR="${INSTALL_DIR}/BepInEx"

if [ -d "${BEPINEX_DIR}" ]; then
    log_info "BepInEx directory detected."
    
    # -------------------------------------------------------------------------
    # CRITICAL VALIDATION: Interoperability Assemblies
    # -------------------------------------------------------------------------
    # The BepInEx Il2CppInterop generates these assemblies at first run.
    # However, this generation FAILS under ARM64 emulation due to:
    # - Race conditions in the multithreaded assembly generator
    # - JIT compilation issues with Box64
    # 
    # SOLUTION: Generate these files on Windows first, then copy to ARM64
    # -------------------------------------------------------------------------
    INTEROP_DIR="${BEPINEX_DIR}/interop"
    UNITY_LIBS_DIR="${BEPINEX_DIR}/unity-libs"
    
    INTEROP_VALID=true
    
    # Check for interop directory
    if [ ! -d "${INTEROP_DIR}" ]; then
        log_warn "BepInEx/interop directory is MISSING!"
        INTEROP_VALID=false
    elif [ -z "$(ls -A ${INTEROP_DIR} 2>/dev/null)" ]; then
        log_warn "BepInEx/interop directory is EMPTY!"
        INTEROP_VALID=false
    fi
    
    # Check for unity-libs directory
    if [ ! -d "${UNITY_LIBS_DIR}" ]; then
        log_warn "BepInEx/unity-libs directory is MISSING!"
        INTEROP_VALID=false
    elif [ -z "$(ls -A ${UNITY_LIBS_DIR} 2>/dev/null)" ]; then
        log_warn "BepInEx/unity-libs directory is EMPTY!"
        INTEROP_VALID=false
    fi
    
    if [ "${INTEROP_VALID}" = false ]; then
        log_error ""
        log_error "═══════════════════════════════════════════════════════════════════"
        log_error " CRITICAL: BEPINEX INTEROP FILES MISSING"
        log_error "═══════════════════════════════════════════════════════════════════"
        log_error ""
        log_error " BepInEx cannot generate interoperability assemblies on ARM64"
        log_error " due to emulation limitations. You MUST pre-generate these"
        log_error " files on a native Windows x86_64 system."
        log_error ""
        log_error " REQUIRED STEPS:"
        log_error " 1. Install server + BepInEx on Windows"
        log_error " 2. Run server ONCE (generates interop files)"
        log_error " 3. Copy BepInEx/interop/ and BepInEx/unity-libs/ to ARM64"
        log_error ""
        log_error " See docs/BEPINEX_SETUP.md for detailed instructions."
        log_error ""
        log_error " The server will attempt to start WITHOUT mods."
        log_error "═══════════════════════════════════════════════════════════════════"
        log_error ""
        
        # Don't abort - let user troubleshoot, but warn about likely failure
        BEPINEX_ENABLED=false
    else
        log_info "BepInEx interop files validated successfully."
        BEPINEX_ENABLED=true
    fi
    
    # -------------------------------------------------------------------------
    # Configure Wine DLL Override for BepInEx
    # -------------------------------------------------------------------------
    # BepInEx uses a technique called "Unity Doorstop" which replaces
    # winhttp.dll to inject itself at process startup.
    # Wine must be configured to load the local version, not the built-in.
    #
    # winhttp=n,b means:
    #   n = native (load from application directory first)
    #   b = builtin (fallback to Wine's implementation)
    # -------------------------------------------------------------------------
    if [ "${BEPINEX_ENABLED}" = true ]; then
        export WINEDLLOVERRIDES="winhttp=n,b"
        log_info "Wine DLL overrides configured: WINEDLLOVERRIDES=${WINEDLLOVERRIDES}"
    fi
    
else
    log_info "BepInEx not installed. Running in Vanilla mode."
    log_info "To enable mods, install BepInEx with pre-generated interop files."
fi

# =============================================================================
# SECTION 6: UNITY BURST COMPILER WORKAROUND
# =============================================================================
log_section "Unity Compatibility Fixes"

# -------------------------------------------------------------------------
# lib_burst_generated.dll Issue
# -------------------------------------------------------------------------
# Unity's Burst Compiler generates native code at build time for performance.
# This DLL contains x86-64 assembly optimized code that often causes
# Access Violations or SIGILL when executed under Wine/Box64.
#
# Removing it forces Unity to use fallback managed code paths, which is
# slightly slower but stable under emulation.
# -------------------------------------------------------------------------
BURST_DLL="${INSTALL_DIR}/VRisingServer_Data/Plugins/x86_64/lib_burst_generated.dll"

if [ -f "${BURST_DLL}" ]; then
    log_warn "lib_burst_generated.dll detected - this causes crashes under emulation."
    log_info "Moving to backup: ${BURST_DLL}.disabled"
    mv "${BURST_DLL}" "${BURST_DLL}.disabled" || log_warn "Could not move Burst DLL (may already be moved)"
fi

# Also check for older backup format
if [ -f "${BURST_DLL}.bak" ]; then
    log_debug "Burst DLL already backed up as .bak - renaming to .disabled"
    mv "${BURST_DLL}.bak" "${BURST_DLL}.disabled" 2>/dev/null || true
fi

# =============================================================================
# SECTION 7: VIRTUAL DISPLAY (Xvfb)
# =============================================================================
log_section "Virtual Display Configuration"

# -------------------------------------------------------------------------
# Unity Graphics Subsystem Requirement
# -------------------------------------------------------------------------
# Even in "headless" mode, Unity often initializes parts of its graphics
# system and expects a valid X11 display. Without Xvfb, the server may
# crash with "Failed to create OpenGL context" or similar errors.
# -------------------------------------------------------------------------

# Clean up any stale X lock files from previous container runs
if [ -f /tmp/.X0-lock ]; then
    log_info "Removing stale X lock file..."
    rm -f /tmp/.X0-lock
fi

# Start Xvfb (X Virtual Framebuffer) in the background
# Screen configuration: 1024x768 with 16-bit color depth
log_info "Starting Xvfb virtual display server..."
Xvfb :0 -screen 0 1024x768x16 &
XVFB_PID=$!

# Wait for Xvfb to initialize
sleep 2

# Verify Xvfb is running
if ! kill -0 ${XVFB_PID} 2>/dev/null; then
    log_error "Xvfb failed to start. The server may not run correctly."
else
    log_info "Xvfb started successfully (PID: ${XVFB_PID})"
fi

# Export display variable (should already be set in Dockerfile ENV)
export DISPLAY=:0

# =============================================================================
# SECTION 8: SERVER LAUNCH
# =============================================================================
log_section "Launching V Rising Server"

log_info "Working directory: $(pwd)"
log_info "Server executable: VRisingServer.exe"
log_info "BepInEx: $([ ${BEPINEX_ENABLED} = true ] && echo 'ENABLED' || echo 'DISABLED')"
log_info ""
log_info "Starting server process..."
log_info ""

# Build command line arguments
SERVER_ARGS=(
    -persistentDataPath "/data/save-data"
    -serverName "${SERVER_NAME}"
    -saveName "${SAVE_NAME}"
    -logFile "/data/logs/VRisingServer.log"
    -batchmode
    -nographics
)

# Add port configuration if available in newer server versions
# (Uncomment if your server version supports these flags)
# SERVER_ARGS+=(-gamePort "${GAME_PORT}")
# SERVER_ARGS+=(-queryPort "${QUERY_PORT}")

# Launch the server via Box64 -> Wine -> VRisingServer.exe
# Redirect stderr to stdout for unified logging
box64 wine64 ./VRisingServer.exe "${SERVER_ARGS[@]}" 2>&1 &
SERVER_PID=$!

log_info "Server process started with PID: ${SERVER_PID}"

# =============================================================================
# SECTION 9: SIGNAL HANDLING & GRACEFUL SHUTDOWN
# =============================================================================
# -------------------------------------------------------------------------
# Docker sends SIGTERM when stopping a container.
# We intercept this to gracefully shutdown the game server.
# -------------------------------------------------------------------------

cleanup() {
    log_section "Shutdown Sequence Initiated"
    
    log_info "Sending SIGTERM to server process (PID: ${SERVER_PID})..."
    kill -SIGTERM ${SERVER_PID} 2>/dev/null || true
    
    # Give the server time to save world data
    log_info "Waiting for server to save and exit (max 30 seconds)..."
    
    local wait_count=0
    while kill -0 ${SERVER_PID} 2>/dev/null && [ ${wait_count} -lt 30 ]; do
        sleep 1
        wait_count=$((wait_count + 1))
    done
    
    if kill -0 ${SERVER_PID} 2>/dev/null; then
        log_warn "Server did not respond to SIGTERM. Sending SIGKILL..."
        kill -SIGKILL ${SERVER_PID} 2>/dev/null || true
    else
        log_info "Server exited gracefully."
    fi
    
    # Stop Xvfb
    log_info "Stopping Xvfb..."
    kill ${XVFB_PID} 2>/dev/null || true
    
    # Wait for Wine server to finish
    log_info "Waiting for Wine server to terminate..."
    wineserver -w 2>/dev/null || true
    
    log_info "Shutdown complete."
    exit 0
}

# Register signal handlers
trap cleanup SIGTERM SIGINT SIGHUP

# =============================================================================
# SECTION 10: PROCESS MONITORING
# =============================================================================
log_info "Server is running. Monitoring process..."
log_info "Use 'docker logs -f <container>' to view server output."
log_info ""

# Wait for the server process
# This keeps the container running and allows signal handling
wait ${SERVER_PID}
EXIT_CODE=$?

log_section "Server Process Exited"
log_info "Exit code: ${EXIT_CODE}"

# Cleanup Xvfb on normal exit
kill ${XVFB_PID} 2>/dev/null || true

exit ${EXIT_CODE}
