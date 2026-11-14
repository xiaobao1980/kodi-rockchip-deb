# debian/ 目录说明（Kodi Rockchip 打包）

本目录同时承载 **两条不同的 `.deb` 产出路径**，请勿混淆：

## 路径 A：openEuler 自包含打包（本仓库主用）
由 `build-kodi-rockchip-openeuler.sh` 在 openEuler 24.03 上构建，
从 `/usr/local` staging 树用 `dpkg-deb` **现场生成** `.deb`
（`DEBIAN/control` 在脚本内 heredoc 生成，不读本目录的 `control`）。

- 本目录被脚本直接使用的只有 `*.service`（systemd 单元）：
  `kodi-rockchip-gbm.kodi.service` / `kodi-pulse.service` / `pulseaudio.service`
- `kodi-rockchip-gbm.postinst` 也在此，但脚本用的是自身 heredoc 的 postinst，
  二者内容一致，仅源不同。
- 产出的 `.deb` 自带 `/usr/local` 全套依赖（FFmpeg/dav1d/MPP/RGA），
  可在 **deepin 25 / Debian trixie·forky / Ubuntu resolute·noble**
  （glibc ≥ 2.38）免 `LD_LIBRARY_PATH` 安装。

## 路径 B：上游原生 Debian/Ubuntu 打包（参考 / 备选）
来自上游 `armsurvivors/kodi-rockchip-deb`，使用标准 `debuild` 流程：
`control`（含 `@ARCH@`/`@FLAVOR@` 模板占位）+ `rules`（dh + systemd）+
`source/format`（3.0 native）+ `copyright`。

- 这套是**系统装好依赖后**打 `.deb`（依赖走 apt，非 `/usr/local` 自包含）。
- 使用方式：先由上游 `packaging/render-metadata.sh` 把 `control` 里的
  占位符替换为实际值，再 `debuild -us -uc` 产出 `.deb`。
- 若要本仓库也能直接 `debuild`，需另外 vendor `packaging/render-metadata.sh`
  （当前未纳入，仅作参考保留）。

## 结论
- 想打 **openEuler / 跨发行版自包含**包 → 用 `build-kodi-rockchip-openeuler.sh`。
- 想在 **原生 Debian/Ubuntu** 上走标准 debuild → 用本目录 B 路径（需 render-metadata.sh）。
- 两者共用同一套 systemd 单元与补丁，解码栈（rkmpp / v4l2requests）一致。
