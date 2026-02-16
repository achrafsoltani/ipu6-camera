#!/bin/bash
# ==============================================================================
# IPU6 Camera Setup for Intel Meteor Lake (14th Gen) on Ubuntu
# ==============================================================================
#
# Enables the integrated camera on laptops with Intel Meteor Lake IPU6 and
# Lattice USB-IO bridge (e.g. Lenovo ThinkPad X1 Carbon Gen 12).
#
# What this script does:
#   1. Installs build dependencies
#   2. Builds & installs Intel USBIO drivers (DKMS)
#   3. Builds & installs IPU6 PSYS kernel module (DKMS)
#   4. Installs Intel Camera HAL binaries (firmware + libraries)
#   5. Builds & installs Intel Camera HAL (libcamhal)
#   6. Builds & installs icamerasrc GStreamer plugin
#   7. Installs v4l2loopback (DKMS)
#   8. Configures Firefox PipeWire camera support (about:config pref)
#   9. Configures systemd service, udev rules, and module auto-loading
#  10. Installs tray toggle utility (yad-based system tray applet)
#
# Usage:
#   chmod +x setup.sh
#   sudo ./setup.sh
#
# After reboot, the camera appears as "Integrated Camera" on /dev/video99.
#
# Tested on:
#   - Lenovo ThinkPad X1 Carbon Gen 12 (Meteor Lake)
#   - Ubuntu 24.04 LTS with HWE kernel 6.17
#   - OmniVision OV08F40 sensor (ACPI: OVTI08F4)
#
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }
info() { echo -e "${BLUE}[i]${NC} $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
KERNEL_VER="$(uname -r)"

# ==============================================================================
# Pre-flight checks
# ==============================================================================

if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root (sudo ./setup.sh)"
    exit 1
fi

if ! grep -qi 'ubuntu\|debian' /etc/os-release 2>/dev/null; then
    warn "This script is designed for Ubuntu/Debian. Other distros may need adjustments."
fi

# Check for IPU6 hardware
if ! lspci | grep -qi "Multimedia.*Intel.*IPU"; then
    err "No Intel IPU6 device found. This script is for Meteor Lake (14th Gen) laptops."
    exit 1
fi

# Check for Lattice USB-IO bridge
if lsusb | grep -q "2ac1:"; then
    log "Lattice USB-IO bridge detected"
elif lsusb | grep -q "8086:0b63"; then
    warn "Intel LJCA bridge detected — this script targets Lattice USB-IO (Meteor Lake)."
    warn "Your device may use a different driver stack. Proceeding anyway..."
else
    warn "No USB-IO bridge detected. Camera may use a different power path."
fi

log "Kernel: ${KERNEL_VER}"
log "Starting IPU6 camera setup..."
echo ""

mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

# ==============================================================================
# Step 1: Install dependencies
# ==============================================================================

log "Step 1/8: Installing build dependencies..."

apt-get update -qq
apt-get install -y -qq \
    build-essential \
    cmake \
    dkms \
    git \
    pkg-config \
    linux-headers-"${KERNEL_VER}" \
    v4l2loopback-dkms \
    libexpat1-dev \
    automake \
    autoconf \
    libtool \
    libgstreamer1.0-dev \
    libgstreamer-plugins-base1.0-dev \
    gstreamer1.0-plugins-base \
    gstreamer1.0-plugins-good \
    gstreamer1.0-tools \
    gir1.2-ayatanaappindicator3-0.1 \
    python3-gi \
    > /dev/null

log "Dependencies installed."

# ==============================================================================
# Step 2: Build Intel USBIO drivers (DKMS)
# ==============================================================================

log "Step 2/8: Building Intel USBIO drivers..."

USBIO_VER="0.3"
if dkms status "usbio/${USBIO_VER}" 2>/dev/null | grep -q "installed"; then
    info "USBIO drivers already installed via DKMS, skipping."
else
    if [[ ! -d usbio-drivers ]]; then
        git clone https://github.com/intel/usbio-drivers.git
    fi
    cd usbio-drivers

    # Install to DKMS source tree
    DKMS_SRC="/usr/src/usbio-${USBIO_VER}"
    rm -rf "${DKMS_SRC}"
    mkdir -p "${DKMS_SRC}"
    cp -r drivers include Makefile LICENSE.txt "${DKMS_SRC}/"

    cat > "${DKMS_SRC}/dkms.conf" << EOF
PACKAGE_NAME="usbio"
PACKAGE_VERSION="${USBIO_VER}"

MAKE="make -C . KERNELDIR=/lib/modules/\${kernelver}/build"
CLEAN="make -C . clean"

BUILT_MODULE_NAME[0]="usbio"
DEST_MODULE_LOCATION[0]="/updates"

BUILT_MODULE_NAME[1]="gpio-usbio"
DEST_MODULE_LOCATION[1]="/updates"

BUILT_MODULE_NAME[2]="i2c-usbio"
DEST_MODULE_LOCATION[2]="/updates"

AUTOINSTALL="yes"
EOF

    dkms add "usbio/${USBIO_VER}" 2>/dev/null || true
    dkms build "usbio/${USBIO_VER}"
    dkms install "usbio/${USBIO_VER}"
    cd "${BUILD_DIR}"
    log "USBIO drivers installed."
fi

# ==============================================================================
# Step 3: Build IPU6 PSYS kernel module (DKMS)
# ==============================================================================

log "Step 3/8: Building IPU6 PSYS kernel module..."

IPU6_DKMS_VER="0.0.0"
if dkms status "ipu6-drivers/${IPU6_DKMS_VER}" 2>/dev/null | grep -q "installed"; then
    info "IPU6 PSYS driver already installed via DKMS, skipping."
else
    if [[ ! -d ipu6-drivers ]]; then
        git clone https://github.com/intel/ipu6-drivers.git
    fi

    # Fetch kernel headers that may be missing from the headers package
    PSYS_HEADER_DIR="ipu6-drivers/drivers/media/pci/intel/ipu6"
    KERNEL_MAJOR_MINOR="$(echo "${KERNEL_VER}" | grep -oP '^\d+\.\d+')"
    KERNEL_TAG="v${KERNEL_MAJOR_MINOR}"

    IPU6_HEADERS=(
        ipu6.h ipu6-bus.h ipu6-buttress.h ipu6-cpd.h ipu6-dma.h
        ipu6-fw-com.h ipu6-mmu.h ipu6-platform-buttress-regs.h
        ipu6-platform-regs.h
    )

    HEADERS_NEEDED=false
    for h in "${IPU6_HEADERS[@]}"; do
        if [[ ! -f "${PSYS_HEADER_DIR}/${h}" ]]; then
            HEADERS_NEEDED=true
            break
        fi
    done

    if ${HEADERS_NEEDED}; then
        info "Fetching IPU6 kernel headers from kernel.org (${KERNEL_TAG})..."
        for h in "${IPU6_HEADERS[@]}"; do
            if [[ ! -f "${PSYS_HEADER_DIR}/${h}" ]]; then
                curl -sfL "https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/drivers/media/pci/intel/ipu6/${h}?h=${KERNEL_TAG}" \
                    -o "${PSYS_HEADER_DIR}/${h}" || warn "Could not fetch ${h}"
            fi
        done

        # Also fetch ipu6-trace.h if missing (needed by some builds)
        if [[ ! -f "${PSYS_HEADER_DIR}/ipu6-trace.h" ]]; then
            curl -sfL "https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/drivers/media/pci/intel/ipu6/ipu6-trace.h?h=${KERNEL_TAG}" \
                -o "${PSYS_HEADER_DIR}/ipu6-trace.h" 2>/dev/null || true
        fi
    fi

    # Install to DKMS
    DKMS_SRC="/usr/src/ipu6-drivers-${IPU6_DKMS_VER}"
    rm -rf "${DKMS_SRC}"
    cp -r ipu6-drivers "${DKMS_SRC}"

    dkms add "ipu6-drivers/${IPU6_DKMS_VER}" 2>/dev/null || true
    dkms build "ipu6-drivers/${IPU6_DKMS_VER}"
    dkms install "ipu6-drivers/${IPU6_DKMS_VER}"
    cd "${BUILD_DIR}"
    log "IPU6 PSYS module installed."
fi

# ==============================================================================
# Step 4: Install Camera HAL binaries (firmware + libraries)
# ==============================================================================

log "Step 4/8: Installing Intel Camera HAL binaries..."

if [[ ! -d ipu6-camera-bins ]]; then
    git clone https://github.com/intel/ipu6-camera-bins.git
fi
cd ipu6-camera-bins

# Install firmware
if [[ -d lib/firmware ]]; then
    cp -r lib/firmware/* /lib/firmware/
    info "Firmware files installed to /lib/firmware/"
fi

# Install libraries for the correct platform
# Detect IPU6 variant from PCI ID
IPU6_PCI=$(lspci -nn | grep -i "Multimedia.*Intel" | grep -oP '\[8086:\K[0-9a-f]+' | head -1)
case "${IPU6_PCI}" in
    7d19) IPU6_VARIANT="ipu6epmtl" ;;  # Meteor Lake
    a75d) IPU6_VARIANT="ipu6epmtl" ;;  # Arrow Lake (same HAL)
    462e) IPU6_VARIANT="ipu6ep"    ;;  # Alder Lake / Raptor Lake
    9a19) IPU6_VARIANT="ipu6"      ;;  # Tiger Lake
    4e19) IPU6_VARIANT="ipu6"      ;;  # Jasper Lake (ipu6se uses ipu6 bins)
    *)
        warn "Unknown IPU6 PCI ID: ${IPU6_PCI}. Defaulting to ipu6epmtl (Meteor Lake)."
        IPU6_VARIANT="ipu6epmtl"
        ;;
esac

info "Detected IPU6 variant: ${IPU6_VARIANT} (PCI: 8086:${IPU6_PCI})"

# Install all libraries (HAL needs them)
cp -P lib/*.so lib/*.so.* /usr/lib/ 2>/dev/null || true
cp -P lib/*.a /usr/lib/ 2>/dev/null || true

# Install headers
cp -r include/* /usr/include/

# Install pkgconfig
if [[ -d lib/pkgconfig ]]; then
    mkdir -p /usr/lib/pkgconfig
    cp lib/pkgconfig/* /usr/lib/pkgconfig/
fi

ldconfig
cd "${BUILD_DIR}"
log "Camera HAL binaries installed (${IPU6_VARIANT})."

# ==============================================================================
# Step 5: Build Intel Camera HAL (libcamhal)
# ==============================================================================

log "Step 5/8: Building Intel Camera HAL..."

if [[ -f /usr/lib/libcamhal.so ]]; then
    info "libcamhal already installed, skipping. (Delete /usr/lib/libcamhal.so to rebuild.)"
else
    if [[ ! -d ipu6-camera-hal ]]; then
        git clone https://github.com/intel/ipu6-camera-hal.git
    fi
    cd ipu6-camera-hal

    rm -rf build && mkdir build && cd build

    cmake .. \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DIPU_VER="${IPU6_VARIANT}" \
        -DPRODUCTION_NAME="${IPU6_VARIANT}" \
        > /dev/null 2>&1

    make -j"$(nproc)" > /dev/null 2>&1
    make install > /dev/null 2>&1

    ldconfig
    cd "${BUILD_DIR}"
    log "Camera HAL built and installed."
fi

# ==============================================================================
# Step 6: Build icamerasrc GStreamer plugin
# ==============================================================================

log "Step 6/8: Building icamerasrc GStreamer plugin..."

if [[ -f /usr/lib/gstreamer-1.0/libgsticamerasrc.so ]]; then
    info "icamerasrc already installed, skipping. (Delete to rebuild.)"
else
    if [[ ! -d icamerasrc ]]; then
        git clone -b icamerasrc_slim_api https://github.com/intel/icamerasrc.git
    fi
    cd icamerasrc

    # Set required environment for build
    export CHROME_SLIM_CAMHAL=ON
    export STRIP_VIRTUAL_CHANNEL_CAMHAL=ON

    if [[ ! -f configure ]]; then
        ./autogen.sh > /dev/null 2>&1
    fi

    ./configure --prefix=/usr > /dev/null 2>&1
    make -j"$(nproc)" > /dev/null 2>&1
    make install > /dev/null 2>&1

    # Ensure plugin is in GStreamer search path
    if [[ -f /usr/lib/gstreamer-1.0/libgsticamerasrc.so ]]; then
        log "icamerasrc plugin installed."
    elif [[ -f /usr/lib/x86_64-linux-gnu/gstreamer-1.0/libgsticamerasrc.so ]]; then
        cp /usr/lib/x86_64-linux-gnu/gstreamer-1.0/libgsticamerasrc.so /usr/lib/gstreamer-1.0/
        log "icamerasrc plugin installed (copied to gstreamer-1.0/)."
    else
        warn "icamerasrc built but .so not found in expected locations."
    fi

    cd "${BUILD_DIR}"
fi

# ==============================================================================
# Step 7: Configure module auto-loading
# ==============================================================================

log "Step 7/10: Configuring kernel modules and udev rules..."

# Auto-load modules on boot
cat > /etc/modules-load.d/ipu6-camera.conf << 'EOF'
# Intel IPU6 camera stack
usbio
gpio-usbio
i2c-usbio
intel-ipu6-psys
EOF

# udev rule: hide raw IPU6 capture nodes from applications
# The camera HAL (running as root) still has access
cp "${SCRIPT_DIR}/99-hide-ipu6-raw.rules" /etc/udev/rules.d/ 2>/dev/null || \
cat > /etc/udev/rules.d/99-hide-ipu6-raw.rules << 'EOF'
# Hide raw IPU6 ISYS capture devices from applications
# Remove user access so PipeWire/browsers can't enumerate them
# The camera HAL runs as root (sudo) so it still has access
SUBSYSTEM=="video4linux", ATTR{name}=="Intel IPU6 ISYS Capture *", MODE="0600", GROUP="root", TAG-="uaccess", TAG-="seat"
EOF

udevadm control --reload-rules 2>/dev/null || true

log "Module loading and udev rules configured."

# ==============================================================================
# Step 8: Configure Firefox PipeWire camera support
# ==============================================================================

log "Step 8/10: Configuring Firefox PipeWire camera support..."

# Firefox does not use PipeWire for camera access by default.
# This autoconfig pref enables it so Firefox Snap can use the camera
# via the xdg-desktop-portal camera interface.

# Firefox Snap autoconfig directory
FIREFOX_SNAP_PREFS="/snap/firefox/current/usr/lib/firefox/defaults/pref"
FIREFOX_SYSTEM_PREFS="/usr/lib/firefox/defaults/pref"
FIREFOX_SNAP_AUTOCONFIG="/etc/firefox/syspref.js"

# Install for system Firefox (deb)
if [[ -d "${FIREFOX_SYSTEM_PREFS}" ]]; then
    cp "${SCRIPT_DIR}/firefox-pipewire-camera.js" "${FIREFOX_SYSTEM_PREFS}/"
    info "Firefox system pref installed to ${FIREFOX_SYSTEM_PREFS}/"
fi

# Install for Firefox Snap via /etc/firefox/syspref.js (snap reads this)
mkdir -p /etc/firefox
if [[ -f "${FIREFOX_SNAP_AUTOCONFIG}" ]]; then
    if ! grep -q "media.webrtc.camera.allow-pipewire" "${FIREFOX_SNAP_AUTOCONFIG}"; then
        cat "${SCRIPT_DIR}/firefox-pipewire-camera.js" >> "${FIREFOX_SNAP_AUTOCONFIG}"
        info "Firefox Snap pref appended to ${FIREFOX_SNAP_AUTOCONFIG}"
    else
        info "Firefox Snap pref already present in ${FIREFOX_SNAP_AUTOCONFIG}"
    fi
else
    cp "${SCRIPT_DIR}/firefox-pipewire-camera.js" "${FIREFOX_SNAP_AUTOCONFIG}"
    info "Firefox Snap pref installed to ${FIREFOX_SNAP_AUTOCONFIG}"
fi

log "Firefox PipeWire camera support configured."

# ==============================================================================
# Step 9: Install systemd service
# ==============================================================================

log "Step 9/10: Installing systemd service..."

# Install PipeWire fixup script (restarts WirePlumber so Firefox detects the camera)
cp "${SCRIPT_DIR}/ipu6-pipewire-fixup" /usr/local/bin/ipu6-pipewire-fixup
chmod +x /usr/local/bin/ipu6-pipewire-fixup

cp "${SCRIPT_DIR}/ipu6-camera-loopback.service" /etc/systemd/system/ 2>/dev/null || \
cat > /etc/systemd/system/ipu6-camera-loopback.service << 'EOF'
[Unit]
Description=IPU6 Integrated Camera to V4L2 Loopback
After=multi-user.target
Wants=multi-user.target

[Service]
Type=simple
Environment=GST_PLUGIN_PATH=/usr/lib/gstreamer-1.0
ExecStartPre=/sbin/modprobe v4l2loopback video_nr=99 card_label="Integrated Camera" exclusive_caps=1
ExecStart=/usr/bin/gst-launch-1.0 -e icamerasrc buffer-count=7 ! video/x-raw,format=NV12,width=1280,height=720 ! videoconvert ! video/x-raw,format=YUY2,width=1280,height=720,framerate=30/1 ! identity drop-allocation=true ! v4l2sink device=/dev/video99 sync=false
ExecStartPost=-/usr/local/bin/ipu6-pipewire-fixup
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ipu6-camera-loopback.service

log "Systemd service installed and enabled."

# ==============================================================================
# Step 10: Install tray toggle utility
# ==============================================================================

log "Step 10/10: Installing tray toggle utility..."

# Install the tray script to PATH
cp "${SCRIPT_DIR}/ipu6-camera-tray" /usr/local/bin/ipu6-camera-tray
chmod +x /usr/local/bin/ipu6-camera-tray

# Install desktop file for app launcher and autostart (per-user)
REAL_USER="${SUDO_USER:-${USER}}"
REAL_HOME=$(eval echo "~${REAL_USER}")

DESKTOP_DIR="${REAL_HOME}/.local/share/applications"
AUTOSTART_DIR="${REAL_HOME}/.config/autostart"
mkdir -p "${DESKTOP_DIR}" "${AUTOSTART_DIR}"

cp "${SCRIPT_DIR}/ipu6-camera-tray.desktop" "${DESKTOP_DIR}/"
cp "${SCRIPT_DIR}/ipu6-camera-tray.desktop" "${AUTOSTART_DIR}/"
chown "${REAL_USER}:${REAL_USER}" "${DESKTOP_DIR}/ipu6-camera-tray.desktop" "${AUTOSTART_DIR}/ipu6-camera-tray.desktop"

update-desktop-database "${DESKTOP_DIR}" 2>/dev/null || true

log "Tray utility installed. It will auto-start on login."

# ==============================================================================
# Done
# ==============================================================================

echo ""
echo "=============================================="
echo -e "${GREEN} IPU6 Camera Setup Complete${NC}"
echo "=============================================="
echo ""
echo "Next steps:"
echo "  1. Reboot your machine"
echo "  2. The camera will start automatically as 'Integrated Camera' on /dev/video99"
echo "  3. Use the IPU6 Camera tray icon to toggle camera on/off and adjust settings"
echo "  4. Test at https://webcamtests.com in any browser (Firefox, Chrome, Brave, Edge)"
echo ""
echo "Manual start (without reboot):"
echo "  sudo modprobe usbio gpio-usbio i2c-usbio intel-ipu6-psys"
echo "  sudo systemctl start ipu6-camera-loopback"
echo ""
echo "Firefox note:"
echo "  PipeWire camera support has been enabled automatically."
echo "  If the camera doesn't appear in Firefox, verify about:config:"
echo "    media.webrtc.camera.allow-pipewire = true"
echo ""
echo "Troubleshooting:"
echo "  sudo systemctl status ipu6-camera-loopback"
echo "  sudo journalctl -u ipu6-camera-loopback -f"
echo "  dmesg | grep -iE 'ipu6|int3472|ov08|usbio'"
echo ""
