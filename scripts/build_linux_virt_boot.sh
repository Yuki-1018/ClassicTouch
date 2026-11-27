#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$ROOT_DIR/Resources/linux-virt"
mkdir -p "$OUT_DIR"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/linux-virt-build.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

DEBS_DIR="$WORK_DIR/debs"
UNPACK="$WORK_DIR/unpack"
INITRD="$WORK_DIR/initrd"
mkdir -p "$DEBS_DIR" "$UNPACK" "$INITRD"

BASE_URL="https://archive.debian.org/debian"
KVER="4.19.0-21-armmp"

DEBS=(
  "pool/main/l/linux/linux-image-4.19.0-21-armmp_4.19.249-2_armhf.deb"
  "pool/main/b/busybox/busybox-static_1.30.1-4_armhf.deb"
  "pool/main/e/e2fsprogs/e2fsprogs_1.44.5-1+deb10u3_armhf.deb"
  "pool/main/e/e2fsprogs/libext2fs2_1.44.5-1+deb10u3_armhf.deb"
  "pool/main/e/e2fsprogs/libcom-err2_1.44.5-1+deb10u3_armhf.deb"
  "pool/main/e/e2fsprogs/libss2_1.44.5-1+deb10u3_armhf.deb"
  "pool/main/u/util-linux/libblkid1_2.33.1-0.1_armhf.deb"
  "pool/main/u/util-linux/libuuid1_2.33.1-0.1_armhf.deb"
  "pool/main/g/glibc/libc6_2.28-10+deb10u1_armhf.deb"
  "pool/main/g/gcc-8/libgcc1_8.3.0-6_armhf.deb"
)

echo "[build_linux_virt_boot] Downloading Debian Buster armhf packages ($KVER)..."
for rel in "${DEBS[@]}"; do
  deb="$DEBS_DIR/$(basename "$rel")"
  curl -fsSL --retry 3 --retry-delay 2 "$BASE_URL/$rel" -o "$deb"
  data_member="$(ar t "$deb" | grep -E '^data\.tar\.(xz|gz|bz2|zst)$' | head -n1)"
  case "$data_member" in
    data.tar.xz)  ar p "$deb" "$data_member" | tar -xJ -C "$UNPACK" ;;
    data.tar.gz)  ar p "$deb" "$data_member" | tar -xz -C "$UNPACK" ;;
    data.tar.bz2) ar p "$deb" "$data_member" | tar -xj -C "$UNPACK" ;;
    *)
      echo "Unsupported data archive in $deb: $data_member" >&2
      exit 1
      ;;
  esac
done

VMLINUZ_SRC="$UNPACK/boot/vmlinuz-$KVER"
if [ ! -f "$VMLINUZ_SRC" ]; then
  echo "Missing kernel image: $VMLINUZ_SRC" >&2
  exit 1
fi
cp -f "$VMLINUZ_SRC" "$OUT_DIR/vmlinuz-virt-armhf"

mkdir -p "$INITRD"/{bin,sbin,etc,proc,sys,dev,dev/pts,dev/shm,run,tmp,newroot,mnt/chk,mnt/userdata,mnt/stateful,usr/bin,usr/sbin,lib/arm-linux-gnueabihf}

# 1. BusyBox static + applets
cp -f "$UNPACK/bin/busybox" "$INITRD/bin/busybox"
chmod 0755 "$INITRD/bin/busybox"
BIN_APPLETS=(
  sh ash mount umount mkdir rmdir mknod cp mv rm ln chmod chown touch
  cat head tail grep egrep cut sed awk tr wc ls sync sleep kill ps tee expr
  test '[' dd blkid switch_root modprobe insmod rmmod lsmod
)
for applet in "${BIN_APPLETS[@]}"; do
  ln -sf busybox "$INITRD/bin/$applet"
done
for sapplet in modprobe insmod rmmod lsmod blkid switch_root; do
  ln -sf ../bin/busybox "$INITRD/sbin/$sapplet"
done

