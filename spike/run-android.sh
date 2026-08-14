#!/usr/bin/env bash
# 在 Android 模拟器 / 真机上跑 spike
#
# 两个必须知道的点:
#   1. 交叉编译要显式指定 NDK 的 clang 当 linker, 光装 rustup target 不够
#   2. ORT 静态链进来的那份 C++ 运行时要 libc++_shared.so, 系统里没有,
#      得自己从 NDK sysroot 推一份过去。不推的话进程根本起不来:
#      CANNOT LINK EXECUTABLE ... library "libc++_shared.so" not found
#      正式 App 里这一步是 Gradle 的 externalNativeBuild 自动做的。
#
# 用法: ./run-android.sh <模型目录> <照片> [--long-edge N]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REMOTE=/data/local/tmp/spike
API="${ANDROID_API:-24}"

if [ $# -lt 2 ]; then
  echo "用法: $0 <模型目录> <照片> [--long-edge N]" >&2
  exit 2
fi
MODELS="$1"; PHOTO="$2"; shift 2

# 没给 NDK 路径就在 SDK 目录里挑一个最新的
NDK="${ANDROID_NDK_HOME:-}"
if [ -z "$NDK" ]; then
  NDK="$(ls -d "${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}"/ndk/* 2>/dev/null | sort -V | tail -1)"
fi
[ -n "$NDK" ] && [ -d "$NDK" ] || { echo "找不到 NDK, 设一下 ANDROID_NDK_HOME" >&2; exit 1; }

HOST_TAG="$(ls "$NDK/toolchains/llvm/prebuilt" | head -1)"   # darwin-x86_64 / linux-x86_64
TC="$NDK/toolchains/llvm/prebuilt/$HOST_TAG"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$TC/bin/aarch64-linux-android$API-clang"
export CC_aarch64_linux_android="$TC/bin/aarch64-linux-android$API-clang"
export AR_aarch64_linux_android="$TC/bin/llvm-ar"

rustup target add aarch64-linux-android >/dev/null
(cd "$HERE" && cargo build --release --target aarch64-linux-android)

BIN="$HERE/target/aarch64-linux-android/release/spike"
CXX="$TC/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so"
echo "二进制 $(du -h "$BIN" | cut -f1), libc++_shared $(du -h "$CXX" | cut -f1)"

adb shell "mkdir -p $REMOTE"
adb push "$BIN" "$CXX" "$REMOTE/" >/dev/null
adb push "$MODELS" "$REMOTE/models" >/dev/null
adb push "$PHOTO" "$REMOTE/photo.png" >/dev/null
adb shell "chmod 755 $REMOTE/spike"

adb shell "cd $REMOTE && LD_LIBRARY_PATH=$REMOTE ./spike models photo.png out.docx $*"
