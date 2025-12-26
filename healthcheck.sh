#!/bin/bash
# =============================================================================
# V Rising Server - Container Health Check Script
# =============================================================================
# Used by Docker's HEALTHCHECK instruction to determine container health.
# Returns 0 (healthy) if the server process is running, 1 otherwise.
# =============================================================================

# Check if VRisingServer process is running
# Note: Under Wine/Box64, the process appears as wine64-preloader with VRisingServer
if pgrep -f "VRisingServer" > /dev/null 2>&1; then
    # Process is running
    exit 0
elif pgrep -f "wine64" > /dev/null 2>&1; then
    # Wine is running (server might be in early startup)
    exit 0
else
    # No relevant processes found
    exit 1
fi