# 2. e2fsprogs (e2fsck, mke2fs) + real mke2fs.conf + required ARM EABI shared libs
cp -f "$UNPACK/sbin/e2fsck" "$INITRD/sbin/e2fsck"
cp -f "$UNPACK/sbin/mke2fs" "$INITRD/sbin/mke2fs"
chmod 0755 "$INITRD/sbin/e2fsck" "$INITRD/sbin/mke2fs"
cp -f "$UNPACK/etc/mke2fs.conf" "$INITRD/etc/mke2fs.conf"

if [ -e "$UNPACK/lib/ld-linux-armhf.so.3" ]; then
  cp -a "$UNPACK/lib/ld-linux-armhf.so.3" "$INITRD/lib/"
fi
for pat in \
  'ld-*.so*' 'libc.so*' 'libc-*.so*' 'libpthread*.so*' 'libdl*.so*' 'libm*.so*' \
  'libblkid*.so*' 'libuuid*.so*' 'libext2fs*.so*' 'libe2p*.so*' \
  'libcom_err*.so*' 'libss*.so*' 'libgcc_s*.so*'
do
  for f in "$UNPACK"/lib/arm-linux-gnueabihf/$pat "$UNPACK"/usr/lib/arm-linux-gnueabihf/$pat; do
    if [ -e "$f" ] || [ -L "$f" ]; then
      cp -a "$f" "$INITRD/lib/arm-linux-gnueabihf/"
    fi
  done
done

# Verify every DT_NEEDED library required by e2fsck/mke2fs is staged
python3 - "$INITRD" <<'PY'
import os, subprocess, sys
initrd = sys.argv[1]
lib_dir = os.path.join(initrd, "lib", "arm-linux-gnueabihf")
staged = set(os.listdir(lib_dir)) | set(os.listdir(os.path.join(initrd, "lib")))
for tool in ("sbin/e2fsck", "sbin/mke2fs"):
    out = subprocess.check_output(["readelf", "-d", os.path.join(initrd, tool)], text=True)
    for line in out.splitlines():
        if "(NEEDED)" in line:
            soname = line.split("[", 1)[1].split("]", 1)[0]
            if soname not in staged:
                raise SystemExit(f"Missing DT_NEEDED {soname} for {tool}")
print("[build_linux_virt_boot] Verified DT_NEEDED libs for e2fsck & mke2fs.")
PY

# 3. Kernel modules (desired roots + transitive ELF .modinfo depends resolution)
MOD_SRC="$UNPACK/lib/modules/$KVER"
MOD_DST="$INITRD/lib/modules/$KVER"
mkdir -p "$MOD_DST"
for meta in modules.order modules.builtin; do
  if [ -f "$MOD_SRC/$meta" ]; then
    cp -f "$MOD_SRC/$meta" "$MOD_DST/$meta"
  fi
done

python3 - "$MOD_SRC" "$MOD_DST" <<'PY'
import os, re, shutil, sys
src_root, dst_root = sys.argv[1], sys.argv[2]

def norm(name):
    return name.strip().replace("-", "_")

by_name = {}
for dp, _, fns in os.walk(src_root):
    for fn in fns:
        if fn.endswith(".ko"):
            full = os.path.join(dp, fn)
            rel = os.path.relpath(full, src_root)
            by_name[norm(fn[:-3])] = (full, rel)

want_names = [
    "virtio", "virtio_ring", "virtio_pci", "virtio_mmio", "virtio_blk", "virtio_net",
    "virtio_input", "virtio-rng", "rng-core", "virtio_console",
    "drm", "drm_kms_helper", "ttm", "bochs-drm", "virtio-gpu",
    "crc16", "crc32c_generic", "libcrc32c", "mbcache", "jbd2", "fscrypto", "ext4",
    "overlay", "fuse", "loop", "tun", "dm-mod", "zram", "zsmalloc", "squashfs",
    "usb-common", "usbcore", "ehci-hcd", "ehci-pci", "ohci-hcd", "ohci-pci", "xhci-hcd", "xhci-pci", "hid", "hid-generic", "usbhid",
    "evdev", "uinput",
    "soundcore", "snd", "snd-timer", "snd-seq-device", "snd-rawmidi", "snd-pcm",
    "snd-hwdep", "snd-usbmidi-lib", "snd-usb-audio",
    "rfkill", "cfg80211",
]

