# Warning to the reader. This produces a .deb package with stuff in /usr/local. If this scares you, stop reading.
# It is in fact, non-debian packaging. Probably fpm would be a better choice?
# xiaobao: 2026-07 新增 pvr.iptvsimple（IPTV Simple Client 直播插件）构建
# xiaobao: 2026-07 新增 noble/jammy 兼容（见下方三处 xiaobao 注释）
ARG BASE_IMAGE="debian:trixie"
FROM ${BASE_IMAGE} AS packager

#### Dependencies. In batches; this is built under buildx and layers not published so we don't care about layer size.
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get -y update && apt-get -y dist-upgrade && apt-get -y install git bash wget curl build-essential devscripts debhelper pkg-config cmake meson tree
# xiaobao: dh-sequence-single-binary 在老发行版可能不存在，装不上不致命（打包阶段会自适应）
RUN apt-get -y install dh-sequence-single-binary || echo "dh-sequence-single-binary unavailable, will adapt at packaging time"
# xiaobao: jammy(22.04) 工具链太旧，自动升级：gcc 11 -> 12，meson 0.61/cmake 3.22 -> pip 新版
RUN . /etc/os-release && if [ "${VERSION_CODENAME}" = "jammy" ]; then \
        apt-get -y install gcc-12 g++-12 && \
        update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-12 100 --slave /usr/bin/g++ g++ /usr/bin/g++-12 && \
        pip3 install --no-cache-dir -U 'cmake<4' meson ninja; \
    fi
# Generic Dependencies for kodi
RUN apt-get -y install debhelper autoconf automake autopoint gettext autotools-dev curl gawk gcc gdc gperf libtool lsb-release meson nasm ninja-build \
               python3-dev python3-pil python3-pip swig unzip uuid-dev zip

# Kodi GBM dependencies; also CEC and  MariaDB (not Mysql) dependencies.
# Dependencies for ffmpeg and libdisplay-info
RUN apt-get -y install libdrm-dev hwdata

## Deps for Kodi
RUN apt-get -y install libasound2-dev libass-dev libavahi-client-dev \
    libavahi-common-dev libbluetooth-dev libbluray-dev libbz2-dev libcdio-dev libcdio++-dev libp8-platform-dev libcrossguid-dev libcurl4-openssl-dev libcwiid-dev libdbus-1-dev  \
    libegl1-mesa-dev libenca-dev libexiv2-dev libflac-dev libfmt-dev libfontconfig-dev libfreetype6-dev libfribidi-dev libfstrcmp-dev libgcrypt-dev libgif-dev \
    libgles2-mesa-dev libgl1-mesa-dev libglu1-mesa-dev libgnutls28-dev libgpg-error-dev libgtest-dev libiso9660-dev libjpeg-dev liblcms2-dev libltdl-dev liblzo2-dev \
    libmicrohttpd-dev libnfs-dev libogg-dev libpcre2-dev libplist-dev libpng-dev libpulse-dev libshairplay-dev libsmbclient-dev libspdlog-dev libsqlite3-dev \
    libssl-dev libtag1-dev libtiff5-dev libtinyxml-dev libtinyxml2-dev libudev-dev libunistring-dev libvorbis-dev  \
    libxslt1-dev libxt-dev rapidjson-dev zlib1g-dev default-jre libgbm-dev libinput-dev libxkbcommon-dev libcec-dev libmariadb-dev liblirc-dev # Removed: libva-dev libvdpau-dev libxmu-dev libxrandr-dev libdrm-dev

# New dep for kodi in 2025?
RUN apt-get -y install nlohmann-json3-dev


#### Git clones. Heavy stuff.
ARG FFMPEG_BRANCH="8.1"
SHELL ["/bin/bash", "-e", "-c"]
WORKDIR /src
RUN git -c advice.detachedHead=false clone https://gitlab.freedesktop.org/emersion/libdisplay-info.git libdisplay-info && \
    git -c advice.detachedHead=false clone -b jellyfin-mpp --depth=1 https://github.com/nyanmisaka/mpp.git rkmpp && \
    git -c advice.detachedHead=false clone -b jellyfin-rga --depth=1 https://github.com/nyanmisaka/rk-mirrors.git rkrga && \
    git -c advice.detachedHead=false clone -b 1.5.3 --depth=1 https://code.videolan.org/videolan/dav1d.git dav1d && \
    git -c advice.detachedHead=false clone -b "${FFMPEG_BRANCH}" --depth=1 https://github.com/nyanmisaka/ffmpeg-rockchip.git ffmpeg

