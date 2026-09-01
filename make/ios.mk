IOS_DIR = $(PLATFORM_DIR)/ios

define UPDATE_PATH_EXCLUDES +=
plugins/SSH.koplugin
plugins/autofrontlight.koplugin
plugins/hello.koplugin
plugins/timesync.koplugin
tools
endef

# Preflight: bail out early with a single message listing every missing
# brew package + the PATH export, instead of failing one tool at a time.
ios-check-prereqs:
	@$(CURDIR)/platform/ios/check-prereqs.sh

ios-info-plist:
	@$(CURDIR)/platform/ios/generate-info-plist.sh

ios-source-check:
	@$(CURDIR)/platform/ios/check-source-invariants.sh

update: ios-check-prereqs ios-source-check all
	$(CURDIR)/platform/ios/do_ios_bundle.sh $(INSTALL_DIR)

# Generate KOReader.xcodeproj at the repo root from platform/ios/project.yml.
# Depends on `all` so the staging tree + base/build/<machine>/libs/ exist
# (the project's pre-build script also calls `make TARGET=ios all`, but
# having them present at generation time avoids confusing first-time errors).
xcodeproj: ios-check-prereqs ios-source-check all ios-info-plist
	xcodegen generate \
		--spec $(IOS_DIR)/project.yml \
		--project $(CURDIR) \
		--project-root $(CURDIR)
	@echo
	@echo "Generated $(CURDIR)/KOReader.xcodeproj"
	@echo "Open it in Xcode, set your Team under Signing & Capabilities,"
	@echo "then Run on a connected device (or a simulator if libs are simulator-built)."

PHONY += ios-check-prereqs ios-info-plist ios-source-check xcodeproj
