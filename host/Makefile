# ScreenRecordHost 构建与测试入口
# 注意:本环境 SwiftPM manifest 沙箱不可用,必须 --disable-sandbox

BUILD_FLAGS ?= --disable-sandbox
BIN := .build/debug/ScreenRecordHost

.PHONY: build test clean

build:
	swift build $(BUILD_FLAGS)

test: build
	python3 Tests/protocol_smoke.py $(BIN)
	swift Tests/check_js.swift ../extension/background/service-worker.js ../extension/popup/popup.js ../extension/annotate/annotate.js

clean:
	swift package clean
	rm -rf .build
