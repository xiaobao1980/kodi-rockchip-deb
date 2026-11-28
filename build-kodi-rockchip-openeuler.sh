#!/usr/bin/env bash
#===============================================================================
# build-kodi-rockchip-openeuler.sh  v1.0
# 在 openEuler 24.03 (aarch64, RK35xx vendor 内核 6.1.x) 一键编译：
#   rockchip-mpp + rockchip-rga + dav1d + libdisplay-info + ffmpeg-rockchip + Kodi(Piers 22.x, GBM/GLES)
#   + shadertoy 视觉/屏保 + 二进制插件(vfs.rar/libarchive/inputstream.*/peripheral.joystick/pvr.iptvsimple)
#   + Jellyfin 仓库插件
# 全部装入 /usr/local 自闭环；从同一份 staging 树产出两类安装包：
#   * .rpm   —— openEuler 24.03（rpmbuild）
#   * .deb   —— Debian 系：deepin 25 / trixie / forky / resolute / noble（dpkg-deb，跨发行版通用）
#   * tar.gz —— 可选，跨发行版裸机分发（沿用参考范式）
# 设计原则：
#   * glibc 就低不就高——在 openEuler(glibc 2.38) 构建，新 glibc 目标可直接跑（反向不行）
#   * 全部依赖打进 /usr/local，与系统 ffmpeg 完全并行，不污染
#   * kodi-gbm / ffmpeg / ffprobe 以 RUNPATH=/usr/local/lib 链接，目标机无需 LD_LIBRARY_PATH
#   * 参考上游 armsurvivors/kodi-rockchip-deb（Dockerfile.kodi），把 apt/debuild 改写为 dnf/rpmbuild/dpkg-deb
#
# 用法：
#   FLAVOR=rkmpp            BUILD_RPM=yes BUILD_DEB=yes ./build-kodi-rockchip-openeuler.sh
#   FLAVOR=v4l2requests    BUILD_DEB=yes ./build-kodi-rockchip-openeuler.sh
#   SKIP_MPP_CHECK=1 ./build-kodi-rockchip-openeuler.sh     # 纯编译（CI 容器无 /dev/mpp_service）
#===============================================================================
set -euo pipefail

#------------------------- 可调版本（全部锁死，勿漂） -------------------------
KODI_BRANCH="Piers"                 # Kodi 22.x 发布分支
DAV1D_VER="1.5.4"                   # AV1 软解兜底
MESA_VER="24.3.4"                   # openEuler 自带 mesa 无 panfrost，见 Step 3.6
# rkmpp（vendor 内核）线
MPP_REPO="https://github.com/nyanmisaka/mpp.git"
MPP_BRANCH="jellyfin-mpp"
RGA_REPO="https://github.com/nyanmisaka/rk-mirrors.git"
RGA_BRANCH="jellyfin-rga"
FF_REPO_RKMPP="https://github.com/nyanmisaka/ffmpeg-rockchip.git"
FF_BRANCH_RKMPP="8.1"
# v4l2requests（mainline 内核）线
FF_REPO_V4L2="https://github.com/FFmpeg/FFmpeg.git"
FF_BRANCH_V4L2="n9.0.2"

#------------------------- 路径 ----------------------------------------------
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="/opt/kodi-rockchip-build"      # 源码与中间产物
STAGE="$WORK/root"                  # staging 根，内含 usr/local
PREFIX="/usr/local"                 # 所有组件统一前缀
# 自带 mesa 的落脚点：故意不放 $PREFIX/lib|lib64——openEuler 的 /etc/ld.so.conf 第一行就是
# /usr/local/lib64，GL 库丢进去等于给全系统多出第二个 libEGL.so.1。走 mpv 线同款的"兜底目录"
# 方案：只靠 kodi-gbm/ffmpeg 的 RUNPATH 命中；mesa 的 prefix 必须是这个目录本身，因为 DRI
# 搜索路径与 gbm backend 目录是编译期写死的。
GLFALL="$PREFIX/share/kodi-rockchip/glfallback"
OUT="${OUT:-$SRC/out}"             # 最终包输出目录
JOBS="$(nproc)"

# openEuler 是 lib64 体系：pkg-config 默认搜索路径不含 /usr/local/lib/pkgconfig（它找 lib64 那套），
# 显式加入以便 ffmpeg/kodi 的 configure/cmake 找到我们装到 /usr/local 的 dav1d/mpp/rga。
export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:/usr/local/lib64/pkgconfig:${PKG_CONFIG_PATH:-}"

#------------------------- 开关 ----------------------------------------------
FLAVOR="${FLAVOR:-rkmpp}"           # rkmpp (vendor) | v4l2requests (mainline)
BUILD_RPM="${BUILD_RPM:-yes}"       # 产 .rpm（openEuler）
BUILD_DEB="${BUILD_DEB:-yes}"       # 产 .deb（Debian 系跨发行版）
BUILD_TAR="${BUILD_TAR:-no}"        # 产 tar.gz（裸机跨发行版分发，可选）
PKG_VERSION="${PKG_VERSION:-$(date +%Y%m%d)}"

log()  { printf '\033[1;32m[BUILD]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }
gate() { printf '\033[1;34m[GATE]\033[0m %s\n' "$*"; }

#------------------------- 风味参数 ------------------------------------------
case "${FLAVOR}" in
  rkmpp)
    FF_REPO="$FF_REPO_RKMPP"; FF_BRANCH="$FF_BRANCH_RKMPP"; FFMPEG_ID="81rkmpp"
    FFMPEG_DECODERS="h264 hevc vp9 av1 libdav1d h264_rkmpp hevc_rkmpp vp9_rkmpp av1_rkmpp"
    KODI_PATCH_SETS=(common)
    # ffmpeg-rockchip 的 rkmpp/rkrga 解码器
    FF_CONFIG=(--enable-gpl --enable-version3 --enable-libdrm --enable-rkmpp --enable-rkrga --enable-libdav1d --enable-gnutls)
    MPP_RGA=yes
    ;;
  v4l2requests)
    FF_REPO="$FF_REPO_V4L2"; FF_BRANCH="$FF_BRANCH_V4L2"; FFMPEG_ID="902v4l2requests"
    FFMPEG_DECODERS="h264 hevc vp9 av1 libdav1d h264_v4l2m2m hevc_v4l2m2m vp9_v4l2m2m"
    KODI_PATCH_SETS=(common drmprime-filter)
    FF_CONFIG=(--enable-gpl --enable-version3 --enable-libdrm --enable-libdav1d --enable-v4l2_m2m --enable-gnutls)
    MPP_RGA=no
    ;;
  *) die "FLAVOR 必须是 rkmpp 或 v4l2requests，得到 '${FLAVOR}'" ;;
