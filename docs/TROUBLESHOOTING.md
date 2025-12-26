# Troubleshooting Guide

> **Solutions for common issues when running V Rising on ARM64 with Box64/Wine**

## Table of Contents

- [Quick Diagnosis](#quick-diagnosis)
- [Server Won't Start](#server-wont-start)
- [BepInEx Issues](#bepinex-issues)
- [Performance Problems](#performance-problems)
- [Network Issues](#network-issues)
- [Crash Analysis](#crash-analysis)
- [Log Locations](#log-locations)

---

## Quick Diagnosis

### Enable Debug Mode

```bash
# Add to .env or docker-compose environment
DEBUG=1
BOX64_LOG=2
WINEDEBUG=+seh,+loaddll
```

### View All Logs

```bash
# Real-time logs
docker compose logs -f

# Last 500 lines
docker compose logs --tail=500

# Save to file
docker compose logs > server-debug.log 2>&1
```

### Enter Container Shell

```bash
docker compose exec vrising bash

# As vrising user
cd /data/server
ls -la

# Check processes
ps aux

# Check Wine
wine64 --version
```

---

## Server Won't Start

### Problem: Container exits immediately

**Symptoms:**
- Container status shows "Exited (1)"
- No game logs are generated

**Solutions:**

1. **Check for server files:**
   ```bash
   docker compose exec vrising ls -la /data/server/
   # Should show VRisingServer.exe
   ```

2. **Verify permissions:**
   ```bash
   docker compose exec vrising ls -la /data/
   # Owner should be vrising:vrising
   ```

3. **Check Wine prefix:**
   ```bash
   docker compose exec vrising ls -la /data/wineprefix/
   # Should contain drive_c, system.reg, etc.
   ```

### Problem: "VRisingServer.exe not found"

**Cause:** Server files not uploaded or wrong path.

**Solution:**
```bash
# Upload server files to correct location
docker cp ./VRisingDedicatedServer/. vrising-server:/data/server/

# Restart
docker compose restart
```

### Problem: Wine initialization fails

**Symptoms:**
- Errors mentioning "wineboot" or "wineserver"
- "Failed to initialize Wine prefix"

**Solutions:**

1. **Clear and reinitialize prefix:**
   ```bash
   docker compose down
   docker volume rm vrising_vrising-data
   docker compose up -d
   ```

2. **Check disk space:**
   ```bash
   df -h
   # Wine prefix needs ~500MB
   ```

### Problem: Box64 crashes with SIGILL

**Symptoms:**
- "Illegal instruction" errors
- "SIGILL" in logs

**Cause:** CPU doesn't support required ARM extensions or Box64 build issue.

**Solutions:**

1. **Verify ARM64 architecture:**
   ```bash
   uname -m
   # Should show: aarch64
   ```

2. **Rebuild Box64 for your specific CPU:**
   ```dockerfile
   # In Dockerfile, add specific target
   cmake .. -DARM_DYNAREC=ON -DRPI4=ON  # For Raspberry Pi 4
   # OR
   cmake .. -DARM_DYNAREC=ON -DRKXXX=ON  # For RK3588
   ```

---

## BepInEx Issues

### Problem: Mods don't load

**Symptoms:**
- Server runs but mods have no effect
- `BepInEx/LogOutput.log` doesn't exist

**Diagnosis:**
```bash
# Check BepInEx structure
docker compose exec vrising ls -la /data/server/BepInEx/

# Should contain:
# - core/
# - config/
# - plugins/
# - interop/  (CRITICAL - must have DLLs)
# - unity-libs/  (CRITICAL - must have DLLs)
```

**Solutions:**

1. **Verify Wine DLL override:**
   Check logs for:
   ```
   Wine DLL overrides configured: WINEDLLOVERRIDES=winhttp=n,b
   ```

2. **Confirm winhttp.dll exists:**
   ```bash
   ls -la /data/server/winhttp.dll
   # Must exist in server root, not in BepInEx folder
   ```

3. **Regenerate interop on Windows:**
   See [BEPINEX_SETUP.md](BEPINEX_SETUP.md)

### Problem: "Interop files missing" warning

**Cause:** Il2CppInterop generation was skipped or failed.

**Solution:**
Generate on Windows and transfer:

```bash
# Required files from Windows:
scp -r BepInEx/interop/ server:/data/server/BepInEx/
scp -r BepInEx/unity-libs/ server:/data/server/BepInEx/
```

### Problem: BepInEx/LogOutput.log shows errors

**Common errors and fixes:**

| Error | Cause | Fix |
|-------|-------|-----|
| `TypeLoadException` | Interop mismatch | Regenerate interop files |
| `PluginException` | Mod incompatible | Check mod version compatibility |
| `Assembly 'xxx' not found` | Missing dependency | Install required mod dependency |

---

## Performance Problems

### Problem: High CPU usage (>80%)

**Causes:**
- Emulation overhead (expected 30-50% overhead)
- Suboptimal Box64 settings
- Too many players/mods

**Solutions:**

1. **Tune Box64 (less safe but faster):**
   ```env
   BOX64_DYNAREC_STRONGMEM=0
   BOX64_DYNAREC_BIGBLOCK=2
   BOX64_DYNAREC_SAFEFLAGS=0
   ```

2. **Reduce game complexity:**
   - Lower max players
   - Reduce mod count
   - Shrink map size

### Problem: High memory usage

**Symptoms:**
- OOM kills
- Container randomly stops

**Solutions:**

1. **Increase memory limit:**
   ```yaml
   deploy:
     resources:
       limits:
         memory: 12G
   ```

2. **Set MALLOC limits:**
   ```env
   MALLOC_MMAP_THRESHOLD_=131072
   MALLOC_TRIM_THRESHOLD_=131072
   ```

### Problem: Lag spikes every few seconds

**Cause:** Garbage collection or Wine process management.

**Solutions:**

1. **Increase Wine server priority:**
   ```bash
   # Not directly configurable, but ensure no other heavy processes
   ```

2. **Disable host transparent huge pages:**
   ```bash
   # On host system
   echo never > /sys/kernel/mm/transparent_hugepage/enabled
   ```

---

## Network Issues

### Problem: Server not visible in browser

**Symptoms:**
- Direct connect works
- Server browser doesn't show server

**Causes:**
- Port 9877/udp (query port) not exposed
- Firewall blocking

**Solutions:**

1. **Verify port mapping:**
   ```bash
   docker port vrising-server
   # Should show:
   # 9876/udp -> 0.0.0.0:9876
   # 9877/udp -> 0.0.0.0:9877
   ```

2. **Check host firewall:**
   ```bash
   # UFW
   sudo ufw allow 9876/udp
   sudo ufw allow 9877/udp
   
   # iptables
   sudo iptables -A INPUT -p udp --dport 9876 -j ACCEPT
   sudo iptables -A INPUT -p udp --dport 9877 -j ACCEPT
   ```

### Problem: Players can't connect

**Symptoms:**
- "Connection failed" on client
- Server appears running

**Solutions:**

1. **Test internal connectivity:**
   ```bash
   docker compose exec vrising nc -uvz localhost 9876
   ```

2. **Check NAT/Router:**
   - Forward ports 9876-9877 UDP to host IP
   - Disable SIP ALG if available

3. **Verify server config:**
   ```json
   // ServerHostSettings.json
   {
     "Port": 9876,
     "QueryPort": 9877,
     "ListOnMasterServer": true
   }
   ```

---

## Crash Analysis

### Problem: Random crashes during gameplay

**Diagnosis:**

1. **Enable core dumps:**
   ```bash
   # On host
   ulimit -c unlimited
   echo '/tmp/core.%e.%p' | sudo tee /proc/sys/kernel/core_pattern
   ```

2. **Check Box64 logs:**
   ```env
   BOX64_LOG=2
   BOX64_SHOWSEGV=1
   ```

3. **Look for patterns:**
   - Crashes during combat → Physics/Burst issues
   - Crashes on save → Filesystem/memory issues
   - Crashes with many players → Threading issues

**Common fixes:**

| Pattern | Fix |
|---------|-----|
| SEGV in mono | Enable `BOX64_DYNAREC_STRONGMEM=2` |
| Access Violation | Disable Burst (remove lib_burst_generated.dll) |
| Stack overflow | Increase container ulimits |

### Problem: "lib_burst_generated.dll" errors

**Symptoms:**
- Access Violation at startup
- SIGILL in Burst functions

**Solution:**
The startup script should auto-handle this, but verify:

```bash
ls -la /data/server/VRisingServer_Data/Plugins/x86_64/
# lib_burst_generated.dll should be renamed to .disabled
```

---

## Log Locations

### Inside Container

| Log | Path | Purpose |
|-----|------|---------|
| Server Log | `/data/logs/VRisingServer.log` | Game server output |
| BepInEx Log | `/data/server/BepInEx/LogOutput.log` | Mod loader output |
| Wine Debug | stdout | Wine/Box64 debugging |

### Accessing Logs

```bash
# All logs combined
docker compose logs

# Game log only
docker compose exec vrising cat /data/logs/VRisingServer.log

# BepInEx log
docker compose exec vrising cat /data/server/BepInEx/LogOutput.log

# Export for analysis
docker compose logs > full-debug.log 2>&1
```

### Log Level Reference

| Component | Variable | Levels |
|-----------|----------|--------|
| Box64 | `BOX64_LOG` | 0=none, 1=info, 2=debug, 3=trace |
| Wine | `WINEDEBUG` | -all, +channel, =channel |
| Script | `DEBUG` | 0=normal, 1=verbose |

---

## Getting Help

If issues persist:

1. **Collect diagnostic info:**
   ```bash
   docker compose logs > logs.txt 2>&1
   docker compose exec vrising cat /data/server/BepInEx/LogOutput.log >> logs.txt
   docker compose exec vrising uname -a >> logs.txt
   docker compose exec vrising cat /proc/cpuinfo | head -20 >> logs.txt
   ```

2. **Check community resources:**
   - [Box64 Issues](https://github.com/ptitSeb/box64/issues)
   - [V Rising Modding Discord](https://discord.gg/vrising)
   - [BepInEx Discord](https://discord.gg/bepinex)

3. **Open an issue with:**
   - Hardware specs (CPU model, RAM)
   - Docker version
   - Full logs (sanitize passwords)
   - Steps to reproduce

---

**Good luck, and happy hunting! 🧛**
