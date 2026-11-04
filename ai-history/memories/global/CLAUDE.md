# graphify
- **graphify** (`~/.claude/skills/graphify/SKILL.md`) - any input to knowledge graph. Trigger: `/graphify`
When the user types `/graphify`, invoke the Skill tool with `skill: "graphify"` before doing anything else.

# My system
Assume this machine unless I say otherwise. It is **Arch Linux** (pacman, AUR, Arch package names, systemd). If I mention odd networking problems, assume my own local misconfiguration before suspecting code.

## Audio
- PipeWire 1.6 with WirePlumber, plus pipewire-pulse, pipewire-jack and pipewire-alsa. `pactl` reports "PulseAudio (on PipeWire)". It runs as systemd **user** services.
- The default output is a USB DAC (Burr-Brown/TI "USB AUDIO CODEC"). There is also onboard Realtek ALC897 and HDMI/DP audio on every GPU.

## Graphics stack
- **X11, not Wayland.** The X server is **XLibre** (`xlibre-xserver`, a fork of Xorg, using `xlibre-video-amdgpu`), started by SDDM.
- **Openbox** is the window manager. **picom** (`picom-arian8j2-git`) is the compositor, **polybar** the bar, and rofi/dmenu the launchers. feh is installed.
- The live openbox config is the **system-wide `/etc/xdg/openbox/`** (rc.xml, autostart, menu.xml, environment). There is no `~/.config/openbox`. `~/sav/openbox/` is an older 2020–21 copy that differs from it.
- The autostart in `/etc/xdg/openbox/autostart` runs `openrgb -p White`, `xscreensaver`, `redshift -l [REDACTED: home coordinates]`, `polybar --config=~/.config/polybar/config.ini` and `picom`.
- Xorg config is in `/etc/X11/xorg.conf.d/` (`00-keyboard.conf`, `20-amdgpu.conf`). `20-amdgpu.conf` sets TearFree and DRI3, plus the monitor modes and layout.
- Monitors, both on the AMD GPU:
  - `DisplayPort-0`: ASUS PG32UCDP, 3840x2160 at 240 Hz (custom modeline), primary.
  - `DisplayPort-1`: Lenovo L27h-4A, 2560x1440 at 100 Hz, rotated right (portrait), to the right of DP-0.

## Hardware
- CPU: AMD Ryzen 7 9800X3D (8 cores / 16 threads). It has an iGPU (Radeon 610M "Granite Ridge"), which is present but not used for display.
- Motherboard: ASRock B650M Pro RS WiFi. RAM: 64 GB.
- **Main GPU: AMD Radeon RX 7800 XT (Navi 32)**, using `amdgpu` and Mesa (`vulkan-radeon`). It sits in the primary PCIe x16 slot, is boot_vga, drives all the displays and does the X rendering.
- **Secondary GPU: NVIDIA RTX A4000**, using the `nvidia-580xx-dkms` proprietary driver. It is in the second slot with **reduced bandwidth (PCIe x4; it idles at 2.5 GT/s, the maximum is 16 GT/s x16)**. It drives no displays and is used for compute, CUDA or offload only. Remember the bandwidth limit when GPU transfers or performance matter.
- Storage:
  - Samsung 990 EVO Plus 2 TB (NVMe, system drive)
  - WD Purple 4 TB (SATA HDD)
  - Seagate 1 TB (SATA HDD, 2.5")
- Kernel: `linux` (the stock Arch kernel).

# Rules
## Full disk
- If a command fails because a disk or partition is out of space ("No space left on device", ENOSPC, etc.), tell me in ALL CAPS, for example: "YOUR DISK SEEMS FULL PLEASE FREE UP SOME SPACE". Name the disk or mount if known.
- **You must not free up space yourself**, except for files you created in the current session that are no longer needed. For example, Docker images or containers you built during a Docker task can be removed. Never delete my pre-existing files, caches, packages, images or logs to make room.

## Installing packages
- I manage system packages with **pacman** (official repos) and **paru** (AUR). Install system packages only through those two. Do not use `make install`, `pip install` into the system, `npm -g`, curl-to-bash installers, manual copies into `/usr`, etc.
- Exceptions are possible, but tell me first. If using pacman/paru isn't possible, or doing it another way would leave a mess, explain the situation and let me decide.

## Git
- **Never create or publish anything under my name.** That means no `commit`, `commit --amend`, `merge`, `rebase`, `cherry-pick`, `revert`, `tag` or `push`, and no opening PRs. I write, review and publish all commits and their messages myself.
- These are fine: `fetch`, `pull`, `stash`, and read-only commands (`status`, `log`, `diff`, `show`, `blame`, …). Run pulls as `git pull --ff-only`. If that fails because a merge or rebase would be needed, ask me, since that would create a commit.
- Ask before anything that throws away work, such as `reset --hard`, `checkout -- <file>`, `clean` or `stash drop`.
- When a task is done, leave the changes uncommitted in the working tree. If I ask for one, suggest a commit message as text only.
- My commit message style: a single subject line with a type prefix, e.g. `Feat: [REDACTED: example from another project]` or `Fix: [REDACTED: example from another project]`. **No body**, and so no Co-Authored-By or other trailers; I use the body only for signing. If a project's own convention conflicts with this ([REDACTED: example from another project]), point that out and let me choose.
