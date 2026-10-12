# FreeBSD SD card image for the Banana Pi BPI-R64 (MediaTek MT7622)

Everything here builds without root and without a FreeBSD host: the world
and the `MEDIATEK` kernel are cross-compiled on Linux with
`tools/build/make.py`, the firmware with an `aarch64-linux-gnu` GCC, and the
image is assembled with `makefs(8)` and `sgdisk(8)`.  The same steps run on
GitHub Actions in `.github/workflows/bpi-r64-image.yml`.

## Boot chain and card layout

MT7622 boots from SD card as: BootROM -> BL2 (ARM Trusted Firmware) ->
FIP (BL31 + U-Boot) -> U-Boot -> `EFI/BOOT/BOOTAA64.EFI` (FreeBSD
`loader.efi`) -> kernel.  `mkimage.sh` produces this layout (512-byte
sectors), which is what frank-w's `mtk-atf` `build.sh createimg` and OpenWrt
use for `sdmmc`:

| Offset            | Content                                   |
|-------------------|-------------------------------------------|
| LBA 0             | MBR: protective 0xEE entry + bootable 0xEF entry for BL2 |
| LBA 1-33          | GPT                                       |
| LBA 1024 (512 KiB)| `bl2.img` (raw, no partition)             |
| LBA 2048 (1 MiB)  | p1 `fip`: `fip.bin` (BL31 + U-Boot)       |
| LBA 6144 (3 MiB)  | p2 `ubootenv`: reserved, see Booting       |
| LBA 8192 (4 MiB)  | p3 `efi`: FAT16 ESP, loader + `dtb/`      |
| next MiB          | p4 `rootfs`: UFS2, grown on first boot    |

The MT7622 BootROM does not read BL2 from a fixed SD offset: it looks for
a bootable MBR partition entry (frank-w writes `r64_header_sdmmc.bin`,
OpenWrt uses `ptgen -H`) and loads BL2 from where that entry points.
`mkimage.sh` adds the entry (type 0xEF, LBA 1024, 1024 sectors) next to
the protective 0xEE entry sgdisk creates; without it the board stops at
`System halt!` before BL2 prints anything.

## Manual build on Linux (Debian/Ubuntu)

```sh
sudo apt install bmake libarchive-dev flex bison time gdisk \
    gcc-aarch64-linux-gnu bison flex swig python3-dev python3-setuptools \
    python3-pyelftools libssl-dev device-tree-compiler uuid-dev libgnutls28-dev bc xxd

git clone -b max-support-mediatek-7622-bananapir64 https://github.com/Martinfx/freebsd-src.git
cd freebsd-src

# 1. firmware: ATF BL2 + FIP with U-Boot (frank-w/u-boot 2026-07-bpi + mtk-atf)
./tools/bpi-r64/build-firmware.sh -o ../firmware -w ../firmware-src

# 2. world + MEDIATEK kernel, cross-built from Linux.
# The compiler must be at least as new as the in-tree LLVM (see
# lib/clang/include/llvm/Config/llvm-config.h, 21.1.8 today); Ubuntu's
# clang-18 fails in libc++.  Use the official release binaries:
V=$(awk '$2 == "LLVM_VERSION_STRING" {gsub(/"/, "", $3); print $3}' lib/clang/include/llvm/Config/llvm-config.h)
sudo mkdir -p /opt/llvm
curl -sSfL "https://github.com/llvm/llvm-project/releases/download/llvmorg-$V/LLVM-$V-Linux-X64.tar.xz" \
    | sudo tar xJ -C /opt/llvm --strip-components=1
export MAKEOBJDIRPREFIX=$PWD/../obj
cat > ../src.conf <<'EOT'
WITHOUT_TOOLCHAIN=yes
WITHOUT_LLVM_TARGET_ALL=yes
WITHOUT_LLDB=yes
WITHOUT_TESTS=yes
WITHOUT_DEBUG_FILES=yes
WITHOUT_PROFILE=yes
WITHOUT_LIB32=yes
WITHOUT_GOOGLETEST=yes
EOT
LLVM=/opt/llvm/bin
# X* binutils must be full paths, otherwise buildworld bootstraps lib/clang
# and the LLVM binutils from source (hours).
ARGS="--cross-bindir=$LLVM TARGET=arm64 TARGET_ARCH=aarch64 \
      -DWITHOUT_CLEAN -DWITH_DISK_IMAGE_TOOLS_BOOTSTRAP SRCCONF=$PWD/../src.conf \
      XAR=$LLVM/llvm-ar XNM=$LLVM/llvm-nm XOBJCOPY=$LLVM/llvm-objcopy \
      XSIZE=$LLVM/llvm-size XSTRINGS=$LLVM/llvm-strings XSTRIPBIN=$LLVM/llvm-strip"
./tools/build/make.py $ARGS buildworld -s -j$(nproc)
./tools/build/make.py $ARGS KERNCONF=MEDIATEK buildkernel -s -j$(nproc)
./tools/build/make.py $ARGS KERNCONF=MEDIATEK DESTDIR=$PWD/../rootfs NO_ROOT=1 \
    -DDB_FROM_SRC installworld installkernel distribution -s -j$(nproc)

# 3. assemble the SD image
OBJ=$MAKEOBJDIRPREFIX$PWD/arm64.aarch64
./tools/bpi-r64/mkimage.sh -d ../rootfs \
    -l $OBJ/stand/efi/loader_lua/loader_lua.efi \
    -m $(find $OBJ/tmp -type f -perm -u+x -name makefs | head -n1) \
    -b ../firmware/bl2.img -f ../firmware/fip.bin -s 2g \
    -o ../bpi-r64-freebsd.img

# 4. write it
sudo dd if=../bpi-r64-freebsd.img of=/dev/sdX bs=1M status=progress conv=fsync
```