#### Builds

# We'll build into /usr/local, so zero that out to get a clean slate. Yeah, not too smart, but it works.
RUN rm -rfv /usr/local/*

# RKMPP
WORKDIR /src/rkmpp/rkmpp_build
RUN cmake -DCMAKE_INSTALL_PREFIX=/usr/local -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON -DBUILD_TEST=OFF .. && \
    make -j$(nproc) && \
    make install

# RKRGA
WORKDIR /src
RUN meson setup rkrga rkrga_build --prefix=/usr/local --libdir=lib --buildtype=release --default-library=shared -Dcpp_args=-fpermissive -Dlibdrm=false -Dlibrga_demo=false && \
    meson configure rkrga_build && \
    ninja -C rkrga_build install

# dav1d: fast software AV1 decoder, built from source. Enables AV1 software fallback in ffmpeg.
# h264/hevc/vp9 software decoders are already native to ffmpeg; AV1's native decoder is too slow, so we bring dav1d.
WORKDIR /src/dav1d
RUN meson setup build --prefix=/usr/local --libdir=lib --buildtype=release --default-library=shared -Denable_tools=false -Denable_tests=false && \
    ninja -C build install

# ffmpeg, with rkxxx stuff. Nyanmisaka's fork, full of boogie goodness. You folks rock.
# Software decode: native h264/hevc/vp9 (default) + libdav1d for AV1. Hardware decode: rkmpp. SIMD asm (NEON) is on by default on aarch64.
WORKDIR /src/ffmpeg
RUN ./configure --prefix=/usr/local --enable-gpl --enable-version3 --enable-libdrm --enable-rkmpp --enable-rkrga --enable-libdav1d && \
    make -j $(nproc) && \
    make install && \
    LD_LIBRARY_PATH=/usr/local/lib /usr/local/bin/ffmpeg -hide_banner -decoders | tee /tmp/decoders.txt && \
    for d in h264 hevc vp9 av1 libdav1d h264_rkmpp hevc_rkmpp vp9_rkmpp av1_rkmpp; do \
      grep -qw "$d" /tmp/decoders.txt || { echo "MISSING DECODER: $d"; exit 1; }; \
    done && \
    echo "All expected decoders present." && \
    { LD_LIBRARY_PATH=/usr/local/lib /usr/local/bin/ffmpeg -hide_banner -buildconf | grep -q -- '--disable-asm' && { echo "ERROR: ffmpeg asm disabled"; exit 1; }; } || echo "ffmpeg asm enabled."

# Libdisplay-info, a hard dependency for kodi GBM.
WORKDIR /src/libdisplay-info
RUN mkdir build && cd build && meson setup --prefix=/usr/local --buildtype=release .. && ninja && ninja install

# Clone Kodi; ARG invalidates the cache!
ARG KODI_BRANCH="master"
# xiaobao: 固定到上游最后一次验证可编译的 master 提交（2026-07-21，对应上游 release 20260721-1741）。
#          kodi master 是移动目标，Rockchip 支持多次被合并/回退（见 README），最新 master 随时可能断编译。
#          KODI_COMMIT 留空或填 "latest" 时回退为克隆最新 master。
ARG KODI_COMMIT="70b11fc1ec8b493ef7580e54bacef76215afb1a1"
WORKDIR /src
RUN if [ -n "${KODI_COMMIT}" ] && [ "${KODI_COMMIT}" != "latest" ]; then \
        echo "=== Building PINNED Kodi commit: ${KODI_COMMIT} ==="; \
        git init kodi && cd kodi && \
        git remote add origin https://github.com/xbmc/xbmc.git && \
        git -c advice.detachedHead=false fetch --depth=1 origin "${KODI_COMMIT}" && \
        git checkout -q FETCH_HEAD; \
    else \
        echo "=== Building LATEST Kodi ${KODI_BRANCH} ==="; \
        git -c advice.detachedHead=false clone -b "${KODI_BRANCH}" --single-branch https://github.com/xbmc/xbmc.git kodi; \
    fi
WORKDIR /src/kodi
RUN git rev-parse HEAD

# Add some quality of life patches, taken from LibreELEC.
ADD patches /src/patches
WORKDIR /src/kodi
RUN for p in /src/patches/kodi/*.patch; do echo "Applying patch ${p} ..."; patch -p1 < "$p"; done

# In the beggining there was boogie PR https://github.com/xbmc/xbmc/pull/24431 -- we cherry-picked from that and life was good.
# Then that PR got merged -- we got from master, and life was good.
# Then, the whoile thing got reverted in https://github.com/xbmc/xbmc/pull/25864 - revision 9a6358ee823a92a2126354e0e579965c773cdff7
# So now we revert the revert so Rockchip does the boogie again
# May'2026: boogie/reardonia/chewitt at it again: https://github.com/xbmc/xbmc/pull/27402 et al - thus plain "master"

# Kodi build. the --build step actually downloads things and that might fail, so retry it a few times.
WORKDIR /src/kodi-build
RUN cmake ../kodi -DCMAKE_INSTALL_PREFIX=/usr/local -DCORE_PLATFORM_NAME=gbm -DAPP_RENDER_SYSTEM=gles -DENABLE_INTERNAL_FMT=ON -DENABLE_INTERNAL_FLATBUFFERS=ON && \
    cmake --build . -- -j$(nproc) || cmake --build . -- -j$(nproc) || cmake --build . -- -j$(nproc) && \
    make install

# Lets build & install shadertoy visualization addon
WORKDIR /src
RUN git clone --branch Piers https://github.com/xbmc/visualization.shadertoy.git
WORKDIR /src/visualization.shadertoy/build
RUN cmake -DADDONS_TO_BUILD=visualization.shadertoy -DADDON_SRC_PREFIX=../.. -DCMAKE_INSTALL_PREFIX=/usr/local/share/kodi/addons -DCMAKE_BUILD_TYPE=Release -DPACKAGE_ZIP=1 /src/kodi/cmake/addons
RUN make

# Lets build & install shadertoy screensaver addon
WORKDIR /src
RUN git clone --branch Piers https://github.com/xbmc/screensaver.shadertoy.git
WORKDIR /src/screensaver.shadertoy/build
RUN cmake -DADDONS_TO_BUILD=screensaver.shadertoy -DADDON_SRC_PREFIX=../.. -DCMAKE_INSTALL_PREFIX=/usr/local/share/kodi/addons -DCMAKE_BUILD_TYPE=Release -DPACKAGE_ZIP=1 /src/kodi/cmake/addons
RUN make

# xiaobao: Lets build & install the PVR IPTV Simple Client addon (直播源 PVR 插件)
# 分支须与 Kodi 版本对应：kodi master == Piers (v22) 时期用 Piers 分支
ARG PVR_IPTVSIMPLE_BRANCH="Piers"
WORKDIR /src
RUN git -c advice.detachedHead=false clone --branch "${PVR_IPTVSIMPLE_BRANCH}" --depth=1 https://github.com/kodi-pvr/pvr.iptvsimple.git
WORKDIR /src/pvr.iptvsimple/build
RUN cmake -DADDONS_TO_BUILD=pvr.iptvsimple -DADDON_SRC_PREFIX=../.. -DCMAKE_INSTALL_PREFIX=/usr/local/share/kodi/addons -DCMAKE_BUILD_TYPE=Release -DPACKAGE_ZIP=1 /src/kodi/cmake/addons && \
    make -j$(nproc) && \
    ls -lah /usr/local/share/kodi/addons/pvr.iptvsimple

# Lets preinstall the Jellyfin Kodi repository add-on, just for convenience
WORKDIR /usr/local/share/kodi/addons
RUN wget "https://kodi.jellyfin.org/repository.jellyfin.kodi.zip"
RUN unzip repository.jellyfin.kodi.zip
RUN rm repository.jellyfin.kodi.zip
RUN ls -lah /usr/local/share/kodi/addons /usr/local/share/kodi/addons/repository.jellyfin.kodi

### ------- packaging

# Drop headers for now. We don't need them in the final package.
WORKDIR /pkg/src/usr
RUN rm -rf /usr/local/include && cp -pr /usr/local /pkg/src/usr/

# Prepare debian binary package
WORKDIR /pkg/src
ADD debian /pkg/src/debian

# xiaobao: debhelper < 14（noble 13.14 / jammy 13.6）不支持 compat 14，打包前自动降级到 13；
#          若 dh-sequence-single-binary 不存在则从 Build-Depends 剔除（单包场景行为一致）
RUN DH_MAJOR="$(dpkg-query -W -f='${Version}' debhelper | cut -d. -f1)" && \
    if [ "${DH_MAJOR}" -lt 14 ]; then \
        echo "debhelper ${DH_MAJOR} detected: downgrading X-DH-Compat to 13"; \
        sed -i 's/^X-DH-Compat:.*/X-DH-Compat: 13/' /pkg/src/debian/control && \
        sed -i 's/debhelper (>= 13.16~)/debhelper (>= 13)/' /pkg/src/debian/control; \
    fi && \
    if ! dpkg-query -W dh-sequence-single-binary >/dev/null 2>&1; then \
        echo "dh-sequence-single-binary missing: stripping from Build-Depends"; \
        sed -i 's/, dh-sequence-single-binary//' /pkg/src/debian/control; \
    fi
