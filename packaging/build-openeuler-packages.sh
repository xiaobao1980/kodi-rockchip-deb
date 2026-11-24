#!/usr/bin/env bash
# openEuler packaging for Dockerfile.kodi (rpm family).
#
# Turns the prepared staging tree (<stage>/usr/local, appliance.xml + system.pa already in place) into:
#   * a native .rpm  for openEuler            (rpmbuild)
#   * a cross-distro .deb for deepin/Debian/Ubuntu (dpkg-deb, no debuild: nothing here is a Debian source package)
#   * the same pair for the ffmpeg-only payload
#
# The openEuler quirks handled here are the same ones build-kodi-rockchip-openeuler.sh needed to get through CI:
# kodi-gbm lands in /usr/local/lib64 (Kodi's cmake ignores CMAKE_INSTALL_LIBDIR), rpmbuild splits %files on
# whitespace (so "Read Me.txt" becomes a bare "Me.txt" and errors), openEuler rejects `date -R` in %changelog,
# and find-debuginfo fails on a prebuilt tree with no sources.
#
# usage: build-openeuler-packages.sh <staging-dir> <out-dir>
# env: FLAVOR FFMPEG_BRANCH FFMPEG_ID KODI_BRANCH DAV1D_BRANCH PACKAGE_VERSION OS_ARCH OS_ID [SRC_DIR] [GLIBC_MIN]
set -euo pipefail

STAGE="${1:?usage: $0 <staging dir containing usr/> <output dir>}"
OUT="${2:?usage: $0 <staging dir containing usr/> <output dir>}"
: "${FLAVOR:?}" "${FFMPEG_BRANCH:?}" "${FFMPEG_ID:?}" "${KODI_BRANCH:?}" "${DAV1D_BRANCH:?}"
: "${PACKAGE_VERSION:?}" "${OS_ARCH:?}" "${OS_ID:?}"
SRC_DIR="${SRC_DIR:-/src}"
GLIBC_MIN="${GLIBC_MIN:-2.38}"
RPM_ARCH="${OS_ARCH/arm64/aarch64}" # deb says arm64, rpm says aarch64

PREFIX=/usr/local
WORK="${WORK:-/tmp/oe-pack}"
JOBS="$(nproc)"

log() { printf '[OE-PKG] %s\n' "$*"; }
die() { printf '[OE-PKG][FAIL] %s\n' "$*" >&2; exit 1; }

# rkmpp needs the vendor-kernel decoders, v4l2requests the mainline ones.
case "${FLAVOR}" in
	rkmpp)
		FFMPEG_DECODERS="h264 hevc vp9 av1 libdav1d h264_rkmpp hevc_rkmpp vp9_rkmpp av1_rkmpp"
		SYNOPSIS="Kodi GBM/GLES for Rockchip vendor kernels (rkmpp + rkrga hw decoding)"
		FFMPEG_NAME="ffmpeg-rockchip"
		;;
	v4l2requests)
		FFMPEG_DECODERS="h264 hevc vp9 av1 libdav1d h264_v4l2m2m hevc_v4l2m2m vp9_v4l2m2m"
		SYNOPSIS="Kodi GBM/GLES for mainline kernels (V4L2 Request API hw decoding)"
		FFMPEG_NAME="FFmpeg"
		;;
	*) die "unknown FLAVOR '${FLAVOR}'" ;;
esac

[ -d "${STAGE}/usr" ] || die "no ${STAGE}/usr in the staging tree"
mkdir -p "${OUT}" "${WORK}"

rev() { git -C "${SRC_DIR}/$1" rev-parse --short=10 HEAD 2> /dev/null || echo "unknown"; }

### ------- gates (before anything is written into a package)

kodi_bin=""
for cand in "${STAGE}${PREFIX}/lib/kodi/kodi-gbm" "${STAGE}${PREFIX}/lib64/kodi/kodi-gbm"; do
	[ -f "${cand}" ] && { kodi_bin="${cand}"; break; }
