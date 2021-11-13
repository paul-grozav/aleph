#!/bin/bash
# ============================================================================ #
# Author: Tancredi-Paul Grozav <paul@grozav.info>
# ============================================================================ #
set -x && # Start debugging
#project_root="$(git rev-parse --show-toplevel)" &&
project_root="$(cd $(dirname $0) ; pwd)" &&
project_name="aleph" &&
version="0.1.9" &&
debian_base_image="$(cat ${project_root}/.gitlab-ci.yml | grep ^image |
  head -n 1 | awk '{print $2}')" &&

# docker:
container_marker=/.dockerenv &&
# podman (requires to be ran as root):
if [ -z ${is_podman_available+x} ]
then
  echo "is_podman_available is unset. trying to detect it"
  if command -v podman &> /dev/null
  then
    is_podman_available="1"
  fi
else
  # inside container, it will be passed on and available from host
  echo "is_podman_available is set to '${is_podman_available}'"
fi
if [ "${is_podman_available}" == "1" ]
then
  function docker(){ podman ${@} ; } && container_marker=/run/.containerenv
fi &&

# Distribution directory
distro_dir="$(pwd)" &&
if [ "${distro_dir}" == "/" ] ; then
  distro_dir="/distribution_content"
else
  distro_dir="${distro_dir}/distribution_content"
fi &&
if [ ! -d ${distro_dir} ] ; then
  mkdir -p ${distro_dir}
fi &&




# ============================================================================ #
# ============================================================================ #
# ============================================================================ #
# Utils
# If the caller function is not running in container, then create the container
# and call it again
# Returns 0 if running in the container, the caller can continue/run and 1 if
# and only if the function is running outside of the container, and the caller
# function should do something specific or exit.
function run_in_container()
{(
  if [ ! -f ${container_marker} ]; then
    docker stop -t0 ${project_name}_core_builder ;
    docker rm ${project_name}_core_builder ;
#    if [ ! -d ${project_root}/distribution_content ]
#    then
#      mkdir ${project_root}/distribution_content
#    fi &&
    # Privileged is required to start docker in chroot inside the container
    #  --privileged \
    # tty required for input
    #  --tty \
#    --volume ${project_root}/distribution_content:/distribution_content:rw,dev\
    time ( echo "cd /mnt && ./aleph.sh --${FUNCNAME[1]}" |
    docker run \
      --interactive \
      --privileged \
      --rm \
      --name=${project_name}_core_builder \
      --volume ${project_root}:/mnt:rw,dev \
      --env is_podman_available="${is_podman_available}" \
      --entrypoint "/bin/bash" \
      ${debian_base_image} ) ;
    # exit 1 so that the caller function does not continue outside the container
    exit 1
  fi
  # Fix dns issue in podman
  # > /etc/resolv.conf &&
  # gw_ip="$(ip route | grep -w default | awk '{print $3}')" &&
  # gw_ip="192.168.0.1" &&
  # echo "nameserver ${gw_ip}" >> /etc/resolv.conf &&
  # Continue running the caller function
  exit 0
)}
# ============================================================================ #
# ============================================================================ #
# ============================================================================ #





# ============================================================================ #
# Build the undionly.kpxe kernel to have DHCP serve the iPXE kernel directly
# from the TFTP server.
#
# Or, boot the .iso from a USB / CD / DVD or, from the TFTP server, using:
# PXE booting instructions:
# use memdisk as the kernel and load ipxe.iso
# use this ipxe config to load the aleph distribution:
#
# kernel ${http-root}/bin/os/aleph/v1/aleph.krnl
# initrd ${http-root}/bin/os/aleph/v1/aleph.ird
# imgargs aleph.krnl console=ttyS0 console=tty0 rooturl=${http-root}/bin/os/aleph/v1/aleph.sfs boot=pxe maxTryCount=10
# boot
# ============================================================================ #
function core__build__pxe_iso()
{(
  run_in_container || {
#    echo "Nothing to do outside of container" &&
    exit 0
  } &&

  echo "Building Aleph Core - PXE iso ..." &&

  echo "Installing packages..." &&
  DEBIAN_FRONTEND=noninteractive apt-get update &&
  # live-boot - installed to provide wget inside ram-disk, might only need some
  #   smaller dependency of it.
  DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
    git gcc libc6-dev binutils make perl liblzma-dev mtools mkisofs isolinux \
    syslinux syslinux-common \
  &&

  # Download iPXE sources
  cd / &&
  git clone git://git.ipxe.org/ipxe.git &&
  cd ipxe/src/ &&

  ( cat - <<EOF > ./my_script.ipxe
#!ipxe
# ============================================================================ #
# Author: Tancredi-Paul Grozav <paul@grozav.info>
# ============================================================================ #
echo Performing DHCP on first network interface
# dhcp net0
# should auto detect network card ?
dhcp

# Continue booting from HTTP server
chain http://alice.home.server.paul.grozav.info:1027/
# chain http://192.168.0.2:1027/
# chain http://boot.ipxe.org/demo/boot.php
# ============================================================================ #
EOF
  ) &&

  # Build:
  # 1. ./bin/undionly.kpxe - and make DHCP point to the kpxe file served by TFTP
  # 2. ./bin/ipxe.iso - and boot it over TFTP or from a USB / CD / DVD / ...
  make EMBED=my_script.ipxe &&

  cp ./bin/undionly.kpxe ${distro_dir}/undionly.kpxe &&
  cp ./bin/ipxe.iso ${distro_dir}/ipxe.iso &&

  echo "Removing packages..." &&
  DEBIAN_FRONTEND=noninteractive apt-get purge -y \
    git gcc libc6-dev binutils make perl liblzma-dev mtools mkisofs isolinux \
    syslinux syslinux-common \
  &&
  DEBIAN_FRONTEND=noninteractive apt-get -y autoremove &&
  DEBIAN_FRONTEND=noninteractive apt-get clean &&

  exit 0
)}





# ============================================================================ #
# Build the Init RAM Disk - the kernel that starts systemd from the squashfs
# ============================================================================ #
# PXE booting instructions.
# use memdisk as the kernel and load ipxe.iso
# use this ipxe config to load the aleph distribution:
#
# kernel ${http-root}/bin/os/aleph/v1/aleph.krnl
# initrd ${http-root}/bin/os/aleph/v1/aleph.ird
# imgargs aleph.krnl console=ttyS0 console=tty0 rooturl=${http-root}/bin/os/aleph/v1/aleph.sfs boot=pxe maxTryCount=10
# boot
# ============================================================================ #
function core__build__pxe_kernel()
{(
  run_in_container || {
#    echo "Nothing to do outside of container" &&
    exit 0
  } &&

  echo "Building Aleph Core - PXE kernel ..." &&

  echo "Installing packages..." &&
  DEBIAN_FRONTEND=noninteractive apt-get update &&
  # live-boot - installed to provide wget inside ram-disk, might only need some
  #   smaller dependency of it.
  DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
    linux-image-amd64 \
    live-boot \
  &&

#  echo "Detecting kernel version ..." &&
#  kernel_version="$(dpkg -l | grep linux-image | grep -v "meta-package" |
#    awk '{print $2}' | awk -F'-' '{print $3"-"$4"-"$5}')" &&
#  echo "Detected kernel version : ${kernel_version}" &&

  echo "Setting kernel modules ..." &&
  cp \
    ${project_root}/fs/core/etc/initramfs-tools/modules \
    /etc/initramfs-tools/modules &&

  echo "Setting PXE script ..." &&
  cp \
    ${project_root}/fs/core/usr/share/initramfs-tools/scripts/pxe \
    /usr/share/initramfs-tools/scripts/pxe &&

  echo "Generating initramfs/kernel file ..." &&
  update-initramfs -u -k all &&

  echo "Removing old kernel file ..." &&
  rm -rf {distro_dir}/aleph.krnl &&

  echo "Renaming kernel file ..." &&
#  cp /boot/vmlinuz-${kernel_version} ${distro_dir}/aleph.ird &&
  cp /boot/vmlinuz-* ${distro_dir}/aleph.krnl &&

  echo "Removing old initram fs/disk file ..." &&
  rm -rf {distro_dir}/aleph.ird &&

  echo "Renaming initram fs/disk file ..." &&
#  cp /boot/initrd.img-${kernel_version} ${distro_dir}/aleph.ird &&
  cp /boot/initrd.img-* ${distro_dir}/aleph.ird &&

  echo "Removing packages..." &&
  DEBIAN_FRONTEND=noninteractive apt-get purge -y \
    linux-image-amd64 \
    live-boot \
  &&
  DEBIAN_FRONTEND=noninteractive apt-get -y autoremove &&
  DEBIAN_FRONTEND=noninteractive apt-get clean &&

  exit 0
)}




