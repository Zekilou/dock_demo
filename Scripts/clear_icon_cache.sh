#!/bin/bash
# 清理 macOS 图标缓存（Dock / LaunchServices / iconservices），刷新后重启 Dock
rm -rf /Library/Caches/com.apple.iconservices.store
find /private/var/folders/ \( -name com.apple.dock.iconcache -or -name com.apple.iconservices \) -exec rm -rf {} \; 2>/dev/null
killall Dock
