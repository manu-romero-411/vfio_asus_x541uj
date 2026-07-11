#!/usr/bin/env bash
set -euo pipefail

USUARIO=${SUDO_USER:-$(logname)}
ROOTDIR="$(
  cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null
  pwd -P
)"

LIBVIRT_FILES=/usr/local/etc/libvirt
LIBVIRT_LOCAL_DIR="/etc/apparmor.d/local/abstractions/libvirt-qemu"

# Parámetros de kernel para VFIO en este PC (i7 Kaby Lake, Intel)
VFIO_KERNEL_PARAMS="intel_iommu=on video=efifb:off,vesafb:off kvm.ignore_msrs=1 iommu=no-igfx video=vesafb:off i915.enable_gvt=1 i915.enable_guc=0 mitigations=off"

remove_vfio_grub_params() {
  info "Revirtiendo parámetros de kernel VFIO en GRUB..."
  local current
  current="$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub | cut -d'"' -f2)"

  for p in $VFIO_KERNEL_PARAMS; do
    current="$(echo "$current" | sed "s|${p}||")"
  done
  current="$(echo "$current" | sed 's/  */ /g' | sed 's/^ //; s/ $//')"

  sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${current}\"|" /etc/default/grub
  update-grub

  rm -f /etc/udev/rules.d/10-vfio.rules
}


remove_virt(){
  info "Desinstalando virtualización..."
  remove_vfio_grub_params

  rm -rf "${LIBVIRT_LOCAL_DIR}"
  systemctl restart apparmor 2>/dev/null || true

  apt-get autoremove --purge -y qemu-kvm libvirt-clients libvirt-daemon-system bridge-utils virt-manager ovmf swtpm
  rm -f /usr/share/polkit-1/actions/org.spice-space.lowlevelusbaccess.policy
  rm -f /etc/polkit-1/rules.d/50-libvirt.rules
  rm -f /etc/udev/rules.d/50-spice.rules
  rm -f /home/${USUARIO}/.config/libvirt/libvirt.conf
  rm -f "/home/${USUARIO}/.bashrc.d/06_libvirt"
  rm -rf "${LIBVIRT_FILES}"
  rm -rf /etc/libvirt/hooks
  rm -f /home/${USUARIO}/.local/share/applications/win11-vfio.desktop

  update-grub

  warn "Reinicia el equipo para aplicar todos los cambios."
}



remove_virt
exit 0
