#!/bin/sh
# 在 Alpine ARM64 Docker 容器内运行
# 环境变量: NODE_VER (目标版本号), /output (输出目录)
set -e

apk add --no-cache nodejs npm xz icu-data-full

ACTUAL_VER=$(node --version | sed 's/^v//')
echo "Alpine Node.js version: v${ACTUAL_VER} (requested: v${NODE_VER})"

# 打包为 portable tarball (与官方 tarball 相同结构)
PKG_NAME="node-v${NODE_VER}-linux-arm64-musl"
PKG_DIR="/tmp/${PKG_NAME}"
mkdir -p "${PKG_DIR}/bin" "${PKG_DIR}/lib/node_modules" "${PKG_DIR}/include/node"

# 复制 node 二进制
cp "$(which node)" "${PKG_DIR}/bin/node.bin"
chmod +x "${PKG_DIR}/bin/node.bin"

# 收集 node 依赖的所有共享库 (Alpine node 是动态链接的)
echo "=== Collecting shared libraries ==="
LIB_DIR="${PKG_DIR}/lib"
ldd "$(which node)" 2>/dev/null | while read -r line; do
  # 解析 ldd 输出: libxxx.so => /usr/lib/libxxx.so (0x...)
  lib_path=$(echo "$line" | grep -oE '/[^ ]+\.so[^ ]*' | head -1)
  if [ -n "$lib_path" ] && [ -f "$lib_path" ]; then
    cp -L "$lib_path" "$LIB_DIR/" 2>/dev/null || true
    echo "  + $(basename "$lib_path")"
  fi
done
# 确保 musl 动态链接器也在
if [ -f /lib/ld-musl-aarch64.so.1 ]; then
  cp -L /lib/ld-musl-aarch64.so.1 "$LIB_DIR/" 2>/dev/null || true
  echo "  + ld-musl-aarch64.so.1"
fi
echo "Libraries collected: $(ls "$LIB_DIR"/*.so* 2>/dev/null | wc -l) files"

# 复制 ICU 完整数据 (npm 的 Intl.Collator 需要)
echo "=== Copying ICU data ==="
ICU_DAT=$(find /usr/share/icu -name "icudt*.dat" 2>/dev/null | head -1)
if [ -n "$ICU_DAT" ] && [ -f "$ICU_DAT" ]; then
  mkdir -p "${PKG_DIR}/share/icu"
  cp "$ICU_DAT" "${PKG_DIR}/share/icu/"
  echo "  + $(basename "$ICU_DAT") ($(du -h "$ICU_DAT" | cut -f1))"
else
  echo "  WARNING: ICU data file not found"
fi

# 创建 node wrapper 脚本 (使用打包的 musl 链接器，避免系统 musl 版本不兼容)
cat > "${PKG_DIR}/bin/node" << 'NODEWRAPPER'
#!/bin/sh
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="${SELF_DIR}/../lib"
export NODE_ICU_DATA="${SELF_DIR}/../share/icu"
exec "${LIB_DIR}/ld-musl-aarch64.so.1" --library-path "${LIB_DIR}" "${SELF_DIR}/node.bin" "$@"
NODEWRAPPER
chmod +x "${PKG_DIR}/bin/node"

# 复制 npm
if [ -d /usr/lib/node_modules/npm ]; then
  cp -r /usr/lib/node_modules/npm "${PKG_DIR}/lib/node_modules/"
fi

# 创建 npm wrapper
cat > "${PKG_DIR}/bin/npm" << 'NPMWRAPPER'
#!/bin/sh
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="${SELF_DIR}/../lib"
export NODE_ICU_DATA="${SELF_DIR}/../share/icu"
exec "${LIB_DIR}/ld-musl-aarch64.so.1" --library-path "${LIB_DIR}" "${SELF_DIR}/node.bin" "${LIB_DIR}/node_modules/npm/bin/npm-cli.js" "$@"
NPMWRAPPER
# 创建 npx wrapper
cat > "${PKG_DIR}/bin/npx" << 'NPXWRAPPER'
#!/bin/sh
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="${SELF_DIR}/../lib"
export NODE_ICU_DATA="${SELF_DIR}/../share/icu"
exec "${LIB_DIR}/ld-musl-aarch64.so.1" --library-path "${LIB_DIR}" "${SELF_DIR}/node.bin" "${LIB_DIR}/node_modules/npm/bin/npx-cli.js" "$@"
NPXWRAPPER
chmod +x "${PKG_DIR}/bin/npm" "${PKG_DIR}/bin/npx"

# 验证
echo "=== Verification ==="
"${PKG_DIR}/bin/node" --version
"${PKG_DIR}/bin/node" -e "console.log(process.arch, process.platform, process.versions.modules)"
"${PKG_DIR}/bin/npm" --version 2>/dev/null || echo "npm wrapper created"

# 打包
cd /tmp
tar cJf "/output/${PKG_NAME}.tar.xz" "${PKG_NAME}"
ls -lh "/output/${PKG_NAME}.tar.xz"
echo "=== Done: ${PKG_NAME}.tar.xz ==="
