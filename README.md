# ClassicTouch - Native Classic iOS Emulator for Modern iOS & iPadOS

ClassicTouch is a native, high-performance emulator running classic iOS versions (iPhone OS 1.x, 2.x, 3.x, iOS 4.x, 5.x, 6.x, and iOS 10.x on iPhone 5) on modern Apple devices (iOS 15.0 through iOS 18+ and beyond). It is optimized to extract peak performance from modern Apple Silicon hardware while maintaining full compatibility.

---

## 1. Supported Guest Hardware & Firmware

The built-in catalog (`firmware-catalog.json`) supports **329+ official firmware builds**:

- **iPhone 5 (`iPhone5,1`, `iPhone5,2` / `n41ap`, `n42ap`)**: iOS 6.0 through iOS 10.3.4 (Apple A6 Swift SoC, 32-bit ARMv7s, 640x1136 Retina display)
- **iPhone 4 (`iPhone3,1` / `n90ap`)**: iOS 4.0 through iOS 7.1.2 (Apple A4 SoC)
- **iPhone 3GS (`iPhone2,1` / `n88ap`)**: iPhone OS 3.0 through iOS 6.1.6
- **iPhone (Original 2G, `iPhone1,1` / `m68ap`)**: iPhone OS 1.0 through iPhone OS 3.1.3
- **iPod touch (1st Gen, `iPod1,1` / `n45ap`)**: iPhone OS 1.1 through iPhone OS 3.1.3
- **iPod touch (2nd Gen, `iPod2,1` / `n72ap`)**: iPhone OS 2.1.1 through iOS 4.2.1
- **iPod touch (3rd Gen, `iPod3,1` / `n18ap`)**: iPhone OS 3.1.1 through iOS 5.1.1
- **iPod touch (4th Gen, `iPod4,1` / `n81ap`)**: iOS 4.1 through iOS 6.1.6
- **iPad (1st Gen, `iPad1,1` / `k48ap`)**: iPhone OS 3.2 through iOS 5.1.1

---

## 2. Key Architecture & Features

### High-Performance Rendering & Metal Direct Display
- **Metal MTKView Pipeline (`IOSMetalView`)**: Zero-tearing, low-overhead direct rendering at native device refresh rates (60Hz / 120Hz ProMotion).
- **Zero-Copy IOSurface Direct Path**: Hardware texture sharing between the guest GLES pipeline and host Metal view, avoiding heavy CPU pixel copying.
- **Dynamic Orientation & Window Mode**: Full iPad and iPadOS multitasking support (Split View, Slide Over, Stage Manager), with free window resizing and rotation handling.
- **Low-Latency CoreAudio (`IOSAudioBridge`)**: Low-latency PCM audio ring buffer operating at 44.1kHz.
- **CoreMotion Telemetry (`IOSMotionManager`)**: Physical device accelerometer and gyroscope data mapped to guest hardware.

### Automated Firmware Preparation & App Management
- **In-Process `firmwarekit`**: 100% in-process preparation pipeline (`libfirmwarekit.a`) that validates hashes, decrypts root filesystem DMG and IMG3/IMG4 containers, formats HFS+ system and data volumes, and seeds guest tools.
- **Integrated IPA Installer (`ios_ipa_installer.mm`)**: Sideload decrypted 32-bit ARM iOS applications directly into containers via native UI.
- **Virtual USB Mux Bridge (`ios_usb_mux.mm`)**: Built-in usbmuxd emulation providing virtual USB connectivity.
- **Transparent Network Proxy (`ios_network_proxy.mm`)**: Built-in proxy routing with automatic root CA injection to allow modern HTTPS browsing from legacy MobileSafari.

### JIT Acceleration & System Stability
- **Dual-Mapped RX/RW via `mach_vm_remap`**: Bypasses W^X memory restrictions by mapping the exact same physical code pages as RW and RX.
- **TXM / StikDebug Guard**: iOS TXM traps (`brk #0xf00d` and `brk #0x69`) are protected with signal handlers, with graceful fallbacks.
- **Multi-Threaded TCG (MTTCG)**: Multi-core guest execution with optimized cross-core TLB invalidation and cached block management.

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

- `scripts/build_app.sh`: Compiles the Objective-C / C++ / Metal sources, links with libraries, and packages into `.ipa`, `.tipa`, and `.deb`.
- `scripts/package_app.sh`: Assembles the application bundle, packs guest tools, signs with entitlements, and outputs `.ipa`, `.tipa`, and `.deb`.
- `scripts/build_engine.sh`: Cross-compiles the native arm64 iOS QEMU engine into `build/Frameworks/libqemu-arm.dylib`.
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
