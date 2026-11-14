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
- **ffmpeg 用 `--enable-shared --disable-static`**：保证 Kodi 能链接到 `/usr/local/lib` 的 `libav*`，
  与已验证可用的 mpv 参考线一致（上游 Dockerfile 默认静态，Kodi 外链需要共享库）。
- **运行时依赖**（写进 rpm `Requires` / deb `Depends`）：mesa（gbm/egl/gles）、X11、wayland、alsa、pulse、libdrm 等，
  这些是目标机系统基础库，随发行版自带。

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

1. **未在真实 rk35xx 板 + openEuler 24.03 上实跑构建**（本环境为 macOS，无法原生 arm64 构建）。
   脚本结构、依赖映射、打包流程已按上游与 openEuler 范式对齐，但首次实跑可能要微调个别包名或 Kodi cmake 开关。
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