done
[ -n "${kodi_bin}" ] || die "kodi-gbm not found under ${STAGE}${PREFIX}/lib or lib64"
log "kodi-gbm: ${kodi_bin}"

for elf in "${kodi_bin}" "${STAGE}${PREFIX}/bin/ffmpeg" "${STAGE}${PREFIX}/bin/ffprobe"; do
	[ -f "${elf}" ] || die "RUNPATH target missing: ${elf}"
	readelf -d "${elf}" | grep -qF RUNPATH || die "no RUNPATH on ${elf}"
done

decoders="$(LD_LIBRARY_PATH="${STAGE}${PREFIX}/lib:${STAGE}${PREFIX}/lib64" "${STAGE}${PREFIX}/bin/ffmpeg" -hide_banner -decoders 2> /tmp/oe-ffmpeg.err || true)"
if [ -z "${decoders}" ]; then
	log "ffmpeg -decoders produced no output; runtime libs:"
	tail -20 /tmp/oe-ffmpeg.err
	ldd "${STAGE}${PREFIX}/bin/ffmpeg" 2>&1 | grep -i "not found" || true
	die "staging ffmpeg is not runnable"
fi
missing=""
for d in ${FFMPEG_DECODERS}; do
	printf '%s\n' "${decoders}" | grep -qw "${d}" || missing="${missing} ${d}"
done
[ -z "${missing}" ] || die "ffmpeg decoders missing:${missing}"
{ ldd "${kodi_bin}" "${STAGE}${PREFIX}/bin/ffmpeg" "${STAGE}${PREFIX}/bin/ffprobe" 2>&1 | grep 'not found'; } &&
	die "unresolved dependencies in the staging tree" || true
log "gates passed (decoders, RUNPATH, link closure)"
### ------- staging tree finishing touches

# Build info for Kodi's System Information page (the deb path renders the same placeholders via render-metadata.sh).
rev_extra=""
[ "${FLAVOR}" = "rkmpp" ] && rev_extra=", MPP @$(rev rkmpp), RGA @$(rev rkrga)"
BUILD_INFO="${FLAVOR} ${PACKAGE_VERSION} (${OS_ID}/${OS_ARCH})"
COMPONENTS="Kodi ${KODI_BRANCH} @$(rev kodi), ${FFMPEG_NAME} ${FFMPEG_BRANCH} @$(rev ffmpeg), dav1d ${DAV1D_BRANCH}${rev_extra}"
# The openEuler leg also carries its own GL fallback (see the Dockerfile/bare-metal mesa step). Name the
# version in the metadata so System info, the appliance build stamp and the package agree.
gl_so="$(ls "${STAGE}${PREFIX}"/share/kodi-rockchip/glfallback/lib/libgallium-*.so 2> /dev/null | head -1)"
[ -n "${gl_so}" ] && COMPONENTS="${COMPONENTS}, mesa $(basename "${gl_so}" .so | sed 's/^libgallium-//') (panfrost)"

appliances=("${STAGE}${PREFIX}/share/kodi/system/settings/appliance.xml" "${STAGE}${PREFIX}/lib64/kodi/system/settings/appliance.xml")
xml_escaped_build_info="${BUILD_INFO//&/&amp;}"; xml_escaped_build_info="${xml_escaped_build_info//</&lt;}"; xml_escaped_build_info="${xml_escaped_build_info//>/&gt;}"
xml_escaped_components="${COMPONENTS//&/&amp;}"; xml_escaped_components="${xml_escaped_components//</&lt;}"; xml_escaped_components="${xml_escaped_components//>/&gt;}"
for f in "${appliances[@]}"; do
	[ -f "${f}" ] || continue
	sed -i "s|@BUILD_INFO@|${xml_escaped_build_info}|g; s|@COMPONENTS@|${xml_escaped_components}|g" "${f}"
	grep -q '@BUILD_INFO@\|@COMPONENTS@' "${f}" && die "unrendered placeholders left in ${f}" || true
	python3 -c "import xml.etree.ElementTree as ET; ET.parse('${f}')" || die "appliance.xml is not valid XML: ${f}"
	log "appliance.xml rendered: ${f}"
