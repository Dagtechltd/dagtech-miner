# ============================================================================
# DagTech Miner - Build System
# Copyright (c) 2024-2026 DagTech Ltd / Dawie Nel
# https://dagtech.network
# ============================================================================

CC = gcc
CFLAGS = -O2 -Wall -Wextra -Wno-stringop-truncation -Wno-unused-result
LDFLAGS = -lpthread -lm

# Auto-detect native optimizations
NATIVE_FLAGS := $(shell $(CC) -march=native -E -x c /dev/null >/dev/null 2>&1 && echo "-march=native" || echo "")
CFLAGS += $(NATIVE_FLAGS)

# Auto-detect OpenSSL (prefer it if available, fall back to built-in SHA256)
HAS_OPENSSL := $(shell pkg-config --exists openssl 2>/dev/null && echo yes || (test -f /usr/include/openssl/sha.h && echo yes) || echo no)
ifeq ($(HAS_OPENSSL),yes)
  CFLAGS += -DUSE_OPENSSL
  LDFLAGS += -lssl -lcrypto
endif

SRC = src/dagtech_miner.c
BIN = dagtech-miner

PREFIX ?= $(HOME)/.dagtech-miner
BINDIR = $(PREFIX)/bin

.PHONY: all clean install uninstall help

all: $(BIN)
	@echo ""
	@echo "  DagTech Miner built successfully!"
	@echo "  Run: ./$(BIN) --help"
	@echo ""

$(BIN): $(SRC)
	@echo "[DagTech] Compiling $(SRC)..."
	$(CC) $(CFLAGS) -o $(BIN) $(SRC) $(LDFLAGS)
	@echo "[DagTech] Build complete: ./$(BIN)"

clean:
	rm -f $(BIN)
	@echo "[DagTech] Cleaned"

install: $(BIN)
	@echo "[DagTech] Installing to $(PREFIX)..."
	@mkdir -p $(BINDIR) $(PREFIX)/dashboard $(PREFIX)/logs
	cp $(BIN) $(BINDIR)/
	cp -r dashboard/* $(PREFIX)/dashboard/ 2>/dev/null || true
	@echo "[DagTech] Installed to $(PREFIX)"

uninstall:
	@echo "[DagTech] Removing $(PREFIX)..."
	rm -rf $(PREFIX)
	@echo "[DagTech] Uninstalled"

help:
	@echo ""
	@echo "  DagTech Miner - Build Targets"
	@echo "  =============================="
	@echo "  make          Build the miner"
	@echo "  make install  Install to ~/.dagtech-miner"
	@echo "  make clean    Remove build artifacts"
	@echo "  make uninstall Remove installation"
	@echo ""
