# ⚠️ 
# sudo podman run -it --rm --name aleph_oracle -v $(pwd):/mnt:rw oraclelinux:9 /bin/bash
sudo true &&
sudo qemu-system-x86_64 -m 3G -smp 8 -display none -serial stdio \
  -machine graphics=off -cpu host --enable-kvm \
  -kernel ./vmlinuz-5.15.0-305.176.4.el9uek.x86_64 \
  -initrd ./initramfs-5.15.0-305.176.4.el9uek.img \
  -device e1000,netdev=net0,mac=52:55:00:d1:55:04 \
  -netdev user,id=net0,hostfwd=tcp::1122-:22 \
  ` # https://linuxlink.timesys.com/docs/static_ip ` \
  ` # ip=<client-ip>:<srv-ip>:<gw-ip>:<netmask>:<host>:<device>:<autoconf> ` \
  -append "enforcing=0 ifname=eth1:52:55:00:d1:55:04 ip=10.0.2.16::10.0.2.2:255.255.255.0:myhostname:eth1:none nameserver=8.8.8.8 nomodeset console=ttyS0,115200n8 config_srv_url=http://172.21.183.215:8080/ rooturl=http://172.21.183.215:8080/target.squashfs" \
  ` # -append "ip=dhcp inst.text nomodeset console=ttyS0" ` \
  &&

# ip addr add 10.0.2.15/24 dev eth1
# ip link set dev eth1 up
# ip route add default via 10.0.2.2 dev eth1
# wget 172.21.183.215:8080/robots.txt

true
