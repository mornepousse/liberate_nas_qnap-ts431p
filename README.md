# QNAP TS-431P — Debian on Custom Kernel

Replacing stock QNAP QTS with **Debian Bookworm** on a QNAP TS-431P NAS, running a **custom kernel 6.12 LTS** with RAID 5 and Samba.

The stock QTS firmware (kernel 4.2.8) is end-of-life with known CVEs. This project gives the hardware a second life with a modern, maintainable Debian system.

## Status: Fully Operational

- Debian Bookworm (armhf) booting from RAID 5
- Kernel 6.12.77 LTS (custom cross-compiled)
- 4x 3TB SATA drives in RAID 5 (~8.2 TB usable)
- Samba file sharing (SMB2/3)
- SMART disk monitoring
- SSH access

## Hardware

| Component | Details |
|-----------|---------|
| **SoC** | Annapurna Labs Alpine AL-212 (ARMv7-A Cortex-A15 dual-core @ 1.7 GHz) |
| **RAM** | 1 GB DDR3 |
| **Flash** | 2 MB SPI NOR (U-Boot) + 512 MB NAND (stock kernel/rootfs) |
| **SATA** | 4x SATA III (6 Gb/s) via integrated PCIe AHCI |
| **Network** | 2x Gigabit Ethernet (Qualcomm Atheros AR8035 PHY) |
| **UART** | JST PHR-4 header, 115200 8N1, 3.3V TTL |

## Boot Chain

```
U-Boot (SPI NOR) → TFTP/NAND loads:
  ├── uImage (kernel 6.12.77 zImage, no appended DTB)
  ├── alpine-qnap-ts431p.dtb (separate, so U-Boot can patch initrd addresses)
  └── uInitrd (custom initramfs)
        ├── busybox
        ├── mdadm + libs
        ├── al_eth.ko (network driver)
        ├── RAID modules (xor-neon, xor, raid6_pq, async_*, raid456)
        └── init script:
              1. Load al_eth → network up
              2. Load RAID modules
              3. Wait for SATA (deferred probe, ~15s)
              4. mdadm --assemble /dev/md0
              5. mount + switch_root → Debian
```

**Important**: The DTB must be loaded as a separate file, not appended to zImage. U-Boot needs to patch the FDT with initrd start/end addresses. With an appended DTB, U-Boot patches the wrong memory and the initramfs is not found → kernel panic.

## U-Boot Commands

```
setenv serverip 192.168.1.113
setenv ipaddr 192.168.1.109
tftpboot 0x5000000 uImage
tftpboot 0x4000000 alpine-qnap-ts431p.dtb
tftpboot 0x4500000 uInitrd
bootm 0x5000000 0x4500000 0x4000000
```

## Building

### Prerequisites (NixOS)

```bash
cd build/
nix-shell shell.nix
```

This provides the ARM cross-compiler (`armv7l-unknown-linux-gnueabihf-gcc`), `mkimage`, `dtc`, and all kernel build dependencies.

### Kernel

```bash
# Start from multi_v7_defconfig + our fragment
cd linux-6.12/
make multi_v7_defconfig
scripts/kconfig/merge_config.sh .config ../build/kernel-config.fragment
make -j$(nproc) zImage dtbs modules

# Create uImage (load/entry at 0x8000 for ARM zImage)
mkimage -A arm -O linux -T kernel -C none -a 0x00008000 -e 0x00008000 \
  -d arch/arm/boot/zImage /tmp/tftp/uImage

# Copy DTB
cp arch/arm/boot/dts/amazon/alpine-qnap-ts431p.dtb /tmp/tftp/
```

### al_eth Network Driver

