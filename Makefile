SHELL := /bin/zsh

# Prefer Xcode's Apple-signed Python for local tooling while allowing explicit overrides.
PYTHON3 ?= $(if $(wildcard /usr/bin/python3),/usr/bin/python3,python3)
export PYTHON3

PROJECT_NAME := MacTools
APP_PRODUCT_NAME ?= MacTools Dev
REMOTE_URL ?= git@github.com:owner/MacTools.git
PLACEHOLDER_REMOTE_URL := git@github.com:owner/MacTools.git
PROJECT_FILE := $(PROJECT_NAME).xcodeproj
WORKSPACE_FILE := $(PROJECT_NAME).xcworkspace
DERIVED_DATA := build/DerivedData
APP_PATH := $(DERIVED_DATA)/Build/Products/Debug/$(APP_PRODUCT_NAME).app
APP_EXECUTABLE := $(APP_PATH)/Contents/MacOS/$(APP_PRODUCT_NAME)
HOST_ARCH := $(shell uname -m)
BUILD_DESTINATION := platform=macOS,arch=$(HOST_ARCH)
XCODEBUILD ?= $(abspath scripts/xcodebuild-filtered.sh)
LOCAL_PLUGIN_SOURCE_DIR ?= Plugins
PLUGIN_PROJECT_SOURCE_DIR ?= Plugins
GENERATED_PLUGIN_PROJECT_CONFIG := Configs/GeneratedPlugins.yml
LOCAL_PLUGIN_BUILD_DIR ?= build/LocalPlugins
LOCAL_PLUGIN_CATALOG := $(LOCAL_PLUGIN_BUILD_DIR)/catalog.dev.json
DEBUG_BUILD_PRODUCTS_DIR := $(DERIVED_DATA)/Build/Products/Debug
DEBUG_PLUGIN_INSTALL_DIR ?= $(HOME)/Library/Application Support/MacTools Dev/Plugins/Installed
LOCAL_ICON_GALLERY_DIR ?= build/LocalIconGallery
LOCAL_ICON_GALLERY_CATALOG := $(LOCAL_ICON_GALLERY_DIR)/catalog.dev.json
PLUGIN_RELEASE_REPO ?= ggbond268/MacTools
PLUGIN_RELEASE_TAG ?= plugins-local
PLUGIN_RELEASE_BUILD_DIR ?= build/PluginRelease/Build
PLUGIN_RELEASE_DIST_DIR ?= build/PluginRelease
PLUGIN_RELEASE_ASSETS_DIR ?= $(PLUGIN_RELEASE_DIST_DIR)/Assets
PLUGIN_RELEASE_CATALOG ?= $(PLUGIN_RELEASE_DIST_DIR)/catalog.json
PLUGIN_KIT_VERSION ?= $(shell $(PYTHON3) -c 'import glob,json; versions={json.load(open(path, encoding="utf-8"))["pluginKitVersion"] for path in glob.glob("Plugins/*/plugin.json")}; print(next(iter(versions)) if len(versions) == 1 else "")')
PLUGIN_RELEASE_SIGNED_CATALOG ?= $(if $(filter 2,$(PLUGIN_KIT_VERSION)),docs/plugins/catalog.json,docs/plugins/v$(PLUGIN_KIT_VERSION)/catalog.json)
PLUGIN_RELEASE_BASE_URL ?= https://github.com/$(PLUGIN_RELEASE_REPO)/releases/download/$(PLUGIN_RELEASE_TAG)

.PHONY: setup generate-plugin-config generate build sync-debug-plugins build-plugin build-plugins generate-icon-gallery package-plugins-release stop-debug-app run run-open clean release release-local

setup:
	@if [ ! -f LocalConfig.xcconfig ]; then cp LocalConfig.sample.xcconfig LocalConfig.xcconfig; fi
	@if [ ! -d .git ]; then git init; fi
	@git branch -M main
	@if [ "$(REMOTE_URL)" = "$(PLACEHOLDER_REMOTE_URL)" ]; then echo "Skipping origin remote setup. Pass REMOTE_URL=git@github.com:<owner>/MacTools.git to make setup when ready."; \
	else \
		if git remote get-url origin >/dev/null 2>&1; then git remote set-url origin $(REMOTE_URL); else git remote add origin $(REMOTE_URL); fi; \
	fi

generate-plugin-config:
	@./scripts/plugins/generate-plugin-project-config.rb \
		--source-dir "$(PLUGIN_PROJECT_SOURCE_DIR)" \
		--output "$(GENERATED_PLUGIN_PROJECT_CONFIG)"

generate: generate-plugin-config
	@xcodegen generate

build: generate
	@echo "Building Debug app and plugins..."
	@$(XCODEBUILD) -project $(PROJECT_FILE) -scheme $(PROJECT_NAME) -configuration Debug -destination "$(BUILD_DESTINATION)" -derivedDataPath $(DERIVED_DATA) build -quiet

sync-debug-plugins: build
	@if [ -n "$(PLUGIN)" ]; then \
		PLUGIN_ARGS=(--plugin "$(PLUGIN)"); \
	else \
		PLUGIN_ARGS=(); \
	fi; \
	./scripts/plugins/sync-debug-plugins.sh \
		--source-dir "$(LOCAL_PLUGIN_SOURCE_DIR)" \
		--products-dir "$(DEBUG_BUILD_PRODUCTS_DIR)" \
		--output-dir "$(LOCAL_PLUGIN_BUILD_DIR)" \
		--install-dir "$(DEBUG_PLUGIN_INSTALL_DIR)" \
		$${PLUGIN_ARGS[@]}