def parse_depends(ko_path):
    with open(ko_path, "rb") as f:
        blob = f.read()
    m = re.search(rb"depends=([^\x00]*)\x00", blob)
    if not m or not m.group(1):
        return []
    return [norm(x) for x in m.group(1).decode("ascii", "ignore").split(",") if x]

visited = set()
stack = [norm(w) for w in want_names]
missing_roots = []
while stack:
    k = stack.pop(0)
    if k in visited:
        continue
    if k not in by_name:
        missing_roots.append(k)
        continue
    visited.add(k)
    full, _ = by_name[k]
    for dep in parse_depends(full):
        if dep not in visited:
            stack.append(dep)

if missing_roots:
    print("[build_linux_virt_boot] Note: skipped unavailable/built-in modules:", ", ".join(missing_roots))

for k in sorted(visited):
    full, rel = by_name[k]
    out_path = os.path.join(dst_root, rel)
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    shutil.copy2(full, out_path)
print(f"[build_linux_virt_boot] Staged {len(visited)} kernel modules.")
PY

PATH="/sbin:/usr/sbin:$PATH" depmod -b "$INITRD" "$KVER"

# 4. Write /init
cat > "$INITRD/init" <<EOF
#!/bin/sh
export PATH=/sbin:/bin:/usr/sbin:/usr/bin
KVER="$KVER"

mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev || mount -t tmpfs tmpfs /dev
mkdir -p /dev/pts /dev/shm /run /tmp /mnt/chk
mount -t devpts -o gid=5,mode=0620 devpts /dev/pts 2>/dev/null || true
mount -t tmpfs -o mode=1777 tmpfs /dev/shm
mount -t tmpfs -o mode=0755 tmpfs /run
mount -t tmpfs -o mode=1777 tmpfs /tmp

# Re-open console/ttyAMA0 for clear diagnostics
if [ -c /dev/console ]; then
    exec </dev/console >/dev/console 2>&1
fi

echo "[linux-virt] initrd starting (kernel \$(uname -r))"

CT_MODE="ubuntutouch"
CT_GFX="virtio"
for param in \$(cat /proc/cmdline); do
    case "\$param" in
        ct_mode=*) CT_MODE="\${param#ct_mode=}" ;;
        ct_gfx=*) CT_GFX="\${param#ct_gfx=}" ;;
    esac
done
echo "[linux-virt] mode=\$CT_MODE gfx=\$CT_GFX"

for mod in \\
    virtio virtio_ring virtio_pci virtio_mmio virtio_blk virtio_net \\
    virtio_input rng-core virtio-rng virtio_console \\
    crc16 crc32c_generic libcrc32c mbcache jbd2 fscrypto ext4 overlay fuse loop tun dm-mod zsmalloc zram \\
    usb-common usbcore ehci-hcd ehci-pci ohci-hcd ohci-pci xhci-hcd xhci-pci hid hid-generic usbhid evdev uinput \\
    soundcore snd snd-usb-audio rfkill cfg80211
do
    modprobe "\$mod" 2>/dev/null || true
done

if [ "\$CT_GFX" = "bochs" ]; then
    modprobe bochs-drm 2>/dev/null || modprobe virtio-gpu 2>/dev/null || true
else
    modprobe virtio-gpu 2>/dev/null || modprobe bochs-drm 2>/dev/null || true
fi

wait_dev() {
    local dev="\$1"
    local tries=0
    while [ ! -b "\$dev" ] && [ "\$tries" -lt 150 ]; do
        sleep 0.1
        tries=\$((tries + 1))
    done
    [ -b "\$dev" ]
}

prepare_modules_overlay() {
    local target="\$1"
    if [ -d "\$target/lib/modules" ]; then
        mount -t tmpfs tmpfs "\$target/lib/modules"
        cp -a "/lib/modules/\$KVER" "\$target/lib/modules/"
    fi
}

