This is Simon Eisenmann"s (longsleep) patch tree for:
  - Mainline Kernel 3.19

It is currently used to maintain and develop the following subsystems:
  - Lenovo Yoga 3 Pro (https://github.com/longsleep/yoga3pro-linux)

This tree is a set of patches, in quilt format[1] that are to be applied
to the latest kernel version.  For more information on how to use this
set of patches, see the section USING below.

This tree is being managed by Simon Eisenmann <simon@longsleep.org>
Please contact him for any questions relating to the code contained
within it, or any procedures relating to these patches.

The tree style is based on the tree provided by Greg Kroah-Hartman
<gregkh@suse.de>. Thank you for this great idea to maintain kernel
patches with quilt.

## Using

To use this tree, you should have git and quilt installed.

1. Clone the my patches git tree

2. Then push the tree of patches onto the a kernel tree:

	QUILT_PATCHES=../patches/ quilt push -a

3. Now build and test the kernel as usual. See https://wiki.ubuntu.com/KernelTeam/GitKernelBuild

## Bug Warning

  There is a bug in kernel-package (make-kpkg) which makes kernel package builds fail.
  See https://lkml.org/lkml/2014/4/7/455 for details. Fix is to modify your local
  kernel-package installation.
  sudo vi /usr/share/kernel-package/ruleset/misc/version_vars.mk
  and make sure the variable HAVE_INST_PATH is false (change the grep or something).

## Short instructions

	cp /boot/config-`uname -r` .config
	make oldconfig
	make clean
	CONCURRENCY_LEVEL=`getconf _NPROCESSORS_ONLN` fakeroot make-kpkg --initrd kernel_image kernel_headers

## Wifi support (Broadcom driver)

  The bcmwl driver in Utopic is too old and does not compile whith Kernel 3.19. Install the version from Vivid: http://packages.ubuntu.com/vivid/amd64/bcmwl-kernel-source/download

[1] quilt can be found included in all Linux distros, and its home page
    is at http://savannah.nongnu.org/projects/quilt