done

# systemd units: the deb path ships them through debian/*.service; here they go into the tree itself.
# debian/ uses the dh template naming (kodi-rockchip-gbm.<unit>.service), which dh_installinit would strip on
# install; we are not running dh, so strip the <package>. prefix here - otherwise the units land as
# kodi-rockchip-gbm.kodi.service and "systemctl start kodi" (which the docs, and pulseaudio.service's own
# WantedBy, both use) finds nothing.
unit_src="${STAGE}/debian"
if compgen -G "${unit_src}/*.service" > /dev/null; then
	mkdir -p "${STAGE}/usr/lib/systemd/system"
	for u in "${unit_src}"/*.service; do
		unit="$(basename "${u}")"
		cp -v "${u}" "${STAGE}/usr/lib/systemd/system/${unit#kodi-rockchip-gbm.}"
	done
fi

# Slim down: no headers, no static libs, no libtool files.
rm -rf "${STAGE}${PREFIX}/include"
for libdir in lib lib64; do
	[ -d "${STAGE}${PREFIX}/${libdir}" ] || continue
	find "${STAGE}${PREFIX}/${libdir}" -name '*.a' -delete 2> /dev/null || true
	find "${STAGE}${PREFIX}/${libdir}" -name '*.la' -delete 2> /dev/null || true
done

# rpmbuild tokenises %files on whitespace, so a Kodi add-on named "Read Me.txt" arrives as the bare name
# "Me.txt" and fails with 'File must begin with "/"'. Normalise such names once, for both package types.
# Names are normalized before anything is recorded: the %files list and the tarball must describe the same paths.
normalize_names() { # <root>
	find "$1" -depth -print0 | while IFS= read -r -d '' p; do
		local b c
		b="$(basename "${p}")"
		c="$(printf '%s' "${b}" | tr -c 'A-Za-z0-9._-' '_')"
		[ "${c}" = "${b}" ] || mv -f "${p}" "$(dirname "${p}")/${c}"
	done
}
normalize_names "${STAGE}/usr"

FILES=()
while IFS= read -r line; do FILES+=("${line}"); done < <(cd "${STAGE}" && find usr \( -type f -o -type l \) -printf '/%p\n' | sort -u | grep '^/usr/')
[ "${#FILES[@]}" -gt 0 ] || die "staging tree is empty, nothing to package"
log "${#FILES[@]} files to ship"

# rpm Version must stay machine-parsable: no dashes (CI feeds PACKAGE_VERSION as YYYYmmdd-HHMM).
RPM_VERSION="$(printf '%s' "${PACKAGE_VERSION}" | tr -c 'A-Za-z0-9._+' '.' | sed 's/^[^A-Za-z0-9]*//')"
DEB_VERSION="$(printf '%s' "${PACKAGE_VERSION}" | sed 's/[^A-Za-z0-9.+-]/./g')-kodi-${KODI_BRANCH}-ffmpeg-${FFMPEG_ID}"
[[ "${RPM_VERSION}" =~ ^[0-9] ]] || RPM_VERSION="0.${RPM_VERSION}"
log "rpm Version=${RPM_VERSION} deb Version=${DEB_VERSION}"

# The mesa entries are the distro GL stack, which every desktop/base install already carries. On openEuler they are
# not what makes GL work (the bundled glfallback in front of kodi-gbm's RUNPATH is), but keeping them costs nothing
# and still covers the case where the mesa build step was skipped, plus it mirrors the load-bearing deb Depends.
RUNTIME_REQUIRES="mesa-libgbm, mesa-libEGL, mesa-libGLES, mesa-libGL, mesa-dri-drivers, libX11, libXext, libXrandr, libXinerama, libXv, libXt, libxkbcommon, wayland, alsa-lib, pulseaudio-libs, libdrm, libinput, systemd"
DEB_DEPENDS="libgbm1, libegl1, libgles2, libgl1, libx11-6, libxext6, libxrandr2, libxinerama1, libxv1, libxt6, libxkbcommon0, libwayland-client0, libasound2t64 | libasound2, libpulse0, libdrm2, libinput10, libstdc++6, libc6, zlib1g"