if [ "\$CT_MODE" = "chromeos" ]; then
    echo localhost > /proc/sys/kernel/hostname

    if ! wait_dev /dev/vda3; then
        echo "[linux-virt] ERROR: /dev/vda3 (Chrome OS ROOT-A) not found"
        ls -la /dev/vd* 2>/dev/null || true
        exec /bin/sh
    fi

    if wait_dev /dev/vdb; then
        if ! mount -t ext4 -o ro /dev/vdb /mnt/chk 2>/dev/null; then
            echo "[linux-virt] Formatting stateful QCOW2 /dev/vdb as ext4..."
            /sbin/mke2fs -t ext4 -F -L STATE /dev/vdb
        else
            umount /mnt/chk 2>/dev/null || true
            /sbin/e2fsck -p /dev/vdb 2>/dev/null || true
        fi
    fi

    echo "[linux-virt] Mounting Chrome OS ROOT-A (/dev/vda3)..."
    if ! mount -t ext2 -o ro /dev/vda3 /newroot 2>/dev/null; then
        mount -o ro /dev/vda3 /newroot
    fi

    prepare_modules_overlay /newroot

    PATCH="/run/cros-patch"
    mkdir -p "\$PATCH"

    # 1. Replace ARM SoC exynos X11 driver with generic fbdev driver
    cat > "\$PATCH/exynos.conf" <<'EOCFG'
Section "Device"
    Identifier  "QEMU FBDEV"
    Driver      "fbdev"
    Option      "fbdev" "/dev/fb0"
EndSection

Section "Screen"
    Identifier   "DefaultScreen"
    Device       "QEMU FBDEV"
    DefaultDepth 24
EndSection
EOCFG
    if [ -f /newroot/etc/X11/xorg.conf.d/exynos.conf ]; then
        mount --bind "\$PATCH/exynos.conf" /newroot/etc/X11/xorg.conf.d/exynos.conf
    fi

    # 2. Override Chrome OS touchpad/touchscreen rules for QEMU USB/Virtio HID
    cat > "\$PATCH/input-qemu.conf" <<'EOCFG'
Section "InputClass"
    Identifier      "QEMU USB/Virtio Tablet Evdev"
    MatchProduct    "QEMU"
    MatchDevicePath "/dev/input/event*"
    Driver          "evdev"
    Option          "IgnoreAbsoluteAxes" "false"
    Option          "SendCoreEvents" "true"
EndSection

Section "InputClass"
    Identifier      "QEMU Virtio Keyboard Evdev"
    MatchProduct    "QEMU"
    MatchIsKeyboard "on"
    MatchDevicePath "/dev/input/event*"
    Driver          "evdev"
    Option          "SendCoreEvents" "true"
EndSection

Section "InputClass"
    Identifier      "QEMU Generic Mouse Fallback"
    MatchIsPointer  "on"
    MatchDevicePath "/dev/input/event*"
    Driver          "evdev"
    Option          "SendCoreEvents" "true"
EndSection
EOCFG
    if [ -f /newroot/etc/X11/xorg.conf.d/50-touchpad-cmt-daisy.conf ]; then
        mount --bind "\$PATCH/input-qemu.conf" /newroot/etc/X11/xorg.conf.d/50-touchpad-cmt-daisy.conf
    elif [ -f /newroot/etc/X11/xorg.conf.d/20-touchscreen.conf ]; then
        mount --bind "\$PATCH/input-qemu.conf" /newroot/etc/X11/xorg.conf.d/20-touchscreen.conf
    fi

    # 3. Configure Chrome 2D Skia software compositing (fast SoftwareOutputDeviceX11)
    cat > "\$PATCH/chrome_dev.conf" <<'EOCFG'
