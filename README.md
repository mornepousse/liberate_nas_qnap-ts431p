# QNAP TS-431P — Debian on Custom Kernel

Replacing stock QNAP QTS with **Debian Bookworm** on a QNAP TS-431P NAS, running a **custom kernel 6.12 LTS** with RAID 5 and Samba.

The stock QTS firmware (kernel 4.2.8) is end-of-life with known CVEs. This project gives the hardware a second life with a modern, maintainable Debian system.

## Status: Fully Operational

- Debian Bookworm (armhf) booting from NAND
- Kernel 6.12.77 LTS (custom cross-compiled)
- 4x 3TB SATA drives in RAID 5 (~8.2 TB usable)
- Samba file sharing (SMB2/3)
- SMART disk monitoring
- nftables firewall
- Hardware RTC (Epson RX8010)
- CPU thermal monitoring (al_thermal)
- NAND accessible from Linux (al_nand, mtd-utils)
- SSH (key-only authentication)
- NTP via chrony

## Hardware

| Component | Details |
|-----------|---------|
| **SoC** | Annapurna Labs Alpine AL-212 (ARMv7-A Cortex-A15 dual-core @ 1.7 GHz) |
| **RAM** | 1 GB DDR3 |
| **Flash** | 2 MB SPI NOR (U-Boot) + 512 MB NAND (kernel/initrd) |
| **SATA** | 4x SATA III (6 Gb/s) via integrated PCIe AHCI |
| **Network** | 2x Gigabit Ethernet (Qualcomm Atheros AR8035 PHY) |
| **UART** | JST PHR-4 header, 115200 8N1, 3.3V TTL |

## Boot Chain

```
U-Boot (SPI NOR) → NAND loads:
  ├── uImage (kernel 6.12.77, ~12 MB)
  ├── alpine-qnap-ts431p.dtb (separate FDT)
  └── uInitrd (custom initramfs, ~1.9 MB)
        ├── busybox (static)
        ├── mdadm + libs
        ├── al_eth.ko (network driver)
        ├── al_thermal.ko (CPU temperature)
        ├── al_nand.ko (NAND flash access)
        └── init script:
              1. Load modules (al_eth, al_thermal, al_nand)
              2. Wait for SATA (deferred probe)
              3. mdadm --assemble --run /dev/md0
              4. mount + switch_root → Debian
```

RAID modules (md/raid456, xor, raid6_pq, async_*) are built into the kernel — no module loading needed.

**Important**: The DTB must be loaded as a separate file, not appended to zImage. U-Boot needs to patch the FDT with initrd start/end addresses. With an appended DTB, U-Boot patches the wrong memory and the initramfs is not found → kernel panic.

## NAND Boot (permanent)

```
bootcmd=nand read 0x5000000 0x0 0xC00000;nand read 0x4000000 0xC00000 0x20000;nand read 0x4500000 0xE00000 0x200000;bootm 0x5000000 0x4500000 0x4000000
```

| Offset | Size | Content |
|--------|------|---------|
| 0x000000 | 12 MB | uImage |
| 0xC00000 | 128 KB | DTB |
| 0xE00000 | 2 MB | uInitrd |

## TFTP Boot (for updates/recovery)

```
setenv serverip <HOST_IP>
setenv ipaddr <NAS_IP>
tftpboot 0x5000000 uImage
tftpboot 0x4000000 alpine-qnap-ts431p.dtb
tftpboot 0x4500000 uInitrd
bootm 0x5000000 0x4500000 0x4000000
```

## Updating from Linux (no U-Boot needed)

With al_nand loaded, NAND is accessible via MTD devices:

```bash
# Update kernel
flash_erase /dev/mtd0 0 0
nandwrite -p /dev/mtd0 /tmp/uImage

# Update DTB
flash_erase /dev/mtd0 0xC00000 1
nandwrite -p -s 0xC00000 /dev/mtd0 /tmp/alpine-qnap-ts431p.dtb

# Update initramfs
flash_erase /dev/mtd0 0xE00000 16
nandwrite -p -s 0xE00000 /dev/mtd0 /tmp/uInitrd
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
cd linux-6.12/
make multi_v7_defconfig
scripts/kconfig/merge_config.sh .config ../build/kernel-config.fragment
make -j$(nproc) zImage dtbs modules

mkimage -A arm -O linux -T kernel -C none -a 0x00008000 -e 0x00008000 \
  -d arch/arm/boot/zImage /tmp/tftp/uImage

cp arch/arm/boot/dts/amazon/alpine-qnap-ts431p.dtb /tmp/tftp/
```

### Out-of-tree Drivers