### ------- pre/post scriptlets

# Advisory only, like the deb-family packages this tree is built alongside: a hard abort would also break the
# containerized-kodi stage, which installs the package on a runner that has no /dev/mpp_service.
pre_checks() { # <progname>
	cat <<-'SCRIPTLET'
	if [ ! -e /dev/mpp_service ]; then
		echo "PKGNAME: /dev/mpp_service is missing - the rkmpp flavor needs a Rockchip vendor kernel." >&2
	fi
	glibc="$(ldd --version | head -1 | grep -oP '[0-9]+\.[0-9]+$' || echo 0)"
	awk -v v="${glibc}" -v min="GLIBC_MIN" 'BEGIN{exit !(v+0 >= min+0)}' ||
		echo "PKGNAME: built against glibc >= GLIBC_MIN, this host has ${glibc}." >&2
	SCRIPTLET
}

post_script() {
	cat <<-'SCRIPTLET'
	systemctl disable --now gdm3 sddm lightdm 2> /dev/null || true
	if [ ! -f /etc/pulse/system.pa ] && [ -f /usr/local/share/pulse-kodi/system.pa ]; then
		mkdir -p /etc/pulse
		cp /usr/local/share/pulse-kodi/system.pa /etc/pulse/system.pa || true
	fi
	ldconfig 2> /dev/null || true
	echo "kodi-rockchip-gbm: installed. systemctl start kodi (or kodi-pulse) to run, enable for boot."
	SCRIPTLET
}

### ------- .rpm

emit_rpm() { # <name> <artifact-name> <summary> <description> <requires> <conflicts> <tar-root> <tarball-name> <files...>
	local name="$1" artifact="$2" summary="$3" desc="$4" requires="$5" conflicts="$6" tar_root="$7" tarball="$8"
	shift 8
	local rpmdir="${WORK}/rpmbuild-${name}" spec
	mkdir -p "${rpmdir}"/{SPECS,SOURCES,RPMS,SRPMS,BUILD}
	spec="${rpmdir}/SPECS/${name}.spec"
	# Source0 is looked up in %{_sourcedir}, which is this rpmdir's SOURCES: the tarball has to live there.
	tar --numeric-owner -C "${tar_root}" -czf "${rpmdir}/SOURCES/${tarball}" usr
	{
		echo "Name:           ${name}"
		echo "Version:        ${RPM_VERSION}"
		echo "Release:        1%{?dist}"
		echo "Summary:        ${summary}"
		echo "License:        GPLv2+ and GPLv3+ and LGPLv2+"
		echo "Group:          Applications/Multimedia"
		echo "Source0:        ${tarball}"
		echo "BuildArch:      ${RPM_ARCH}"
		echo "%define debug_package %{nil}"
		echo "Requires:       ${requires}"
		[ -z "${conflicts}" ] || echo "Conflicts:      ${conflicts}"
		echo "%description"
		printf '%s\n' "${desc}"
		echo "%prep"
		echo "%setup -T -c -n ${name}"
		echo "%build"
		echo "# nothing to compile: the binaries come from the openEuler build stage"
		echo "%install"
		echo "rm -rf %{buildroot}"
		echo "mkdir -p %{buildroot}"
		echo "tar -xzf %{S:0} -C %{buildroot}"
		echo "%pre"
		pre_checks "${name}" | sed -e "s/PKGNAME/${name}/g" -e "s/GLIBC_MIN/${GLIBC_MIN}/g"
		echo "%post"
		post_script
		echo "%files"
		echo "%defattr(-,root,root,-)"
		printf '%s\n' "$@"
		echo "%changelog"
		echo "* $(date '+%a %b %d %Y') openEuler Kodi SIG <kodi@openeuler.local> - ${RPM_VERSION}-1"
		echo "- Built in the openEuler container of Dockerfile.kodi (${FLAVOR}, ffmpeg ${FFMPEG_BRANCH})."
	} > "${spec}"
	log "spec: ${spec}"
	rpmbuild --define "%_topdir ${rpmdir}" -bb "${spec}" > "${WORK}/rpmbuild-${name}.log" 2>&1 || {
		tail -40 "${WORK}/rpmbuild-${name}.log"
		die "rpmbuild failed for ${name}"
	}
	find "${rpmdir}/RPMS" -name "*.rpm" -exec mv -fv {} "${OUT}/${artifact}" \;
}

