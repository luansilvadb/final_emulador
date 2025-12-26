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
    make install DESTDIR=/tmp/box64-install

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
    # ---------------------------------------------------------------------
    # V Rising Server Settings (can be overridden)
    # ---------------------------------------------------------------------
    SERVER_NAME="V Rising Docker ARM64" \
    SAVE_NAME="world_main"

# =============================================================================
# PACKAGE INSTALLATION
# =============================================================================
# Add armhf (32-bit ARM) architecture for potential future compatibility needs
# Install runtime dependencies in a single layer to minimize image size
RUN dpkg --add-architecture armhf && \
    apt-get update && apt-get install -y --no-install-recommends \
    # Basic utilities
    wget \
    curl \
    unzip \
    tar \
    xz-utils \
    ca-certificates \
    # Virtual display server (Unity requires a display context)
    xvfb \
    # Wine dependencies
    cabextract \
    libgl1 \
    libx11-6 \
    libfreetype6 \
    libfontconfig1 \
    libxext6 \
    libxrender1 \
    # Process management
    gosu \
    procps \
    # Wine packages from Debian repositories
    # Note: For bleeding-edge Wine, consider WineHQ staging builds
    wine \
    wine64 \
    libwine \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

# =============================================================================
# BOX64 INSTALLATION
# =============================================================================
# Copy compiled Box64 from builder stage
COPY --from=box64_builder /tmp/box64-install/usr/local/bin/box64 /usr/local/bin/box64
COPY --from=box64_builder /tmp/box64-install/usr/local/lib/box64 /usr/local/lib/box64

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