# ============================================================================ #
# Build the core squashfs
# https://gitlab.com/tancredi-paul-grozav/aleph/-/jobs/artifacts/main/raw/distribution_content/aleph.sfs?job=build
# ============================================================================ #
function core__build__squashfs()
{(
  run_in_container || {
#    echo "Nothing to do outside of container" &&
    exit 0
  } &&

  echo "Building Aleph Core - PXE squashfs ..." &&

  echo "Installing packages..." &&
  DEBIAN_FRONTEND=noninteractive apt-get update &&
  DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
    debootstrap \
    squashfs-tools \
  &&

  echo "Cleaning chroot directory ..." &&
  if [ -d ${distro_dir}/chroot ]
  then
    echo "Clearing ${distro_dir}/chroot/* ..." &&
    rm -rf ${distro_dir}/chroot/*
  else
    echo "Creating directory ${distro_dir}/chroot ..." &&
    mkdir -p ${distro_dir}/chroot
  fi &&

  echo "Creating minimal debian system (debootstrap)  ..." &&
  # use the same version as the container that was started.
  debootstrap \
    --arch=amd64 \
    --components=main,non-free \
    --variant=minbase \
    $(. /etc/os-release && echo ${VERSION_CODENAME}) \
    ${distro_dir}/chroot \
    http://ftp.ro.debian.org/debian/ \
  &&

  # Call the setup function/body inside the chroot
  declare -f core__build__squashfs__setup | tail -n +3 | head -n -1 |
    chroot ${distro_dir}/chroot &&

  echo -n "Copying this script to /root/aleph.sh to be called at startup ..." &&
  cp ${project_root}/aleph.sh ${distro_dir}/chroot/root/aleph.sh &&

  squash_fs_file="${distro_dir}/aleph.sfs" &&
  echo "Removing previous Squash filesystem file: ${squash_fs_file}" &&
  rm -f ${squash_fs_file} &&

  echo "Compress the chroot environment into a Squash filesystem." &&
  mksquashfs ${distro_dir}/chroot ${squash_fs_file} -e boot &&

  echo "Removing chroot dir ${distro_dir}/chroot ..." &&
  rm -rf ${distro_dir}/chroot &&

  echo "Removing packages..." &&
  DEBIAN_FRONTEND=noninteractive apt-get purge -y \
    debootstrap \
    squashfs-tools \
  &&
  DEBIAN_FRONTEND=noninteractive apt-get -y autoremove &&
  DEBIAN_FRONTEND=noninteractive apt-get clean &&

  exit 0
)}





# ============================================================================ #
# PRIVATE: Build the core squashfs - setup the system
# Note: If you change this function's name, please don't forget to update the
#   caller above.
# ============================================================================ #
function core__build__squashfs__setup()
{(
    set -x && # Start debugging
    cat /etc/resolv.conf &&

    echo "Setting hostname ..." &&
    echo "aleph" > /etc/hostname &&

    echo "Setting root's password to aleph ..." &&
    echo root:aleph | chpasswd &&

    echo "Installing extra packages ..." &&
#    apt-cache search linux-image &&
    DEBIAN_FRONTEND=noninteractive apt-get update &&
    # systemd-sysv is required as it is the init system that will be started by
    # the kernel
    DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
      systemd-sysv &&

      (
        echo "Installing docker ..." &&
        # might also require: fuse-overlayfs
        # install packages to allow apt to use a repository over HTTPS
        DEBIAN_FRONTEND=noninteractive apt-get \
          install -y --no-install-recommends \
          apt-transport-https ca-certificates curl gnupg-agent gnupg2 \
          software-properties-common &&
        # Add Docker's official GPG key
        curl -fsSL https://download.docker.com/linux/debian/gpg |
          apt-key add - &&
        # set up the stable docker repository
        add-apt-repository \
          "deb [arch=amd64] https://download.docker.com/linux/debian \
          $(lsb_release -cs) \
          stable" &&
        # Get list of docker packages from repository
        DEBIAN_FRONTEND=noninteractive apt-get update &&
        # Install docker daemon and client
        DEBIAN_FRONTEND=noninteractive apt-get \
          install -y --no-install-recommends \
          docker-ce docker-ce-cli containerd.io &&
        # Docker install will fail at pkg: aufs-dkms
        # docker-compose ???

        # Trying to start docker in chroot inside container
        # mount -o bind /proc /distribution_content/chroot/proc/
        # mount -o bind /sys /distribution_content/chroot/sys/
        # /usr/bin/cgroupfs-mount
        # /usr/bin/dockerd -H unix://

        # configure docker
        sed -i "s/-H fd:\/\/ //g" /lib/systemd/system/docker.service &&

        mkdir -p /etc/docker &&
        ( echo "{
  \"data-root\": \"/data/docker\",
  \"hosts\": [\"tcp://0.0.0.0:2375\"]
}" ) > /etc/docker/daemon.json &&
        #systemctl enable docker &&
        #systemctl start docker &&

        # export DOCKER_HOST="tcp://127.0.0.1:2375" &&
        # docker run --rm hello-world &&
        # docker image rm hello-world ;
        # return 0 even if docker installation will fail
        systemctl enable docker ;

        # https://itectec.com/superuser/iptables-1-8-2-failed-to-initialize-nft-protocol-not-supported/
        update-alternatives --set iptables /usr/sbin/iptables-legacy &&

        exit 0
      ) &&

    echo "Install startup service ..." &&
     # called later at xfce startup
    (
      (cat - <<EOF2
[Unit]
Description=Aleph core start service

[Service]
ExecStart=/root/aleph.sh --core__start

[Install]
WantedBy=multi-user.target
EOF2
      ) > /etc/systemd/system/aleph_core_start.service &&
      systemctl enable aleph_core_start
    ) &&

    DEBIAN_FRONTEND=noninteractive apt-get -y autoremove &&
    DEBIAN_FRONTEND=noninteractive apt-get clean &&







    # !!! TO DO:
    # 0. define config service
    # 1. request config from IRD
    # 2. Register service for config request from IP(given as krnl param)
    #   After=network-online.service , WantedBy=multi-user.target






    echo "exit chroot - back to container ..." &&
    exit 0
    (
      packages="" &&
      # See contents of package:
      # https://packages.debian.org/buster/amd64/PACKAGE_NAME/filelist
      # search for binary in packages:
      # https://packages.debian.org/cgi-bin/search_contents.pl?word=lspci&searchmode=searchfiles&case=insensitive&version=stable&arch=i386
      # Kernel
      packages="${packages} linux-image-amd64" && # kernel
      packages="${packages} systemd-sysv" && # systemd init - or start my_APP???
      packages="${packages} live-boot" && # boot configuration for live systems
      # SysAdmin: pulseaudio, touchpad-click
      packages="${packages} net-tools" && # ifconfig,netstat,route,arp,rarp
      packages="${packages} telnet" && # telnet
      packages="${packages} ifupdown" && # ifup, ifdown
      packages="${packages} iputils-ping" && # ping, ping4, ping6
      packages="${packages} iproute2" && # ip, ss
      packages="${packages} dnsutils" && # host, dig, nslookup
      packages="${packages} openssh-client" && # ssh
      packages="${packages} openssh-server" && # sshd
      packages="${packages} nmap" && # nmap
      packages="${packages} wget" && # wget
      packages="${packages} ca-certificates" && #recognize CA authorty and certs
      packages="${packages} lsof" && # lsof
      packages="${packages} strace" && # strace
      packages="${packages} procps" && # ps,kill,free,top,uptime,watch,sysctl
#      packages="${packages} upower powertop" && #monitor electrical power usage
      packages="${packages} fdisk" && # fdisk - partitioning
      packages="${packages} pciutils" && # lspci
      packages="${packages} usbutils" && # lsusb
      packages="${packages} lshw" && # lshw
      packages="${packages} dmidecode" && # dmidecode
      packages="${packages} hdparm" && # hdparm
      packages="${packages} smartmontools" && # smartctl
      packages="${packages} wireless-tools" && # iwlist, iwconfig
#      packages="${packages} lm-sensors" && # lm-sensors
      # For WPA & WPA2 wifi security
      packages="${packages} wpasupplicant" && # wpa_passphrase, wpa_supplicant
      packages="${packages} isc-dhcp-client" && # dhclient
      packages="${packages} rsyslog" && # rsyslogd
      # drivers / firmware
      # tablet Asus T101 - wifi - Qualcomm Atheros QCA9377
#      packages="${packages} firmware-atheros" &&
      # tablet Asus T101 - sound - alsa_card.platform-cht-bsw-rt5645.
#      packages="${packages} firmware-intel-sound" &&
      # Utilities:
      packages="${packages} tmux" && # tmux
      packages="${packages} nano" && # nano
      packages="${packages} less" && # less

      # noninteractive set because packet keyboard-configuration asks for layout
      DEBIAN_FRONTEND=noninteractive \
        apt-get install -y --no-install-recommends ${packages}
    ) &&

    # You probably want to disable this for production
    echo "SSH daemon PermitRootLogin yes ..." &&
    echo "PermitRootLogin yes" >> /etc/ssh/sshd_config &&

    echo "Installing additional software ..." &&
    (
      #exit 0 &&
      echo &&
      (
        echo "Installing docker ..." &&
        # install packages to allow apt to use a repository over HTTPS
        DEBIAN_FRONTEND=noninteractive apt-get \
          install -y --no-install-\
          apt-transport-https ca-certificates curl gnupg-agent \
          software-properties-common &&
        # Add Docker's official GPG key
        curl -fsSL https://download.docker.com/linux/debian/gpg |
          apt-key add - &&
        # set up the stable docker repository
        add-apt-repository \
          "deb [arch=amd64] https://download.docker.com/linux/debian \
          $(lsb_release -cs) \
          stable" &&
        # Get list of docker packages from repository
        apt-get update &&
        # Install docker daemon and client
        apt-get install -y docker-ce docker-ce-cli containerd.io &&
        # Docker install will fail at pkg: aufs-dkms
        # docker-compose ???

        # Trying to start docker in chroot inside container
        # mount -o bind /proc /distribution_content/chroot/proc/
        # mount -o bind /sys /distribution_content/chroot/sys/
        # /usr/bin/cgroupfs-mount
        # /usr/bin/dockerd -H unix://

        docker run --rm hello-world &&
        docker image rm hello-world ;
        # return 0 even if docker installation will fail
        systemctl enable docker ;
        exit 0
      ) &&
      echo &&
      (
        exit 0 &&
        echo "Installing Google Chrome" &&
        deb_name="google-chrome-stable_current_amd64.deb" &&
        wget https://dl.google.com/linux/direct/${deb_name} &&
        apt-get install -y ./${deb_name} ;
        # Chrome will fail at pkg: aufs-dkms
        rm -f ./${deb_name} &&
        exit 0
      ) &&
      echo &&
      (
        exit 0 &&
        echo "Installing NoMachine ..." &&
        latest_version="$(wget -qO- \
	          "https://www.nomachine.com/download/download&id=2" |
          grep Version: -A 3 | tail -n1 | awk -F'[<>]' '{print $3}')" &&
        short_version="$(echo ${latest_version} | awk -F'.' '{print $1"."$2}')" &&
        wget https://download.nomachine.com/download/${short_version}/Linux/nomachine_${latest_version}_amd64.deb &&
        apt-get install ./nomachine_${latest_version}_amd64.deb ;
        # NoMachine will fail at pkg: aufs-dkms
        rm -f ./nomachine_${latest_version}_amd64.deb &&
        exit 0
        # /var/NX/nx - connection files
      ) &&

      exit 0
    ) &&

    apt-get clean &&


    set +x && # Stop debugging
    exit 0
)}





# ============================================================================ #
# Build the core .iso
# ============================================================================ #
function core__build__iso()
{(
  run_in_container || {
    # After running it in container, do outside:
    iso_path="${project_root}/distribution_content/aleph.iso" &&
    if [ -f ${iso_path} ]; then
      echo "Copying generated .iso as version ${version} ..."
      echo cp ${iso_path} ${project_root}/v${version}.iso
    fi
    exit 0
  } &&

  echo "Checking requirements ..." &&
  if [ ! -f ${distro_dir}/aleph.sfs ]; then
    echo "Missing ${distro_dir}/aleph.sfs . build it using job" &&
    exit 1
  fi

  echo "Building Aleph Core .iso ..." &&

  echo "Installing packages..." &&
  DEBIAN_FRONTEND=noninteractive apt-get update &&
  DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
    linux-image-amd64 \
    live-boot \
    isolinux \
    syslinux-common \
    syslinux-efi \
    grub-pc-bin \
    grub-efi-amd64-bin \
    mtools \
    dosfstools \
    xorriso \
  &&

  echo "Cleaning staging directory ..." &&
  if [ -d ${distro_dir}/staging ]
  then
    echo "Clearing ${distro_dir}/staging/* ..." &&
    rm -rf ${distro_dir}/staging/*
  else
    echo "Creating directory ${distro_dir}/staging ..." &&
    mkdir -p ${distro_dir}/staging
  fi &&

  echo -n "Create directories that will contain files for our live" &&
  echo " environment files and scratch files." &&
  mkdir -p \
    ${distro_dir}/{staging/{EFI/boot,boot/grub/x86_64-efi,isolinux,live},tmp} &&

  echo "Adding the Squash filesystem." &&
  cp ${distro_dir}/aleph.sfs ${distro_dir}/staging/live/filesystem.squashfs &&

  echo -n "Copy the kernel and initramfs from inside the chroot to the live" &&
  echo " directory." &&
  cp /boot/vmlinuz-* ${distro_dir}/staging/live/vmlinuz &&
  cp /boot/initrd.img-* ${distro_dir}/staging/live/initrd &&

  echo "Create an ISOLINUX (Syslinux) boot menu." &&
  echo "This boot menu is used when booting in BIOS/legacy mode." &&
  cp ${project_root}/fs/core/staging/isolinux/isolinux.cfg \
    ${distro_dir}/staging/isolinux/isolinux.cfg &&

  echo "Create a second, similar, boot menu for GRUB." &&
  echo "This boot menu is used when booting in EFI/UEFI mode." &&
  cp ${project_root}/fs/core/staging/boot/grub/grub.cfg \
    ${distro_dir}/staging/boot/grub/grub.cfg &&

  echo -n "Create a third boot config. This config will be an early" &&
  echo -n " configuration file that is embedded inside GRUB in the EFI" &&
  echo -n " partition. This finds the root and# loads the GRUB config from" &&
  echo " there." &&
  cp ${project_root}/fs/core/tmp/grub-standalone.cfg \
    ${distro_dir}/tmp/grub-standalone.cfg &&

  echo -n "Create a special file in staging named DEBIAN_CUSTOM. This file" &&
  echo -n " will be used to help GRUB figure out which device contains our" &&
  echo -n " live filesystem. This file name must be unique and must match" &&
  echo " the file name in our grub.cfg config." &&
  touch ${distro_dir}/staging/DEBIAN_CUSTOM &&

  echo "Prepare Boot Loader Files" &&
  echo "Copy BIOS/legacy boot required files into our workspace." &&
  cp /usr/lib/ISOLINUX/isolinux.bin ${distro_dir}/staging/isolinux/ &&
  cp /usr/lib/syslinux/modules/bios/* ${distro_dir}/staging/isolinux/ &&

  echo "Copy EFI/modern boot required files into our workspace." &&
  cp -r /usr/lib/grub/x86_64-efi/* \
    ${distro_dir}/staging/boot/grub/x86_64-efi/ &&

  echo "Generate an EFI bootable GRUB image." &&
  grub-mkstandalone \
    --format=x86_64-efi \
    --output=${distro_dir}/tmp/bootx64.efi \
    --locales="" \
    --fonts="" \
    boot/grub/grub.cfg=${distro_dir}/tmp/grub-standalone.cfg \
  &&

  echo "Create a FAT16 UEFI boot disk image containing the EFI bootloader." &&
  # Note the use of the mmd and mcopy commands to copy our UEFI boot
  # loader named bootx64.efi.
  efi_file=${distro_dir}/staging/EFI/boot/efiboot.img &&
  dd if=/dev/zero of=${efi_file} bs=1M count=20 &&
  mkfs.vfat ${efi_file} &&
  mmd -i ${efi_file} efi efi/boot &&
  mcopy -vi ${efi_file} ${distro_dir}/tmp/bootx64.efi ::efi/boot/ &&

  echo "Removing efi tmp folder..." &&
  rm -rf ${distro_dir}/tmp &&

  echo "Removing old .iso file..." &&
  rm -rf ${distro_dir}/aleph.iso &&

  echo "Create Bootable ISO/CD" &&
  xorriso \
    -as mkisofs \
    -iso-level 3 \
    -o ${distro_dir}/aleph.iso \
    -full-iso9660-filenames \
    -volid DEBIAN_CUSTOM \
    -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
    -eltorito-boot \
        isolinux/isolinux.bin \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        --eltorito-catalog isolinux/isolinux.cat \
    -eltorito-alt-boot \
        -e /EFI/boot/efiboot.img \
        -no-emul-boot \
        -isohybrid-gpt-basdat \
    -append_partition 2 0xef ${distro_dir}/staging/EFI/boot/efiboot.img \
    ${distro_dir}/staging \
  &&

  echo "Removing staging folder..." &&
  rm -rf ${distro_dir}/staging &&

  echo "Removing packages..." &&
  DEBIAN_FRONTEND=noninteractive apt-get purge -y \
    linux-image-amd64 \
    live-boot \
    isolinux \
    syslinux-common \
    syslinux-efi \
    grub-pc-bin \
    grub-efi-amd64-bin \
    mtools \
    dosfstools \
    xorriso \
  &&
  DEBIAN_FRONTEND=noninteractive apt-get -y autoremove &&
  DEBIAN_FRONTEND=noninteractive apt-get clean &&

# To boot this ISO in your existing GRUB, add this to /etc/grub.d/40_custom to
# add the .iso to your existing GRUB. Make sure you set the isofile var to the
# path relative to the partition. Use "ls (hd0,2)" in GRUB's console to inspect
# the filesystem.

#menuentry "Aleph ISO" --class os {
#  insmod part_gpt
#  set isofile="/v0.1.8.iso"
#  loopback loop (hd0,gpt6)$isofile
#  linux (loop)/live/vmlinuz boot=live findiso=${isofile}
#  initrd (loop)/live/initrd
#}

  exit 0
)}





# ============================================================================ #
# Start (boot) the distribution
# ============================================================================ #
function core__emulate()
{
  # fdisk /dev/sda # n ENTER ENTER ENTER w
  # mkfs.ext4 /dev/sda1
  # mkdir /data && mount /dev/sda1 /data
  # echo "{\"data-root\": \"/data/docker\"}" > /etc/docker/daemon.json
  # systemctl restart docker
  # qemu-img create -f qcow2 persistent.hdd 10G
#    -device rtl8139,netdev=net0 \
#    -device e1000,netdev=net0 \
  (qemu-system-x86_64 \
    -m 1G \
    -cdrom ${project_root}/v${version}.iso \
    -hda ${project_root}/persistent.hdd \
    -boot d \
    -device e1000,netdev=net0 \
    -netdev user,id=net0,hostfwd=tcp::1122-:22 \
    -display gtk,zoom-to-fit=on \
    & ) &&
  exit 0
}





# ============================================================================ #
# Start programs once the distribution booted
# ============================================================================ #
function core__start()
{
  mkdir -p /data &&
  # V1
  # if [ "$(mount | grep -w /data | wc -l)" == "0" ]; then
    # mount /dev/sda1 /data
  # fi &&
  # cp /data/start.sh /tmp/start.sh &&
  # /tmp/start.sh && # following example of start.sh contents:

  # V2
(
  # If booted live from aleph.krnl, then that will use dhcp to get it's IP,
  # NetMask, GW, DNS(0,1), domain/search, etc, so we want to inherit that DNS
  # from it.
  ( . /run/net-*.conf && echo "nameserver ${IPV4DNS0}" > /etc/resolv.conf ) &&

  mount -t tmpfs -o size=1024m tmpfs /data &&
  mkdir /data/docker &&
  # cat /etc/resolv.conf &&
  # echo "nameserver 192.168.0.1" > /etc/resolv.conf &&
  apt install -y nano tmux procps kmod iputils-ping less &&
  export PATH="${PATH}:/sbin" &&
  # docker is frozen because of bad data-root
  # kill it and it'll start at first docker client cli invocation

#  kill -9 $(cat /run/docker.pid) ;
#  ( nohup dockerd > /var/log/dockerd.log 2>&1 & ) && sleep 20 &&

  # systemctl start docker &&
  #if [ "$(docker ps | grep -w web | awk '{print $NF}')" != "web" ]
  #then
  #  docker stop -t0 web ;
  #  docker rm web ;
    export DOCKER_HOST="tcp://127.0.0.1:2375" &&
    docker run -it --rm -d -p 8080:80 --name web nginx &&
  #fi &&

  # mkdir -p /etc/docker /data/docker &&
  # echo "{\"data-root\": \"/data/docker\"}" > /etc/docker/daemon.json &&
  # kill -9 $(cat /run/docker.pid) ;
  # docker run -it --rm -d -p 8080:80 --name web nginx &&
  # # Start stateless container - or set docker data-root on ramfs
  true ;
  exit 0
) > /tmp/aleph__core__start.log 2>&1 ;
  exit 0

  # === example of start:sh
(
set -x &&
# mkdir /data && mount /dev/sda1 /data
umount /dev/sda1 &&
mount -t tmpfs -o size=1024m tmpfs /data &&
mkdir /data/docker &&
#cat /etc/resolv.conf &&
#echo "nameserver 192.168.0.1" > /etc/resolv.conf &&
apt install -y nano tmux procps kmod iputils-ping less &&
export PATH="${PATH}:/sbin" &&
mkdir -p /etc/docker &&
echo "{\"data-root\": \"/data/docker\"}" > /etc/docker/daemon.json &&
# docker is frozen because of bad data-root
# kill it and it'll start at first docker client cli invocation
kill -9 $(cat /run/docker.pid) ;
# systemctl start docker &&
#if [ "$(docker ps | grep -w web | awk '{print $NF}')" != "web" ]
#then
#  docker stop -t0 web ;
#  docker rm web ;
  docker run -it --rm -d -p 8080:80 --name web nginx &&
#fi &&
set +x &&
exit 0
) > /tmp/aleph__core__start.log 2>&1
  # === end of start.sh


  # Does not work well from SystemD service
  # OPTION 1 - start Desktop environment directly
  # lastly, let the Xfce run
#  startxfce4 &&

  # OPTION 2 - Start X srv manually and then the apps inside it
#  if [ "${DISPLAY}" == "" ]; then
#    xinit /root/aleph.sh --core__start -- :0 vt${XDG_VTNR} &&
#    exit 0
#  fi
  # X server is started, so start your apps
#  xlogo &
#  sleep inf &&

  device="$(dmidecode | grep "System Information" -A 2 | tail -n 2 | awk -F':' \
    '{printf $2}' | awk -F'(' '{print $1}' | sed 's/^ *//g' | sed 's/ *$//')" &&
  echo "Device = \"${device}\"" &&
  if [ "${device}" == "ASUSTeK COMPUTER INC. T101HA" ]; then
    # Press F2 for entering BIOS then left,up,up,enter to boot from USB UEFI

    # mount persistent storage
    # umount /dev/mmcblk0p6 ;
    if [ "$(mount | grep "^/dev/mmcblk0p6 on /data" | wc -l)" == "0" ]; then
      if [ "$(mount | grep "^/dev/mmcblk0p6 on /run/live/findiso" | wc -l
        )" == "0" ]; then
        ( [ ! -d /data ] && mkdir /data || true ) &&
        mount /dev/mmcblk0p6 /data
      else
        mount -o remount,rw /dev/mmcblk0p6 /run/live/findiso &&
        systemctl stop docker &&
        rm -rf /data &&
        ln -s /run/live/findiso /data &&
        systemctl start docker
      fi
    fi

    # Load docker from disk
    if [ ! -f /etc/docker/daemon.json ]; then
      echo "Restarting docker from persistent storage ..." &&
      echo "{\"data-root\": \"/data/docker\"}" > /etc/docker/daemon.json &&
      systemctl restart docker
    fi

    # Connect to WiFi:
    (
      if [ "$(ping -c 1 -W 1 8.8.8.8 >/dev/null ; echo ${?})" == "0" ]; then
        echo "Already connected to internet" &&
        exit 0
      else
        # should connect to the internet
        if [ ! -f /data/aleph/config_wifi ]; then
          echo "Could not connect to wifi - no cfg exists" &&
          exit 0
        fi
        echo "Connecting to the internet ..."
      fi

      ps faux | grep wpa_supplicant | grep -v grep |
        awk '{print "kill -9 "$2}' | bash ;

      # ifconfig && # show interfaces, detect wifi interface

      # Let's say that our interface's name is wlp1s0
      iface_name="wlp1s0" &&

      # Bring it up - Set IP and Netmask
      ifconfig wlp1s0 192.168.0.13 netmask 255.255.255.0 up &&
      #  ( ifconfig ${iface_name} up || true ) &&

      # Search for available WiFi networks:
      # iwlist ${iface_name} scan &&

      # Pick a WPA or a WPA2 encrypted network
      # And generate the pre-shared-key for network's ESSID:
#      echo -n "Please type WiFi password for mansarda: " &&
#      read -s wifi_password &&
      wifi_ssid="$(head -n 1 /data/aleph/config_wifi)" &&
      wifi_password="$(tail -n 1 /data/aleph/config_wifi)" &&
      echo ${wifi_password} | wpa_passphrase ${wifi_ssid} \
        > /etc/wpa_supplicant.conf &&

      # Connect to the wifi network:
      wpa_supplicant -B -D wext -i ${iface_name} -c /etc/wpa_supplicant.conf &&

      # Use DHCP to get an IP address inside the network:
      # dhclient ${iface_name} &&
      # Using static IP for this wireless LAN

      # Add GW
      ip_gw="192.168.0.1" &&
      route add default gw ${ip_gw} &&

      # Set DNS
      ip_dns="${ip_gw}" &&
      (cat - <<EOF
nameserver ${ip_dns}
EOF
      ) > /etc/resolv.conf &&

      # make sure that internet works:
      echo "Waiting for wifi network connection ..." &&
#      (timeout 30 while ping -q -c 1 8.8.8.8 >/dev/null ; do sleep 1; done) &&
      # Wait for wifi interface to become up
      while [ "$(ip link | grep ${iface_name} | grep "state DOWN" | wc -l)" == "1" ]; do
        sleep 1
      done
      ping -c 1 8.8.8.8 &&
      ping -c 1 google.com &&
      # ping -c 1 192.168.0.1 &&

      # That's it !
      exit 0
    )

    # run startup script from persistent storage
#    [ -f /mnt/start_up.sh ] && bash /mnt/start_up.sh || true ;
  elif [ "${device}" == "QEMU Standard PC" ]; then
    # mount persistent storage
    # umount /dev/sda1 ;
    if [ "$(mount | grep "^/dev/sda1 on /data" | wc -l)" == "0" ]; then
      ( [ ! -d /data ] && mkdir /data || true ) &&
      mount /dev/sda1 /data
    fi

    # Load docker from disk
    if [ ! -f /etc/docker/daemon.json ]; then
      echo "Restarting docker from persistent storage ..." &&
      echo "{\"data-root\": \"/data/docker\"}" > /etc/docker/daemon.json &&
      systemctl restart docker
    fi
  else
    echo "Unknown device: ${device}" &&
    echo "Nothing to do"
  fi

  # Start prometheus
  (
    exit 0 &&
    docker run \
      --name prometheus_full_node_exporter \
      --restart always \
      -d \
      --net="host" \
      --pid="host" \
      -v "/:/host:ro,rslave" \
      prom/node-exporter:v1.0.1 \
      --path.rootfs /host
  ) ;

  if [ -f /data/aleph/aleph.sh ]; then
    /data/aleph/aleph.sh --x__start
  else
    x__start # Call from this script
  fi
#  exit 0
}





# ============================================================================ #
# Build the aleph container
# ============================================================================ #
function x__build()
{
  if [ ! -f ${container_marker} ]; then
    docker stop -t0 ${project_name}_x_builder ;
    docker rm ${project_name}_x_builder ;
    time (echo "/data/aleph/aleph.sh --x__build" \
    | docker run -i \
      --name=${project_name}_x_builder \
      --volume /data:/data:rw \
      --volume ${project_root}/aleph.sh:/data/aleph/aleph.sh:ro \
      ${debian_base_image} ) &&
    docker commit ${project_name}_x_builder aleph-x:${version} &&
    docker rm ${project_name}_x_builder &&
    exit 0
  fi
  echo "Building Aleph X ..." &&

  apt-get update &&
  (
    packages="" &&
    # See contents of package:
    # https://packages.debian.org/buster/amd64/PACKAGE_NAME/filelist
    # search for binary in packages:
    # https://packages.debian.org/cgi-bin/search_contents.pl?word=lspci&searchmode=searchfiles&case=insensitive&version=stable&arch=i386
    # SysAdmin:
    packages="${packages} net-tools" && # ifconfig,netstat,route,arp,rarp
    packages="${packages} telnet" && # telnet
    packages="${packages} ifupdown" && # ifup, ifdown
    packages="${packages} iputils-ping" && # ping, ping4, ping6
    packages="${packages} iproute2" && # ip, ss
    packages="${packages} dnsutils" && # host, dig, nslookup
    packages="${packages} openssh-client" && # ssh
    packages="${packages} openssh-server" && # sshd
    packages="${packages} nmap" && # nmap
    packages="${packages} wget" && # wget
    packages="${packages} ca-certificates" && #recognize CA authorty and certs
    packages="${packages} lsof" && # lsof
    packages="${packages} strace" && # strace
    packages="${packages} procps" && # ps,kill,free,top,uptime,watch,sysctl
    packages="${packages} upower powertop" && # monitor electrical power usage
    packages="${packages} pciutils" && # lspci
    packages="${packages} usbutils" && # lsusb
    packages="${packages} lshw" && # lshw
    packages="${packages} dmidecode" && # dmidecode
    packages="${packages} hdparm" && # hdparm
    packages="${packages} smartmontools" && # smartctl
    packages="${packages} wireless-tools" && # iwlist, iwconfig
    packages="${packages} lm-sensors" && # lm-sensors
    # For WPA & WPA2 wifi security
#    packages="${packages} wpasupplicant" && # wpa_passphrase, wpa_supplicant
#    packages="${packages} isc-dhcp-client" && # dhclient
    packages="${packages} rsyslog" && # rsyslogd
#    packages="${packages} firmware-intel-sound" && # sound driver - not needed?
    packages="${packages} pulseaudio" && # sound server
    packages="${packages} pavucontrol" && # sound server settings
    packages="${packages} alsa-utils" && # sound CLI settings & utils
    # drivers / firmware
    # tablet Asus T101 - wifi - Qualcomm Atheros QCA9377
#    packages="${packages} firmware-atheros" &&
    # Utilities:
    packages="${packages} tmux" && # tmux
    packages="${packages} nano" && # nano
    packages="${packages} less" && # less
    packages="${packages} git" && # git
    packages="${packages} tree" && # tree
    # GUI apps: super-light web browser
    packages="${packages} xorg" && # xinit, xauth, xterm
    packages="${packages} xserver-xorg-input-mouse" && # mouse driver for Xorg
    packages="${packages} xserver-xorg-input-kbd" && # keyboard driver for Xorg
    packages="${packages} xserver-xorg-input-libinput" && # main driver
    packages="${packages} x11-apps" && # xeyes, xedit, xcalc
    packages="${packages} xloadimage" && # xsetbg - set background for x server
    packages="${packages} xinput" && # configure x input devices(keyboard,touch)

##      packages="${packages} sddm" && # Display manager(graphical login)
##      packages="${packages} openbox" && # OpenBox Window manager
##      packages="${packages} menu" && # OpenBox show menu of debian system apps
      packages="${packages} xfce4" && # Xfce 4 Desktop Environment (449+mib)
      packages="${packages} dbus-x11" && # dependency of XFCE4
      packages="${packages} xfce4-terminal" && # terminal
      # xfce4-screenshooter --region --mouse --clipboard --save ~/Desktop
      packages="${packages} xfce4-screenshooter" && # screenshot utility
      packages="${packages} xfce4-genmon-plugin" && # generic monitor panel
      packages="${packages} xfce4-battery-plugin" && # battery level on panel
      packages="${packages} gvfs-backends" && # SFTP support in thunar file mngr
      packages="${packages} meld" && # meld
      packages="${packages} gitk git-gui" && # gitk, git gui
      packages="${packages} gedit" && # gedit
      packages="${packages} gedit-plugins" && # gedit embedded terminal
#      packages="${packages} feh" && # Image viewer (jpeg & png)
#      packages="${packages} pavucontrol" && # Sound server settings
      # teams nxplayer

      # noninteractive set because packet keyboard-configuration asks for layout
    DEBIAN_FRONTEND=noninteractive \
      apt-get install -y --no-install-recommends ${packages}
  ) &&

  (
#    exit 0 &&
    echo "Installing Google Chrome" &&
    deb_name="google-chrome-stable_current_amd64.deb" &&
    wget https://dl.google.com/linux/direct/${deb_name} &&
    apt-get install -y ./${deb_name} ;
    # Chrome will fail at pkg: aufs-dkms
    rm -f ./${deb_name} &&
    exit 0
  ) &&

  exit 0
}





# ============================================================================ #
# Start the aleph container
# ============================================================================ #
function x__start()
{
#  device="$(dmidecode | grep "System Information" -A 2 | tail -n 2 | awk -F':'\
#    '{printf $2}' | awk -F'(' '{print $1}' | sed 's/^ *//g' | sed 's/ *$//')"&&
#  echo "Device = \"${device}\"" &&

  if [ ! -f ${container_marker} ]; then
    # Determine the user and group
    hypervisor_user_id="$(id -u)" &&
    hypervisor_group_id="$(id -g)" &&
    hypervisor_user_name="$(whoami)" &&
    # Could be more than 1 group. see: id -G and id -Gn
    hypervisor_group_name="$(id -Gn | cut -f 1 -d " ")" &&
    if [ "${hypervisor_user_name}" == "root" ]; then
      hypervisor_user_id="1000" &&
      hypervisor_group_id="1000" &&
      hypervisor_user_name="paul" &&
      hypervisor_group_name="paul"
    fi &&
#    hypervisor_time_zone="$(timedatectl | grep "Time zone:" |
#      awk '{print $3}')" &&
    hypervisor_time_zone="Europe/Bucharest" &&

    # Check if X is running
    is_x_running="$([ ! -z "${DISPLAY}" ] && echo 1 || echo 0)" &&
    docker_x_parameters="" &&
    if [ "${is_x_running}" == "1" ]; then
      docker_x_parameters="--volume /tmp/.X11-unix:/tmp/.X11-unix:rw" &&
      docker_x_parameters="${docker_x_parameters} --env DISPLAY"
    fi

    # if X is running, allow connections into current session
    ( [ "${is_x_running}" == "1" ] && xhost +local:${hypervisor_user_name} || true ) &&

    # /run/udev is required for X to detect IO devices: kbd, touch, etc
    echo "/aleph/aleph.sh --x__start" |
      docker run \
      -i \
      --rm=true \
      --privileged \
      --name=aleph-x \
      --hostname $(hostname) \
      --env TZ="${hypervisor_time_zone}" \
      --env hypervisor_user_id="${hypervisor_user_id}" \
      --env hypervisor_user_name="${hypervisor_user_name}" \
      --env hypervisor_group_id="${hypervisor_group_id}" \
      --env hypervisor_group_name="${hypervisor_group_name}" \
      --volume /run/udev:/run/udev:rw \
      --volume /data:/data:rw \
      --volume ${project_root}:/aleph:ro \
      ${docker_x_parameters} \
      aleph-x:${version} ;

#      --device /dev/snd/pcmC1D0p \
#      --device /dev/snd \
#      --volume /dev/snd:/dev/snd:rw \
# root@aleph:/# apt install pulseaudio-utils pulseaudio-module-gsettings paprefs pamix
# aplay /data/file_example_WAV_1MG.wav
# paul@aleph:~$ pulseaudio --start --log-target=stderr --verbose --verbose --verbose --verbose
# paul@aleph:~$ pulseaudio --log-target=stderr --verbose --verbose --verbose --verbose
# paul@aleph:~$ pulseaudio --kill
# root@aleph:~$ pulseaudio --verbose --system --log-target=stderr --verbose --verbose --verbose --verbose
# paul@aleph:~$ pactl list cards # while PA is running

    ( [ "${is_x_running}" == "1" ] && xhost -local:${hypervisor_user_name} || true ) ;
    exit ${?}
  fi

  echo "Aleph X is starting up ..." &&

  # At runtime we know the current user(id&name) and group(id&name)
  home_me="/data/home/${hypervisor_user_name}" &&
  echo "Creating group name ..." &&
  groupadd --gid ${hypervisor_group_id} ${hypervisor_group_name} &&
  echo "Creating user name ..." &&
  useradd \
    --gid ${hypervisor_group_id} \
    --uid ${hypervisor_user_id} ${hypervisor_user_name} \
    --shell /bin/bash \
    --home-dir ${home_me} \
    &&
  echo "Setting password aleph for user: ${hypervisor_user_name} ..." &&
  echo ${hypervisor_user_name}:aleph | chpasswd &&
  echo "Adding user to groups ..." &&
  usermod -a -G audio ${hypervisor_user_name} &&
  echo "Creating home folder ..." &&
  mkdir -p ${home_me} &&
  chown -R ${hypervisor_user_name}:${hypervisor_group_name} ${home_me} &&

  echo -n "Copying various files to HOME ..." &&
  cp --no-target-directory --recursive --verbose /aleph/fs/x/root ${home_me} &&
  chown -R ${hypervisor_user_name}:${hypervisor_group_name} ${home_me} &&

  echo "DISPLAY=\"${DISPLAY}\"" &&
  is_x_running="$([ ! -z "${DISPLAY}" ] && echo 1 || echo 0)" &&
  echo "is_x_running=\"${is_x_running}\"" &&

  if [ "${is_x_running}" == "0" ]; then
    # If X is not running, then we'll have to start it

    # This seems to be needed for both asus and qemu - for mouse & kbd to work
#    echo "Setting up X server config file ..." &&
    (exit 0 ; cat - <<EOF > /usr/share/X11/xorg.conf.d/xorg.conf
EOF
    ) &&

    echo "Setting up apps to run at X startup ..." &&
    (cat - <<EOF >${HOME}/.xinitrc
#      # Display adjustment
#      (
#        # exit 0 &&
#        # Rotate display
#        xrandr --output DSI-1 --rotate right &&
#
#        # poor type of backlight reduction
#        xrandr --output DSI-1 --brightness 0.3 ;
#
#        exit 0
#      ) &&
#
#      # xsetbg -fullscreen /usr/share/pixmaps/debian-logo.png
#      xterm -maximize &&

      # For qemu(maybe asus too?)
      (
        # exit 0 &&
        xhost + &&
        cd ${home_me} &&
        HOME="${home_me}" \
        su ${hypervisor_user_name} \
        --preserve-environment \
        --pty \
        --command startxfce4 ;
        xhost -
      ) &&
      # xfce4-terminal --maximize
      exit 0
EOF
    ) &&

#     sed -i 's/ main/ main non-free/g' /etc/apt/sources.list ;
#     apt-get update ;
#     apt-get install -y \
#      ;

    # Start X as root, then xfce4 session as normal user
#    timeout 10 \
      startx
#    cat /usr/share/X11/xorg.conf.d/*
#    cat /var/log/Xorg.0.log
#    cp /var/log/Xorg.0.log /data/Xorg.0.log
  else
    # If X is already running:
#    su --command startxfce4 --login ${hypervisor_user_name}
#    su --command xfce4-terminal --login ${hypervisor_user_name}
#    xfce4-session 2>/dev/null
#    xfce4-terminal
    (
      cd ${home_me} &&
      HOME="${home_me}" \
      su ${hypervisor_user_name} \
      --preserve-environment \
      --pty \
      --command startxfce4
    )
  fi
}





# ============================================================================ #
# Calculate RAM usage as percentage-to be displayed in xfce panel genericmonitor
# ============================================================================ #
function x__xfce__panel__ram()
{
  free -m | grep ^Mem: | awk '
    function ceil(x, y)
    {
      y = int(x);
      return ( x > y ? y+1 : y )
    }

    {
      print "R:" ceil(100*$3/$2) "%"
    }
    '
}





# ============================================================================ #
# start script when XFCE starts
# ============================================================================ #
function x__xfce__start()
{
  if [ -z "${WINDOWID}" ]; then
    # not running in a windows, so run again in terminal
    xfce4-terminal -e '/aleph/aleph.sh --x__xfce__start'
  fi

  # If here, then this will run in a new terminal window

  # Can not use dmidecode, because we're running as limited user(needs root)
  device="$(
    echo -n "$(cat /sys/devices/virtual/dmi/id/sys_vendor)"
    echo -n " "
    echo -n "$(cat /sys/devices/virtual/dmi/id/product_name)"
    echo
    )" &&
  echo "Device = \"${device}\"" &&

  if [ "${device}" == "ASUSTeK COMPUTER INC. T101HA" ]; then
    # Rotate screen and reeduce brightness to save battery
    xrandr --output DSI-1 --rotate right --brightness 0.3 &&
    # Rotate touch screen in horizontal mode (laptop)
    # - libinput /dev/input/event11
    xinput set-prop \
      "SIS0457:00 0457:11ED" \
      "Coordinate Transformation Matrix" \
      0 1 0 -1 0 1 0 0 1 &&
    # Enable touchpad tapping
    xinput --set-prop \
      "ASUS Tech Inc. ASUS HID Device  Touchpad" \
      "libinput Tapping Enabled" 1

    # Sound server should start to allow sound output
    pulseaudio --start &
    # aplay -l # to list sound devices
    # aplay ./my.wav # to play a wav file
  elif [ "${device}" == "QEMU Standard PC" ]; then
    echo "Nothing to do"
  else
    echo "Unknown device: ${device}" &&
    echo "Nothing to do"
  fi

  # keep the terminal open for future commands
  bash
}





