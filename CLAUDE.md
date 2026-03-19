# CLAUDE.md

## Communication
- **Parler en français** — l'utilisateur est francophone
- Commandes courtes pour console série (pas de copier-coller)
- Expliquer les risques avant les opérations destructives (NAND erase, partition delete)
- Toujours suggérer des backups avant modifications

## Hardware Reference

| Detail | Value |
|--------|-------|
| SoC | Alpine AL-212 (dual-core Cortex-A15 @ 1.7 GHz) |
| RAM | 1 GB DDR3 |
| Flash | 2 MB SPI NOR + 512 MB NAND |
| SATA | 4x SATA III via PCIe AHCI |
| Network | 2x GbE (AR8035 PHY), out-of-tree al_eth driver |
| NAS IP | 192.168.1.109 (DHCP on enp0s1) |
| TFTP host | 192.168.1.113, files in /tmp/tftp/ |

## Build Commands

```bash
# Enter cross-compilation environment (NixOS)
cd /home/mae/qnap-kernel-build && nix-shell build/shell.nix

# Kernel
cd linux-6.12 && make -j$(nproc) zImage dtbs modules

# al_eth driver
cd al_eth-standalone && make KDIR=../linux-6.12

# uImage
mkimage -A arm -O linux -T kernel -C none -a 0x8000 -e 0x8000 -d arch/arm/boot/zImage /tmp/tftp/uImage

# Initramfs
cd initramfs && find . | cpio -o -H newc | gzip > /tmp/initrd.gz
mkimage -A arm -O linux -T ramdisk -C gzip -a 0 -e 0 -n initramfs -d /tmp/initrd.gz /tmp/tftp/uInitrd
```

## Key Technical Facts
- DTB must be loaded separately (not appended to zImage) for initrd to work
- PCI/SATA probe is deferred ~15s in kernel 6.12 — init must poll
- al_eth needs SerDes DT node; board params come from U-Boot scratch registers, not DTB
- PCIe must use `pci-host-ecam-generic`, not stock `alpine-internal-pcie`
- msix node needs `interrupt-controller;` property (removed in 6.12 alpine.dtsi)
- MDIO C22 wrappers required for al_eth on kernel >= 6.3
- RAID module load order: xor-neon → xor → raid6_pq → libcrc32c → async_tx → async_memcpy → async_xor → async_pq → async_raid6_recov → raid456
- xor-neon.ko is at arch/arm/lib/xor-neon.ko (separate from lib/xor.ko)

## Pending Work
- Flash kernel+initrd to NAND for permanent boot
- Set persistent MAC addresses
- Fix CPU count in DTB (AL-212 = 2 cores, not 4)
- Re-enable watchdog after diagnosing systemd boot hang