The Alpine Ethernet driver is **not in mainline**. Use [al_eth-standalone](https://github.com/delroth/al_eth-standalone):

```bash
cd al_eth-standalone/
make KDIR=../linux-6.12/
cp src/al_eth.ko ../initramfs/lib/modules/
```

**Note**: For kernel >= 6.3, a fix for MDIO C22 callbacks is required. See our [PR on al_eth-standalone](https://github.com/delroth/al_eth-standalone/pull/XXX).

### Initramfs

```bash
cd initramfs/
# Populate lib/modules/ with al_eth.ko + RAID modules from kernel build
# Populate bin/ with busybox (static armhf) and mdadm + its libs
find . | cpio -o -H newc | gzip > /tmp/initrd.gz
mkimage -A arm -O linux -T ramdisk -C gzip -a 0x0 -e 0x0 \
  -n "initramfs" -d /tmp/initrd.gz /tmp/tftp/uInitrd
```

## Key Technical Challenges & Solutions

### 1. Ethernet Driver — MDIO C22/C45 Split (kernel >= 6.3)

Since kernel 6.3, MDIO bus separates Clause 22 and Clause 45 into distinct callbacks. The al_eth driver only set C45 callbacks, leaving `bus->read`/`bus->write` NULL. PHY probing uses C22 → `__mdiobus_read()` returns `-EOPNOTSUPP` → "Could not attach to PHY".

**Fix**: Add C22 wrappers calling C45 with `dev=0`, assign all 4 callbacks.

### 2. MSI-X Interrupts — Missing `interrupt-controller` Property (kernel >= 6.12)

Kernel 6.12's `alpine.dtsi` removed `interrupt-controller;` from the msix node. The `of_irq_init()` function requires this property to recognize the node as an interrupt controller. Without it: `failed to request irq → -EINVAL`.

**Fix**: Add `interrupt-controller;` back to the msix node in `alpine.dtsi`:
```dts
msix: msix@fbe00000 {
    compatible = "al,alpine-msix";
    reg = <0x0 0xfbe00000 0x0 0x100000>;
    interrupt-controller;  /* required — removed upstream in 6.12 */
    msi-controller;
    al,msi-base-spi = <96>;
    al,msi-num-spis = <64>;
};
```

### 3. DTB Must Be Loaded Separately

With an appended DTB, U-Boot cannot find the FDT to patch initrd addresses. The `bootm` command's 3-argument form (`bootm <kernel> <initrd> <fdt>`) is required:
- `0x5000000` — uImage
- `0x4500000` — uInitrd
- `0x4000000` — DTB

### 4. PCI Deferred Probe (kernel >= 6.12)

SATA drives appear ~15s after boot (vs ~3s in 6.1). The initramfs init must poll for block devices instead of using a fixed sleep.

### 5. RAID Module Dependencies

`raid456.ko` depends on 9 modules that must be loaded in exact order:
```
xor-neon → xor → raid6_pq → libcrc32c → async_tx → async_memcpy → async_xor → async_pq → async_raid6_recov → raid456
```
Note: `xor-neon.ko` is built separately at `arch/arm/lib/xor-neon.ko` (easy to miss).

### 6. SerDes Node Required for al_eth

The al_eth driver needs a SerDes device tree node. Board parameters (PHY address, RGMII mode) come from MAC scratch registers written by U-Boot, not from the DTB. Only the SerDes base address is needed from DT:
```dts
serdes@fd8c0000 {
    compatible = "annapurna-labs,al-serdes";
    reg = <0x0 0xfd8c0000 0x0 0x1000>;
};
```

### 7. PCIe Host Controller

Stock QNAP uses `alpine-internal-pcie` which is incompatible with modern kernels. Use `pci-host-ecam-generic` from mainline `alpine.dtsi` instead.

## NAND Layout

### SPI NOR (2 MB)
| Partition | Content | Size |
|-----------|---------|------|
| mtd0 | U-Boot loader | 1088 KB (read-only) |
| mtd1 | U-Boot env | 384 KB |

### NAND (512 MB)
| Partition | Content | Size |
|-----------|---------|------|
| mtd2 | boot1_kernel | 32 MB |
| mtd3 | boot1_rootfs2 | 216 MB |
| mtd4 | boot2_kernel (backup) | 32 MB |
| mtd5 | boot2_rootfs2 (backup) | 216 MB |
| mtd6 | config (UBI) | 15 MB |

Dual A/B boot slots. 32 MB kernel partition is plenty for our ~12 MB uImage.

## UART Pinout

```
Pin 0: GND
Pin 1: RX
Pin 2: VCC (3.3V — DO NOT CONNECT)
Pin 3: TX
```

Connector: JST PHR-4. Use `picocom -b 115200 /dev/ttyUSB0`.

## File Structure

```
├── README.md                          # This file
├── CLAUDE.md                          # AI assistant guidance
├── dts/
│   ├── alpine-qnap-ts431p.dts        # Custom DTB source
│   └── qnap-stock.dts                # Stock QNAP DTB (decompiled, reference)
├── initramfs/
│   └── init                           # Initramfs init script (RAID assembly + switch_root)
├── build/
│   ├── shell.nix                      # NixOS cross-compilation environment
│   └── kernel-config.fragment         # Kernel config additions over multi_v7_defconfig
├── research/
│   ├── recon1.log                     # Hardware reconnaissance (cpuinfo, mtd, dmesg)
│   ├── recon2.log
│   └── recon3.log
├── tftp/
│   └── tftp_server.py                 # Minimal TFTP server for boot testing
└── uboot/
    └── nand_backup/                   # NAND partition dumps (.gitignored)
```

## Related Projects

- [al_eth-standalone](https://github.com/delroth/al_eth-standalone) — Out-of-tree Alpine Ethernet driver
- [revive_nas_dns-345](https://github.com/mornepousse/revive_nas_dns-345) — Similar project for D-Link DNS-345 (completed)
- [delroth/linux-qnap-tsx32x](https://github.com/delroth/linux-qnap-tsx32x) — Kernel patches for Alpine v2 (ARMv8) QNAP NAS

## Known Issues

- **CPU count**: DTB inherits 4 CPUs from `alpine.dtsi` but AL-212 is dual-core → CPU2/3 fail to come online (harmless but noisy)
- **MAC addresses**: Random at each boot (not persistent yet)
- **Watchdog**: Disabled (`RuntimeWatchdogSec=0`) because systemd hangs during boot with it enabled
- **IRQ**: `of_irq_parse_pci: failed with rc=-22` on network interfaces (non-blocking, network works fine)

## License

The custom DTS and init scripts in this repository are provided under the MIT License. The al_eth driver and kernel are subject to their respective licenses (GPL-2.0).
