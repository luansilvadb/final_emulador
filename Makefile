# V Rising ARM64 Server - Makefile
# =============================================================================
# Convenience commands for building and managing the Docker environment
# =============================================================================

.PHONY: help build up down logs shell clean rebuild

# Default target
help:
	@echo "V Rising ARM64 Docker - Available Commands"
	@echo "==========================================="
	@echo ""
	@echo "  make build      - Build the Docker image"
	@echo "  make up         - Start the container (detached)"
	@echo "  make down       - Stop and remove the container"
	@echo "  make logs       - Follow container logs"
	@echo "  make shell      - Open a shell in the container"
	@echo "  make restart    - Restart the container"
	@echo "  make clean      - Remove container, image, and volumes"
	@echo "  make rebuild    - Full clean rebuild"
	@echo "  make status     - Show container status"
	@echo ""

# Build the Docker image
build:
	@echo "Building V Rising ARM64 Docker image..."
	docker compose build

# Start container in detached mode
up:
	@echo "Starting V Rising server..."
	docker compose up -d
	@echo ""
	@echo "Server starting. Use 'make logs' to view output."

# Stop and remove container
down:
	@echo "Stopping V Rising server..."
	docker compose down

# Follow logs
logs:
	docker compose logs -f

# Open shell in container
shell:
	docker compose exec vrising bash

# Restart container
restart:
	@echo "Restarting V Rising server..."
	docker compose restart

# Show status
status:
	@echo "Container Status:"
	@docker compose ps
	@echo ""
	@echo "Resource Usage:"
	@docker stats --no-stream vrising-server 2>/dev/null || echo "Container not running"

# Clean everything (WARNING: removes data)
clean:
	@echo "WARNING: This will remove the container, image, and all data!"
	@read -p "Are you sure? [y/N] " confirm && [ "$$confirm" = "y" ]
	docker compose down -v --rmi local

# Full rebuild
rebuild: down
	@echo "Performing full rebuild..."
	docker compose build --no-cache
	docker compose up -d
	@echo ""
	@echo "Rebuild complete. Use 'make logs' to view output."
