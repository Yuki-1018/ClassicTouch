# Open Source Notices & Licenses for ClassicTouch

ClassicTouch is distributed under the terms of the **GNU General Public License Version 2 (GPL-2.0)**.
Copyright (C) 2026 ClassicTouch Authors.

This program is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation; version 2 of the License.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

---

## 1. Upstream & Referenced Projects 

ClassicTouch is built upon, incorporates code from, and references the following open-source projects:

### LightTouch
- **Repository**: [https://github.com/blake-lucas/LightTouch](https://github.com/blake-lucas/LightTouch)
- **Authors**: Blake Lucas and contributors
- **License**: GNU General Public License Version 2 (GPL-2.0)
- **Copyright**: Copyright (c) 2024-2026 Blake Lucas
- **Description**: Foundational mobile emulation architecture, iBoot/kboot environment, firmware preparation framework (`lighttouch-firmware`), and portable runtime libraries.

### QEMU & qemu-ios
- **Repositories**:
  - [https://github.com/qemu/qemu](https://github.com/qemu/qemu)
  - [https://github.com/blake-lucas/qemu-ios](https://github.com/blake-lucas/qemu-ios)
  - [https://github.com/devos50/qemu-ios](https://github.com/devos50/qemu-ios)
  - [https://github.com/samhenrigold/qemu-ios](https://github.com/samhenrigold/qemu-ios)
- **Authors**: Fabrice Bellard, QEMU team, devos50, Blake Lucas, Sam Henri Gold
- **License**: GNU General Public License Version 2 (GPL-2.0) / GNU Lesser General Public License Version 2.1 (LGPL-2.1)
- **Copyright**: Copyright (c) 2003-2026 Fabrice Bellard and the QEMU Project developers
- **Description**: Apple SoC hardware emulation (S5L8900, S5L8720, S5L8920, S5L8930, S5L8950), dynamic binary translation (TCG), and Darwin service bridges.

### LightTouchMac
- **Repository**: [https://github.com/samhenrigold/LightTouchMac](https://github.com/samhenrigold/LightTouchMac)
- **Authors**: Sam Henri Gold
- **License**: GNU General Public License Version 2 (GPL-2.0)
- **Copyright**: Copyright (c) 2024-2026 Sam Henri Gold
- **Description**: Metal MTKView rendering pipeline, shader implementations, and native Apple display integration.

### Henge
- **Repository**: [https://github.com/Leviidev/Henge](https://github.com/Leviidev/Henge)
- **Authors**: Leviidev
- **License**: GNU General Public License Version 2 or later (GPL-2.0-or-later)
- **Copyright**: Copyright (c) Leviidev
- **Description**: iOS hypervisor and virtualization research, native StikDebug breakpoint trap handlers (`henge-brk.S`).

### Podium
- **Repository**: [https://github.com/Leviidev/Podium](https://github.com/Leviidev/Podium)
- **Authors**: Leviidev
- **License**: GNU General Public License Version 2 or later (GPL-2.0-or-later)
- **Copyright**: Copyright (c) Leviidev
- **Description**: Mobile emulation framework and system bridge implementation.

### Inferno
- **Repository**: [https://github.com/MakrSas/Inferno](https://github.com/MakrSas/Inferno)
- **Authors**: MakrSas / ChefKiss
- **License**: GNU General Public License Version 3 (GPL-3.0) / GNU Affero General Public License Version 3 (AGPL-3.0)
- **Copyright**: Copyright (c) 2021-2026 MakrSas
- **Description**: iOS kernel-level virtualization and hypervisor architecture insights.

### Kernarium
- **Repository**: [https://github.com/imxieyi/Kernarium](https://github.com/imxieyi/Kernarium)
- **Authors**: imxieyi
- **License**: GNU General Public License Version 2 (GPL-2.0)
- **Copyright**: Copyright (c) 2021-2026 imxieyi
- **Description**: S5L8960X/Apple SoC device emulation and kernel insights.

### iphone-1-emulator
- **Repository**: [https://github.com/kelindi/iphone-1-emulator](https://github.com/kelindi/iphone-1-emulator)
- **Authors**: kelindi
- **License**: GNU General Public License Version 2 (GPL-2.0)
- **Copyright**: Copyright (c) 2020-2026 kelindi
- **Description**: Early S5L8900 iPhone OS 1.x emulation research.

### WindowsiOS
- **Repository**: [https://github.com/ammaarreshi/WindowsiOS](https://github.com/ammaarreshi/WindowsiOS)
- **Authors**: Ammaar Reshi
- **License**: MIT License
- **Description**: JIT acceleration and virtual machine execution techniques on modern iOS.

### LinuxRunner
- **Repository**: [https://github.com/mxhm11cr/LinuxRunner](https://github.com/mxhm11cr/LinuxRunner)
- **Authors**: mxhm11cr
- **License**: MIT License
- **Description**: JIT compilation and virtual machine execution engine on iOS.

---

## 2. Bundled & Linked Third-Party Libraries (サードパーティ製ライブラリ)

### libslirp
- **License**: BSD-2-Clause / BSD-4-Clause / MIT
- **Copyright**: Copyright (c) 1995, 1996 Danny Gasparovski; Copyright (c) 2018-2026 Slirp Project contributors

### pixman
- **License**: MIT License
- **Copyright**: Copyright (c) 2000-2026 Keith Packard, Red Hat, Inc., and contributors

### GLib (libglib-2.0)
- **License**: GNU Lesser General Public License Version 2.1 or later (LGPL-2.1+)
- **Copyright**: Copyright (c) 1995-2026 Peter Mattis, Spencer Kimball, Josh MacDonald, and GNOME contributors

### OpenSSL (libcrypto, libssl)
- **License**: Apache License 2.0
- **Copyright**: Copyright (c) 1998-2026 The OpenSSL Project Authors

### PCRE2 (libpcre2-8)
- **License**: BSD 3-Clause License
- **Copyright**: Copyright (c) 1997-2026 University of Cambridge and Zoltan Herczeg

### libffi
- **License**: MIT License
- **Copyright**: Copyright (c) 1996-2026 Anthony Green, Red Hat, Inc., and contributors

### zlib
- **License**: zlib License
- **Copyright**: Copyright (c) 1995-2026 Jean-loup Gailly and Mark Adler
