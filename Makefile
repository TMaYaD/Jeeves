# Jeeves — developer Makefile
#
# Common targets for running the Flutter app across platforms and spinning
# up the backend stack via podman compose.
#
# Quick reference:
#   make setup              install Flutter deps + run code generators
#   make backend            start Postgres/PowerSync/FastAPI/Redis via podman
#   make android            launch Android emulator and run the app on it
#   make iphone             boot iOS Simulator and run the app on it
#   make web                run the app in Chrome
#   make macos              run the macOS desktop build
#   make linux              run the Linux desktop build
#   make windows            run the Windows desktop build
#   make emulator-android   just boot the Android emulator
#   make emulator-ios       just boot the iOS Simulator

# Use bash so ${ProgramFiles(x86)} and similar parameter expansions work.
SHELL := /usr/bin/env bash

APP_DIR      := app
COMPOSE_FILE := infra/docker-compose.yml
COMPOSE      := podman compose -f $(COMPOSE_FILE)

# First AVD reported by `flutter emulators` (Pixel_7_API_34, etc.).
# Override with:   make android ANDROID_AVD=My_AVD
ANDROID_AVD ?= $(shell flutter emulators 2>/dev/null | awk -F'•' '/android/ {gsub(/ /,"",$$1); print $$1; exit}')

# iOS Simulator device name. Override with:  make iphone IOS_DEVICE="iPhone 15 Pro"
IOS_DEVICE ?= iPhone 15

# Web device selection:
#   unset (default) → auto: use `chrome` if a Chromium browser is detected,
#                     otherwise fall back to `web-server` (any browser).
#   chrome          → Flutter auto-launches a Chromium browser. Point at
#                     Edge/Brave/Arc/Chromium via CHROME_EXECUTABLE (auto-detected).
#   web-server      → Flutter serves localhost:$(WEB_PORT); open in any browser
#                     (Firefox, Safari, …).
# Override with:  make web WEB_DEVICE=chrome
WEB_DEVICE ?=
WEB_PORT   ?= 8787

.PHONY: help setup backend backend-down \
        android seeker web macos iphone ios windows linux \
        emulator-android emulator-ios \
        detect-chromium \
        clean

help:
	@awk 'BEGIN{FS":.*##"} /^[a-zA-Z_-]+:.*##/ {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# -----------------------------------------------------------------------------
# Setup
# -----------------------------------------------------------------------------

setup: ## Fetch Flutter packages, download web assets, and run build_runner
	cd $(APP_DIR) && flutter pub get
	bash tool/fetch_web_assets.sh
	cd $(APP_DIR) && dart run build_runner build --delete-conflicting-outputs

# -----------------------------------------------------------------------------
# Backend (podman)
# -----------------------------------------------------------------------------

backend: ## Start backend stack (postgres, powersync, fastapi, redis)
	$(COMPOSE) up -d --build

backend-down: ## Stop backend stack
	$(COMPOSE) down

# -----------------------------------------------------------------------------
# Emulators / simulators
# -----------------------------------------------------------------------------