!--use-gl=egl
!--gpu-sandbox-failures-fatal
!--gpu-sandbox-start-early
!--ui-prioritize-in-gpu-process
!--vmodule
--disable-gpu
--disable-gpu-compositing
--ui-disable-threaded-compositing
--disable-gpu-sandbox
--no-sandbox
--num-raster-threads=2
--disable-login-animations
--disable-boot-animation
EOCFG
    if [ -f /newroot/etc/chrome_dev.conf ]; then
        mount --bind "\$PATCH/chrome_dev.conf" /newroot/etc/chrome_dev.conf
    fi

    # 4. Override encrypted stateful mount with direct /dev/vdb bind mounts
    cat > "\$PATCH/startup_utils.sh" <<'EOCFG'
mount_var_and_home_chronos() {
    mkdir -p /mnt/stateful_partition/var_overlay \\
             /mnt/stateful_partition/home/chronos \\
             /var /home/chronos
    chmod 0755 /mnt/stateful_partition/var_overlay /mnt/stateful_partition/home/chronos
    mount --bind /mnt/stateful_partition/var_overlay /var
    mount --bind /mnt/stateful_partition/home/chronos /home/chronos
    return 0
}
EOCFG
    if [ -f /newroot/usr/share/cros/startup_utils.sh ]; then
        mount --bind "\$PATCH/startup_utils.sh" /newroot/usr/share/cros/startup_utils.sh
    fi

    # 5. Redirect STATE_DEV to /dev/vdb (the QCOW2 stateful disk) inside chromeos_startup
    if [ -f /newroot/sbin/chromeos_startup ] && [ -b /dev/vdb ]; then
        cp /newroot/sbin/chromeos_startup "\$PATCH/chromeos_startup"
        sed -i 's|STATE_DEV=\${ROOTDEV_TYPE}1|STATE_DEV=/dev/vdb|g; s|FS_FORMAT_STATE=\${FS_FORMAT_STATE}|ext4|g; s|commit=600|commit=5|g' "\$PATCH/chromeos_startup"
        chmod 0755 "\$PATCH/chromeos_startup"
        mount --bind "\$PATCH/chromeos_startup" /newroot/sbin/chromeos_startup
    fi

    # 6. Mask hardware-only Chromebook jobs & switch machine-info to nonchrome
    printf 'manual\n' > "\$PATCH/manual.conf"
    for job in vpd-log tcsd tpm-probe daisydog bluetoothd modemmanager chromeos-touch-update update-engine laptop-mode-boot; do
        if [ -f "/newroot/etc/init/\${job}.conf" ]; then
            mount --bind "\$PATCH/manual.conf" "/newroot/etc/init/\${job}.conf"
        fi
    done

    cat > "\$PATCH/machine-info.conf" <<'EOCFG'
description "Chrome OS machine info (ClassicTouch nonchrome virt)"
start on starting ui
stop on start-user-session or stopping ui
env MACHINE_INFO=/tmp/machine-info
pre-start script
  if [ -e /var/lib/enterprise_serial_number_recovery -o ! -e /var/lib/whitelist/owner.key ]; then
    touch "\$MACHINE_INFO"
    chmod 0644 "\$MACHINE_INFO"
    echo "serial_number=\"nonchrome-\$(date -u +%s)\"" >> "\$MACHINE_INFO"
  fi
end script
post-stop exec rm -f "\$MACHINE_INFO"
EOCFG
    if [ -f /newroot/etc/init/machine-info.conf ]; then
        mount --bind "\$PATCH/machine-info.conf" /newroot/etc/init/machine-info.conf
    fi

    echo "[linux-virt] Switching to Chrome OS init..."
    mkdir -p /newroot/proc /newroot/sys /newroot/dev
    mount --move /proc /newroot/proc 2>/dev/null || true
    mount --move /sys /newroot/sys 2>/dev/null || true
    mount --move /dev /newroot/dev 2>/dev/null || true
    exec switch_root -c /dev/console /newroot /sbin/init
fi

# ct_mode=ubuntutouch
echo ubuntu-phablet > /proc/sys/kernel/hostname

if ! wait_dev /dev/vda; then
    echo "[linux-virt] ERROR: /dev/vda (Ubuntu Touch rootfs) not found"
    ls -la /dev/vd* 2>/dev/null || true
    exec /bin/sh
fi