esac

#------------------------- Step 0 前置检查 ------------------------------------
log "Step 0/14 前置检查"
[ "$(uname -m)" = "aarch64" ] || die "仅支持 arm64 原生构建（无交叉编译）"
if [ "${FLAVOR}" = "rkmpp" ] && [ "${SKIP_MPP_CHECK:-0}" != "1" ]; then
  ls /dev/mpp_service >/dev/null 2>&1 || die "无 /dev/mpp_service，本机不是 vendor 内核；mainline 请走 v4l2requests 线（纯编译可 SKIP_MPP_CHECK=1）"
fi
# 不用 head -1：pipefail 下 head 提前收工会让 ldd（本身是 shell 脚本，分多次写）吃到 SIGPIPE，
# 整条管道以 141 退出并被 set -e 杀掉，且只在写第二行赶在 head 退出之后时复现——时好时坏的源头。
# awk 读完全部输入才退出，不存在这个问题。
glibc_ver=$(ldd --version 2>/dev/null | awk 'NR==1{print $NF}')
case "$glibc_ver" in
  *[0-9]*) ;;
  *) die "取不到构建机 glibc 版本（ldd --version 输出异常）" ;;
esac
log "构建机 glibc = $glibc_ver（须为三目标中最低，当前 openEuler 24.03 = 2.38）"
command -v dnf >/dev/null || die "本脚本按 openEuler/dnf 编写"
[ "${BUILD_RPM}" = "yes" ] && { command -v rpmbuild >/dev/null || dnf install -y rpm-build >/dev/null 2>&1 || die "需要 rpmbuild（dnf install rpm-build）"; }
[ "${BUILD_DEB}" = "yes" ] && { command -v dpkg-deb >/dev/null || dnf install -y dpkg >/dev/null 2>&1 || die "需要 dpkg-deb（dnf install dpkg）"; }
mkdir -p "$WORK" "$STAGE$PREFIX" "$OUT"

