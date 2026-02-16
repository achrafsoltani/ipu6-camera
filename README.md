# IPU6 Camera on Linux

Enable the integrated camera on Intel Meteor Lake (14th Gen) laptops running Ubuntu/Debian.

This fixes the camera on devices where the sensor is connected via the **Lattice USB-IO bridge** (USB `2ac1:20c9`) and the **Intel IPU6** image processing unit — a combination that requires multiple out-of-tree drivers and the Intel Camera HAL userspace stack.

## Requirements

- **OS**: Ubuntu 24.04 LTS or Debian 12+ (other apt-based distros may work with adjustments)
- **Kernel**: 6.10+ recommended (IPU6 ISYS and sensor drivers are in mainline). Older kernels need additional out-of-tree modules.
- **Hardware**: Intel IPU6 (see [Supported IPU6 Variants](#supported-ipu6-variants)) with Lattice USB-IO bridge
- **Packages**: `build-essential`, `cmake`, `dkms`, `git`, GStreamer dev libraries (installed automatically by `setup.sh`)

## Affected Hardware

| Laptop | Sensor | IPU6 PCI | USB-IO Bridge |
|--------|--------|----------|---------------|
| Lenovo ThinkPad X1 Carbon Gen 12 | OmniVision OV08F40 | `8086:7d19` | `2ac1:20c9` |
| Other Meteor Lake laptops | Various | `8086:7d19` | `2ac1:20c9` |

Check if your laptop is affected:

```bash
# Should show Intel IPU6
lspci | grep -i "Multimedia"

# Should show Lattice device (2ac1:xxxx)
lsusb | grep 2ac1

# Should show OVTI08F4 or similar sensor in ACPI
grep -r . /sys/bus/acpi/devices/OVTI*/  2>/dev/null | head -5

# Should show INT3472 deferring on GPIO chip
dmesg | grep -i "int3472"
```

## The Problem

On mainline Linux kernels (6.10+), the IPU6 ISYS driver and camera sensor drivers are included, but:

1. **Missing USBIO driver**: The Lattice USB-IO bridge (`2ac1:20c9`) provides GPIO/I2C access to the camera sensor. Without the `usbio` driver, the `INT3472` discrete power controller cannot find the GPIO chip (`INTC1007:00`) and the sensor never powers on.

2. **Missing PSYS module**: The IPU6 Processing System (PSYS) kernel module is **not in mainline**. The Camera HAL requires it.

3. **No direct V4L2 streaming**: Unlike typical USB cameras, IPU6 cameras cannot stream via V4L2 directly. They require the **Intel Camera HAL** (userspace image processing) and the `icamerasrc` GStreamer plugin.

4. **App compatibility**: Since the camera only works via `icamerasrc` (not V4L2), a **v4l2loopback** virtual device is needed so that browsers and apps can access it.

## Solution Architecture

```
┌─────────────────────────────────────────────────────────┐
│  Firefox (PipeWire camera portal)                       │
│  Chromium-based browsers (direct V4L2)                  │
├─────────────────────────────────────────────────────────┤
│  PipeWire V4L2 SPA node ←──── ipu6-pipewire-fixup      │
│  (for Firefox / portal-based apps)                      │
├─────────────────────────────────────────────────────────┤
│  /dev/video99 — v4l2loopback (virtual V4L2 device)      │
├─────────────────────────────────────────────────────────┤
│  GStreamer pipeline: icamerasrc → videoconvert → v4l2sink│
├─────────────────────────────────────────────────────────┤
│  Intel Camera HAL (libcamhal) — userspace ISP           │
├─────────────────────────────────────────────────────────┤
│  IPU6 PSYS kernel module (out-of-tree)                  │
│  IPU6 ISYS kernel module (mainline ≥6.10)               │
├─────────────────────────────────────────────────────────┤
│  Camera sensor driver (ov08x40, mainline)               │
├─────────────────────────────────────────────────────────┤
│  INT3472 power controller ← GPIO from INTC1007          │
├─────────────────────────────────────────────────────────┤
│  USBIO drivers (out-of-tree) — usbio, gpio-usbio,      │
│  i2c-usbio → Lattice USB bridge (2ac1:20c9)            │
└─────────────────────────────────────────────────────────┘
```

## Quick Start

```bash
git clone https://github.com/achrafsoltani/ipu6-camera.git
cd ipu6-camera
sudo ./setup.sh
sudo reboot
```

After reboot, the camera appears as **"Integrated Camera"** on `/dev/video99`.

Test it at [webcamtests.com](https://webcamtests.com) in **any browser** — Firefox, Chrome, Brave, or Edge.

## What the Setup Script Does

1. Installs build dependencies (`build-essential`, `cmake`, `dkms`, GStreamer dev libs, etc.)
2. Clones and builds [Intel USBIO drivers](https://github.com/intel/usbio-drivers) via DKMS
3. Clones and builds [IPU6 PSYS module](https://github.com/intel/ipu6-drivers) via DKMS (fetches kernel headers from kernel.org)
4. Installs [Camera HAL binaries](https://github.com/intel/ipu6-camera-bins) (firmware + proprietary ISP libraries)
5. Builds [Intel Camera HAL](https://github.com/intel/ipu6-camera-hal) (`libcamhal`)
6. Builds [icamerasrc](https://github.com/intel/icamerasrc) GStreamer plugin (branch: `icamerasrc_slim_api`)
7. Installs `v4l2loopback-dkms` and configures it on `/dev/video99`
8. Configures Firefox PipeWire camera support (`media.webrtc.camera.allow-pipewire`)
9. Installs a systemd service (`ipu6-camera-loopback`) for automatic startup
10. Installs PipeWire fixup script (creates V4L2 SPA node + portal permissions)
11. Configures udev rules to hide raw IPU6 nodes from applications
12. Sets up module auto-loading (`/etc/modules-load.d/ipu6-camera.conf`)

## Manual Setup

If you prefer to build each component yourself, follow these steps:

### Dependencies

```bash
sudo apt install build-essential cmake dkms git pkg-config \
    linux-headers-$(uname -r) v4l2loopback-dkms libexpat1-dev \
    automake autoconf libtool libgstreamer1.0-dev \
    libgstreamer-plugins-base1.0-dev gstreamer1.0-plugins-base \
    gstreamer1.0-plugins-good gstreamer1.0-tools
```

### 1. USBIO Drivers

```bash
git clone https://github.com/intel/usbio-drivers.git
cd usbio-drivers
make -C . KERNELDIR=/lib/modules/$(uname -r)/build
sudo make -C . KERNELDIR=/lib/modules/$(uname -r)/build install
sudo modprobe usbio gpio-usbio i2c-usbio
```

Verify: `dmesg | grep usbio` should show the bridge binding, and `dmesg | grep int3472` should no longer show "deferring".

### 2. IPU6 PSYS Module

```bash
git clone https://github.com/intel/ipu6-drivers.git
cd ipu6-drivers

# Fetch headers missing from kernel headers package (kernel ≥6.10)
KVER=$(echo $(uname -r) | grep -oP '^\d+\.\d+')
for h in ipu6.h ipu6-bus.h ipu6-buttress.h ipu6-cpd.h ipu6-dma.h \
         ipu6-fw-com.h ipu6-mmu.h ipu6-platform-buttress-regs.h \
         ipu6-platform-regs.h; do
    curl -sfL "https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/drivers/media/pci/intel/ipu6/${h}?h=v${KVER}" \
        -o drivers/media/pci/intel/ipu6/${h}
done

make KERNELRELEASE=$(uname -r)
sudo make KERNELRELEASE=$(uname -r) install
sudo modprobe intel-ipu6-psys
```

### 3. Camera HAL Binaries

```bash
git clone https://github.com/intel/ipu6-camera-bins.git
cd ipu6-camera-bins
sudo cp -r lib/firmware/* /lib/firmware/
sudo cp -P lib/*.so lib/*.so.* /usr/lib/
sudo cp -P lib/*.a /usr/lib/
sudo cp -r include/* /usr/include/
sudo mkdir -p /usr/lib/pkgconfig
sudo cp lib/pkgconfig/* /usr/lib/pkgconfig/
sudo ldconfig
```

### 4. Camera HAL

```bash
git clone https://github.com/intel/ipu6-camera-hal.git
cd ipu6-camera-hal
mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr \
    -DIPU_VER=ipu6epmtl -DPRODUCTION_NAME=ipu6epmtl
make -j$(nproc)
sudo make install
sudo ldconfig
```

> Replace `ipu6epmtl` with `ipu6ep` for Alder/Raptor Lake, or `ipu6` for Tiger Lake.

### 5. icamerasrc GStreamer Plugin

```bash
git clone -b icamerasrc_slim_api https://github.com/intel/icamerasrc.git
cd icamerasrc
export CHROME_SLIM_CAMHAL=ON
export STRIP_VIRTUAL_CHANNEL_CAMHAL=ON
./autogen.sh
./configure --prefix=/usr
make -j$(nproc)
sudo make install
```

### 6. v4l2loopback + Test

```bash
sudo modprobe v4l2loopback video_nr=99 card_label="Integrated Camera" exclusive_caps=1

export GST_PLUGIN_PATH=/usr/lib/gstreamer-1.0
sudo -E gst-launch-1.0 -e \
    icamerasrc buffer-count=7 \
    ! video/x-raw,format=NV12,width=1280,height=720 \
    ! videoconvert \
    ! video/x-raw,format=YUY2,width=1280,height=720,framerate=30/1 \
    ! identity drop-allocation=true \
    ! v4l2sink device=/dev/video99 sync=false
```

The camera should now be visible in browsers as "Integrated Camera".

## Files

| File | Description |
|------|-------------|
| `setup.sh` | Automated setup script (run with `sudo`) |
| `start-camera.sh` | Manual camera start script (run with `sudo`) |
| `ipu6-camera-loopback.service` | systemd service for automatic startup |
| `ipu6-pipewire-fixup` | PipeWire V4L2 node + portal permissions (runs after service starts) |
| `firefox-pipewire-camera.js` | Firefox autoconfig pref to enable PipeWire camera |
| `99-hide-ipu6-raw.rules` | udev rule to hide raw IPU6 nodes from apps |

## Troubleshooting

### Camera not detected after reboot

```bash
# Check modules are loaded
lsmod | grep -E 'usbio|ipu6|v4l2loopback'

# Check service status
sudo systemctl status ipu6-camera-loopback

# Check kernel logs
dmesg | grep -iE 'ipu6|int3472|ov08|usbio'

# INT3472 still deferring? USBIO modules not loaded
sudo modprobe usbio gpio-usbio i2c-usbio
```

### Browser shows many "ipu6" entries

The udev rule should hide raw IPU6 nodes. If they still appear:

```bash
# Reload udev rules
sudo udevadm control --reload-rules
sudo udevadm trigger

# Strip leftover ACLs (one-time, does not persist)
sudo setfacl -b /dev/video{0..47}
```

### Firefox doesn't detect the camera

Firefox Snap requires **PipeWire** for camera access (it cannot use V4L2 directly from the sandbox). The setup script configures this automatically, but if the camera still doesn't appear:

1. **Check the Firefox about:config pref**:
   - Open `about:config` in Firefox
   - Search for `media.webrtc.camera.allow-pipewire`
   - Set it to `true` if it isn't already
   - Restart Firefox

2. **Check the PipeWire V4L2 node exists**:
   ```bash
   wpctl status | grep -A5 "Video"
   # Should show "Integrated-Camera" under Sources
   ```

3. **Check portal camera permission**:
   ```bash
   busctl --user get-property org.freedesktop.portal.Desktop \
       /org/freedesktop/portal/desktop \
       org.freedesktop.portal.Camera IsCameraPresent
   # Should return: b true
   ```

4. **Re-run the PipeWire fixup manually**:
   ```bash
   sudo /usr/local/bin/ipu6-pipewire-fixup
   ```

5. **Restart Firefox completely** (close all windows, reopen).

**How it works**: The `ipu6-pipewire-fixup` script creates a PipeWire V4L2 SPA node (via `pw-cli create-node spa-node-factory`) that points at `/dev/video99`. This node has `port.physical=true` and `port.terminal=true`, which are properties the XDG desktop portal requires to expose a camera device. The script also grants camera permission in the portal's permission store and restarts the portal daemon.

### Service fails to start

```bash
# Check detailed logs
sudo journalctl -u ipu6-camera-loopback -n 50

# Verify GStreamer can find icamerasrc
GST_PLUGIN_PATH=/usr/lib/gstreamer-1.0 gst-inspect-1.0 icamerasrc

# Try manual pipeline
sudo GST_PLUGIN_PATH=/usr/lib/gstreamer-1.0 gst-launch-1.0 -e \
    icamerasrc buffer-count=7 ! video/x-raw,format=NV12,width=1280,height=720 ! fakesink
```

### Wrong resolution / corrupt image

The Camera HAL only supports specific resolutions. Known working:
- **1280x720** (recommended, lower CPU usage)
- **1920x1080**

Other resolutions (e.g. native 3856x2416) may fail or produce corrupt output.

### DKMS build fails on kernel update

If a kernel update breaks the DKMS modules:

```bash
# Rebuild both modules for the new kernel
sudo dkms autoinstall

# Or rebuild individually
sudo dkms build usbio/0.3
sudo dkms install usbio/0.3
sudo dkms build ipu6-drivers/0.0.0
sudo dkms install ipu6-drivers/0.0.0
```

If the IPU6 PSYS build fails because of missing kernel headers, re-run `setup.sh` — it fetches the correct headers for the running kernel.

## Supported IPU6 Variants

| Platform | Generation | PCI ID | HAL variant |
|----------|-----------|--------|-------------|
| Tiger Lake (TGL) | 11th Gen | `8086:9a19` | `ipu6` |
| Jasper Lake (JSL) | Pentium/Celeron | `8086:4e19` | `ipu6` |
| Alder Lake (ADL) | 12th Gen | `8086:462e` | `ipu6ep` |
| Raptor Lake (RPL) | 13th Gen | `8086:462e` | `ipu6ep` |
| Meteor Lake (MTL) | 14th Gen (Core Ultra) | `8086:7d19` | `ipu6epmtl` |

> The setup script auto-detects the variant from the PCI ID.

## DKMS

Both USBIO and IPU6 PSYS modules are installed via DKMS, so they automatically rebuild when you update your kernel.

```bash
dkms status
# usbio/0.3, 6.17.0-14-generic, x86_64: installed
# ipu6-drivers/0.0.0, 6.17.0-14-generic, x86_64: installed
```

## Performance

The GStreamer pipeline (`icamerasrc → videoconvert → v4l2sink`) runs continuously while the camera is active. Typical resource usage:

- **720p (1280x720)**: ~3-5% CPU on a Core Ultra 7 165U
- **1080p (1920x1080)**: ~5-8% CPU

To switch to 1080p, edit the resolution in `/etc/systemd/system/ipu6-camera-loopback.service` (change both `width` and `height` values) and restart the service:

```bash
sudo systemctl restart ipu6-camera-loopback
```

## Uninstall

To fully reverse the setup:

```bash
# 1. Stop and disable the service
sudo systemctl stop ipu6-camera-loopback
sudo systemctl disable ipu6-camera-loopback
sudo rm /etc/systemd/system/ipu6-camera-loopback.service
sudo systemctl daemon-reload

# 2. Remove DKMS modules
sudo dkms remove ipu6-drivers/0.0.0 --all
sudo dkms remove usbio/0.3 --all
sudo rm -rf /usr/src/ipu6-drivers-0.0.0 /usr/src/usbio-0.3

# 3. Remove Camera HAL and icamerasrc
sudo rm -f /usr/lib/libcamhal.so*
sudo rm -f /usr/lib/gstreamer-1.0/libgsticamerasrc.so

# 4. Remove configuration
sudo rm -f /etc/modules-load.d/ipu6-camera.conf
sudo rm -f /etc/udev/rules.d/99-hide-ipu6-raw.rules
sudo rm -f /usr/local/bin/ipu6-pipewire-fixup
sudo rm -f /etc/firefox/syspref.js
sudo rm -f /usr/lib/firefox/defaults/pref/firefox-pipewire-camera.js
sudo udevadm control --reload-rules

# 5. Reboot
sudo reboot
```

> **Note**: This does not remove the Camera HAL binaries (firmware, headers, static libraries) installed to `/lib/firmware/`, `/usr/lib/`, and `/usr/include/`. These are harmless to leave in place, but can be removed manually if desired.

## Tested On

| Laptop | CPU | Sensor | Kernel | OS | Status |
|--------|-----|--------|--------|----|--------|
| Lenovo ThinkPad X1 Carbon Gen 12 | Core Ultra 7 165U | OV08F40 | 6.17.0-14-generic (HWE) | Ubuntu 24.04 LTS | Working |

If you've tested this on other hardware, please open an issue or PR to add your configuration.

## Upstream References

- [intel/usbio-drivers](https://github.com/intel/usbio-drivers) — Lattice USB-IO bridge drivers
- [intel/ipu6-drivers](https://github.com/intel/ipu6-drivers) — IPU6 out-of-tree drivers (PSYS, sensor drivers)
- [intel/ipu6-camera-bins](https://github.com/intel/ipu6-camera-bins) — Proprietary firmware and ISP libraries
- [intel/ipu6-camera-hal](https://github.com/intel/ipu6-camera-hal) — Camera HAL (userspace image processing)
- [intel/icamerasrc](https://github.com/intel/icamerasrc) — GStreamer source plugin

## Kernel Compatibility

- **Kernel ≥6.10**: IPU6 ISYS and sensor drivers are in mainline. Only PSYS and USBIO need out-of-tree builds.
- **Kernel <6.10**: More out-of-tree modules needed (full IPU6, IVSC, etc.). The `ipu6-drivers` DKMS handles this automatically.

## Contributing

If you've tested this on additional hardware, please open an issue or PR with your laptop model, sensor, and kernel version.

## License

Setup scripts and configuration files: MIT

This project orchestrates components from Intel's open-source repositories, each with their own licences (GPL-2.0 for kernel modules, Apache-2.0 for Camera HAL, proprietary for camera-bins).
