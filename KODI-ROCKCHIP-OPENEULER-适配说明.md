# Kodi-rockchip 适配 openEuler / deepin 25（rk35xx vendor 内核）

把上游 [armsurvivors/kodi-rockchip-deb](https://github.com/armsurvivors/kodi-rockchip-deb) 的构建逻辑改写成
openEuler 范式，让 Kodi（Piers 22.x，GBM/GLES）在 **Rockchip rk35xx**（RK3566 / RK3568 / RK3576 / RK3588）
的 **vendor 内核**上跑硬件解码（MPP + RGA，即 `rkmpp` 风味），并以原生安装包形式分发：

| 目标系统 | 安装包 | 包管理 |
|---|---|---|
| openEuler 24.03（rk35xx vendor） | `kodi-rockchip-gbm-<ver>-1.*.aarch64.rpm` | `dnf` / `rpm` |
| deepin 25（rk35xx vendor） | `kodi-rockchip-gbm_<ver>_arm64.deb` | `apt` / `dpkg` |
| Debian trixie/forky、Ubuntu resolute/noble | 同一份 `.deb`（glibc ≥ 2.38 即可） | `apt` / `dpkg` |

> 注：`.deb` 是 Debian 系通用包（deepin 25 / trixie / forky / resolute / noble 共用一个 arm64 包），
> 因为除了系统基础库（mesa / X11 / wayland / alsa）外，所有组件都自闭环在 `/usr/local`。

> **现在有两条 openEuler 构建路径**，产物同源、用途不同（详见第 9 节）：
> ① 上游 Docker 主线 `Dockerfile.kodi` + `build.sh` + `kodi-latest.yml`，`DISTRO=openeuler-24.03` 即出 rpm + deb + 容器镜像；
> ② 裸机脚本 `build-kodi-rockchip-openeuler.sh`，不用 Docker，直接在 openEuler 主机/容器里跑。

## 1. 与上游的差异（改了什么）

上游只支持 Debian/Ubuntu（apt + `debuild` 出 `.deb` + debian 基镜像容器）。本适配的改动：

1. **包管理改写**：`apt` / `debuild` → `dnf` / `rpmbuild` + `dpkg-deb`。
2. **基镜像/构建机**：在 **openEuler 24.03**（glibc 2.38）原生 arm64 上构建，保证 glibc 向后兼容基线。
3. **自闭环前缀**：所有组件（mpp / rga / dav1d / libdisplay-info / ffmpeg-rockchip / Kodi）统一装进
   `/usr/local`，与系统 ffmpeg 完全并行；`kodi-gbm` / `ffmpeg` / `ffprobe` 用 `patchelf` 写入
   `RUNPATH=/usr/local/lib`，目标机**无需 `LD_LIBRARY_PATH`**。
4. **同一份 staging 树产出 rpm + deb**：构建只做一次，打包阶段从 `$STAGE/usr` 分别打成 rpm 与 deb。
5. **补丁/appliance/systemd 直接复用上游**：`patches/kodi/common`（遥控器电源键菜单）、
   `kodi/appliance.xml`（默认 DRM PRIME 硬解 + Direct-To-Plane）、三个 systemd 单元、pulseaudio `system.pa`。

没改的：解码栈本身（还是 nyanmisaka 的 ffmpeg-rockchip + MPP/RGA）、Kodi 的 GBM/GLES 配置、
二进制插件（vfs.rar/libarchive、inputstream.adaptive/rtmp、peripheral.joystick、pvr.iptvsimple）、Jellyfin 仓库插件。

## 2. 设计原则：glibc 就低不就高

- 三个目标里 **openEuler 24.03 的 glibc 2.38 最低**，在它上面构建一次，新 glibc 的目标（deepin 25、trixie …）都能跑。
- **反向不行**：在更高 glibc 上构建的二进制无法在 openEuler 24.03 上加载。
- 硬门禁：目标机必须有 `/dev/mpp_service`（rk35xx vendor 内核）。mainline 内核不适用 `rkmpp`，需改用 `v4l2requests` 风味。

## 3. 构建（在 openEuler 24.03 / aarch64 上执行）

```bash
sudo dnf install -y git
git clone <本仓库> && cd kodi-rockchip-deb
chmod +x build-kodi-rockchip-openeuler.sh
# 默认 rkmpp，产 rpm + deb
sudo FLAVOR=rkmpp BUILD_RPM=yes BUILD_DEB=yes ./build-kodi-rockchip-openeuler.sh
```

脚本顺序（共 14 步）：

| 步 | 内容 |
|---|---|
| 0 | 前置检查（arm64、`/dev/mpp_service`、glibc 基线、dnf、rpmbuild/dpkg-deb） |
| 1 | `dnf` 编译依赖（含“风险包”单独装，缺失不致命） |
| 2–3 | libdisplay-info、dav1d（AV1 软解兜底） |
| 3.5–3.6 | pugixml（openEuler 不打包）、**mesa 24.3.4 + panfrost**（openEuler 自带 mesa 无 panfrost DRI 驱动），装进 `share/kodi-rockchip/glfallback` |
| 4–5 | rockchip-mpp、rockchip-rga（仅 rkmpp 线） |
| 6 | ffmpeg-rockchip（`--enable-rkmpp --enable-rkrga`）/ v4l2requests（打 V4L2 无状态补丁） |
| 7 | Kodi（Piers，GBM/GLES，`DESTDIR` 装进 staging） |
| 8–9 | shadertoy 视觉/屏保、二进制插件 |
| 10 | Jellyfin 仓库插件 |
| 11 | 渲染 appliance.xml、注入 pulseaudio `system.pa`、三个 systemd 单元 |
| 12 | 写 RUNPATH |
| 13 | 三道门禁（ffmpeg 解码器 / ldd 无 not found / kodi-gbm 存在） |
| 14 | 瘦身（丢头文件、静态库）后打 rpm + deb（可选 tar.gz） |

版本全部锁死在脚本头部。CI（`.github/workflows/build-kodi-rockchip-openeuler.yml`）在
`openeuler/openeuler:24.03` 容器里跑，纯编译（`SKIP_MPP_CHECK=1`），产物作为 Artifact / Release 上传。

## 4. 依赖映射要点（Debian → openEuler）与风险包

构建依赖已按 openEuler / Fedora 命名习惯改写（详见脚本 Step 1）。**需要特别注意的：**

- **风险包**（openEuler 24.03 可能缺，脚本单独装、缺失不致命）：`libcec-devel`、`lirc-devel`、
  `mariadb-devel`、`rtmpdump-devel`、`lame-devel`、`enca-devel`。若某包缺失，对应 Kodi 功能默认仍开启，
  构建失败时在 Kodi 的 cmake 里加 `-DENABLE_CEC=OFF` / `-DENABLE_LIRC=OFF` / `-DENABLE_MYSQL=OFF` 等即可。
- **为避开必缺包，已默认关闭**：`AIRPLAY`(shairplay)、`WII`(cwiid)、`OPTICAL`(libbluray/libcdio)、
  并 `-DENABLE_INTERNAL_CROSSGUID=ON`（自带 crossguid，不依赖系统 `libcrossguid-devel`）。
- **HDMI-CEC 在 openEuler 线上是关掉的**：`dnf` 里没有 `libcec-devel`（风险包探测必缺），所以
  `-DENABLE_CEC=OFF`。板子上 `/dev/cec0` 还在、内核仍支持 CEC，但 Kodi 不碰它——电视遥控器开关机、
  音频直通这类都用不了；要 CEC 得把 libcec 一起编进 `/usr/local`，属于另一件事。
- **ffmpeg 用 `--enable-shared --disable-static`**：保证 Kodi 能链接到 `/usr/local/lib` 的 `libav*`，
  与已验证可用的 mpv 参考线一致（上游 Dockerfile 默认静态，Kodi 外链需要共享库）。
- **运行时依赖**（写进 rpm `Requires` / deb `Depends`）：mesa（gbm/egl/gles）、X11、wayland、alsa、pulse、libdrm 等，
  这些是目标机系统基础库，随发行版自带。

### 4.1 为什么自带 mesa（panfrost）

在 RK3576（Mali-G52 MC3）上实测：openEuler 24.03 SP4 的 mesa 是 **24.0.3，只编 `llvmpipe`，没有
`panfrost_dri.so`**，也没有任何更新版的仓库可选。结果 Kodi GBM 拿到的 GL 驱动是 llvmpipe——整个 UI
在 3840×2160 的 framebuffer 上纯 CPU 渲染，`kodi.bin` 稳定吃掉一个核，画面卡顿；而 CPU 频率、温度、
内存、MPP/RGA 都正常，硬解本身是好的（`/proc/mpp_service/load` 有负载）。也就是说卡的是**渲染**，不是解码。

因此 openEuler 这条线自带一套 GL 栈（Debian/Ubuntu 的 mesa 有 panfrost，无需此步骤），落在
**`/usr/local/share/kodi-rockchip/glfallback/lib`**，并且**只打进 rpm、不打进 deb**：

- **为什么不放 `/usr/local/lib`／`lib64`**：openEuler 的 `/etc/ld.so.conf` 第一行就是 `/usr/local/lib64`，
  GL 库丢进去等于给全系统多出第二个 `libEGL.so.1` / `libgbm.so.1`，和发行版 mesa 抢 soname——比没 GL 更糟。
  兜底目录不被加载器搜索，只有 `kodi-gbm` / `ffmpeg` 的 RUNPATH 显式命中它。也因此**刻意不跑 `ldconfig`**。
  meson 的 `--prefix` 必须是这个目录本身：DRI 搜索路径与 gbm backend 目录是编译期写死进二进制的。
- **为什么不重编发行版自家 24.0.3 SRPM**：本仓库的 Armbian rk35xx vendor kernel 线要求 **mesa ≥ 24.1**
  （Panthor 路径，RK3588 的 Mali-G610 走它），24.0.3 过不了这条线；跨发行版 deb 也要能覆盖 deepin 25。
  直接取上游 24.3.4 一份，路径确定；deb 面向的 Debian/Ubuntu/deepin 自带 panfrost，多塞一套 GL 反而添乱，
  所以打包时从 deb 树里删掉（RUNPATH 里多一条不存在的路径会被忽略，无害）。

- **版本取 24.3，不是 25.x**：25.2 把 panfrost 挪到了 CLC 预编译着色器路径，`meson.build` 里
  `with_driver_using_cl` 含 `with_gallium_panfrost`，于是硬性要求 libclc + SPIRV-Tools **≥ 2024.1**，
  而 openEuler SP4 只有 2023.2.1；`pan_context.c` 直接 `#include "clc/pan_compile.h"`，绕不过去。
  24.3 的 `with_clc` 只在 asahi / rusticl / clover 下为真，panfrost 干净。
- **`-Dshared-llvm=disabled`**：LLVM 静态链进驱动，产物不 `NEEDED libLLVM.so.17`。这点很关键——本包要跨
  openEuler / deepin / Debian / Ubuntu 安装，而各发行版的 LLVM soname 都不一样。
- **`-Dgallium-drivers=panfrost,llvmpipe`**：保留软渲染兜底，panfrost 初始化失败时不至于黑屏。
  **边界**：这套只带 Bifrost（rk3566/3568/3576 的 Mali-G52），**不带 panthor**——rk3588 的 Mali-G610 走
  Panthor 路径，本构建不覆盖（24.3 的 panthor 依赖链比 panfrost 重，且还要内核侧 panthor UAPI），
  rk3588 建议走 Debian/Ubuntu 线用发行版 mesa。
- **RUNPATH**：meson 安装时会清掉 build rpath，而兜底目录根本不在系统搜索路径里，所以 `dri/*.so`、
  `gbm/*.so`、`libgallium-*.so` 都要用 `patchelf` 补 `RUNPATH=<glfallback>/lib`（与 Step 12 同一手法）。
  **枚举必须走 `find -type f`，不能按 `libEGL.so.1` 这种写法列名字**：mesa 的实体叫 `libEGL.so.1.0.0`，
  `libEGL.so.1` 只是软链——按软链名循环、再跳过软链，真正的 ELF 反而一条 RUNPATH 都没打上，
  解包到板子上就找不到 libgallium、掉回 llvmpipe（这条是板上 `ls -l /usr/local/lib64` 核对出来的）。
  同一写法也顺带避开了第二个坑：patchelf 是“临时文件 + rename”写回的，对着 `dri/*_dri.so` 软链下手
  会把链接换成一份 66 MB 实体。Step 12 之后还会断言 `kodi-gbm` 的 RUNPATH 里确实带着这条目录。
- **`dri/` 目录要自己摆**：mesa 只在 `src/gallium/targets/dril` 里生成 `panfrost_dri.so` / `swrast_dri.so`
  这些“按驱动命名”的入口，而 `src/meson.build` 只有在 `with_glx=='dri'` 或启用 x11/xcb 平台时才编这个子目录。
  本线是纯 GBM 构建（`-Dplatforms=`），装完根本没有 `dri/`，GBM 按确切名字 dlopen 找不到驱动，又掉回 llvmpipe。
  所以 `ninja install` 之后按 dril 之前 mesa 自己的老办法补软链：
  `dri/{panfrost,swrast,kms_swrast}_dri.so -> ../libgallium-<ver>.so`（一个 megadriver 已含全部驱动，
  按名字给几条链即可）。
- **构建依赖**（openEuler 包名）：`llvm-devel`、`zstd-devel`、`byacc`、`flex`、`expat-devel`、
  `elfutils-libelf-devel`、`python3-mako`、`python3-ply`、`python3-pyyaml`；libdrm 2.4.119 已满足 mesa 的
  2.4.109 下限，无需自带 libdrm。`spirv-tools-devel` / `libclc` **故意不装**——一旦链进 libgallium，
  跨发行版就多了两个必炸的依赖；Step 3.6 的门禁会 grep `NEEDED libLLVM|libclc|libSPIRV` 拦住。
- **并行度按内存压**：LLVM 静态链进 megadriver 时，`-j$(nproc)` 在 2 GB 级板子上会被 OOM 打死。
  所以 `MESA_JOBS = min(nproc, MemTotal/1 GiB)`，编译目录按这个值 `-j`。
- **板上实测（RK3576 实机）**：mesa 24.3.4 装到独立前缀 `/opt/mesa25` 后用 `LD_LIBRARY_PATH` 起
  Kodi，日志由 `GL_RENDERER = llvmpipe (LLVM 17.0.6, 128 bits)` 变成 `GL_RENDERER = Mali-G52 r1 (Panfrost)`，
  `EGL_VERSION = 1.5 / Mesa Project`，GBM 通路（`HDMI-A-1`、gui plane 3840×2160 AR24 LINEAR）不变。
  另外提醒一句：空闲首页和连点 Down/Up 两种采样下，两种渲染的 `kodi-gbm` CPU 都在 ~20% 单核——Kodi 只在
  界面变化时重绘，合成负载测不出差距，主观流畅度还得在实际播放/操作里确认。
- 系统其余部分照旧用发行版 mesa：只有 `kodi-gbm` / `ffmpeg` 通过 RUNPATH 命中 `glfallback/lib` 这套。
  板上另有一处踩坑记录：干净系统里若有人手工往 `/usr/local/lib64` 装过带 panfrost 的 mesa，`kodi-gbm`
  会直接蹭到它、看不出问题——所以验证包本身是否带 GL，要看 rpm 文件清单，而不是只看一次运行日志。

## 5. 安装

**openEuler 24.03：**
```bash
sudo rpm -ivh kodi-rockchip-gbm-<ver>-1.oe*.aarch64.rpm
# 或：sudo dnf install ./kodi-rockchip-gbm-<ver>-1.oe*.aarch64.rpm
```

**deepin 25 / Debian / Ubuntu（rk35xx vendor 内核）：**
```bash
sudo apt-get install -y ./kodi-rockchip-gbm_<ver>_arm64.deb   # 缺依赖时加 -f
# 或：sudo dpkg -i kodi-rockchip-gbm_<ver>_arm64.deb && sudo apt-get -f install
```

安装脚本/包的 `pre` 阶段会检查 `/dev/mpp_service` 与 glibc ≥ 2.38，不满足直接拒绝；
`post` 阶段禁用 GDM3/SDDM/LightDM（Kodi 接管 KMS）并布置 pulseaudio `system.pa`。
**`post` 不会 enable 也不会 start Kodi**（只打印提示），所以装完必须手动 `systemctl start kodi`，
想开机有画面还得 `systemctl enable kodi`——否则重启后就是一片黑，别误判成包坏了。

> 旧包踩过的坑：单元文件沿用了 deb 的 dh 模板名 `kodi-rockchip-gbm.kodi.service`，`systemctl start kodi`
> 报 “Unit kodi.service not loaded”。rpm 侧已在打包时剥掉 `<package>.` 前缀；手上还装着旧包的话，
> 先用全名 `systemctl start kodi-rockchip-gbm.kodi` 顶一下。

## 6. 运行

```bash
# ALSA（无桌面独占 KMS）
sudo systemctl start kodi            # 或 enable 开机自启
# PulseAudio
sudo systemctl start kodi-pulse
# 手工前台调试
kodi --logging=console --windowing=gbm --audio-backend=alsa
```

确认硬解：播放时 `watch -n 1 cat /proc/mpp_service/load` 有非零负载即生效；系统信息页 `Git:` 行含
`-rkmpp-ffmpeg-8.1-openeuler-build-<ver>`。

## 7. 已知风险 / 待验证

1. **mesa 步骤尚未跑过完整 CI**：板子上是用独立前缀 `/opt/mesa25` 手工验证的（见 4.1 末尾），
   构建线里的 `Dockerfile.kodi` MESA 段与裸机脚本 Step 3.6 是同参数复刻，`dri/` 补软链与三道门禁已按实测布局写好，
   但要等一次 openEuler 流水线绿了才算通关。其余部分：GitHub Actions 的
   `openeuler/openeuler:24.03` 容器（`ubuntu-24.04-arm` 运行器）此前已跑通全流程并发布 rpm + deb
   （run `43600738878` / Release `kodi-v20261114`）；裸机直编仍可能需微调个别 `-devel` 包名。
2. **openEuler 缺 `dpkg` / `rpm-build`**：脚本在开启 `BUILD_DEB` / `BUILD_RPM` 时自动 `dnf install`，需联网源可用。
3. **deepin 25 包名差异**：deb `Depends` 用了 `libasound2t64 | libasound2` 兜底，deepin 25 若用旧名 `libasound2`
   走 `|` 备选；其余 mesa/X11/wayland 包名三发行版一致。
4. **Kodi 构建耗时**：在 arm64 上约 1–2 小时，且二进制插件会从网络拉源码，需稳定网络。
5. **`v4l2requests` 风味**：脚本已内置（打 V4L2 无状态补丁 + 头文件门禁），但本适配主验 `rkmpp`；
   若要 mainline 内核硬解，把 `FLAVOR=v4l2requests` 即可，其余流程一致。

## 8. 与 mpv tar 线的关系

本仓库另有一套 **mpv + rkmpp 的 tar.gz 分发线**（`build-rk-hwaccel-local.sh` 等，作为参考）。
两者共享“openEuler 24.03 构建 + `/usr/local` 自闭环 + glibc 2.38 基线”的范式，区别在：

- mpv 线：tar.gz 裸机分发，适用 openEuler / Armbian trixie / deepin 25 vendor 内核；
- 本 Kodi 线：rpm + deb 原生包，面向 openEuler 24.03 与 deepin 25（及 Debian 系）的**包管理可审计**场景。

## 9. 两条 openEuler 构建路径

| | ① Docker 主线 | ② 裸机脚本 |
|---|---|---|
| 入口 | `DISTRO=openeuler-24.03 ./build.sh`；CI `.github/workflows/kodi-latest.yml` | `./build-kodi-rockchip-openeuler.sh`；CI `build-kodi-rockchip-openeuler.yml` |
| 构建环境 | `openeuler/openeuler:24.03` 作为 `BASE_IMAGE` | 当前 openEuler 主机/容器（需自带 dnf） |
| 产物 | rpm + 跨发行版 deb + ffmpeg-only 对 + **容器镜像**（`openeuler-24.03-<flavor>-latest`） | rpm + 跨发行版 deb（可选 tar.gz） |
| Debian/Ubuntu | 同一条流水线，切 `DISTRO` 即可 | 不适用（只产跨发行版 deb） |
| 安装前门禁 | **仅告警**（否则 CI 容器里装不上：runner 无 `/dev/mpp_service`） | **硬失败**（`%pre`/`preinst` 直接 exit 1） |

Docker 主线的 openEuler 分支由 `base` 阶段一次探测决定（写入容器内 `/src/os-info.env`：`OS_ID=openeuler-24.03`、
`PKG_FAMILY=rpm`），后续按家族分叉：

- 依赖：`dnf_install()` 逐个校验包名（RHEL 命名 `*-devel`），缺的记 `/src/missing-deps.txt` 不中断；
  另装 `rpm-build` + `dpkg`（容器默认没有，否则产物静默缺失）。
- lib64 体系：`ENV PKG_CONFIG_PATH` 含 `/usr/local/lib{,64}/pkgconfig`；mpp/pugixml `-DCMAKE_INSTALL_LIBDIR=lib`；
  ffmpeg `--enable-shared --disable-static --enable-rpath`；每步装完 `ldconfig`。
- 源码补依赖：openEuler 不打包 pugixml，`base` 阶段从源码编；同一阶段还按 4.1 编出自带 mesa（`PKG_FAMILY=rpm`
  才走，Debian/Ubuntu 直接跳过），装到 `${KODI_GL_PREFIX}=/usr/local/share/kodi-rockchip/glfallback`，
  装完补 `dri/*_dri.so` 软链 + patchelf RUNPATH，并用门禁卡住
  “EGL/GLES2/GBM/panfrost 四个文件必须存在、且不得 NEEDED libLLVM/libclc/libSPIRV”。该阶段结束**不跑 ldconfig**。
- Kodi：删掉损坏的 `harfbuzz` cmake config 走 pkg-config；`ENABLE_INTERNAL_FSTRCMP/CROSSGUID=ON`，
  `AIRPLAY/WII/OPTICAL/CEC/LIRC/ENCA/PULSEAUDIO/TESTING=OFF`。
- 二进制插件：去掉 `inputstream.rtmp`（无 librtmp），否则会拖垮整批插件。
- RUNPATH 与打包：`kodi-gbm` 在 `/usr/local/lib64/kodi/`，探测 lib/lib64；RUNPATH 拼成
  `<glfallback>/lib:/usr/local/lib:/usr/local/lib64:/usr/local/lib/<tuple>`（兜底目录在**最前**，且只在
  该目录存在时才加，Debian/Ubuntu 线不受影响）。打包段 `packaging/build-openeuler-packages.sh` 复刻裸机脚本
  Step 12–14 已验证的 rpm 规避（文件名清洗、`%changelog` 日期格式、`%define debug_package %{nil}`），
  并在生成 deb 树时 `rm -rf` 掉 `glfallback`（见 4.1）；rpm 的文件清单由 `find usr` 生成，软链会原样保留。
- v4l2requests 风味：openEuler 的 6.6 头文件缺 `V4L2_CID_STATELESS_HEVC_EXT_*`，这几个符号在该家族降为
  告警（与裸机脚本一致），四个核心符号仍是硬门禁。

> 裸机脚本保持原样不动：它面向“在板子/openEuler 主机上直接编”的场景，硬门禁更严格。
> 两条路径的 openEuler 特殊处理有意保持一致，改一处记得看另一处。
