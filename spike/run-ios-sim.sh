#!/usr/bin/env bash
# 在 iOS 模拟器里跑 spike
#
# 不需要 Xcode 工程, 也不需要打 .app 包: simctl spawn 能直接执行一个
# aarch64-apple-ios-sim 的裸可执行文件, 而且模拟器看得见宿主机的文件系统,
# 模型和照片的路径原样传进去就行。
#
# 用法: ./run-ios-sim.sh <模型目录> <照片> [--long-edge N]
set -euo pipefail

DEV="${SIM_DEVICE:-iPhone 17 Pro}"
HERE="$(cd "$(dirname "$0")" && pwd)"

if [ $# -lt 2 ]; then
  echo "用法: $0 <模型目录> <照片> [--long-edge N]" >&2
  exit 2
fi
MODELS="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
PHOTO="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
shift 2

rustup target add aarch64-apple-ios-sim >/dev/null
(cd "$HERE" && cargo build --release --target aarch64-apple-ios-sim)

BIN="$HERE/target/aarch64-apple-ios-sim/release/spike"
echo "二进制 $(du -h "$BIN" | cut -f1)"

# 已经开着就不用再 boot, 所以吞掉这里的报错
xcrun simctl boot "$DEV" 2>/dev/null || true
xcrun simctl bootstatus "$DEV" -b >/dev/null

# 输出写到宿主机的临时目录 —— 模拟器和宿主共用文件系统
xcrun simctl spawn "$DEV" "$BIN" "$MODELS" "$PHOTO" "${TMPDIR:-/tmp}/spike-ios.docx" "$@"
