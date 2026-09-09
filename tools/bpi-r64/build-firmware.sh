#!/bin/sh
#
# Build the BPI-R64 (MediaTek MT7622) boot firmware: ARM Trusted Firmware
# BL2 (bl2.img) and the FIP (BL31 + U-Boot as BL33, fip.bin).
#
# Sources default to Frank Wunderlich's trees, which are the de-facto
# upstream for the Banana Pi routers:
#   U-Boot: https://github.com/frank-w/u-boot (branch 2026-07-bpi)
#   ATF:    https://github.com/frank-w/u-boot (branch mtk-atf, a fork of
#           mtk-openwrt/arm-trusted-firmware)
#
# Runs on a Linux host with an aarch64-linux-gnu- cross toolchain
# (Debian/Ubuntu: gcc-aarch64-linux-gnu bison flex swig python3-dev
# libssl-dev device-tree-compiler uuid-dev libgnutls28-dev bc xxd).
#
# Usage: build-firmware.sh [-o outdir] [-w workdir] [-d sdmmc|emmc]
#
# Environment overrides: UBOOT_REPO UBOOT_BRANCH UBOOT_DEFCONFIG UBOOT_ENV_FILE
#                        ATF_REPO ATF_BRANCH CROSS_COMPILE ATF_EXTRA_FLAGS
#
# UBOOT_ENV_FILE is the default U-Boot environment compiled into u-boot.bin
# (uEnv_freebsd.txt next to this script by default, which boots the FreeBSD
# loader off the image's ESP).  Set it empty to keep frank-w's Linux one.
#

set -eu

SCRIPTDIR=$(cd "$(dirname "$0")" && pwd)

OUTDIR=${OUTDIR:-$(pwd)/firmware}
WORKDIR=${WORKDIR:-$(pwd)/firmware-src}
BOOT_DEVICE=${BOOT_DEVICE:-sdmmc}

while getopts "o:w:d:" opt; do
	case ${opt} in
	o) OUTDIR=$OPTARG ;;
	w) WORKDIR=$OPTARG ;;
	d) BOOT_DEVICE=$OPTARG ;;
	*) echo "usage: $0 [-o outdir] [-w workdir] [-d sdmmc|emmc]" >&2; exit 2 ;;
	esac
done

UBOOT_REPO=${UBOOT_REPO:-https://github.com/frank-w/u-boot.git}
UBOOT_BRANCH=${UBOOT_BRANCH:-2026-07-bpi}
UBOOT_DEFCONFIG=${UBOOT_DEFCONFIG:-mt7622_bpi-r64_defconfig}
ATF_REPO=${ATF_REPO:-https://github.com/frank-w/u-boot.git}
ATF_BRANCH=${ATF_BRANCH:-mtk-atf}
ATF_PLAT=mt7622
# Unset (not just empty) means "use ours"; UBOOT_ENV_FILE= keeps the stock one.
UBOOT_ENV_FILE=${UBOOT_ENV_FILE-${SCRIPTDIR}/uEnv_freebsd.txt}
# DDR3_FLYBY=1 is what frank-w's build.sh uses for the BPI-R64.
ATF_EXTRA_FLAGS=${ATF_EXTRA_FLAGS:-DDR3_FLYBY=1}

export ARCH=arm64
export CROSS_COMPILE=${CROSS_COMPILE:-aarch64-linux-gnu-}

NPROC=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)

clone() {
	# clone <repo> <branch> <dir>
	if [ -d "$3/.git" ]; then
		echo ">>> reusing $3"
		return 0
	fi
	echo ">>> cloning $1 ($2) into $3"
	git clone --depth 1 --single-branch -b "$2" "$1" "$3"
}

mkdir -p "${OUTDIR}" "${WORKDIR}"
UBOOT_DIR=${WORKDIR}/u-boot
ATF_DIR=${WORKDIR}/atf

clone "${UBOOT_REPO}" "${UBOOT_BRANCH}" "${UBOOT_DIR}"
clone "${ATF_REPO}" "${ATF_BRANCH}" "${ATF_DIR}"

echo ">>> building U-Boot (${UBOOT_DEFCONFIG})"
make -C "${UBOOT_DIR}" "${UBOOT_DEFCONFIG}"

if [ -n "${UBOOT_ENV_FILE}" ]; then
	# The defconfig compiles frank-w's Linux boot menu (uEnv_r64.txt) in as
	# the default environment and selects CONFIG_ENV_IS_NOWHERE=y, so the
	# board cannot be taught to boot FreeBSD with setenv + saveenv: there is
	# nowhere to save it.  Replace the environment at build time instead.
	echo ">>> default U-Boot environment: ${UBOOT_ENV_FILE}"
	test -f "${UBOOT_ENV_FILE}"
	cp "${UBOOT_ENV_FILE}" "${UBOOT_DIR}/uEnv_freebsd.txt"
	sed -i '/^CONFIG_ENV_DEFAULT_ENV_TEXT_FILE=/d' "${UBOOT_DIR}/.config"
	echo 'CONFIG_ENV_DEFAULT_ENV_TEXT_FILE="uEnv_freebsd.txt"' \
	    >> "${UBOOT_DIR}/.config"
	make -C "${UBOOT_DIR}" olddefconfig
	# olddefconfig silently drops values whose dependencies are unmet.
	grep -q '^CONFIG_ENV_DEFAULT_ENV_TEXT_FILE="uEnv_freebsd.txt"$' \
	    "${UBOOT_DIR}/.config" || \
	    { echo "$0: U-Boot kept its own default environment" >&2; exit 1; }
fi

make -C "${UBOOT_DIR}" -j"${NPROC}" all tools
test -f "${UBOOT_DIR}/u-boot.bin"
test -x "${UBOOT_DIR}/tools/mkimage"

echo ">>> building ATF BL2 + FIP (PLAT=${ATF_PLAT} BOOT_DEVICE=${BOOT_DEVICE})"
# The MediaTek ATF wraps BL2 with mkimage(1) into the header the MT7622
# BootROM expects; the FIP carries BL31 plus U-Boot (BL33).
make -C "${ATF_DIR}" -j"${NPROC}" \
	PLAT=${ATF_PLAT} BOOT_DEVICE=${BOOT_DEVICE} ${ATF_EXTRA_FLAGS} \
	USE_MKIMAGE=1 MKIMAGE="${UBOOT_DIR}/tools/mkimage" \
	BL33="${UBOOT_DIR}/u-boot.bin" \
	all fip

BUILD=${ATF_DIR}/build/${ATF_PLAT}/release
cp "${BUILD}/bl2.img" "${OUTDIR}/bl2.img"
cp "${BUILD}/fip.bin" "${OUTDIR}/fip.bin"
cp "${UBOOT_DIR}/u-boot.bin" "${OUTDIR}/u-boot.bin"
cp "${UBOOT_DIR}/tools/mkimage" "${OUTDIR}/mkimage"

cat > "${OUTDIR}/VERSIONS" <<VEOF
u-boot: ${UBOOT_REPO} ${UBOOT_BRANCH} $(git -C "${UBOOT_DIR}" rev-parse HEAD) ${UBOOT_DEFCONFIG}
env:    ${UBOOT_ENV_FILE:-(stock uEnv_r64.txt)}
atf:    ${ATF_REPO} ${ATF_BRANCH} $(git -C "${ATF_DIR}" rev-parse HEAD) PLAT=${ATF_PLAT} BOOT_DEVICE=${BOOT_DEVICE} ${ATF_EXTRA_FLAGS}
VEOF

echo ">>> firmware written to ${OUTDIR}:"
ls -l "${OUTDIR}"