/sbin/e2fsck -p /dev/vda 2>/dev/null || true
echo "[linux-virt] Mounting Ubuntu Touch rootfs (/dev/vda)..."
mount -t ext4 -o rw,noatime /dev/vda /newroot

prepare_modules_overlay /newroot

mkdir -p /newroot/etc/udev/rules.d
cat > /newroot/etc/udev/rules.d/99-virtio-touchscreen.rules <<'EORULES'
ACTION=="add|change", SUBSYSTEM=="input", ATTRS{name}=="QEMU Virtio MultiTouch", ENV{ID_INPUT}="1", ENV{ID_INPUT_TOUCHSCREEN}="1", ENV{ID_INPUT_MOUSE}="", ENV{ID_INPUT_TABLET}=""
EORULES
if [ -f /newroot/etc/init/ubuntu-touch-virt.conf ]; then
    sed -i 's/GRID_UNIT_PX=16/GRID_UNIT_PX=12/g' /newroot/etc/init/ubuntu-touch-virt.conf 2>/dev/null || true
    if ! grep -q "LP_NUM_THREADS" /newroot/etc/init/ubuntu-touch-virt.conf 2>/dev/null; then
        awk '
        /maliit-server/ { print "                export LP_NUM_THREADS=2" }
        /QML_NO_TOUCH_COMPRESSION/ { has_qml=1 }
        /exec \/usr\/bin\/unity8/ {
            print "    export LP_NUM_THREADS=\"\$(nproc 2>/dev/null || echo 4)\""
            if (!has_qml) print "    export QML_NO_TOUCH_COMPRESSION=1"
        }
        { print }
        ' /newroot/etc/init/ubuntu-touch-virt.conf > /tmp/ut-virt.conf.new && \
        mv /tmp/ut-virt.conf.new /newroot/etc/init/ubuntu-touch-virt.conf
    fi
fi

if wait_dev /dev/vdb; then
    if ! mount -t ext4 -o ro /dev/vdb /mnt/chk 2>/dev/null; then
        echo "[linux-virt] Formatting userdata QCOW2 /dev/vdb as ext4..."
        /sbin/mke2fs -t ext4 -F -L userdata /dev/vdb
    else
        umount /mnt/chk 2>/dev/null || true
        /sbin/e2fsck -p /dev/vdb 2>/dev/null || true
    fi
    if mount -t ext4 -o rw,noatime /dev/vdb /mnt/userdata; then
        if [ ! -e /mnt/userdata/.seeded ] && [ -d /newroot/home/phablet ]; then
            echo "[linux-virt] Seeding /home/phablet to /dev/vdb..."
            mkdir -p /mnt/userdata/phablet
            cp -a /newroot/home/phablet/. /mnt/userdata/phablet/ 2>/dev/null || true
            chown -R 32011:32011 /mnt/userdata/phablet 2>/dev/null || true
            touch /mnt/userdata/.seeded
        fi
        if [ -d /mnt/userdata/phablet ] && [ -d /newroot/home/phablet ]; then
            mount --bind /mnt/userdata/phablet /newroot/home/phablet
        fi
        umount /mnt/userdata 2>/dev/null || true
    fi
fi

echo "[linux-virt] Switching to Ubuntu Touch init..."
mkdir -p /newroot/proc /newroot/sys /newroot/dev
mount --move /proc /newroot/proc 2>/dev/null || true
mount --move /sys /newroot/sys 2>/dev/null || true
mount --move /dev /newroot/dev 2>/dev/null || true
exec switch_root -c /dev/console /newroot /sbin/init
EOF
chmod 0755 "$INITRD/init"

echo "[build_linux_virt_boot] Packing initrd..."
(
  cd "$INITRD"
  find . -print0 | LC_ALL=C sort -z | cpio --null -o --format=newc --quiet | gzip -9 > "$OUT_DIR/initrd-virt-armhf.cpio.gz"
)

ls -lh "$OUT_DIR/vmlinuz-virt-armhf" "$OUT_DIR/initrd-virt-armhf.cpio.gz"