#------------------------- Step 1 依赖 ----------------------------------------
log "Step 1/14 安装编译依赖（dnf）"
# openEuler/RHEL 命名习惯：devel 包名通常就是项目名（xz-devel / avahi-devel），
# 不是 Debian 的 lib<名>-dev。dnf_install 逐个校验可用性：有的才装，没有的记下来继续，
# 一次运行即可暴露全部包名问题，避免“一遇错包整批中断”。
dnf_install() {
  local avail=() missing=()
  for p in "$@"; do
    if dnf -q list --available "$p" >/dev/null 2>&1; then
      avail+=("$p")
    else
      missing+=("$p")
      log "  [缺失] $p（仓库无此名，跳过；若 Kodi 对应功能需要，请改 cmake 关闭）"
    fi
  done
  if [ ${#avail[@]} -gt 0 ]; then
    dnf install -y "${avail[@]}" >/dev/null 2>&1 || die "核心依赖 dnf install 失败，请检查上面输出"
  fi
  if [ ${#missing[@]} -gt 0 ]; then
    printf '%s\n' "${missing[@]}" > "$WORK/missing-deps.txt"
    log "  [汇总] 缺失包已写入 $WORK/missing-deps.txt"
  fi
}

# 核心工具链 + Kodi 编译必需（缺失即致命）
dnf_install \
  gcc gcc-c++ make cmake meson ninja-build git pkgconf \
  nasm yasm gperf bison gettext autoconf automake libtool patch \
  wget curl zip unzip tar bzip2 rsync python3 python3-devel python3-pip \
  patchelf tree gawk \
  zlib-devel bzip2-devel xz-devel libtool-devel \
  libdrm-devel hwdata \
  alsa-lib-devel pulseaudio-libs-devel libass-devel freetype-devel fribidi-devel fontconfig-devel harfbuzz-devel \
  libjpeg-turbo-devel libpng-devel libtiff-devel giflib-devel \
  libogg-devel libvorbis-devel flac-devel \
  openssl-devel gnutls-devel libgcrypt-devel libgpg-error-devel \
  sqlite-devel taglib-devel libzip-devel libxml2-devel libxslt-devel pcre2-devel \
  util-linux-devel libunistring-devel libcurl-devel \
  libX11-devel libXext-devel libXrandr-devel libXinerama-devel libXv-devel libXt-devel \
  libxkbcommon-devel wayland-devel wayland-protocols-devel \
  mesa-libEGL-devel libglvnd-devel mesa-libgbm-devel mesa-libGL-devel mesa-libGLU-devel \
  libinput-devel dbus-devel systemd-devel \
  avahi-devel bluez-devel exiv2-devel libplist-devel libbluray-devel libcdio-devel \
  rapidjson-devel nlohmann-json-devel spdlog-devel fmt-devel lcms2-devel lzo-devel \
  libarchive-devel libmicrohttpd-devel tinyxml-devel tinyxml2-devel \
  libnfs-devel samba-devel
# Step 3.6 自带 mesa 还需要这些（zstd-devel 目前由 llvm-devel 带进来，显式写出不靠隐式依赖）
dnf_install llvm-devel zstd-devel byacc flex expat-devel libuuid-devel libcap-devel \
  python3-mako python3-ply python3-pyyaml
# 下列“风险包”缺失不致命（CI/构建时按需关闭对应 Kodi 功能）
for p in libcec-devel lirc-devel mariadb-devel rtmpdump-devel lame-devel enca-devel; do
  dnf -q list --available "$p" >/dev/null 2>&1 && dnf install -y "$p" >/dev/null 2>&1 && log "  已装可选包 $p" || log "  [跳过] 可选包 $p 缺失（对应 Kodi 功能将关闭）"
done

#------------------------- Step 2 libdisplay-info（Kodi GBM 硬依赖）-----------
log "Step 2/14 编译 libdisplay-info"
cd "$WORK"
[ -d libdisplay-info ] || git clone --depth 1 https://gitlab.freedesktop.org/emersion/libdisplay-info.git
rm -rf build-libdisplay-info
meson setup build-libdisplay-info libdisplay-info --prefix="$PREFIX" --libdir=lib --buildtype=release
ninja -C build-libdisplay-info install

#------------------------- Step 3 dav1d ---------------------------------------
log "Step 3/14 编译 dav1d ($DAV1D_VER)"
cd "$WORK"
[ -d "dav1d-$DAV1D_VER" ] || { curl -LO "https://code.videolan.org/videolan/dav1d/-/archive/$DAV1D_VER/dav1d-$DAV1D_VER.tar.gz"; tar xf "dav1d-$DAV1D_VER.tar.gz"; }
rm -rf "build-dav1d"
meson setup "build-dav1d" "dav1d-$DAV1D_VER" --prefix="$PREFIX" --libdir=lib --buildtype=release --default-library=shared -Denable_tools=false -Denable_tests=false
ninja -C build-dav1d install

#------------------------- Step 3.5 pugixml（Kodi 硬依赖；openEuler 不打包）---
log "Step 3.5/14 编译 pugixml（源码）"
cd "$WORK"
[ -d pugixml ] || git clone --depth 1 https://github.com/zeux/pugixml.git
rm -rf build-pugixml
cmake -S pugixml -B build-pugixml -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON
cmake --build build-pugixml -j"$JOBS"
cmake --install build-pugixml

#------------------------- Step 3.6 mesa + panfrost ----------------------------
# openEuler 24.03 自带 mesa 24.0.3 不编 panfrost DRI 驱动：Kodi GBM 在瑞芯微板上只能落到 llvmpipe，
# 整个 UI 全软件渲染（4K 下一个核打满、肉眼可见卡顿）。Debian/Ubuntu 的 mesa 有 panfrost，所以只有
# openEuler 这条线需要自带 GL 栈，仍按本项目惯例装进 $PREFIX。
# 选 24.3 而非 25.x：25.2 把 panfrost 挪到 CLC 预编译着色器路径，需要 SPIRV-Tools >= 2024.1，
# 而 openEuler 只有 2023.2.1。shared-llvm=disabled 让 LLVM 静态链进驱动，产物不依赖 libLLVM.so.<版本>
# ——那个 soname 每换一个发行版都不一样，正是本包要跨发行版装的地方。
log "Step 3.6/14 编译 mesa ${MESA_VER}（panfrost 硬件渲染）"
cd "$WORK"
[ -f "mesa-${MESA_VER}.tar.xz" ] || curl -LO "https://archive.mesa3d.org/mesa-${MESA_VER}.tar.xz"
tar xf "mesa-${MESA_VER}.tar.xz"
cd "mesa-${MESA_VER}"
rm -rf build
# LLVM 静态编进 gallium 的编译单元很吃内存：RK3576 板（3.9G）上 nproc 全开会 OOM，实测 4 并发才稳。
# 按“1G 内存 1 个并发”限流，再和核数取小，构建机大小都跑得动。
MESA_JOBS="$(awk -v n="$JOBS" '/MemTotal/{j=int($2/1048576); if (j<1) j=1; if (j<n) n=j; exit} END{print n}' /proc/meminfo)"
log "  mesa 并发：$MESA_JOBS（内存限流，核数 $JOBS）"
meson setup build --prefix="$GLFALL" --libdir=lib --buildtype=release -Dplatforms= -Degl=enabled -Degl-native-platform=drm -Dgbm=enabled -Dgles1=disabled -Dgles2=enabled -Dopengl=false -Dgallium-drivers=panfrost,llvmpipe -Dvulkan-drivers= -Dglvnd=disabled -Dllvm=enabled -Dshared-llvm=disabled -Dvalgrind=disabled -Dlibunwind=disabled -Dzstd=enabled -Dxmlconfig=enabled -Dvideo-codecs= -Dgallium-va=disabled -Dgallium-vdpau=disabled -Dbuild-tests=false
ninja -C build -j"$MESA_JOBS"
ninja -C build install

# mesa 只在 src/gallium/targets/dril 里生成 panfrost_dri.so / swrast_dri.so 这些“按驱动命名”的入口，
# 而 src/meson.build 只有在 with_glx=='dri' 或启用了 x11/xcb 平台时才编那个子目录。这里是纯 GBM 构建，
# 所以按 dril 出现之前 mesa 自己的老办法摆：dri/<驱动>_dri.so -> ../libgallium-<版本>.so。
# GBM 只会按这些确切名字 dlopen，缺了 dri/ 目录 Kodi 就绑不上驱动、又掉回 llvmpipe（正是这一步要解决的问题）。
# 一个 megadriver 里已编入所有 -Dgallium-drivers 的驱动，所以每个名字一条软链就够。
# 已在 RK3576 板实测：这么摆之后 GL_RENDERER = "Mali-G52 r1 (Panfrost)"。
mkdir -p "$GLFALL/lib/dri"
for drv in panfrost swrast kms_swrast; do
  ln -sf "../libgallium-${MESA_VER}.so" "$GLFALL/lib/dri/${drv}_dri.so"
done

# 门禁：Kodi GBM 需要的 EGL/GLES2/GBM/panfrost 必须真的落到 $GLFALL/lib，且不得外连发行版 LLVM。
# 用通配而不是写死 libEGL.so.1：mesa 装的是带版本的实体（libEGL.so.1.0.0），soname 那层是软链。
for f in libEGL libGLESv2 libgbm; do
  compgen -G "$GLFALL/lib/${f}.so*" > /dev/null || die "mesa 未安装 ${f}.so*"
done
[ -e "$GLFALL/lib/dri/panfrost_dri.so" ] || die "mesa 未摆出 dri/panfrost_dri.so"
# 只挑实体文件：对着软链（含我们自己摆的 dri/*_dri.so）跑 patchelf，会被"临时文件 + rename"
# 换成一份 66M 实体顶掉链接；而 mesa 的实体名字带版本号，按 libEGL.so.1 这种写法枚举只会命中软链，
# 真正的 ELF 反而没打上 RUNPATH——解包到目标机就找不到 libgallium，又掉回 llvmpipe。
patched=0
while IFS= read -r f; do
  if readelf -d "$f" | grep -qE "NEEDED +(libLLVM|libclc|libSPIRV)"; then
    die "$f 依赖发行版 LLVM/SPIRV，shared-llvm=disabled 未生效"
  fi
  # meson 安装时会清掉 build rpath，而兜底目录刻意不进 ld.so.conf：
  # 解包到目标机后驱动只能靠 RUNPATH 找到 libgallium。
  patchelf --set-rpath "$GLFALL/lib" "$f"
  readelf -d "$f" | grep -qF RUNPATH || die "$f 未能写入 RUNPATH"
  patched=$((patched + 1))
done < <(find "$GLFALL/lib" -type f -name '*.so*' | sort)
# EGL + GLESv2 + GBM + libgallium 至少四个实体文件，一个都没打上就是枚举写错了。
[ "$patched" -ge 4 ] || die "兜底 GL 只打上 $patched 个 RUNPATH，实体库枚举有问题"
# 刻意不跑 ldconfig：这套 GL 必须对系统加载器保持不可见，只有 Kodi/ffmpeg 的 RUNPATH 指得到它。
log "  mesa 实体库：$(find "$GLFALL/lib" -type f -name '*.so*' -printf '%f ')"
log "  mesa 驱动：$(ls "$GLFALL"/lib/dri | tr '\n' ' ')"

#------------------------- Step 4/5 mpp + rga（仅 rkmpp 线）-------------------
if [ "$MPP_RGA" = "yes" ]; then
  log "Step 4/14 编译 rockchip-mpp ($MPP_BRANCH)"
  cd "$WORK"
  [ -d mpp ] || git clone --depth 1 --branch "$MPP_BRANCH" "$MPP_REPO" mpp
  rm -rf mpp/rkmpp_build
  # 注意：源码树是 mpp/，rkmpp_build 只是 cmake 自建的构建目录（上游同款写法）
  cmake -S mpp -B mpp/rkmpp_build -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON -DBUILD_TEST=OFF
  cmake --build mpp/rkmpp_build -j"$JOBS"
  cmake --install mpp/rkmpp_build

  log "Step 5/14 编译 rockchip-rga ($RGA_BRANCH)"
  cd "$WORK"
  [ -d rkrga ] || git clone --depth 1 --branch "$RGA_BRANCH" "$RGA_REPO" rkrga
  rm -rf build-rga
  meson setup rkrga build-rga --prefix="$PREFIX" --libdir=lib --buildtype=release --default-library=shared -Dcpp_args=-fpermissive -Dlibdrm=false -Dlibrga_demo=false
  ninja -C build-rga install
fi

#------------------------- Step 6 ffmpeg ---------------------------------------
log "Step 6/14 编译 ffmpeg ($FF_BRANCH)"
cd "$WORK"
[ -d ffmpeg ] || git clone --depth 1 --branch "$FF_BRANCH" "$FF_REPO" ffmpeg
cd ffmpeg
if [ "$FLAVOR" = "v4l2requests" ]; then
  # V4L2 无状态解码头文件门禁（仅 mainline 线）
  log "  V4L2 stateless 头文件检查"
  miss=0
  for sym in V4L2_CID_STATELESS_H264_DECODE_MODE V4L2_CID_STATELESS_HEVC_SPS V4L2_CID_STATELESS_VP9_FRAME V4L2_CID_STATELESS_AV1_SEQUENCE; do
    printf '#include <linux/videodev2.h>\nint i = %s;\n' "$sym" | gcc -x c -c - -o /dev/null 2>/dev/null \
      && log "    [OK] $sym" || { log "    [FAIL] $sym"; miss=$((miss+1)); }
  done
  [ "$miss" -eq 0 ] || die "V4L2 stateless 符号缺失，linux 头文件过旧"
  # 0017 号补丁（HEVC sps_st_rps）编译期需要 6.10+ 才有的 HEVC-EXT uAPI；openEuler 24.03 只有 6.6 头文件。
  # 不在这里拦，就要等 ffmpeg 编到一半刷出一屏 undeclared 报错才知道。
  printf '#include <linux/videodev2.h>\nint i = V4L2_CID_STATELESS_HEVC_EXT_SPS_ST_RPS;\n' | gcc -x c -c - -o /dev/null 2>/dev/null ||
    die "内核头文件缺 HEVC-EXT 无状态符号（V4L2_CID_STATELESS_HEVC_EXT_SPS_ST_RPS，需 >= 6.10；本机是 $(rpm -q kernel-headers 2>/dev/null || echo unknown)），打不过 patches/ffmpeg/v4l2requests/9.0.2/0017-*.patch。openEuler 请用 FLAVOR=rkmpp（rk35xx vendor 内核）；mainline 内核硬解请走 Debian/Ubuntu 构建线。"
  for p in "$SRC"/patches/ffmpeg/v4l2requests/"${FF_BRANCH#n}"/*.patch; do
    [ -f "$p" ] && { log "  应用 $(basename "$p")"; patch -p1 < "$p"; }
  done
fi
./configure --prefix="$PREFIX" --enable-shared --disable-static --enable-rpath "${FF_CONFIG[@]}" \
  || die "ffmpeg configure 失败"
make -j"$JOBS"
make install
# 把刚装到 /usr/local 的库纳入链接器缓存（openEuler 默认不搜 /usr/local/lib）
echo '/usr/local/lib' >/etc/ld.so.conf.d/usrlocal.conf 2>/dev/null
ldconfig 2>/dev/null || true

# ffmpeg 解码器门禁（与上游一致：确认本风味硬解解码器已编入）
log "  ffmpeg 解码器自检"
DECODERS_TXT=$(LD_LIBRARY_PATH="$PREFIX/lib:$PREFIX/lib64" "$PREFIX/bin/ffmpeg" -hide_banner -decoders 2>/tmp/ff-dec.err)
if [ -z "$DECODERS_TXT" ]; then
  log "  [WARN] ffmpeg -decoders 无输出，疑似运行时库缺失："
  sed 's/^/    /' /tmp/ff-dec.err | tail -20
  log "    ldd $PREFIX/bin/ffmpeg :"
  ldd "$PREFIX/bin/ffmpeg" 2>&1 | grep -i "not found" | sed 's/^/    /' || true
fi
miss=""
for d in $FFMPEG_DECODERS; do
  printf '%s\n' "$DECODERS_TXT" | grep -qw "$d" || miss="$miss $d"
done
[ -z "$miss" ] || die "ffmpeg 解码器不全，缺:$miss"

#------------------------- Step 7 Kodi ----------------------------------------
log "Step 7/14 编译 Kodi ($KODI_BRANCH, GBM/GLES)"
cd "$WORK"
[ -d kodi ] || git clone --depth 1 --branch "$KODI_BRANCH" https://github.com/xbmc/xbmc.git kodi
cd kodi
for s in "${KODI_PATCH_SETS[@]}"; do
  for p in "$SRC"/patches/kodi/"$s"/*.patch; do
    [ -f "$p" ] && { log "  应用 kodi 补丁 $(basename "$p")"; patch -p1 < "$p"; }
  done
done
# GIT_VERSION：只允许 [A-Za-z0-9._-]，用于 Kodi “Git:” 行区分风味
KODI_COMMIT="$(git log -1 --date=format:%Y%m%d --format=%cd-%h)"
GIT_VERSION="${KODI_COMMIT}-${FLAVOR}-ffmpeg-${FF_BRANCH}-openeuler-build-${PKG_VERSION}"
KODI_REV="$(git rev-parse --short=10 HEAD)"
FF_REV="$(git -C "$WORK/ffmpeg" rev-parse --short=10 HEAD 2>/dev/null || echo unknown)"
rm -rf build-kodi
# openEuler 的 harfbuzz-devel 自带的 cmake config 损坏（find_package CONFIG 读取即报
# “Error reading CMake code”，且不会回退 pkg-config）。删除该系统 cmake config，
# 让 Kodi 的 SEARCH_EXISTING_PACKAGES 回退到 pkg-config（harfbuzz.pc 正常）。
rm -f /usr/lib64/cmake/harfbuzz/*.cmake /usr/lib/cmake/harfbuzz/*.cmake 2>/dev/null || true
# 可选功能：AIRPLAY/WII/OPTICAL 关闭以避开 openEuler 可能缺失的 -devel；
# openEuler 无 libcec/liblirc/libenca/pulseaudio-devel，对应功能显式关闭（Kodi 默认开启且缺失即报错）；
# FSTRCMP 在 openEuler 无 libfstrcmp-dev，改用 Kodi 内部构建。
cmake -S . -B build-kodi \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCORE_PLATFORM_NAME=gbm -DAPP_RENDER_SYSTEM=gles \
  -DENABLE_OPENGL=OFF -DENABLE_VAAPI=OFF -DENABLE_VDPAU=OFF \
  -DENABLE_INTERNAL_FMT=ON -DENABLE_INTERNAL_FLATBUFFERS=ON \
  -DENABLE_INTERNAL_TAGLIB=ON -DENABLE_INTERNAL_SWIG=ON -DENABLE_INTERNAL_CROSSGUID=ON \
  -DENABLE_INTERNAL_FSTRCMP=ON \
  -DENABLE_AIRPLAY=OFF -DENABLE_WII=OFF -DENABLE_OPTICAL=OFF \
  -DENABLE_CEC=OFF -DENABLE_LIRC=OFF -DENABLE_ENCA=OFF -DENABLE_PULSEAUDIO=OFF \
  -DENABLE_TESTING=OFF \
  -DCMAKE_PREFIX_PATH="$PREFIX" \
  -DGIT_VERSION="$GIT_VERSION"
cmake --build build-kodi -- -j"$JOBS" || cmake --build build-kodi -- -j"$JOBS" || cmake --build build-kodi -- -j"$JOBS" \
  || die "Kodi 编译失败"
cmake --install build-kodi

#------------------------- Step 8/9 插件（尽力而为，失败不中断核心构建）------
log "Step 8/14 编译 shadertoy 视觉/屏保插件"
cd "$WORK"
for addon in visualization.shadertoy screensaver.shadertoy; do
  [ -d "$addon" ] || git clone --branch "$KODI_BRANCH" "https://github.com/xbmc/$addon.git" || { log "  [跳过] $addon 克隆失败"; continue; }
  rm -rf "$addon/build"
  cmake -S "$addon" -B "$addon/build" \
    -DADDONS_TO_BUILD="$addon" -DAPP_RENDER_SYSTEM=gles \
    -DADDON_SRC_PREFIX="$WORK" -DCMAKE_INSTALL_PREFIX="$PREFIX/share/kodi/addons" \
    -DCMAKE_BUILD_TYPE=Release -DPACKAGE_ZIP=1 "$WORK/kodi/cmake/addons" \
    && cmake --build "$addon/build" -- -j"$JOBS" && cmake --install "$addon/build" \
    || log "  [警告] $addon 构建失败，跳过"
done

log "Step 9/14 编译二进制插件（不含 inputstream.rtmp：openEuler 无 librtmp）"
cd "$WORK"
rm -rf binary-addons/build
cmake -S kodi/cmake/addons -B binary-addons/build \
  -DADDONS_TO_BUILD="vfs.rar vfs.libarchive inputstream.adaptive peripheral.joystick pvr.iptvsimple" \
  -DAPP_RENDER_SYSTEM=gles -DCMAKE_INSTALL_PREFIX="$PREFIX/share/kodi/addons" \
  -DCMAKE_BUILD_TYPE=Release -DPACKAGE_ZIP=1 \
  && cmake --build binary-addons/build -- -j"$JOBS" && cmake --install binary-addons/build \
  || log "  [警告] 二进制插件构建失败，跳过（核心 Kodi 不受影响）"
for a in vfs.rar vfs.libarchive inputstream.adaptive peripheral.joystick pvr.iptvsimple; do
  [ -e "$PREFIX/share/kodi/addons/$a" ] && log "  已装插件 $a" || log "  [跳过] 插件 $a 未生成"
done

#------------------------- Step 10 Jellyfin 仓库插件（尽力而为）----------------
log "Step 10/14 预装 Jellyfin 仓库插件"
cd "$PREFIX/share/kodi/addons"
curl -fsSLO "https://kodi.jellyfin.org/repository.jellyfin.kodi.zip" \
  && unzip -o -q repository.jellyfin.kodi.zip \
  && rm -f repository.jellyfin.kodi.zip \
  || log "  [警告] Jellyfin 仓库插件下载失败，跳过"

#------------------------- Step 10.5 同步 /usr/local → staging ---------------
# Kodi/ffmpeg/插件已装到真实 /usr/local（与上游一致，便于互相发现）；
# 打包前把它们整树同步到 staging（容器内 /usr/local 基本为空，无需先清理）。
log "Step 10.5/14 同步 /usr/local → staging"
rm -rf "$STAGE/usr/local"
mkdir -p "$STAGE/usr/local"
cp -a /usr/local/. "$STAGE/usr/local/"

#------------------------- Step 11 appliance / pulseaudio / systemd ------------
log "Step 11/14 注入 appliance.xml / pulseaudio / systemd 单元"
BUILD_INFO="$FLAVOR $PKG_VERSION (openeuler-24.03/aarch64)"
COMPONENTS="Kodi $KODI_BRANCH @$KODI_REV, ffmpeg-rockchip $FF_BRANCH @$FF_REV, dav1d $DAV1D_VER"
[ "$MPP_RGA" = "yes" ] && COMPONENTS="$COMPONENTS, MPP @$(git -C "$WORK/mpp" rev-parse --short=10 HEAD 2>/dev/null||echo x), RGA @$(git -C "$WORK/rkrga" rev-parse --short=10 HEAD 2>/dev/null||echo x)"
# 自带 mesa 也进组件清单（System info 与包元数据里都能看到 panfrost 版本）
gl_so="$(ls "$STAGE$GLFALL"/lib/libgallium-*.so 2>/dev/null | awk 'NR==1')"
[ -n "$gl_so" ] && COMPONENTS="$COMPONENTS, mesa $(basename "$gl_so" .so | sed 's/^libgallium-//') (panfrost)"
APPLIANCE_DIR="$STAGE$PREFIX/share/kodi/system/settings"
mkdir -p "$APPLIANCE_DIR" "$STAGE$PREFIX/share/pulse-kodi" "$STAGE/usr/lib/systemd/system"
cp "$SRC/kodi/appliance.xml" "$APPLIANCE_DIR/appliance.xml"
# 渲染占位符（与上游 render-metadata.sh 等价，但 DISTRO 用 openEuler）
xml_escape() { local s="$1"; s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"; printf '%s' "$s"; }
sed -i "s|@BUILD_INFO@|$(xml_escape "$BUILD_INFO")|g; s|@COMPONENTS@|$(xml_escape "$COMPONENTS")|g" "$APPLIANCE_DIR/appliance.xml"
cp "$SRC/pulseaudio/system.pa" "$STAGE$PREFIX/share/pulse-kodi/system.pa"
# debian/*.service 用的是 dh 的模板名 kodi-rockchip-gbm.<unit>.service；deb 线由 dh_installinit 自动剥前缀，
# 我们手工装必须自己剥掉，否则 systemctl start kodi 找不到单元（pulseaudio.service 的 WantedBy 也引用 kodi.service）。
for u in "$SRC"/debian/*.service; do
  unit="$(basename "$u")"
  cp "$u" "$STAGE/usr/lib/systemd/system/${unit#kodi-rockchip-gbm.}"
done

#------------------------- Step 12 RUNPATH ------------------------------------
log "Step 12/14 写入 RUNPATH（锁定 /usr/local/lib 与 lib64）"
runpath="$PREFIX/lib:$PREFIX/lib64:$PREFIX/lib/$(gcc -dumpmachine)"
# 自带 mesa 在兜底目录里（不在 ld.so 搜索路径上），RUNPATH 是唯一能命中它的东西，且必须排第一，
# 才不会被 /usr/local/lib 里可能存在的系统版 GL 抢走。缺目录说明 Step 3.6 没跑（非 openEuler 线）。
if [ -d "$STAGE$GLFALL/lib" ]; then
  runpath="$GLFALL/lib:$runpath"
  log "  GL 兜底目录已纳入 RUNPATH：$GLFALL/lib"
else
  log "  [注意] 无 GL 兜底目录，Kodi 将使用系统 mesa（openEuler 上会是 llvmpipe）"
fi
# openEuler 是 lib64 体系：kodi-gbm 可能装在 lib 或 lib64，动态定位
kodi_bin=""
for cand in "$STAGE$PREFIX/lib/kodi/kodi-gbm" "$STAGE$PREFIX/lib64/kodi/kodi-gbm"; do
  [ -f "$cand" ] && { kodi_bin="$cand"; break; }
done
[ -n "$kodi_bin" ] || die "kodi-gbm 未生成（lib/lib64 均未找到）"
for elf in "$kodi_bin" "$STAGE$PREFIX/bin/ffmpeg" "$STAGE$PREFIX/bin/ffprobe"; do
  [ -f "$elf" ] || die "RUNPATH 目标缺失: $elf"
  patchelf --set-rpath "$runpath" "$elf"
  readelf -d "$elf" | grep -qF RUNPATH || die "未写入 RUNPATH: $elf"
  if [ -d "$STAGE$GLFALL/lib" ]; then
    readelf -d "$elf" | grep -F RUNPATH | grep -qF "$GLFALL/lib" ||
      die "$elf 的 RUNPATH 没带上 GL 兜底目录，装到板上会掉回 llvmpipe"
  fi
done

#------------------------- Step 13 门禁 ---------------------------------------
log "Step 13/14 自检门禁"
gate "GATE-1：staging ffmpeg 必须带本风味解码器"
DECODERS_TXT=$(LD_LIBRARY_PATH="$STAGE$PREFIX/lib:$STAGE$PREFIX/lib64" "$STAGE$PREFIX/bin/ffmpeg" -hide_banner -decoders 2>/tmp/ff-dec2.err)
if [ -z "$DECODERS_TXT" ]; then
  log "  [WARN] staging ffmpeg -decoders 无输出："
  sed 's/^/    /' /tmp/ff-dec2.err | tail -20
  ldd "$STAGE$PREFIX/bin/ffmpeg" 2>&1 | grep -i "not found" | sed 's/^/    /' || true
fi
miss=""
for d in $FFMPEG_DECODERS; do
  printf '%s\n' "$DECODERS_TXT" | grep -qw "$d" || miss="$miss $d"
done
[ -z "$miss" ] || die "ffmpeg 解码器不全，缺:$miss"
log "GATE-1 通过"
gate "GATE-2：kodi/ffmpeg 链接闭包无 not found"
LD_LIBRARY_PATH="$STAGE$PREFIX/lib:$STAGE$PREFIX/lib64" ldd "$kodi_bin" "$STAGE$PREFIX/bin/ffmpeg" "$STAGE$PREFIX/bin/ffprobe" \
  | grep 'not found' && die "存在未解析依赖" || true
log "GATE-2 通过"
gate "GATE-3：kodi-gbm 二进制存在"
[ -x "$kodi_bin" ] || die "kodi-gbm 未生成"
log "GATE-3 通过"

#------------------------- Step 14 打包 ---------------------------------------
log "Step 14/14 生成安装包"
# 瘦身：丢弃头文件、静态库、libtool 文件
rm -rf "$STAGE$PREFIX/include"
find "$STAGE$PREFIX/lib" -name '*.a' -delete 2>/dev/null || true
find "$STAGE$PREFIX/lib" -name '*.la' -delete 2>/dev/null || true

# 清理文件名中的空格/特殊字符：rpm %files 按空白分词，含空格的文件名（如 Kodi 插件的
# "Read Me.txt"）会被拆成裸名导致 "File must begin with \"/\"" 报错；统一用下划线替代，
# 同时让 deb 内文件名也保持一致、无怪字符。
if [ -d "$STAGE/usr" ]; then
  find "$STAGE/usr" -depth -print0 | while IFS= read -r -d '' p; do
    b=$(basename "$p"); c=$(printf '%s' "$b" | tr -c 'A-Za-z0-9._-' '_')
    [ "$c" = "$b" ] || mv -f "$p" "$(dirname "$p")/$c"
  done
fi

# 计算文件清单（绝对路径，供 RPM %files 使用）；强制以 /usr/ 开头
mapfile -t FILES < <(cd "$STAGE" && find usr \( -type f -o -type l \) -printf '/%p\n' | sort -u | grep '^/usr/')
[ "${#FILES[@]}" -gt 0 ] || die "staging 为空，无法打包"

#---- .rpm（openEuler）----
if [ "$BUILD_RPM" = "yes" ]; then
  RPMBUILD="$WORK/rpmbuild"
  mkdir -p "$RPMBUILD"/{SPECS,SOURCES,RPMS,SRPMS,BUILD}
  # 把 staging 的 usr 打成 tarball 作为 Source0
  tar --numeric-owner -C "$STAGE" -czf "$RPMBUILD/SOURCES/usr.tgz" usr
  # systemd 单元与 pulseaudio 的 %post 处理
  SPEC="$RPMBUILD/SPECS/kodi-rockchip-gbm.spec"
  {
    echo "Name:           kodi-rockchip-gbm"
    echo "Version:        $PKG_VERSION"
    echo "Release:        1%{?dist}"
    echo "Summary:        Kodi GBM/GLES for Rockchip vendor kernels (rkmpp+rkrga hw decoding)"
    echo "License:        GPLv2+ and GPLv3+ and LGPLv2+"
    echo "Group:          Applications/Multimedia"
    echo "Source0:        usr.tgz"
    echo "BuildArch:      aarch64"
    echo "%define debug_package %{nil}"
    echo "Requires:       mesa-libgbm, mesa-libEGL, mesa-libGLES, mesa-libGL, mesa-dri-drivers, libX11, libXext, libXrandr, libXinerama, libXv, libXt, libxkbcommon, wayland, alsa-lib, pulseaudio-libs, libdrm, libinput, systemd"
    echo "%description"
    echo "Kodi media center built for standalone GBM/KMS with GLES rendering for Rockchip"
    echo "boards on openEuler. Bundles its own FFmpeg, dav1d, libdisplay-info, MPP and RGA"
    echo "under /usr/local (not FHS). Needs a Rockchip vendor kernel (/dev/mpp_service)."
    echo "%prep"
    echo "%setup -T -c -n kodi-rockchip-gbm"
    echo "%build"
    echo "# (空：源码已在 openEuler 构建机编译，此处仅打包 staging 树)"
    echo "%install"
    echo "rm -rf %{buildroot}"
    echo "mkdir -p %{buildroot}"
    echo "tar -xzf %{S:0} -C %{buildroot}"
    echo "%pre"
    echo "if [ ! -e /dev/mpp_service ]; then echo '需要 Rockchip vendor 内核（/dev/mpp_service）' >&2; exit 1; fi"
    echo "glibc=\$(ldd --version | head -1 | grep -oP '[0-9]+\\.[0-9]+\$'); awk -v v=\"\$glibc\" 'BEGIN{exit !(v+0 >= 2.38)}' || { echo \"glibc \$glibc < 2.38，请回 openEuler 24.03 重构建\" >&2; exit 1; }"
    echo "%post"
    echo "systemctl disable --now gdm3 sddm lightdm 2>/dev/null || true"
    echo "if [ ! -f /etc/pulse/system.pa ]; then mkdir -p /etc/pulse; cp -v /usr/local/share/pulse-kodi/system.pa /etc/pulse/system.pa 2>/dev/null || true; fi"
    echo "%files"
    echo "%defattr(-,root,root,-)"
    for f in "${FILES[@]}"; do echo "$f"; done
    echo "%changelog"
    echo "* $(date '+%a %b %d %Y') openEuler Kodi SIG <kodi@openeuler.local> - $PKG_VERSION-1"
    echo "- Build from armsurvivors/kodi-rockchip-deb, adapted for openEuler (rpm+deb)."
  } > "$SPEC"
  log "  生成 RPM：$SPEC"
  rpmbuild --define "%_topdir $RPMBUILD" -bb "$SPEC" \
    && find "$RPMBUILD/RPMS" -name '*.rpm' -exec mv -v {} "$OUT/" \; \
    || die "rpmbuild 失败（见上方 RPM 构建错误）"
fi

#---- .deb（Debian 系跨发行版）----
if [ "$BUILD_DEB" = "yes" ]; then
  DEBROOT="$WORK/deb-root"
  rm -rf "$DEBROOT"
  mkdir -p "$DEBROOT/DEBIAN"
  cp -a "$STAGE/usr" "$DEBROOT/usr"
  # deb 面向 deepin/Debian/Ubuntu：它们的 mesa 本来就带 panfrost，不需要（也不该）被我们这套
  # 纯 GBM 的 mesa 顶掉，所以把兜底 GL 从 deb 里摘掉；kodi-gbm 的 RUNPATH 里那条路径不存在即被忽略。
  rm -rf "$DEBROOT$GLFALL"
  DEB_DEPENDS="libgbm1, libegl1, libgles2, libgl1, libx11-6, libxext6, libxrandr2, libxinerama1, libxv1, libxt6, libxkbcommon0, libwayland-client0, libasound2t64 | libasound2, libpulse0, libdrm2, libinput10, libstdc++6, libc6, zlib1g"
  {
    echo "Package: kodi-rockchip-gbm"
    echo "Version: $PKG_VERSION"
    echo "Section: video"
    echo "Priority: optional"
    echo "Architecture: arm64"
    echo "Maintainer: openEuler Kodi SIG <kodi@openeuler.local>"
    echo "Homepage: https://github.com/armsurvivors/kodi-rockchip-deb"
    echo "Depends: $DEB_DEPENDS"
    echo "Provides: kodi, kodi-rockchip-gbm-$FLAVOR"
    echo "Conflicts: kodi"
    echo "XB-Kodi-Rockchip-Flavor: $FLAVOR"
    echo "XB-Kodi-Rockchip-Build: $BUILD_INFO"
    echo "XB-Kodi-Rockchip-Components: $COMPONENTS"
    echo "Description: Kodi GBM/GLES for Rockchip vendor kernels (rkmpp+rkrga hw decoding)"
    echo " Bundles its own FFmpeg/dav1d/libdisplay-info/MPP/RGA under /usr/local."
    echo " Needs a Rockchip vendor kernel (/dev/mpp_service). Works on deepin 25,"
    echo " Debian trixie/forky, Ubuntu resolute/noble (glibc >= 2.38)."
  } > "$DEBROOT/DEBIAN/control"
  cat > "$DEBROOT/DEBIAN/preinst" <<'PREINST'
#!/bin/sh
set -e
if [ ! -e /dev/mpp_service ]; then
  echo "kodi-rockchip-gbm: 需要 Rockchip vendor 内核（/dev/mpp_service），本机不适用" >&2
  exit 1
fi
glibc=$(ldd --version | head -1 | grep -oP '[0-9]+\.[0-9]+$')
awk -v v="$glibc" 'BEGIN{exit !(v+0 >= 2.38)}' || { echo "glibc $glibc < 2.38，请回 openEuler 24.03 重构建" >&2; exit 1; }
PREINST
  cat > "$DEBROOT/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
set -e
systemctl disable --now gdm3 sddm lightdm 2>/dev/null || true
if [ ! -f /etc/pulse/system.pa ]; then
  mkdir -p /etc/pulse
  cp -v /usr/local/share/pulse-kodi/system.pa /etc/pulse/system.pa 2>/dev/null || true
fi
echo "kodi-rockchip-gbm: 安装完成。sudo systemctl start kodi 运行，enable 开机自启。"
POSTINST
  chmod +x "$DEBROOT/DEBIAN/preinst" "$DEBROOT/DEBIAN/postinst"
  log "  生成 .deb"
  dpkg-deb --build --root-owner-group "$DEBROOT" "$OUT/kodi-rockchip-gbm_${PKG_VERSION}_arm64.deb"
fi

#---- tar.gz（可选，裸机跨发行版）----
if [ "$BUILD_TAR" = "yes" ]; then
  TS="$(date +%Y%m%d-%H%M)"
  TARBALL="$OUT/kodi-rockchip-gbm-$TS.tar.gz"
  tar --numeric-owner -C "$STAGE" -czf "$TARBALL" usr
  log "  生成 tar.gz：$TARBALL"
fi

log "完成。产物目录：$OUT"
ls -lah "$OUT"