build-plugin: generate
	@if [ -n "$(PLUGIN)" ]; then \
		PLUGIN_ARGS=(--plugin "$(PLUGIN)"); \
	else \
		PLUGIN_ARGS=(); \
	fi; \
	./scripts/plugins/build-local-plugins.sh \
		--source-dir "$(LOCAL_PLUGIN_SOURCE_DIR)" \
		--output-dir "$(LOCAL_PLUGIN_BUILD_DIR)" \
		--destination "$(BUILD_DESTINATION)" \
		--xcodebuild "$(XCODEBUILD)" \
		$${PLUGIN_ARGS[@]}

build-plugins: build-plugin

generate-icon-gallery:
	@$(PYTHON3) ./scripts/icons/generate-local-icon-gallery.py \
		--output-dir "$(LOCAL_ICON_GALLERY_DIR)"

package-plugins-release: generate
	@./scripts/plugins/build-plugin-release-assets.sh \
		--source-dir "$(LOCAL_PLUGIN_SOURCE_DIR)" \
		--build-dir "$(PLUGIN_RELEASE_BUILD_DIR)" \
		--dist-dir "$(PLUGIN_RELEASE_DIST_DIR)" \
		--assets-dir "$(PLUGIN_RELEASE_ASSETS_DIR)" \
		--base-url "$(PLUGIN_RELEASE_BASE_URL)" \
		--catalog-output "$(PLUGIN_RELEASE_CATALOG)" \
		--signed-catalog-output "$(PLUGIN_RELEASE_SIGNED_CATALOG)" \
		--sign-identity "$(PLUGIN_CODE_SIGN_IDENTITY)" \
		--destination "$(BUILD_DESTINATION)" \
		--xcodebuild "$(XCODEBUILD)" \
		--release-notes-url "https://github.com/$(PLUGIN_RELEASE_REPO)/releases/tag/$(PLUGIN_RELEASE_TAG)"

# Relaunching a local build needs to replace, rather than duplicate, the
# existing debug app. Stop all matching debug processes first; do not start a
# new copy if the old process declines to quit.
stop-debug-app:
	@PIDS=($$(/usr/bin/pgrep -x "$(APP_PRODUCT_NAME)" 2>/dev/null || true)); \
	if (( $${#PIDS[@]} == 0 )); then \
		exit 0; \
	fi; \
	echo "Stopping existing $(APP_PRODUCT_NAME) instance(s)..."; \
	/bin/kill -TERM $${PIDS[@]} >/dev/null 2>&1 || true; \
	for attempt in {1..50}; do \
		PIDS=($$(/usr/bin/pgrep -x "$(APP_PRODUCT_NAME)" 2>/dev/null || true)); \
		if (( $${#PIDS[@]} == 0 )); then \
			exit 0; \
		fi; \
		/bin/sleep 0.1; \
	done; \
	echo "$(APP_PRODUCT_NAME) is still running; not launching another instance." >&2; \
	exit 1

run: stop-debug-app sync-debug-plugins generate-icon-gallery
	@CATALOG_URL="$(MACTOOLS_PLUGIN_CATALOG_URL)"; \
	ICON_CATALOG_URL="$(MACTOOLS_ICON_CATALOG_URL)"; \
	if [ -z "$$CATALOG_URL" ] && [ -f "$(LOCAL_PLUGIN_CATALOG)" ]; then \
		CATALOG_URL="file://$(abspath $(LOCAL_PLUGIN_CATALOG))"; \
	fi; \
	if [ -z "$$ICON_CATALOG_URL" ] && [ -f "$(LOCAL_ICON_GALLERY_CATALOG)" ]; then \
		ICON_CATALOG_URL="file://$(abspath $(LOCAL_ICON_GALLERY_CATALOG))"; \
	fi; \
	if [ -n "$$CATALOG_URL" ]; then \
		echo "Using plugin catalog: $$CATALOG_URL"; \
	fi; \
	if [ -n "$$ICON_CATALOG_URL" ]; then \
		echo "Using icon catalog: $$ICON_CATALOG_URL"; \
	fi; \
	RUN_ENV=(); \
	if [ -n "$$CATALOG_URL" ]; then \
		RUN_ENV+=("MACTOOLS_PLUGIN_CATALOG_URL=$$CATALOG_URL"); \
	fi; \
	if [ -n "$$ICON_CATALOG_URL" ]; then \
		RUN_ENV+=("MACTOOLS_ICON_CATALOG_URL=$$ICON_CATALOG_URL"); \
	fi; \
	stop_app() { \
		PIDS=($$(/usr/bin/pgrep -x "$(APP_PRODUCT_NAME)" 2>/dev/null || true)); \
		if (( $${#PIDS[@]} > 0 )); then \
			echo "Stopping $(APP_PRODUCT_NAME)..."; \
			/bin/kill -TERM $${PIDS[@]} >/dev/null 2>&1 || true; \
		fi; \
	}; \
	trap 'stop_app; exit 130' INT TERM; \
	if [ -z "$$CATALOG_URL" ] && [ -z "$$ICON_CATALOG_URL" ]; then \
		echo "No local plugin catalog found. Run 'make build-plugin' or set MACTOOLS_PLUGIN_CATALOG_URL."; \
	fi; \
	OPEN_ENV=(); \
	for ENVIRONMENT_VARIABLE in "$${RUN_ENV[@]}"; do \
		OPEN_ENV+=(--env "$$ENVIRONMENT_VARIABLE"); \
	done; \
	open "$${OPEN_ENV[@]}" -W "$(APP_PATH)"

run-open: stop-debug-app build
	@open -W "$(APP_PATH)"

clean:
	@rm -rf build $(PROJECT_FILE) $(WORKSPACE_FILE) "$(GENERATED_PLUGIN_PROJECT_CONFIG)"

release:
	@./scripts/release.py $(ARGS)

release-local:
	@./scripts/release-local.sh $(ARGS)
