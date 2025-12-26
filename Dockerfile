# =============================================================================
# V Rising Dedicated Server - ARM64 Docker Image
# =============================================================================
# Architecture: Multi-stage build for optimized image size
# Emulation Stack: Box64 (x86_64 -> ARM64) + Wine (Win32 API -> POSIX)
# Target Platform: ARM64 hosts (Ampere Altra, Apple Silicon, RK3588, etc.)
# =============================================================================

# -----------------------------------------------------------------------------
# STAGE 1: Box64 Builder
# Purpose: Compile Box64 emulator from source with ARM64 DYNAREC optimizations
# Why from source: Pre-built binaries may not be optimized for specific ARM cores
# -----------------------------------------------------------------------------
FROM debian:bookworm-slim AS box64_builder

# Prevent apt from prompting for user input during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install build dependencies
# - git: Clone Box64 repository
# - cmake: Box64 uses CMake build system
# - build-essential: GCC, make, and other compilation tools
# - python3: Required by Box64's configuration scripts
# - ca-certificates: HTTPS certificate validation for git clone
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    cmake \
    python3 \
    build-essential \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

# Clone and build Box64 with performance optimizations
# Key CMake flags:
# -DARM_DYNAREC=ON: Enable dynamic recompiler (CRITICAL for performance)
# -DCMAKE_BUILD_TYPE=RelWithDebInfo: Release performance with debug symbols
#                                    for crash analysis if needed
# Note: Make sure the git clone has proper spacing before the period
RUN git clone https://github.com/ptitSeb/box64.git . && \
    mkdir build && cd build && \
    cmake .. \
    -DARM_DYNAREC=ON \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo && \
    make -j$(nproc) && \
    make install DESTDIR=/tmp/box64-install && \
    # Debug: Show what was installed
    echo "=== Box64 installation contents ===" && \
    find /tmp/box64-install -type f && \
    echo "==================================="

# -----------------------------------------------------------------------------
# STAGE 2: Runtime Environment
# Purpose: Production image with Wine, display server, and management scripts
# Base: Debian Bookworm Slim for optimal stability/size balance
# -----------------------------------------------------------------------------
FROM debian:bookworm-slim

LABEL maintainer="VRising ARM64 Project"
LABEL description="V Rising Dedicated Server for ARM64 with Box64/Wine/BepInEx support"
LABEL version="1.0.0"

# =============================================================================
# ENVIRONMENT CONFIGURATION
# =============================================================================
# These variables can be overridden at runtime via docker-compose or Easypanel

ENV DEBIAN_FRONTEND=noninteractive \
    # User/Group IDs for volume permission management
    PUID=1000 \
    PGID=1000 \
    # ---------------------------------------------------------------------
    # Wine Configuration
    # ---------------------------------------------------------------------
    # Location of Wine prefix (isolated Windows environment)
    WINEPREFIX=/data/wineprefix \
    # Force 64-bit only Wine prefix (simplifies compatibility)
    WINEARCH=win64 \
    # Suppress Wine debug output (reduce log noise)
    WINEDEBUG=-all \
    # ---------------------------------------------------------------------
    # Box64 Performance Tuning
    # These are CRITICAL for Unity/IL2CPP game stability
    # ---------------------------------------------------------------------
    # Force x86-style memory ordering (prevents race conditions in Unity threads)
    # Cost: ~5-10% performance reduction
    # Benefit: Prevents random crashes and state corruption
    BOX64_DYNAREC_STRONGMEM=1 \
    # Enable larger translation blocks for better CPU throughput
    BOX64_DYNAREC_BIGBLOCK=1 \
    # Simplify NaN handling for floating-point operations (safe for games)
    BOX64_DYNAREC_FASTNAN=1 \
    # Optimize CPU flag handling in function calls
    BOX64_DYNAREC_SAFEFLAGS=1 \
    # Default log level (0=none, 1=info, 2=debug, 3=verbose)
    BOX64_LOG=1 \
    # ---------------------------------------------------------------------
    # System & Display Configuration
    # ---------------------------------------------------------------------
    # Virtual display for Unity's graphics subsystem initialization
    DISPLAY=:0 \
    # Server installation directory (inside container)
    INSTALL_DIR=/data/server \
    # Disable glibc memory corruption checks (false positives with Box64)
    MALLOC_CHECK_=0 \
    # Memory allocation tuning for Unity
    MALLOC_MMAP_THRESHOLD_=131072 \
    # Wine x86_64 paths (for Box64 to find wine binaries)
    PATH="/opt/wine/bin:/usr/local/bin:/usr/bin:/bin" \
    LD_LIBRARY_PATH="/opt/wine/lib" \
    # ---------------------------------------------------------------------
    # V Rising Server Settings (can be overridden)
    # ---------------------------------------------------------------------
    SERVER_NAME="V Rising Docker ARM64" \
    SAVE_NAME="world_main"

