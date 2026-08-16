#!/usr/bin/env bash
# 把三个 ONNX 模型放进 assets/models/
#
# 模型 32 MB, 不进仓库(见根目录 .gitignore), 但 App 又必须带着它们 —— 所以
# 构建前跑一次这个脚本。默认从桌面版仓库拿, 也可以传一个目录进来。
#
#   ./tool/models.sh                       # 从 ../../ScannedPdf2doc/models 拿
#   ./tool/models.sh /path/to/models       # 从别处拿
set -euo pipefail

cd "$(dirname "$0")/.."
SRC="${1:-$(cd .. && pwd)/../ScannedPdf2doc/models}"
DST="assets/models"

NEEDED=(
  PP-OCRv6_det_small.onnx
  PP-OCRv6_rec_small.onnx
  ch_ppocr_mobile_v2.0_cls_mobile.onnx
)

if [ ! -d "$SRC" ]; then
  echo "找不到模型目录: $SRC" >&2
  echo "把三个 .onnx 放一个目录里, 然后 ./tool/models.sh <那个目录>" >&2
  exit 1
fi

mkdir -p "$DST"
for f in "${NEEDED[@]}"; do
  if [ ! -f "$SRC/$f" ]; then
    echo "缺 $f" >&2
    exit 1
  fi
  cp -f "$SRC/$f" "$DST/$f"
  printf '  %-42s %s\n' "$f" "$(du -h "$DST/$f" | cut -f1)"
done
echo "模型已就位: $DST"
