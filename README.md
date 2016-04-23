## Linux patch tree

This is Simon Eisenmann"s (longsleep) patch tree for:
  - Mainline Kernel 4.6

It is currently used to maintain and develop the following subsystems:
  - Chromebook Pixel kernel patches

This tree is a set of patches, in quilt format[1] that are to be applied
to the latest kernel version.  For more information on how to use this
set of patches, see the section USING below.

This tree is being managed by Simon Eisenmann <simon@longsleep.org>
Please contact him for any questions relating to the code contained
within it, or any procedures relating to these patches.

Target platform is Ubuntu 16.04.

The tree style is based on the tree provided by Greg Kroah-Hartman
<gregkh@suse.de>. Thank you for this great idea to maintain kernel
patches with quilt.

Useful documentation: https://wiki.debian.org/InstallingDebianOn/ChromebookPixel

## General usage

To use this tree, you should have git and quilt installed.

1. Clone the my patches git tree

2. Then push the tree of patches onto the a kernel tree:

	`QUILT_PATCHES=../patches quilt push -a`

3. Now build and test the kernel as usual. See https://wiki.ubuntu.com/KernelTeam/GitKernelBuild

## Build Kernel

```bash
cp ../patches/config_PIXEL .config
make oldconfig
make clean
COUNT=1 DATE=`date +%y%j` VERSION=`make kernelversion` && CONCURRENCY_LEVEL=`getconf _NPROCESSORS_ONLN` fakeroot make-kpkg --initrd --append-to-version="-${DATE}-pixel" --revision="${VERSION}-${DATE}.${COUNT}" kernel_image kernel_headers
```

## Parameters and extra configuration

### Kernel parameters

Put those into `/etc/default/grub`.

```
tpm_tis.force=1 tpm_tis.interrupts=0 pcie_aspm=force i915.enable_fbc=1 i915.enable_rc6=7 i915.enable_psr=1
```

### Module parameters

Put them into `/etc/modprobe.d/etc-modules-parameters.conf` or something.

```
options i915 modeset=1
options snd_hda_intel power_save_controller=0
```

[1] quilt can be found included in all Linux distros, and its home page
    is at http://savannah.nongnu.org/projects/quilt