emulator-android: ## Boot the Android emulator (first available AVD)
	@if [ -z "$(ANDROID_AVD)" ]; then \
		echo "No Android AVD found. Create one via Android Studio or 'avdmanager create avd'."; \
		exit 1; \
	fi
	@echo "Booting Android emulator: $(ANDROID_AVD)"
	@flutter emulators --launch $(ANDROID_AVD)
	@echo "Waiting for device to come online..."
	@adb wait-for-device
	@until [ "$$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; do sleep 2; done
	@echo "Android emulator ready."

emulator-ios: ## Boot the iOS Simulator
	@echo "Booting iOS Simulator: $(IOS_DEVICE)"
	@xcrun simctl boot "$(IOS_DEVICE)" 2>/dev/null || true
	@open -a Simulator
	@xcrun simctl bootstatus "$(IOS_DEVICE)" -b
	@echo "iOS Simulator ready."

# -----------------------------------------------------------------------------
# Run targets (per platform)
# -----------------------------------------------------------------------------

android: setup emulator-android ## Run app on Android emulator
	cd $(APP_DIR) && flutter run -d emulator

# Solana Seeker device (physical or emulator).
# Override with:  make seeker SEEKER_DEVICE=<device-id>
SEEKER_DEVICE ?= emulator

seeker: setup ## Run app on Solana Seeker with SWS auth mode
	@if [ "$(SEEKER_DEVICE)" = "emulator" ]; then \
		$(MAKE) emulator-android; \
	fi
	cd $(APP_DIR) && flutter run -d $(SEEKER_DEVICE) --dart-define=JEEVES_AUTH_MODE=sws

iphone ios: setup emulator-ios ## Run app on iOS Simulator
	cd $(APP_DIR) && flutter run -d "$(IOS_DEVICE)"

web: setup ## Run app in a browser (auto: chrome if available, else web-server)
	@chrome_exe="$${CHROME_EXECUTABLE:-$$($(MAKE) -s detect-chromium)}"; \
	 device="$(WEB_DEVICE)"; \
	 if [ -z "$$device" ]; then \
	   if [ -n "$$chrome_exe" ]; then device=chrome; \
	   else device=web-server; fi; \
	 fi; \
	 if [ "$$device" = "chrome" ] && [ -z "$$chrome_exe" ]; then \
	   echo "WEB_DEVICE=chrome but no Chromium browser found. Install one, set CHROME_EXECUTABLE, or use WEB_DEVICE=web-server."; exit 1; \
	 fi; \
	 [ "$$device" = "chrome" ] && echo "Using browser: $$chrome_exe"; \
	 [ "$$device" = "web-server" ] && echo "Serving on http://localhost:$(WEB_PORT) — open in any browser."; \
	 cd $(APP_DIR) && CHROME_EXECUTABLE="$$chrome_exe" flutter run -d $$device --web-port=$(WEB_PORT)

detect-chromium: ## Print path to the first Chromium-based browser found (empty if none)
	@set +e; \
	 pf86="$$(printenv 'ProgramFiles(x86)' 2>/dev/null)"; \
	 for cand in \
	   "$$CHROME_EXECUTABLE" \
	   "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
	   "/Applications/Chromium.app/Contents/MacOS/Chromium" \
	   "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge" \
	   "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser" \
	   "/Applications/Arc.app/Contents/MacOS/Arc" \
	   "/Applications/Vivaldi.app/Contents/MacOS/Vivaldi" \
	   "$$PROGRAMFILES/Google/Chrome/Application/chrome.exe" \
	   "$$pf86/Google/Chrome/Application/chrome.exe" \
	   "$$LOCALAPPDATA/Google/Chrome/Application/chrome.exe" \
	   "$$PROGRAMFILES/Microsoft/Edge/Application/msedge.exe" \
	   "$$pf86/Microsoft/Edge/Application/msedge.exe" \
	   "$$LOCALAPPDATA/Microsoft/Edge/Application/msedge.exe" \
	   "$$PROGRAMFILES/BraveSoftware/Brave-Browser/Application/brave.exe" \
	   "$$pf86/BraveSoftware/Brave-Browser/Application/brave.exe" \
	   "$$PROGRAMFILES/Chromium/Application/chrome.exe" \
	   "$$PROGRAMFILES/Vivaldi/Application/vivaldi.exe"; do \
	   if [ -n "$$cand" ] && { [ -x "$$cand" ] || [ -f "$$cand" ]; }; then echo "$$cand"; exit 0; fi; \
	 done; \
	 for bin in google-chrome google-chrome-stable chromium chromium-browser microsoft-edge brave-browser vivaldi-stable chrome.exe msedge.exe brave.exe; do \
	   p=$$(command -v "$$bin" 2>/dev/null); \
	   if [ -n "$$p" ]; then echo "$$p"; exit 0; fi; \
	 done; \
	 exit 0

macos: setup ## Run app as a macOS desktop build
	cd $(APP_DIR) && flutter run -d macos

linux: setup ## Run app as a Linux desktop build
	cd $(APP_DIR) && flutter run -d linux

windows: setup ## Run app as a Windows desktop build
	cd $(APP_DIR) && flutter run -d windows

# -----------------------------------------------------------------------------
# Housekeeping
# -----------------------------------------------------------------------------

clean: ## flutter clean + remove generated files
	cd $(APP_DIR) && flutter clean
