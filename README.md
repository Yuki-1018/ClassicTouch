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
| **`dist/ClassicTouch_1.0.0_iphoneos-arm64.deb`** | Debian package for jailbroken environments | Sileo, Zebra, Filza, dpkg |

---

## 4. Build Scripts Reference

- `scripts/build_engine.sh`: Cross-compiles the native QEMU engine into `build/Frameworks/libqemu-arm.dylib`.
- `scripts/build_app.sh`: Compiles the Objective-C / C++ / Metal sources, links with libraries, and packages into `.ipa`, `.tipa`, and `.deb`.
- `scripts/build_deps.sh`: Builds cross-compiled static dependencies (`pixman`, `slirp`, `openssl`, `glib`, etc.).
- `scripts/build_firmwarekit.sh`: Compiles the Rust-based firmware preparation engine into `libfirmwarekit.a`.
