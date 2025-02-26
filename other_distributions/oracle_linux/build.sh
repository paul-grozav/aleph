#!/bin/bash
# ============================================================================ #
# Author: Tancredi-Paul Grozav <paul@grozav.info>
# ============================================================================ #
# ⚠️ 
# sudo podman run -it --rm --name aleph_oracle -v $(pwd):/mnt:rw oraclelinux:9
# ============================================================================ #

(
#exit 0 &&
os_root=/mnt/os_root &&
rm -rf ${os_root} &&
mkdir -p ${os_root} &&
dnf install --installroot=${os_root}/ --releasever=9 -y @core &&
dnf install --installroot=${os_root}/ --releasever=9 -y \
  policycoreutils-python-utils \
  nano \
  &&
cp /etc/resolv.conf ${os_root}/etc/resolv.conf &&
mkdir -p ${os_root}/etc/yum.repos.d &&
yes | cp -r /etc/yum.repos.d/* ${os_root}/etc/yum.repos.d/ &&
echo -e "aleph\naleph" | chroot ${os_root} passwd &&
# chroot ${os_root} useradd admin &&
# echo -e "aleph\naleph" | chroot ${os_root} passwd admin &&
# chroot ${os_root} usermod -aG wheel admin &&
# /etc/autid/auditd.conf log_file=/dev/kmsg
#chroot ${os_root} /sbin/fixfiles -T 0 restore &&
cp /mnt/fs/sysroot/root/auditd_selinux_policy/aleph_policy.te \
  ${os_root}/root/aleph_policy.te &&
chroot ${os_root} checkmodule -M -m -o /root/aleph_policy.mod \
  /root/aleph_policy.te &&
chroot ${os_root} semodule_package -o /root/aleph_policy.pp \
  -m /root/aleph_policy.mod &&
chroot ${os_root} semodule -i /root/aleph_policy.pp &&
chroot ${os_root} rm -rf /root/aleph_policy.{pp,mod,te} &&

dnf install -y squashfs-tools &&
mksquashfs ${os_root} /mnt/target.squashfs &&
true
) &&
# ============================================================================ #
# Regenerate initramfs:
(
exit 0
# Choose kernel modules to load
kernel_version="5.14.0-503.22.1.el9_5.x86_64" &&
kernel_version="5.15.0-305.176.4.el9uek" &&
dnf config-manager --enable ol9_UEKR7 &&
#dnf install -y oracle-epel-release-el9 &&
dnf install -y wget busybox systemd-resolved systemd-timesyncd \
  systemd-networkd dracut-squash &&
dnf install -y kernel-uek-modules-${kernel_version} &&
dnf install -y dracut dracut-network NetworkManager &&
yes | cp /mnt/fs/etc/dracut.conf.d/aleph.conf /etc/dracut.conf.d/aleph.conf &&
# Hook custom script into proper boot stage:
mkdir -p /usr/lib/dracut/modules.d/99aleph &&
yes | cp /mnt/fs/usr/lib/dracut/modules.d/99aleph/module-setup.sh \
  /usr/lib/dracut/modules.d/99aleph/module-setup.sh &&
chmod a+x /usr/lib/dracut/modules.d/99aleph/module-setup.sh &&
yes | cp /mnt/fs/usr/lib/dracut/modules.d/99aleph/aleph-script.sh \
  /usr/lib/dracut/modules.d/99aleph/aleph-script.sh &&
chmod a+x /usr/lib/dracut/modules.d/99aleph/aleph-script.sh &&
# Generate initramdisk
# --drivers "e1000"
# --modules "network-manager base"
dracut \
  --verbose \
  --force /boot/initramfs-${kernel_version}.img \
  ${kernel_version}.x86_64 &&
yes | cp /boot/initramfs-${kernel_version}.img \
  /mnt/initramfs-${kernel_version}.img &&
true
) &&

# ============================================================================ #
# Obtain kernel:
# dnf download kernel-uek-${kernel_version}
# rpm2cpio kernel-uek-${kernel_version}.x86_64.rpm | cpio -idmv
# ls -la /lib/modules/5.15.0-204.147.6.2.el9uek.x86_64/vmlinuz

true
# ============================================================================ #