```bash
# al_eth (network) — https://github.com/delroth/al_eth-standalone
cd al_eth-standalone/
make KDIR=../linux-6.12/
cp src/al_eth.ko ../initramfs/lib/modules/

# al_thermal (CPU temperature) — https://github.com/delroth/al_thermal-standalone
cd al_thermal-standalone/
make -C ../linux-6.12 M=$(pwd)/src modules
cp src/al_thermal.ko ../initramfs/lib/modules/

# al_nand (NAND flash) — https://github.com/delroth/al_nand-standalone
cd al_nand-standalone/
make -C ../linux-6.12 M=$(pwd)/src modules
cp src/al_nand.ko ../initramfs/lib/modules/
```

**Note**: For kernel >= 6.3, al_eth requires a fix for MDIO C22 callbacks. See our [fork](https://github.com/mornepousse/al_eth-standalone/tree/fix/mdio-c22-kernel-6.3).

### Initramfs

```bash
cd initramfs/
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

**Fix**: Add `interrupt-controller;` back to the msix node in `alpine.dtsi`.

### 3. DTB Must Be Loaded Separately

With an appended DTB, U-Boot cannot find the FDT to patch initrd addresses. The `bootm` command's 3-argument form (`bootm <kernel> <initrd> <fdt>`) is required.

### 4. PCI Deferred Probe (kernel >= 6.12)

SATA drives appear ~5s after boot (vs ~3s in 6.1). The initramfs init must poll for block devices instead of using a fixed sleep.

### 5. al_nand — API Changes (kernel >= 6.12)

Two fixes needed for kernel 6.12:
- `struct onfi_params`: `async_timing_mode` renamed to `sdr_timing_modes`
- `platform_driver.remove`: return type changed from `int` to `void`

### 6. SerDes Node Required for al_eth

The al_eth driver needs a SerDes device tree node. Board parameters (PHY address, RGMII mode) come from MAC scratch registers written by U-Boot, not from the DTB.

### 7. PCIe Host Controller

Stock QNAP uses `alpine-internal-pcie` which is incompatible with modern kernels. Use `pci-host-ecam-generic` from mainline `alpine.dtsi` instead.

## NAND Layout

### SPI NOR (2 MB)
| Partition | Content | Size |
|-----------|---------|------|
| loader | U-Boot | 1088 KB (read-only) |
| env | U-Boot environment | 384 KB |

### NAND (512 MB)
| Partition | Content | Size |
|-----------|---------|------|
| boot1_kernel | uImage + DTB + uInitrd | 32 MB |
| boot1_rootfs2 | (unused) | 216 MB |
| boot2_kernel | (stock backup) | 32 MB |
| boot2_rootfs2 | (stock backup) | 216 MB |
| config | (stock config) | 15 MB |

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
├── README.md
├── CLAUDE.md                          # AI assistant guidance
├── dts/
│   ├── alpine-qnap-ts431p.dts        # Custom DTB source
│   └── qnap-stock.dts                # Stock QNAP DTB (decompiled, reference)
├── initramfs/
│   └── init                           # Initramfs init script
├── build/
│   ├── shell.nix                      # NixOS cross-compilation environment
│   └── kernel-config.fragment         # Kernel config additions
├── research/
│   ├── recon1.log                     # Hardware reconnaissance
│   ├── recon2.log
│   └── recon3.log
├── tftp/
│   └── tftp_server.py                 # Minimal TFTP server
└── uboot/
    └── nand_backup/                   # NAND partition dumps (.gitignored)
```

## Related Projects

- [al_eth-standalone](https://github.com/delroth/al_eth-standalone) — Out-of-tree Alpine Ethernet driver
- [al_thermal-standalone](https://github.com/delroth/al_thermal-standalone) — Out-of-tree Alpine thermal sensor driver
- [al_nand-standalone](https://github.com/delroth/al_nand-standalone) — Out-of-tree Alpine NAND flash driver
- [delroth/linux-qnap-tsx32x](https://github.com/delroth/linux-qnap-tsx32x) — Kernel patches for Alpine v2 (ARMv8) QNAP NAS

## Known Issues

- **CPU count**: DTB inherits 4 CPUs from `alpine.dtsi` but AL-212 is dual-core → CPU2/3 fail to come online (cosmetic, 2s boot delay)
- **Watchdog**: Disabled (`RuntimeWatchdogSec=0`) because systemd hangs during boot with it enabled
- **IRQ**: `of_irq_parse_pci: failed with rc=-22` on network interfaces (non-blocking, network works fine)
- **NAND ECC**: Warning about ECC strength (4b/2048B vs 4b/512B) — reads/writes work fine

## Credits

Built with help from [Claude Code](https://claude.ai/claude-code) (Anthropic).

## License

The custom DTS and init scripts in this repository are provided under the MIT License. The al_eth driver and kernel are subject to their respective licenses (GPL-2.0).
