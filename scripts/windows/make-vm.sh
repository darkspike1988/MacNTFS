#!/usr/bin/env bash
# Creates the VMware Fusion VM that boots oracle.iso (see build.py) on an empty NVMe disk.
# Usage: scripts/windows/make-vm.sh <directory-for-the-vm> <oracle.iso> [disk-MB]
# The VM has no network, no TPM, no encryption and no shared folders. It boots WinPE from the ISO,
# writes the NTFS volumes to the disk and powers off.
set -euo pipefail

dir="${1:?usage: make-vm.sh <directory> <oracle.iso> [disk-MB]}"
iso="${2:?usage: make-vm.sh <directory> <oracle.iso> [disk-MB]}"
mb="${3:-2304}"
name="NTFS Oracle WinPE"
bundle="$dir/$name.vmwarevm"
mkdir -p "$bundle"
sectors=$((mb * 2048))

: > "$bundle/$name-flat.vmdk"
dd if=/dev/zero of="$bundle/$name-flat.vmdk" bs=1m count=0 seek="$mb" 2>/dev/null
cat > "$bundle/$name.vmdk" <<VMDK
# Disk DescriptorFile
version=1
CID=fffffffe
parentCID=ffffffff
createType="monolithicFlat"

# Extent description
RW $sectors FLAT "$name-flat.vmdk" 0

# The Disk Data Base
#DDB
ddb.adapterType = "nvme"
ddb.geometry.cylinders = "$((sectors / 16065))"
ddb.geometry.heads = "255"
ddb.geometry.sectors = "63"
ddb.virtualHWVersion = "21"
VMDK

cat > "$bundle/$name.vmx" <<VMX
.encoding = "UTF-8"
config.version = "8"
virtualHW.version = "21"
displayName = "$name"
pciBridge0.present = "TRUE"
pciBridge4.present = "TRUE"
pciBridge4.virtualDev = "pcieRootPort"
pciBridge4.functions = "8"
pciBridge5.present = "TRUE"
pciBridge5.virtualDev = "pcieRootPort"
pciBridge5.functions = "8"
pciBridge6.present = "TRUE"
pciBridge6.virtualDev = "pcieRootPort"
pciBridge6.functions = "8"
pciBridge7.present = "TRUE"
pciBridge7.virtualDev = "pcieRootPort"
pciBridge7.functions = "8"
guestOS = "arm-windows11-64"
firmware = "efi"
uefi.secureBoot.enabled = "FALSE"
memsize = "3072"
numvcpus = "2"
cpuid.coresPerSocket = "2"
nvme0.present = "TRUE"
nvme0:0.present = "TRUE"
nvme0:0.fileName = "$name.vmdk"
sata0.present = "TRUE"
sata0:0.present = "TRUE"
sata0:0.deviceType = "cdrom-image"
sata0:0.fileName = "$iso"
sata0:0.startConnected = "TRUE"
usb.present = "FALSE"
svga.graphicsMemoryKB = "131072"
tools.syncTime = "FALSE"
powerType.powerOff = "hard"
powerType.reset = "hard"
floppy0.present = "FALSE"
sata0.pciSlotNumber = "34"
nvme0.pciSlotNumber = "224"
VMX
echo "$bundle/$name.vmx"
