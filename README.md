# ClassicTouch - Multi-OS Native ARM Emulator for Modern iOS & iPadOS

ClassicTouch is a native, high-performance ARM virtualization and emulation app for modern iOS and iPadOS devices (iOS 15.0 through iOS 18+ and beyond). Originally built to run classic iOS versions, ClassicTouch now features a **multi-engine architecture** supporting classic iOS, Android, Firefox OS, Windows RT / Windows 10 ARMv7, Chrome OS (ARM32), and Ubuntu Touch (Virt) with Metal rendering, native multitouch, and JIT acceleration.

---

## 1. Supported Guest Platforms & Hardware

### Classic iOS (Apple SoC Engine — `libqemu-arm.dylib`)
The built-in catalog (`firmware-catalog.json`) supports **329+ official firmware builds**, plus custom and beta IPSW support with automated MobileGestalt / `data_ark.plist` activation fallbacks:

- **iPhone 5 (`iPhone5,1`, `iPhone5,2` / `n41ap`, `n42ap`)**: iOS 6.0 through iOS 10.3.4 (Apple A6 Swift SoC, 32-bit ARMv7s, 640x1136 Retina display)
- **iPhone 4 (`iPhone3,1` / `n90ap`)**: iOS 4.0 through iOS 7.1.2 (Apple A4 SoC)
- **iPhone 3GS (`iPhone2,1` / `n88ap`)**: iPhone OS 3.0 through iOS 6.1.6
- **iPhone (Original 2G, `iPhone1,1` / `m68ap`)**: iPhone OS 1.0 through iPhone OS 3.1.3
- **iPod touch (1st Gen, `iPod1,1` / `n45ap`)**: iPhone OS 1.1 through iPhone OS 3.1.3
- **iPod touch (2nd Gen, `iPod2,1` / `n72ap`)**: iPhone OS 2.1.1 through iOS 4.2.1
- **iPod touch (3rd Gen, `iPod3,1` / `n18ap`)**: iPhone OS 3.1.1 through iOS 5.1.1
- **iPod touch (4th Gen, `iPod4,1` / `n81ap`)**: iOS 4.1 through iOS 6.1.6
- **iPad (1st Gen, `iPad1,1` / `k48ap`)**: iPhone OS 3.2 through iOS 5.1.1

### Android & Firefox OS (Goldfish Engine — `libqemu-android.dylib`)
- **Android (ARMv7 Goldfish)**: Isolated Android emulator engine with integrated APK installer, virtual framebuffer, and touchscreen input.
- **Firefox OS (B2G)**: Boot2Gecko ARMv7 system support running on the Goldfish engine.

### Windows & Linux Virt Platforms (Virt Engine — `libqemu-winrt.dylib`)
- **Windows RT / Windows 10 ARMv7**: QEMU `virt` ARMv7 machine with UEFI (TianoCore), VirtIO GPU/Storage/Input, USB xHCI, and native multitouch (`virtio-multitouch-pci`).
- **Chrome OS (R40 ARM32)**: QEMU `virt` ARM32 environment with VirtIO display, networking, and USB xHCI input.
- **Ubuntu Touch (14.09 / 15.04 Virt)**: Isolated QEMU `virt` Linux environment (separate from Goldfish) with native `virtio-multitouch-pci` touch input, VirtIO GPU, and multi-core MTTCG acceleration.

---

## 2. Key Architecture & Features

### High-Performance Rendering & Metal Direct Display
- **Metal MTKView Pipeline (`IOSMetalView`)**: Zero-tearing, low-overhead direct rendering at native device refresh rates (60Hz / 120Hz ProMotion).
- **Zero-Copy IOSurface Direct Path**: Hardware texture sharing between the guest GLES / VirtIO GPU pipeline and host Metal view, avoiding heavy CPU pixel copying.
- **Dynamic Orientation & Window Mode**: Full iPad and iPadOS multitasking support (Split View, Slide Over, Stage Manager), with free window resizing and rotation handling.
- **Low-Latency CoreAudio (`IOSAudioBridge`)**: Low-latency PCM audio ring buffer operating at 44.1kHz.
- **CoreMotion Telemetry (`IOSMotionManager`)**: Physical device accelerometer and gyroscope data mapped to guest hardware.

### Automated Firmware Preparation & App Management
- **In-Process `firmwarekit`**: 100% in-process preparation pipeline (`libfirmwarekit.a`) that validates hashes, decrypts root filesystem DMG and IMG3/IMG4 containers, formats HFS+ system and data volumes, seeds guest tools, and handles beta/custom IPSW activation fallbacks.
- **Integrated IPA & APK Installers**: Sideload decrypted 32-bit ARM iOS `.ipa` apps into iOS containers (`ios_ipa_installer.mm`) and `.apk` packages into Android VMs (`android_apk_installer.mm`) via native UI.
- **Virtual USB Mux Bridge (`ios_usb_mux.mm`)**: Built-in `usbmuxd` emulation providing virtual USB connectivity.
- **Transparent Network Proxy (`ios_network_proxy.mm`)**: Built-in proxy routing with automatic root CA injection to allow modern HTTPS browsing from legacy MobileSafari.

