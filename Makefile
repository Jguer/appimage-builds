# Make is not shell; this keeps `shellcheck Makefile` from parsing it as sh.
# shellcheck disable=SC1073,SC1065,SC1064,SC1072
APPS ?=
ARCH ?=
APPS_DIR ?= $(HOME)/Applications

BUILD_ARGS := $(APPS)
ifneq ($(ARCH),)
BUILD_ARGS += -a $(ARCH)
endif

CHECK_ARGS := $(foreach arch,$(ARCH),-a $(arch))

.DEFAULT_GOAL := help
.PHONY: help build check clean distclean lint install

help:
	@echo "Targets:"
	@echo "  build              build AppImages (APPS=\"rio\" ARCH=x86_64 make build)"
	@echo "  check              compare upstream vs. released versions"
	@echo "  lint               shellcheck all scripts (same as CI)"
	@echo "  install            move out/*.AppImage to $(APPS_DIR), version-stripped"
	@echo "  clean              remove build/ and out/"
	@echo "  distclean          clean + remove downloads/ and cached tools/"
	@echo ""
	@echo "Variables:"
	@echo "  APPS               app ids or payload paths (default: all)"
	@echo "  ARCH               target arch, repeatable via spaces for check"

build:
	./appimage-build/build.sh $(BUILD_ARGS)

check:
	./appimage-build/check-versions.sh $(CHECK_ARGS)

lint:
	shellcheck -x \
		appimage-build/build.sh \
		appimage-build/check-versions.sh \
		appimage-build/lib/common.sh \
		appimage-build/apps/*/app.sh \
		appimage-build/apps/*/AppRun

clean:
	rm -rf appimage-build/build appimage-build/out

distclean: clean
	rm -rf appimage-build/downloads appimage-build/tools

install:
	mkdir -p $(APPS_DIR)
	@ls appimage-build/out/*.AppImage >/dev/null 2>&1 || { echo "no AppImages in appimage-build/out/ - run make build first" >&2; exit 1; }
	@set -e; \
	for f in appimage-build/out/*.AppImage; do \
		name=$${f##*/}; base=$${name%.AppImage}; \
		arch=$${base##*-}; rest=$${base%-*}; app=$${rest%%-*}; \
		printf '%s-%s\n' "$$app" "$$arch"; \
	done | sort -u | while read -r pair; do \
		app=$${pair%%-*}; arch=$${pair##*-}; \
		latest=$$(ls appimage-build/out/$$app-*-$$arch.AppImage | sort -V | tail -n1); \
		echo "$${latest##*/} -> $(APPS_DIR)/$$app-$$arch.AppImage"; \
		cp -f "$$latest" "$(APPS_DIR)/$$app-$$arch.AppImage"; \
	done
