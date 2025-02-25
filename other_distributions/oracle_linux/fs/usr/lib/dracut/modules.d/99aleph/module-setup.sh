#!/bin/bash
# ============================================================================ #
# Author: Tancredi-Paul Grozav <paul@grozav.info>
# ============================================================================ #

check() {
  return 0
}

depends() {
  return 0
}

install() {
  inst_hook initqueue/online 90 "${moddir}/aleph-script.sh"
}
# ============================================================================ #
