#!/usr/bin/env bash
set -euo pipefail

: "${GAOKUN_DIR:?missing GAOKUN_DIR}"
: "${WORKDIR:?missing WORKDIR}"
: "${KERN_SRC:?missing KERN_SRC}"

KERN_OUT="${KERN_OUT:-$WORKDIR/kernel-out}"
KERN_SRC_BASE="${KERN_SRC_BASE:-$WORKDIR/mainline-linux-base}"
KERN_SRC_EL2="${KERN_SRC_EL2:-$KERN_SRC}"
KERN_OUT_EL2="${KERN_OUT_EL2:-}"
BUILD_EL2="${BUILD_EL2:-false}"

if [[ "$(uname -m)" == "aarch64" ]]; then
  CROSS_COMPILE="${CROSS_COMPILE:-}"
else
  CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
fi

export ARCH=arm64
export CCACHE_DIR="${CCACHE_DIR:-$HOME/.ccache}"
export CCACHE_BASEDIR="${CCACHE_BASEDIR:-$WORKDIR}"
export CCACHE_NOHASHDIR="${CCACHE_NOHASHDIR:-true}"
export CCACHE_COMPILERCHECK="${CCACHE_COMPILERCHECK:-content}"
export PATH="/usr/lib/ccache:$PATH"

configure_git_identity() {
  local repo_dir="$1"
  git -C "$repo_dir" config user.name "github-actions[bot]"
  git -C "$repo_dir" config user.email "github-actions[bot]@users.noreply.github.com"
}

build_variant() {
  local src_dir="$1"
  local out_dir="$2"
  local localversion="${3:-}"

  rm -rf "$out_dir"
  mkdir -p "$out_dir"

  unset KCONFIG_CONFIG
  make -C "$src_dir" O="$out_dir" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" gaokun3_defconfig

  if [[ -n "$localversion" ]]; then
    "$src_dir"/scripts/config --file "$out_dir/.config" --set-str LOCALVERSION "$localversion"
  fi

  make -C "$src_dir" O="$out_dir" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" olddefconfig
  make -C "$src_dir" O="$out_dir" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" -j"$(nproc)"
  make -C "$src_dir" O="$out_dir" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" modules_prepare
}

snapshot_tree() {
  local src_dir="$1"
  local dst_dir="$2"

  rm -rf "$dst_dir"
  mkdir -p "$dst_dir"
  # 只快照工作树：BASE 树仅供后续 modules_install / headers 打包使用（打包脚本均显式排除 .git）。
  # 复制 .git 会把后台 git gc 正在重整的对象卷进竞态，也白白多拷约 1GB
  rsync -a --exclude '.git' "$src_dir"/ "$dst_dir"/
}

mkdir -p "$WORKDIR"

configure_git_identity "$KERN_SRC"
git -C "$KERN_SRC" am "$GAOKUN_DIR"/patches/upstream/*.patch
git -C "$KERN_SRC" am "$GAOKUN_DIR"/patches/others/*.patch
git -C "$KERN_SRC" am "$GAOKUN_DIR"/patches/media/*.patch
# QSEECOM TEE 前端(指纹路线前置): 基于 v7.2.5 干净树, 独立于 gaokun3 DTS, 须在 0099 之前应用
git -C "$KERN_SRC" am "$GAOKUN_DIR"/patches/qseecom-tee/*.patch
git -C "$KERN_SRC" am "$GAOKUN_DIR"/patches/0099-arm64-gaokun3-import-local-dts-and-defconfig.patch
# 0100 基于社区 DTS(0099 之后)的触屏上下文, 必须在 0099 之后应用, 因此与其并列放 patches/ 根
git -C "$KERN_SRC" am "$GAOKUN_DIR"/patches/0100-arm64-dts-qcom-sc8280xp-huawei-gaokun3-select-SPI-mode-for-touchscreen.patch
# 0101 给 SCM 绑定专属 CMA, 供 QSEECOM TEE 加载 TA 的 staging 大块连续内存, 基于 0100 之后的 DTS
git -C "$KERN_SRC" am "$GAOKUN_DIR"/patches/0101-arm64-dts-qcom-sc8280xp-huawei-gaokun3-add-QSEECOM-CMA-for-TA-staging.patch
# 0102 放宽 SCM 设备 DMA mask 到 64 位, 否则 16GiB 机型上 CMA 池(4GiB 以上)被 dma_coherent_ok 拒收, staging 分配静默失败
git -C "$KERN_SRC" am "$GAOKUN_DIR"/patches/0102-firmware-qcom-scm-widen-dma-mask-for-tz-memory.patch
# 0103/0104 诊断: 加载 fingerpr TA 时 APP_START 被 TZ 以 SMC 级错误拒绝, 但 remap_error 默认分支把未知负码一律映射为 -EINVAL,
# 同时镜像物理地址无日志, 无法区分地址(高位 CMA)与参数(arginfo)问题. 定位后移除
git -C "$KERN_SRC" am "$GAOKUN_DIR"/patches/0103-firmware-qcom-scm-log-raw-smc-result.patch
git -C "$KERN_SRC" am "$GAOKUN_DIR"/patches/0104-tee-qseecom-log-staging-image-phys.patch
# 0105 诊断实锤: 动态分配 CMA 落到 34GiB 孤岛(0x87f000000), TZ 拒绝孤岛地址(APP_START 与 uefisecapp APP_SEND 双证, a0=-2),
# 固定 CMA 到主 DDR 空闲窗口 0xc8600000(16MiB 对齐, <4GiB). 0103/0104 保留至 TA 加载成功后再移除
git -C "$KERN_SRC" am "$GAOKUN_DIR"/patches/0105-arm64-dts-qcom-sc8280xp-huawei-gaokun3-pin-qseecom-cma-below-4gib.patch

ccache -z || true
build_variant "$KERN_SRC" "$KERN_OUT"
ccache -s || true

BASE_KREL="$(cat "$KERN_OUT/include/config/kernel.release")"
echo "$BASE_KREL" > "$WORKDIR/kernel-release.txt"

snapshot_tree "$KERN_SRC" "$KERN_SRC_BASE"

if [[ "$BUILD_EL2" != "true" ]]; then
  exit 0
fi

: "${KERN_OUT_EL2:?missing KERN_OUT_EL2}"

configure_git_identity "$KERN_SRC_EL2"
rm -rf "$KERN_OUT_EL2"
make -C "$KERN_SRC_EL2" O="$KERN_OUT_EL2" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" clean
git -C "$KERN_SRC_EL2" apply "$GAOKUN_DIR"/patches/el2/*.patch
git -C "$KERN_SRC_EL2" add -A
git -C "$KERN_SRC_EL2" commit -m "Apply EL2 patches"

ccache -z || true
build_variant "$KERN_SRC_EL2" "$KERN_OUT_EL2" "-gaokun3-el2"
ccache -s || true

EL2_KREL="$(cat "$KERN_OUT_EL2/include/config/kernel.release")"
echo "$EL2_KREL" > "$WORKDIR/kernel-release-el2.txt"