On FreeBSD the same `mkimage.sh` works with the base `makefs` and
`sysutils/gdisk`; run steps 2 and 3 with plain `make` (drop
`--cross-bindir`).  `build-firmware.sh` needs the Linux cross GCC (the
MediaTek ATF does not build with clang), so build the firmware on Linux or
take `bl2.img` / `fip.bin` from a frank-w `bpi-r64_sdmmc.img.gz`.

## GitHub Actions

`.github/workflows/bpi-r64-image.yml` runs on every push to `main` and on
demand (`workflow_dispatch`, inputs: `ref`, `kernconf`, `root_size`,
`modules`).  Three jobs:

* `firmware` (a few minutes): `build-firmware.sh`, uploads `bl2.img`,
  `fip.bin`, `u-boot.bin`, `VERSIONS`.
* `image` (up to 6 h, `timeout-minutes: 360`): buildworld, buildkernel
  `MEDIATEK`, NO_ROOT install, `mkimage.sh`, uploads
  `bpi-r64-freebsd-MEDIATEK-<sha>.img.xz` + `SHA256`.
* `release` (push builds of `main` only): publishes the image as a GitHub
  release `bpi-r64-<date>-<sha>`, marked latest.  Next to the versioned file
  it attaches `bpi-r64-freebsd-MEDIATEK.img.xz`, so this URL always serves
  the newest image and can be linked from a web page:
  `https://github.com/BSD-CZ/freebsd-src/releases/latest/download/bpi-r64-freebsd-MEDIATEK.img.xz`

Artifacts live under the workflow run (Actions -> run -> Artifacts).  To
shorten the kernel step pass `modules`, e.g.
`dtb/mediatek mtkswitch mt7615 if_bridge`.

## Booting

The card boots all the way to FreeBSD on its own: U-Boot loads
`EFI/BOOT/BOOTAA64.EFI` from the ESP with the in-tree
`mt7622-bananapi-bpi-r64.dtb` (falling back to U-Boot's own device tree),
and the loader boots the kernel off the UFS root.  Press a key during the
two-second `bootdelay` for the `BPI-R64>` prompt.

That comes from `uEnv_freebsd.txt`, which `build-firmware.sh` compiles into
`u-boot.bin` as the default environment.  It has to be done at build time:
`mt7622_bpi-r64_defconfig` selects `CONFIG_ENV_IS_NOWHERE=y`, so the board
has no saved environment and `saveenv` cannot create one -- a `bootcmd` set
at the prompt only lasts until the next reset, and the `ubootenv` partition
is reserved by the layout but unused by this build.  Stock frank-w U-Boot
boots its Linux menu (`uEnv_r64.txt`), which looks for a `uImage` under
`bananapi/bpi-r64/linux` and finds nothing on a FreeBSD card.

To boot something else, edit `tools/bpi-r64/uEnv_freebsd.txt` and rebuild
the firmware, point `UBOOT_ENV_FILE` at another file, or keep frank-w's
environment with an empty one:

```sh
UBOOT_ENV_FILE= ./tools/bpi-r64/build-firmware.sh -o ../firmware -w ../firmware-src
```

The image has no users besides `root` (empty password, console login
only); `sshd` is enabled but refuses root, so set a password and add a
user on the serial console first.  `growfs` expands `rootfs` to the whole
card on the first boot.