emit_rpm kodi-rockchip-gbm \
	"kodi-rockchip-gbm_${OS_ARCH}_kodi_${KODI_BRANCH}_ffmpeg_${FFMPEG_ID}_${OS_ID}.rpm" \
	"${SYNOPSIS}" \
	"Kodi media center, built for standalone GBM/KMS with GLES rendering on Rockchip boards,
for openEuler. Bundles its own FFmpeg, dav1d, libdisplay-info${rev_extra:+, MPP and RGA} under
/usr/local (not FHS). The rkmpp flavor needs a Rockchip vendor kernel (/dev/mpp_service)." \
	"${RUNTIME_REQUIRES}" "" "${STAGE}" usr.tgz "${FILES[@]}"

### ------- .deb (cross-distro, Debian-family targets)

debroot="${WORK}/deb-root"
rm -rf "${debroot}"
mkdir -p "${debroot}/DEBIAN"
cp -a "${STAGE}/usr" "${debroot}/usr"
# The deb targets deepin/Debian/Ubuntu, whose mesa already carries panfrost. Drop the openEuler-only
# GL fallback so we never shadow a working distro stack; kodi-gbm's RUNPATH entry for it is simply
# unused when the directory is absent.
rm -rf "${debroot}/usr/local/share/kodi-rockchip/glfallback"
{
	echo "Package: kodi-rockchip-gbm"
	echo "Version: ${DEB_VERSION}"
	echo "Section: video"
	echo "Priority: optional"
	echo "Architecture: ${OS_ARCH}"
	echo "Maintainer: openEuler Kodi SIG <kodi@openeuler.local>"
	echo "Homepage: https://github.com/armsurvivors/kodi-rockchip-deb"
	echo "Depends: ${DEB_DEPENDS}"
	echo "Provides: kodi, kodi-rockchip-gbm-${FLAVOR}"
	echo "Conflicts: kodi"
	echo "XB-Kodi-Rockchip-Flavor: ${FLAVOR}"
	echo "XB-Kodi-Rockchip-Build: ${BUILD_INFO}"
	echo "XB-Kodi-Rockchip-Components: ${COMPONENTS}"
	echo "Description: ${SYNOPSIS}"
	echo " Bundles its own FFmpeg, dav1d and libdisplay-info under /usr/local, plus the"
	echo " shadertoy add-ons and the binary add-ons Kodi does not get from distro repos."
	echo " Built in an openEuler ${OS_ID} container, so it needs glibc >= ${GLIBC_MIN} and"
	echo " works on openEuler, deepin 25, Debian trixie/forky and Ubuntu resolute/noble."
} > "${debroot}/DEBIAN/control"
{
	echo "#!/bin/sh"
	echo "set -e"
	pre_checks "kodi-rockchip-gbm" | sed -e "s/GLIBC_MIN/${GLIBC_MIN}/g"
} > "${debroot}/DEBIAN/preinst"
{
	echo "#!/bin/sh"
	echo "set -e"
	post_script
} > "${debroot}/DEBIAN/postinst"
chmod +x "${debroot}/DEBIAN/preinst" "${debroot}/DEBIAN/postinst"
dpkg-deb --root-owner-group -Zxz -z1 --build "${debroot}" \
	"${OUT}/kodi-rockchip-gbm_${OS_ARCH}_kodi_${KODI_BRANCH}_ffmpeg_${FFMPEG_ID}_${OS_ID}.deb"
log "deb built"

### ------- ffmpeg-only pair (same payload as above, minus Kodi)