# Example GUI settings. This is probably old and unuseful these days.
ADD userdata/guisettings.xml /pkg/src/usr/local/share/kodi/example_userdata_guisettings.xml

# For Pulseaudio, we need to add a system.pa file. This is a hack.
# The unit file sets env PULSE_CONFIG_PATH=/usr/local/share/pulse-kodi
WORKDIR /pkg/src/usr/local/share/pulse-kodi
ADD pulseaudio/system.pa /pkg/src/usr/local/share/pulse-kodi/system.pa

WORKDIR /pkg/src
RUN echo "usr/*" > debian/kodi-rockchip-gbm.install

# Create the "Architecture:" field in control; ARG invalidates the cache.
ARG OS_ARCH="arm64"
RUN echo "Architecture: ${OS_ARCH}" >> /pkg/src/debian/control

# Create the Changelog, fake. ARG here invalidates the cache.
ARG PACKAGE_VERSION="20260513"
ARG FFMPEG_ID="81"
RUN echo "kodi-rockchip-gbm (${PACKAGE_VERSION}-kodi-${KODI_BRANCH}-ffmpeg-${FFMPEG_ID}-pvr) stable; urgency=medium" >> /pkg/src/debian/changelog && \
    echo "" >> /pkg/src/debian/changelog && \
    echo "  * Not a real changelog. Sorry. Includes pvr.iptvsimple." >> /pkg/src/debian/changelog && \
    echo "" >> /pkg/src/debian/changelog && \
    echo " -- Ricardo Pardini <ricardo@pardini.net>  Wed, 15 Sep 2021 14:18:33 +0200" >> /pkg/src/debian/changelog && \
    cat /pkg/src/debian/changelog

