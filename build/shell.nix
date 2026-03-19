{ pkgs ? import <nixpkgs> {} }:

let
  cross = pkgs.pkgsCross.armv7l-hf-multiplatform;
in
pkgs.mkShell {
  nativeBuildInputs = [
    # Cross-compiler ARM
    cross.buildPackages.gcc
    cross.buildPackages.binutils

    # Outils de build kernel
    pkgs.gnumake
    pkgs.bc
    pkgs.flex
    pkgs.bison
    pkgs.openssl
    pkgs.elfutils
    pkgs.ncurses
    pkgs.perl

    # U-Boot tools (mkimage pour uImage)
    pkgs.ubootTools

    # Outils généraux
    pkgs.git
    pkgs.wget
    pkgs.cpio
    pkgs.gzip
    pkgs.dtc
  ];

  shellHook = ''
    export ARCH=arm
    export CROSS_COMPILE=armv7l-unknown-linux-gnueabihf-
    echo "=== QNAP TS-431P Kernel Build Environment ==="
    echo "ARCH=$ARCH"
    echo "CROSS_COMPILE=$CROSS_COMPILE"
    echo ""
    echo "Commandes utiles :"
    echo "  make alpine_defconfig   # Config de base Alpine"
    echo "  make menuconfig         # Config interactive"
    echo "  make -j$(nproc) zImage  # Compiler le kernel"
    echo "  make -j$(nproc) dtbs   # Compiler les device trees"
    echo "  make -j$(nproc) modules # Compiler les modules"
    echo ""
    echo "Pour al_eth-standalone :"
    echo "  cd al_eth-standalone"
    echo "  make KDIR=../linux-X.X.X"
    echo ""
  '';
}