# =============================================================================
# PACKAGE INSTALLATION
# =============================================================================
# Install runtime dependencies in a single layer to minimize image size
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Basic utilities
    wget \
    curl \
    unzip \
    tar \
    xz-utils \
    ca-certificates \
    # Virtual display server (Unity requires a display context)
    xvfb \
    # Wine dependencies (x86_64 Wine running under Box64 needs these)
    cabextract \
    libgl1 \
    libx11-6 \
    libfreetype6 \
    libfontconfig1 \
    libxext6 \
    libxrender1 \
    libxcomposite1 \
    libxcursor1 \
    libxi6 \
    libxrandr2 \
    libxfixes3 \
    libxxf86vm1 \
    libasound2 \
    libpulse0 \
    libdbus-1-3 \
    libgnutls30 \
    # Process management
    gosu \
    procps \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

# =============================================================================
# WINE x86_64 INSTALLATION (for Box64)
# =============================================================================
# IMPORTANT: We need x86_64 Wine binaries, NOT ARM64 native Wine!
# Box64 will emulate these x86_64 binaries on ARM64 hardware.
# Using Wine from Kron4ek's portable builds (widely used for Box64)
ENV WINE_VERSION="9.22"
ENV WINE_BRANCH="staging"

RUN mkdir -p /opt/wine && \
    cd /opt/wine && \
    # Download Wine x86_64 portable build
    wget -q "https://github.com/Kron4ek/Wine-Builds/releases/download/${WINE_VERSION}/wine-${WINE_VERSION}-${WINE_BRANCH}-amd64.tar.xz" -O wine.tar.xz && \
    tar -xf wine.tar.xz --strip-components=1 && \
    rm wine.tar.xz && \
    # Create symlinks to make wine accessible
    ln -sf /opt/wine/bin/wine64 /usr/local/bin/wine64 && \
    ln -sf /opt/wine/bin/wine /usr/local/bin/wine && \
    ln -sf /opt/wine/bin/wineserver /usr/local/bin/wineserver && \
    ln -sf /opt/wine/bin/wineboot /usr/local/bin/wineboot && \
    ln -sf /opt/wine/bin/winecfg /usr/local/bin/winecfg && \
    # Verify installation
    echo "Wine x86_64 installed at /opt/wine"

# =============================================================================
# BOX64 INSTALLATION
# =============================================================================
# Copy compiled Box64 from builder stage
# Note: Box64 is a self-contained binary, no separate libraries needed
COPY --from=box64_builder /tmp/box64-install/usr/local/bin/box64 /usr/local/bin/box64

# Copy x86_64 library wrappers if they were built (optional)
# These help Box64 intercept and wrap library calls
# Using wildcard pattern to handle varying installation paths
RUN mkdir -p /usr/lib/box64-x86_64-linux-gnu

# Create binfmt configuration for automatic x86_64 binary handling
# This allows running .exe files directly without prefixing with 'box64'
RUN mkdir -p /etc/binfmt.d && \
    echo ':box64:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00:\xff\xff\xff\xff\xff\xfe\xfe\x00\x00\x00\x00\x00\x00\x00\x00\x00\xfe\x00\xff\x00:/usr/local/bin/box64:CF' > /etc/binfmt.d/box64.conf

# =============================================================================
# USER AND DIRECTORY SETUP
# =============================================================================
# Create non-root user for security (never run game servers as root)
# The PUID/PGID can be adjusted via environment variables to match host user
RUN mkdir -p ${WINEPREFIX} ${INSTALL_DIR} /data/save-data /data/logs && \
    groupadd -g ${PGID} vrising && \
    useradd -u ${PUID} -g ${PGID} -d /data -s /bin/bash vrising && \
    chown -R vrising:vrising /data

# =============================================================================
# SCRIPT INSTALLATION
# =============================================================================
# Copy startup script and make executable
COPY start.sh /start.sh
RUN chmod +x /start.sh

# Copy health check script
COPY healthcheck.sh /healthcheck.sh
RUN chmod +x /healthcheck.sh

# =============================================================================
# NETWORK CONFIGURATION
# =============================================================================
# V Rising uses UDP for game traffic
# 9876: Main game port (player connections)
# 9877: Steam query port (server browser visibility)
EXPOSE 9876/udp 9877/udp

# =============================================================================
# DATA PERSISTENCE
# =============================================================================
# All persistent data is stored in /data:
# /data/server     - Game server files
# /data/wineprefix - Wine configuration
# /data/save-data  - World saves
# /data/logs       - Server logs
VOLUME ["/data"]

# =============================================================================
# CONTAINER HEALTH CHECK
# =============================================================================
# Check if the server process is still running
HEALTHCHECK --interval=60s --timeout=10s --start-period=120s --retries=3 \
    CMD pgrep -f "VRisingServer" > /dev/null || exit 1

# =============================================================================
# ENTRYPOINT
# =============================================================================
ENTRYPOINT ["/start.sh"]