### JIT Acceleration & System Stability
- **Dual-Mapped RX/RW via `mach_vm_remap`**: Bypasses W^X memory restrictions by mapping the exact same physical code pages as RW and RX.
- **TXM / StikDebug Guard**: iOS TXM traps (`brk #0xf00d` and `brk #0x69`) are protected with signal handlers, with graceful fallbacks.
- **Multi-Threaded TCG (MTTCG) & P-Core QoS**: Multi-core guest execution (`-smp 2`/`4`) with Performance-core QoS scheduling, optimized cross-core TLB invalidation, and cached block management.

---

## 3. Package Outputs

The build produces three ready-to-deploy distribution artifacts in `dist/`:

| File | Description | Recommended Deployment |
| :--- | :--- | :--- |
| **`dist/ClassicTouch.tipa`** | TrollStore IPA with full entitlements | TrollStore (No revokes, full JIT & unrestricted access) |
| **`dist/ClassicTouch.ipa`** | Standard IPA signed with debug / JIT entitlements | AltStore, SideStore, Sideloadly, Xcode |
| **`dist/ClassicTouch_2.0.0_iphoneos-arm64.deb`** | Debian package for jailbroken environments | Sileo, Zebra, Filza, dpkg |

---

## 4. Build Scripts Reference

- `scripts/build_app.sh`: Compiles the Objective-C / C++ / Metal sources, links with all engines and libraries, and packages into `.ipa`, `.tipa`, and `.deb`.
- `scripts/package_app.sh`: Assembles the application bundle, packs guest tools and Virt boot assets, signs with entitlements, and outputs `.ipa`, `.tipa`, and `.deb`.
- `scripts/build_engine.sh`: Cross-compiles the native arm64 iOS Apple SoC QEMU engine into `build/Frameworks/libqemu-arm.dylib`.
- `scripts/build_android_engine.sh`: Cross-compiles the Goldfish ARM32 QEMU engine (Android / Firefox OS) into `build/Frameworks/libqemu-android.dylib`.
- `scripts/build_winrt_engine.sh`: Cross-compiles the Virt ARM32 QEMU engine (Windows RT, Chrome OS, Ubuntu Touch) into `build/Frameworks/libqemu-winrt.dylib`.
- `scripts/build_linux_virt_boot.sh`: Prepares Linux Virt boot assets for Ubuntu Touch and Chrome OS.
- `scripts/build_deps.sh`: Builds cross-compiled static dependencies (`pixman`, `slirp`, `openssl`, `glib`, `pcre2`, etc.).
- `scripts/build_firmwarekit.sh`: Compiles the Rust-based firmware preparation engine into `libfirmwarekit.a`.
- `scripts/build_portable.sh`: Compiles the LightTouch Portable static library into `liblighttouch.a`.
- `scripts/env.sh`: Configures common cross-compilation environment variables, Theos SDK paths, and flags.

---

## 5. Acknowledgments & Related Projects

ClassicTouch builds upon and takes inspiration from extensive prior work across the iOS emulation and virtualization community:

- **[LightTouch](https://github.com/blake-lucas/LightTouch)** (`blake-lucas/LightTouch`): Core ARM emulation architecture, iBoot/kboot environment, firmware preparation pipeline, and foundational engineering for modern mobile iOS emulation.
- **[qemu-ios (blake-lucas)](https://github.com/blake-lucas/qemu-ios)**: QEMU fork featuring Apple SoC emulation, Darwin guest service bridges, and GLES host redirection.
- **[qemu-ios (devos50)](https://github.com/devos50/qemu-ios)**: Groundbreaking pioneering work on Apple iOS hardware emulation in QEMU.
- **[qemu-ios (samhenrigold)](https://github.com/samhenrigold/qemu-ios)**: Enhancements, fixes, and integration improvements for Apple hardware emulation.
- **[LightTouchMac](https://github.com/samhenrigold/LightTouchMac)**: Native macOS implementation and Metal rendering architecture for LightTouch.
- **[Henge](https://github.com/Leviidev/Henge)**: Innovative iOS/iPadOS hypervisor research, sandboxing bypasses, and high-performance virtualization.
- **[Podium](https://github.com/Leviidev/Podium)**: Mobile emulation framework and system bridge implementation.
- **[Inferno](https://github.com/MakrSas/Inferno)**: Advanced iOS virtualization and hypervisor concepts.
- **[Kernarium](https://github.com/imxieyi/Kernarium)**: iOS kernel-level virtualization and device emulation insights.
- **[iphone-1-emulator](https://github.com/kelindi/iphone-1-emulator)**: Emulation research for early S5L8900 iPhone OS devices.
- **[WindowsiOS](https://github.com/ammaarreshi/WindowsiOS)**: JIT acceleration and virtual machine execution techniques on modern iOS.
- **[LinuxRunner](https://github.com/mxhm11cr/LinuxRunner)**: JIT compilation and virtual machine execution engine on iOS.

---

## 6. License

ClassicTouch is distributed under the terms of the **GNU General Public License Version 2 (GPL-2.0)**.
- Full license terms: [LICENSE](LICENSE)
- Upstream attribution & third-party licenses: [NOTICE.md](NOTICE.md)