ffd="${WORK}/ffmpeg-only"
ffstage="${WORK}/ff-stage"
rm -rf "${ffd}" "${ffstage}"
mkdir -p "${ffd}/DEBIAN" "${ffd}/usr/local/bin" "${ffstage}/usr/local/bin"
cp -a "${STAGE}${PREFIX}/bin/ffmpeg" "${STAGE}${PREFIX}/bin/ffprobe" "${ffd}/usr/local/bin/"
cp -a "${STAGE}${PREFIX}/bin/ffmpeg" "${STAGE}${PREFIX}/bin/ffprobe" "${ffstage}/usr/local/bin/"
while IFS= read -r lib; do
	rel="${lib#"${STAGE}"}" # strip the staging root: /usr/local/lib/...
	mkdir -p "${ffd}$(dirname "${rel}")" "${ffstage}$(dirname "${rel}")"
	cp -aL "${lib}" "${ffd}${rel}"
	cp -aL "${lib}" "${ffstage}${rel}"
done < <(
	LD_LIBRARY_PATH="${STAGE}${PREFIX}/lib:${STAGE}${PREFIX}/lib64"
	export LD_LIBRARY_PATH
	ldd "${STAGE}${PREFIX}/bin/ffmpeg" "${STAGE}${PREFIX}/bin/ffprobe" 2> /dev/null |
		awk -v s="${STAGE}" '$3 ~ "^" s "/usr/local/" {print $3}' | sort -u
)

FF_FILES=()
while IFS= read -r line; do FF_FILES+=("${line}"); done < <(cd "${ffstage}" && find usr \( -type f -o -type l \) -printf '/%p\n' | sort -u)
normalize_names "${ffstage}/usr"
[ "${#FF_FILES[@]}" -gt 0 ] || die "ffmpeg-only payload is empty"
emit_rpm kodi-rockchip-gbm-ffmpeg \
	"kodi-rockchip-gbm-ffmpeg_${OS_ARCH}_ffmpeg_${FFMPEG_ID}_${OS_ID}.rpm" \
	"ffmpeg/ffprobe from kodi-rockchip-gbm, without Kodi" \
	"The same ffmpeg build as kodi-rockchip-gbm (${FLAVOR}, ${FFMPEG_NAME} ${FFMPEG_BRANCH}), in
/usr/local, for use without Kodi. It conflicts with kodi-rockchip-gbm, which already contains it." \
	"${RUNTIME_REQUIRES}" kodi-rockchip-gbm "${ffstage}" ff-usr.tgz "${FF_FILES[@]}"

# Same rule as the kodi .deb above: a Debian-family payload never carries the openEuler-only GL fallback.
rm -rf "${ffd}${PREFIX}/share/kodi-rockchip/glfallback"
{
	echo "Package: kodi-rockchip-gbm-ffmpeg"
	echo "Version: ${DEB_VERSION}"
	echo "Section: video"
	echo "Priority: optional"
	echo "Architecture: ${OS_ARCH}"
	echo "Maintainer: openEuler Kodi SIG <kodi@openeuler.local>"
	echo "Homepage: https://github.com/armsurvivors/kodi-rockchip-deb"
	echo "Depends: ${DEB_DEPENDS}"
	echo "Conflicts: kodi-rockchip-gbm"
	echo "Description: ffmpeg/ffprobe from kodi-rockchip-gbm (${FLAVOR}, ffmpeg ${FFMPEG_BRANCH})"
	echo " The same ffmpeg build as kodi-rockchip-gbm, in /usr/local, for use without Kodi."
	echo " It conflicts with kodi-rockchip-gbm, which already contains it."
} > "${ffd}/DEBIAN/control"
dpkg-deb --root-owner-group -Zxz -z1 --build "${ffd}" \
	"${OUT}/kodi-rockchip-gbm-ffmpeg_${OS_ARCH}_ffmpeg_${FFMPEG_ID}_${OS_ID}.deb"
log "ffmpeg-only pair built"

log "artifacts:"
ls -lah "${OUT}"