# Build the package, don't sign it, don't lint it, compress fast with xz
WORKDIR /pkg/src
RUN debuild --no-lintian --build=binary -us -uc -Zxz -z1

# Show package info
RUN file /pkg/*.deb && \
    dpkg-deb -I /pkg/*.deb && \
    dpkg-deb -f /pkg/*.deb && \
    apt-get install -y /pkg/*.deb

# Now prepare the real output: the .deb for this release and arch.
WORKDIR /artifacts
RUN cp -v /pkg/*.deb kodi-rockchip-gbm_${OS_ARCH}_kodi_${KODI_BRANCH}_ffmpeg_${FFMPEG_ID}_pvr_$(lsb_release -c -s).deb

# An intermediate stage, which is just the base image + the installed built package.
# Who wouldn't want to run Kodi in a container?
# Lets avoid a layer with the .deb as that is huge.
FROM ${BASE_IMAGE} AS containerized-kodi

# Install the built package. Bind-mount the .deb from the packager stage so it's
# only present during this RUN and never ends up in a published layer.
ENV DEBIAN_FRONTEND=noninteractive
RUN --mount=type=bind,from=packager,source=/artifacts,target=/debs \
    apt-get -y update && \
    apt-get -y install /debs/*.deb pulseaudio-utils ir-keytable && \
    rm -rf /var/lib/apt/lists/*


# Final stage is just the output deb
FROM scratch
COPY --from=packager /artifacts/* /