# ============================================================================ #
# Print help
# ============================================================================ #
function print_help()
{
  echo "--core__build__pxe_iso     Build the PXE iso." &&
  echo "--core__build__pxe_kernel  Build the core PXE kernel." &&
  echo "--core__build__squashfs    Build the core squashfs." &&
  echo "--core__build__iso         Build the core .iso." &&
  echo "--core__emulate            Boot the distribution iso inside qemu." &&
  echo "--core__start              Start script once the distribution booted."&&
  echo "--x__build                 Build the aleph container." &&
  echo "--x__start                 Start the aleph container." &&
  echo "--x__xfce__panel__ram      Show ram usage in XFCE4 panel." &&
  echo "--x__xfce__start           Script that runs when XFCE4 starts." &&
  echo "--help                     Print the help message."
}





# ============================================================================ #
# Case logic
# ============================================================================ #
# If no parameter
if [ ${#} == 0 ]; then
  print_help
fi &&

# Case
exit_code=100 &&
if [ ${1} ]; then
  case "${1}" in
    --core__build__pxe_iso) core__build__pxe_iso ; exit_code=${?} ;;
    --core__build__pxe_kernel) core__build__pxe_kernel ; exit_code=${?} ;;
    --core__build__squashfs) core__build__squashfs ; exit_code=${?} ;;
    --core__build__iso) core__build__iso ; exit_code=${?} ;;
    --core__emulate) core__emulate ; exit_code=${?} ;;
    --core__start) core__start ; exit_code=${?} ;;
    --x__build) x__build ; exit_code=${?} ;;
    --x__start) x__start ; exit_code=${?} ;;
    --x__xfce__panel__ram) x__xfce__panel__ram ; exit_code=${?} ;;
    --x__xfce__start) x__xfce__start ; exit_code=${?} ;;
    --help) print_help ; exit_code=${?} ;;
    *) print_help ; exit_code=${?} ;;
    esac
