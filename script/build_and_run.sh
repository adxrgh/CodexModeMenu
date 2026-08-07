#!/bin/bash
# build_and_run.sh — Codex 模式菜单栏工具：构建 / 运行 / 日志 / 遥测 / 校验 / 安装
# 用法: ./script/build_and_run.sh <run|debug|logs|telemetry|verify|install>
set -euo pipefail

APP_NAME="Codex 模式"
EXECUTABLE="CodexModeMenu"
BUNDLE_ID="com.codex.mode-menu"
MIN_OS="13.0"

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${PROJECT_DIR}/dist"
BUILD_APP="${DIST_DIR}/${APP_NAME}.app"
CONTENTS="${BUILD_APP}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"
RESOURCES_DIR="${CONTENTS}/Resources"

INSTALL_DIR="/Users/bob/Applications"
INSTALL_APP="${INSTALL_DIR}/${APP_NAME}.app"
INSTALL_BIN="${INSTALL_APP}/Contents/MacOS/${EXECUTABLE}"

LAUNCH_AGENT_DIR="${HOME}/Library/LaunchAgents"
LAUNCH_AGENT_PLIST="${LAUNCH_AGENT_DIR}/com.codex.mode-menu.plist"
LAUNCH_AGENT_LABEL="com.codex.mode-menu"

RUNTIME_DIR="${PROJECT_DIR}/runtime"
STDOUT_LOG="${RUNTIME_DIR}/mode-menu.log"
STDERR_LOG="${RUNTIME_DIR}/mode-menu.err.log"
TELEMETRY_FILE="${RUNTIME_DIR}/telemetry.jsonl"

log_telemetry() {
  mkdir -p "$RUNTIME_DIR"
  printf '{"ts":"%s","event":"%s","pid":%s}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$$" >> "$TELEMETRY_FILE"
}

usage() {
  cat <<'EOF'
用法: ./script/build_and_run.sh <command>

命令:
  run         构建并以菜单栏应用方式启动（open dist/Codex 模式.app）
  debug       构建并以调试模式前台运行（输出到终端）
  logs        查看 runtime 日志（tail -f）
  telemetry   查看运行时事件记录（runtime/telemetry.jsonl）
  verify      校验签名 / Info.plist / 二进制 / 进程
  install     事务式安装到 /Users/bob/Applications 并注册 LaunchAgent
EOF
}

build_app() {
  echo "==> swift build -c release --product ${EXECUTABLE}"
  (cd "$PROJECT_DIR" && swift build -c release --product "$EXECUTABLE")

  rm -rf "$BUILD_APP"
  mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
  cp "${PROJECT_DIR}/.build/release/${EXECUTABLE}" "${MACOS_DIR}/${EXECUTABLE}"

  cat > "${CONTENTS}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>zh_CN</string>
	<key>CFBundleExecutable</key>
	<string>${EXECUTABLE}</string>
	<key>CFBundleIdentifier</key>
	<string>${BUNDLE_ID}</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>${APP_NAME}</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>${MIN_OS}</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
PLIST

  codesign --force --sign - --identifier "$BUNDLE_ID" "$BUILD_APP" >/dev/null
  echo "==> 构建完成: ${BUILD_APP}"
}

install_app() {
  build_app
  mkdir -p "$INSTALL_DIR" "$RUNTIME_DIR"

  local backup="${INSTALL_APP}.bak.$$"
  local ok=0
  if [ -d "$INSTALL_APP" ]; then
    echo "==> 备份旧应用 -> ${backup}"
    mv "$INSTALL_APP" "$backup"
  fi
  if ! cp -R "$BUILD_APP" "$INSTALL_APP"; then
    ok=1
  fi
  if [ "$ok" -eq 1 ]; then
    echo "!! 安装失败，恢复旧应用" >&2
    rm -rf "$INSTALL_APP" 2>/dev/null || true
    if [ -d "$backup" ]; then mv "$backup" "$INSTALL_APP"; fi
    log_telemetry install_failed
    exit 1
  fi
  rm -rf "$backup" 2>/dev/null || true
  chmod +x "$INSTALL_BIN"
  log_telemetry installed
  echo "==> 已安装: ${INSTALL_APP}"
}

write_launch_agent() {
  mkdir -p "$LAUNCH_AGENT_DIR" "$RUNTIME_DIR"
  cat > "$LAUNCH_AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${LAUNCH_AGENT_LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>${INSTALL_BIN}</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<false/>
	<key>StandardOutPath</key>
	<string>${STDOUT_LOG}</string>
	<key>StandardErrorPath</key>
	<string>${STDERR_LOG}</string>
</dict>
</plist>
PLIST
  plutil -lint "$LAUNCH_AGENT_PLIST" >/dev/null
}

register_service() {
  write_launch_agent
  local domain="gui/$(id -u)/${LAUNCH_AGENT_LABEL}"
  echo "==> bootout（不存在可忽略）"
  launchctl bootout "$domain" >/dev/null 2>&1 || true
  echo "==> bootstrap ${LAUNCH_AGENT_PLIST}"
  launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENT_PLIST"
  echo "==> kickstart ${domain}"
  launchctl kickstart "$domain"
}

verify() {
  local app="$BUILD_APP"
  if [ ! -d "$app" ]; then app="$INSTALL_APP"; fi
  echo "==> plutil -lint ${app}/Contents/Info.plist"
  plutil -lint "${app}/Contents/Info.plist"
  echo "==> codesign --verify --deep --strict ${app}"
  codesign --verify --deep --strict "$app"
  echo "==> 可执行文件: ${app}/Contents/MacOS/${EXECUTABLE}"
  test -x "${app}/Contents/MacOS/${EXECUTABLE}" && echo "OK"
  echo "==> 进程检查"
  if pgrep -x "$EXECUTABLE" >/dev/null; then
    echo "OK: ${EXECUTABLE} 运行中 (pid $(pgrep -x "$EXECUTABLE" | tr '\n' ' '))"
  else
    echo "提示: ${EXECUTABLE} 未运行"
  fi
}

CMD="${1:-run}"
case "$CMD" in
  run)
    build_app
    open "$BUILD_APP"
    log_telemetry run
    ;;
  debug)
    build_app
    log_telemetry debug
    exec "${MACOS_DIR}/${EXECUTABLE}"
    ;;
  logs)
    mkdir -p "$RUNTIME_DIR"
    touch "$STDOUT_LOG" "$STDERR_LOG"
    exec tail -n 100 -f "$STDOUT_LOG" "$STDERR_LOG"
    ;;
  telemetry)
    mkdir -p "$RUNTIME_DIR"
    touch "$TELEMETRY_FILE"
    cat "$TELEMETRY_FILE"
    ;;
  verify)
    verify
    ;;
  install)
    install_app
    register_service
    log_telemetry install_complete
    verify
    ;;
  *)
    usage
    exit 1
    ;;
esac
