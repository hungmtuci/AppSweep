#!/bin/bash
set -euo pipefail

# Helper script phát hành nhanh phiên bản mới của AppSweep lên GitHub Releases
# Cách dùng: ./scripts/release_github.sh 1.2.2 "Mô tả tính năng mới"

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

if [ $# -lt 1 ]; then
    echo "Cách dùng: $0 <version> [release_notes]"
    echo "Ví dụ:    $0 1.3.0 \"Tối ưu tốc độ quét sâu & sửa lỗi nhỏ\""
    exit 1
fi

RAW_VER="$1"
CLEAN_VER="${RAW_VER#v}"
TAG="v${CLEAN_VER}"
NOTES="${2:-Phát hành AppSweep ${TAG} cho macOS (Universal Binary arm64 + x86_64).}"

echo "==> [1/4] Cập nhật phiên bản mặc định ${CLEAN_VER} trong build_appsweep.sh..."
sed -i '' "s/^VERSION=\"\${APPSWEEP_VERSION:-[^\"]*}\"/VERSION=\"\${APPSWEEP_VERSION:-${CLEAN_VER}}\"/" build_appsweep.sh

echo "==> [2/4] Biên dịch & đóng gói bộ cài Universal (.dmg & .zip) cho ${TAG}..."
APPSWEEP_VERSION="$CLEAN_VER" ./build_appsweep.sh

echo "==> [3/4] Commit & đẩy tag ${TAG} lên GitHub..."
if [ -n "$(git status --porcelain)" ]; then
    git add -A
    git commit -m "chore(release): bump version to ${TAG}"
fi
git push origin main

if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "Tag $TAG đã tồn tại cục bộ."
else
    git tag -a "$TAG" -m "AppSweep ${TAG}"
fi
git push origin "$TAG"

echo "==> [4/4] Tạo GitHub Release ${TAG} kèm gói cài đặt tự động cập nhật..."
DMG_FILE="dist/AppSweep-Installer-v${CLEAN_VER}.dmg"
ZIP_FILE="dist/AppSweep-v${CLEAN_VER}-macOS.zip"

if gh release view "$TAG" >/dev/null 2>&1; then
    gh release upload "$TAG" "$DMG_FILE" "$ZIP_FILE" --clobber
else
    gh release create "$TAG" "$DMG_FILE" "$ZIP_FILE" \
        --title "AppSweep ${TAG}" \
        --notes "$NOTES"
fi

echo "✓ Đã phát hành thành công: https://github.com/hungmtuci/AppSweep/releases/tag/${TAG}"