fi
set +x && # Stop debugging
exit ${exit_code}
# ============================================================================ #






























# ============================================================================ #
# Documentation
# ============================================================================ #
# Command line connect to wifi (open - no WPA or WPA2):
# ============================================================================ #
(
  ifconfig && # show interfaces, detect wifi interface

  # Let's say that our interface's name is wlp1s0
  iface_name="wlp1s0" &&

  # Bring it up
  ( ifconfig ${iface_name} up || true ) &&

  # Search for available WiFi networks:
  iwlist ${iface_name} scan &&

  # Pick an OPEN network, not a WPA, and not a WPA2 encrypted network
  # And connect to it's ESSID:
  iwconfig ${iface_name} essid hotspot.paul.grozav.info &&

  # Use DHCP to get an IP address inside the network:
  dhclient ${iface_name} &&

  # make sure that internet works:
  ping -c 1 8.8.8.8 &&

  # That's it !
  exit 0
) &&
# Command line connect to wifi (WPA or WPA2):
# ============================================================================ #
(
  ifconfig && # show interfaces, detect wifi interface

  # Let's say that our interface's name is wlp1s0
  iface_name="wlp1s0" &&

  # Bring it up
  ( ifconfig ${iface_name} up || true ) &&

  # Search for available WiFi networks:
  iwlist ${iface_name} scan &&

  # Pick a WPA or a WPA2 encrypted network
  # And generate the pre-shared-key for network's ESSID:
  echo "password" | wpa_passphrase hotspot.paul.grozav.info \
    >> /etc/wpa_supplicant.conf &&

  # Connect to the wifi network:
  wpa_supplicant -B -D wext -i ${iface_name} -c /etc/wpa_supplicant.conf &&

  # Use DHCP to get an IP address inside the network:
  dhclient ${iface_name} &&

  # make sure that internet works:
  ping -c 1 8.8.8.8 &&

  # That's it !
  exit 0
) &&
# Start X server and app
# ============================================================================ #
(
  # The parameters are:
  # argv[1] = The application to be started in X server
  # argv[2, 3, ...] = any parameters that should be passed to the application
  # argv[4] = End of app arguments, the following arguments are passed to X srv
  # argv[5] = display number to be used (set in variable ${DISPLAY}
  # argv[6] = In order to maintain an authenticated session with logind and to
  #  prevent bypassing the screen locker by switching terminals, Xorg has to be
  #  started on the same virtual terminal where the login occurred. Therefore it
  #  is recommended to specify vt${XDG_VTNR}
  xinit /my/app arg1 ${*} -- :0 vt${XDG_VTNR} &&

  exit 0
) &&
# X rotate screen
# ============================================================================ #
(
  # List available screens:
#  xrandr  &&

  # Rotate screen DSI-1 90 degrees to the right:
  xrandr --output DSI-1 --rotate right &&

  exit 0
) &&
# ============================================================================ #
# Turn display light off:
xset dpms force off &&
# monitor battery status:
upower -i $(upower -e | grep BAT) &&
# Rotate touch screen in horizontal mode (laptop) - libinput /dev/input/event11
xinput set-prop 'SIS0457:00 0457:11ED' 'Coordinate Transformation Matrix' 0 1 0 -1 0 1 0 0 1
# ============================================================================ #
# If X server exists, start container like this:
# xhost +local:root ; docker run -it --name=myos --privileged -v /tmp/.X11-unix/:/tmp/.X11-unix/ -e DISPLAY myos:1 ; xhost -local:root
# If not, start it like this:
# docker run -it --name=myos --privileged myos:1

# Use: startx /root/x.sh # with this contents:
# xlogo &
# xsetbg -fullscreen /usr/share/icons/gnome/48x48/apps/web-browser.png # requires pkg xloadimage
# sleep 5
# ============================================================================ #
#for f in /sys/class/power_supply/BATC/*; do echo -n $(basename ${f})=; cat ${f}; done
watch -n1 -t -d "for f in /sys/class/power_supply/BATC/*; do echo -n \$(basename \${f})=; cat \${f}; done"
# ============================================================================ #
exit 0
# ============================================================================ #
(
  echo "apt-get install -y xserver-xorg-input-libinput && apt-get clean" |
  docker run -i --name=aleph-x-new aleph-x:0.1.6 &&
  docker commit aleph-x-new aleph-x:0.1.7 &&
  docker rm aleph-x-new
)

(
  echo "apt-get install -y xinput && apt-get clean" |
  docker run -i --name=aleph-x-new aleph-x:0.1.7 &&
  docker commit aleph-x-new aleph-x:tmp &&
  docker rm aleph-x-new &&
  docker image rm aleph-x:0.1.7 &&
  docker image tag aleph-x:tmp aleph-x:0.1.7 &&
  docker image rm aleph-x:tmp
)
