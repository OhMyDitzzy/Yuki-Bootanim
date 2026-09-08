# Yuki Boot Animation

A Magisk / KernelSU / KernelSU Next / APatch module that lets you install a
custom boot animation straight from its WebUI — no manual `adb push`, no
repacking the ROM, no flashing a new zip every time you want to try a
different animation.

Just open the module page in your manager, pick a `.zip` (standard Android
bootanimation) or `.qmg` (Samsung One UI) file, and it takes care of the
rest: detecting your root manager, picking the right install method for your
device, and applying it.

> **Note**: This module is designed to work with the **OverlayFS** metamodule. For **Magisk** users, Maybe you must install the [magic_overlayfs](https://github.com/agreenbhm/magic_overlayfs) module first.

## Features

- **WebUI-based install** — no terminal required after the initial setup.
- **Two boot animation formats** — standard `bootanimation.zip` for most
  devices, and Samsung's `.qmg` format (`bootsamsung.qmg` /
  `bootsamsungloop.qmg`) for One UI devices. The module detects which one
  your device needs and rejects the wrong format before it touches anything.
- **Automatic install method** — tries a direct read-write remount of
  `/system` first; if that fails (e.g. dm-verity/AVB is still active), it
  falls back to installing through the module's own overlay path using **OverlayFS**.
- **Multi-ROM path detection** — not every ROM keeps its boot animation at
  `/system/media`. The module checks `/product/media`, `/product/etc/media`,
  `/oem/media`, `/system/media`, and `/system/product/media`, and prefers
  whichever one already has a boot animation file on it — that's the
  clearest sign the running ROM actually reads from there. If none of them
  do, the result is flagged as an unconfirmed path in the install log and
  in the module's description, since a ROM using a path outside this list
  won't be detected.
- **Automatic backup & restore** — the file it's about to replace is backed
  up before anything is written, and restored automatically if you uninstall
  the module.

## Compatibility

| Root solution        | Supported | Notes |
|-----------------------|-----------|-------|
| Magisk (v20.4+)        | ❗ (Need tester) | Requires module [magic_overlayfs](https://github.com/agreenbhm/magic_overlayfs) |
| KernelSU / KernelSU Next | ✅ | - |
| APatch                | ✅ | - |

## Installation

1. **(Magisk Only)** Install and activate the [magic_overlayfs](https://github.com/agreenbhm/magic_overlayfs) module first, then reboot your device. **(For KSU/KSU-Next/APatch)** Install a metamodule such as [Hybrid-Mount](https://github.com/Hybrid-Mount/meta-hybrid_mount) or [Mountify](https://github.com/backslashxx/mountify) (Hybird-Mount is Recommended)
2. Flash this zip module in your preferred manager (Magisk Manager, KernelSU Manager, APatch).
3. Reboot — this allows the module to detect available root managers, API levels, and boot animation paths.
4. Open the module from your manager and use its WebUI to select and upload the `.zip` or `.qmg` file.
5. Reboot once again to see the new boot animation.

## Troubleshooting

- **Upload succeeds, no errors, but the boot animation never changes.**
  Check the module's description on its page in your manager — it now shows
  the exact on-device path it installed to. If you're on the overlay path,
  confirm that OverlayFS is active and set to mount that path properly.
- **"Direct remount to /system fails ... install a metamodule" error.**
  Your device can't be remounted read-write (dm-verity/AVB is still
  enforced) and needs OverlayFS to install `/system` overlays.
  If you are using Magisk, make sure the [magic_overlayfs](https://github.com/agreenbhm/magic_overlayfs) module is installed and active, then reboot and try again.
- **All other modules go inactive after installing this one.** This is not
  expected behavior — if you run into it, please open an issue with your
  root manager, Android version, and confirmation of whether OverlayFS is installed.

## License

Licensed under the MIT License — see [LICENSE](LICENSE) for the full text.
You're free to use, modify, and redistribute this module, including in
closed-source forks, as long as the copyright notice is kept.
