#!/bin/bash
# ============================================================================ #
# Author: Tancredi-Paul Grozav <paul@grozav.info>
# ============================================================================ #
set -x &&
echo "Aleph script executed during initramfs stage" > /dev/kmsg

# parse kernel cmdline args.
for x in $(cat /proc/cmdline)
do
  case ${x} in
  config_srv_url=*)
    export config_srv_url=${x#config_srv_url=}
    ;;
  esac
done

# network-legacy dracut module is responsible for setting up the network prior
# to running this script.

echo "Request ird_net script" > /dev/kmsg && echo
(
  wget -O /tmp/script.sh ${config_srv_url}/ird_net &&
  # This is supposed to wget a squashfs and mount it
  source /tmp/script.sh &&
  rm -f /tmp/script.sh
) || echo "Error running ird_net script" > /dev/kmsg
echo "Script ird_net ended" > /dev/kmsg

echo "Aleph script ended during initramfs stage" > /dev/kmsg
set +x &&
# Since this script is hooked into initqueue/online, it's essential to ensure
# that it signals successful completion to prevent Dracut from repeatedly
# invoking it and eventually timing out. Signal success using exit 0
exit 0
# ============================================================================ #
