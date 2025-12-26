# V Rising Dedicated Server - ARM64 Docker Solution

[![Docker](https://img.shields.io/badge/Docker-Compatible-blue?logo=docker)](https://www.docker.com/)
[![ARM64](https://img.shields.io/badge/Architecture-ARM64-green)](https://en.wikipedia.org/wiki/AArch64)
[![License](https://img.shields.io/badge/License-MIT-yellow)](LICENSE)

> **Production-ready V Rising dedicated server for ARM64 architecture using Box64/Wine emulation with full BepInEx modding support.**

## 📋 Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [BepInEx Modding Setup](#bepinex-modding-setup)
- [Configuration](#configuration)
- [Easypanel Deployment](#easypanel-deployment)
- [Troubleshooting](#troubleshooting)
- [Performance Tuning](#performance-tuning)
- [Contributing](#contributing)

## Overview

This project enables hosting V Rising dedicated servers on ARM64 hardware (Ampere Altra, Apple Silicon, Raspberry Pi 5, Orange Pi 5, AWS Graviton, etc.) through a carefully engineered emulation stack:

```
┌─────────────────────────────────────────────────────────────────┐
│                         Docker Container                         │
├─────────────────────────────────────────────────────────────────┤
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────────────┐  │
│  │ VRisingServer│───▶│    Wine     │───▶│       Box64         │  │
│  │    (x86)     │    │  (Win API)  │    │ (x86→ARM64 Dynarec) │  │
│  └─────────────┘    └─────────────┘    └──────────┬──────────┘  │
│                                                    │             │
│  ┌─────────────┐    ┌─────────────┐               │             │
│  │   BepInEx   │    │    Xvfb     │               ▼             │
│  │  (Modding)  │    │  (Display)  │        ARM64 Hardware       │
│  └─────────────┘    └─────────────┘                             │
└─────────────────────────────────────────────────────────────────┘
```

### Key Features

- ✅ **Full V Rising Server Support**: Host multiplayer matches on ARM64
- ✅ **BepInEx Integration**: Complete modding support with pre-generation workflow
- ✅ **Easypanel Ready**: Deploy via GUI with environment variable configuration
- ✅ **Production Optimized**: Box64 DYNAREC tuning for stability
- ✅ **Graceful Shutdown**: Proper world save on container stop
- ✅ **Comprehensive Logging**: Color-coded logs for easy debugging

## Architecture

### The Challenge

V Rising's dedicated server is a Windows x86-64 binary built with Unity's IL2CPP backend. Running this on ARM64 Linux requires:

1. **Binary Translation** (Box64): Converts x86-64 machine code to ARM64 in real-time
2. **API Translation** (Wine): Converts Windows API calls to Linux syscalls
3. **Display Emulation** (Xvfb): Provides a virtual display for Unity's graphics subsystem

### Why BepInEx Pre-Generation?

The BepInEx modding framework uses **Il2CppInterop** to generate .NET assemblies that mirror the game's internal classes. This generation:

- Spawns multiple threads for parallel processing
- Uses JIT compilation extensively
- Performs intensive file I/O

Under ARM64 emulation, this process **consistently fails** due to:
- Race conditions (Box64's threading model differs from native x86)
- JIT translation edge cases
- Memory model mismatches (ARM64 has a weaker memory model)

**Solution**: Generate interop files on native Windows, then transfer to ARM64.

## Prerequisites

### Hardware Requirements

| Component | Minimum | Recommended |
|-----------|---------|-------------|
| CPU | 4 ARM64 cores | 6+ cores |
| RAM | 6 GB | 8-12 GB |
| Storage | 10 GB | 20 GB SSD |
| Network | 10 Mbps | 50+ Mbps |

### Software Requirements

- Docker Engine 20.10+ with BuildKit
- Docker Compose V2
- (For BepInEx) Windows machine for pre-generation

## Quick Start

### 1. Clone the Repository

```bash
git clone https://github.com/your-org/vrising-arm64.git
cd vrising-arm64
```

### 2. Configure Environment

```bash
cp .env.example .env
# Edit .env with your preferred settings
```

### 3. Build the Docker Image

```bash
docker compose build
```

### 4. Start the Container (First Run)

```bash
docker compose up -d
```

The first run will **fail** because server files are not present. This is expected.

### 5. Upload Server Files

On a Windows machine:

```powershell
# Download V Rising Dedicated Server via SteamCMD
steamcmd +login anonymous +app_update 1829350 validate +quit
```

Transfer the server files (from `steamapps/common/VRisingDedicatedServer/`) to the container's `/data/server` directory:

```bash
# Using docker cp
docker cp ./VRisingDedicatedServer/. vrising-server:/data/server/

# Or via SFTP if using Easypanel
```

### 6. Restart the Container

```bash
docker compose restart
```

### 7. Monitor Logs

```bash
docker compose logs -f
```

## BepInEx Modding Setup

> ⚠️ **CRITICAL**: BepInEx interop files MUST be generated on Windows before deploying to ARM64.

### Step-by-Step Guide

See **[docs/BEPINEX_SETUP.md](docs/BEPINEX_SETUP.md)** for detailed instructions.

### Quick Summary

1. **On Windows**: Install server + BepInEx
2. **On Windows**: Run server once (generates interop)
3. **Copy to `mods/` folder**: Place these files in the local `mods/` directory:
   - `BepInEx/` (entire folder with interop, unity-libs, plugins)
   - `doorstop_config.ini`
   - `winhttp.dll`
   - `dotnet/` (.NET runtime folder)
4. **Restart container**: Files are copied automatically!

### Automatic Mods Installation (NEW!)

This project includes **automatic BepInEx installation** from the `mods/` folder:

```
vrising-arm64/
├── mods/                          ← Place your Windows-generated files here
│   ├── BepInEx/
│   │   ├── interop/               ← Pre-generated DLLs (172+ files)
│   │   ├── unity-libs/            ← Unity libraries (66 files)
│   │   ├── plugins/               ← Your mod DLLs
│   │   ├── core/                  ← BepInEx core
│   │   └── config/                ← Mod configurations
│   ├── dotnet/                    ← .NET runtime
│   ├── winhttp.dll                ← Doorstop proxy
│   └── doorstop_config.ini        ← Doorstop configuration
└── ...
```

On container startup, the `start.sh` script will:
- Detect files in `/mods-source` (mounted from `./mods`)
- Copy BepInEx, dotnet, and doorstop files to `/data/server/`
- Sync plugins on every restart (allows easy mod updates)

> 💡 **Tip**: To update mods, just replace files in `mods/BepInEx/plugins/` and restart the container!

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SERVER_NAME` | V Rising Docker ARM64 | Server name in browser |
| `SAVE_NAME` | world_main | World save folder name |
| `TZ` | America/Sao_Paulo | Timezone for logs |
| `PUID` / `PGID` | 1000 | User/Group IDs |
| `BOX64_DYNAREC_STRONGMEM` | 1 | Memory ordering (stability) |
| `BOX64_DYNAREC_BIGBLOCK` | 1 | Translation block size |
| `BOX64_LOG` | 1 | Box64 logging level |
| `WINEDEBUG` | -all | Wine debug output |
| `DEBUG` | 0 | Script debug mode |

### Game Configuration Files

After first run, these files are created in `/data/save-data/Settings/`:

- **ServerHostSettings.json**: Network, ports, admin settings
- **ServerGameSettings.json**: Gameplay rules, rates, difficulty

Example configuration customization:

```json
// ServerHostSettings.json
{
  "Name": "My ARM64 Server",
  "Port": 9876,
  "QueryPort": 9877,
  "MaxConnectedUsers": 40,
  "MaxConnectedAdmins": 4,
  "SaveName": "world_main",
  "Password": "",
  "ListOnMasterServer": true
}
```

## Easypanel Deployment

### Method 1: Docker Compose App

1. Create a new **App** service in Easypanel
2. Choose **Docker Compose** as deployment method
3. Paste the contents of `docker-compose.yml`
4. Configure environment variables in Easypanel GUI
5. Deploy

### Method 2: Git Repository

1. Push this repository to GitHub/GitLab
2. In Easypanel, create new App from **Git Repository**
3. Point to your repository
4. Easypanel will build from Dockerfile automatically

### Volume Management

Easypanel creates volumes at `/etc/easypanel/projects/{project}/data/`. Use the built-in file manager or SFTP to upload server files.

## Troubleshooting

See **[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)** for comprehensive solutions.

### Common Issues

#### Server doesn't start / Crashes immediately

```bash
# Check logs
docker compose logs --tail=100

# Enable debug mode
DEBUG=1 docker compose up
```

#### BepInEx mods not loading

1. Verify `BepInEx/interop/` contains DLL files
2. Check `BepInEx/LogOutput.log` exists
3. Confirm Wine DLL override: `WINEDLLOVERRIDES=winhttp=n,b`

#### High CPU usage

Emulation overhead is expected. Ensure:
- `BOX64_DYNAREC_STRONGMEM=1` (not 2)
- `BOX64_DYNAREC_BIGBLOCK=1` (not 0)

#### Memory errors (OOM kills)

Increase container memory limit:

```yaml
deploy:
  resources:
    limits:
      memory: 12G
```

## Performance Tuning

### Box64 Variables Reference

| Variable | Safe | Aggressive | Notes |
|----------|------|------------|-------|
| `BOX64_DYNAREC_STRONGMEM` | 1 | 0 | Lower = faster, less stable |
| `BOX64_DYNAREC_BIGBLOCK` | 1 | 2 | Higher = faster, may crash |
| `BOX64_DYNAREC_FASTNAN` | 1 | 1 | Keep enabled |
| `BOX64_DYNAREC_SAFEFLAGS` | 1 | 0 | Lower = faster, less safe |

### Kernel Tuning (Host)

For production servers, apply on the Docker host:

```bash
# Disable transparent huge pages (can cause latency spikes)
echo never > /sys/kernel/mm/transparent_hugepage/enabled

# Increase file descriptor limits
echo "fs.file-max = 1000000" >> /etc/sysctl.conf

# Optimize network stack for game servers
echo "net.core.rmem_max = 16777216" >> /etc/sysctl.conf
echo "net.core.wmem_max = 16777216" >> /etc/sysctl.conf

sysctl -p
```

## Project Structure

```
vrising-arm64/
├── Dockerfile              # Multi-stage build (Box64 + Runtime)
├── docker-compose.yml      # Orchestration configuration
├── start.sh                # Container entrypoint script
├── .env.example            # Environment template
├── healthcheck.sh          # Container health check (optional)
├── README.md               # This file
├── docs/
│   ├── BEPINEX_SETUP.md    # BepInEx pre-generation guide
│   └── TROUBLESHOOTING.md  # Problem solving guide
├── scripts/
│   └── windows-prep.ps1    # Windows preparation helper
├── configs/
│   ├── ServerGameSettings.json   # Example game config
│   └── ServerHostSettings.json   # Example host config
└── mods/                   # Pre-configured BepInEx from Windows (auto-copied)
    ├── BepInEx/            # Modding framework with interop
    ├── dotnet/             # .NET runtime for BepInEx
    ├── winhttp.dll         # Doorstop proxy DLL
    └── doorstop_config.ini # Doorstop configuration
```

## Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/improvement`)
3. Commit changes (`git commit -am 'Add improvement'`)
4. Push to branch (`git push origin feature/improvement`)
5. Open a Pull Request

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.

## Acknowledgments

- [Box64](https://github.com/ptitSeb/box64) - Linux Userspace x86_64 Emulator
- [Wine](https://www.winehq.org/) - Windows API Compatibility Layer
- [BepInEx](https://github.com/BepInEx/BepInEx) - Unity Modding Framework
- [Stunlock Studios](https://www.stunlockstudios.com/) - V Rising Developers

---

**Made with ☕ for the ARM64 community**
