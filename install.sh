#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# CONFIGURACIÓN DE ENTORNO Y USUARIO
# ──────────────────────────────────────────────────────────────────────────────
USUARIO=${SUDO_USER:-$(logname)}
ROOTDIR="$(
  cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null
  pwd -P
)"

LIBVIRT_FILES=/usr/local/etc/libvirt
LIBVIRT_LOCAL_DIR="/etc/apparmor.d/local/abstractions/libvirt-qemu"

# Parámetros de kernel para VFIO en este PC (i7 Kaby Lake, Intel)
VFIO_KERNEL_PARAMS="intel_iommu=on video=efifb:off,vesafb:off kvm.ignore_msrs=1 iommu=no-igfx video=vesafb:off i915.enable_gvt=1 i915.enable_guc=0 mitigations=off"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

if [[ $EUID -ne 0 ]]; then
    error "Este script de setup maestro debe ejecutarse con sudo."
    exit 1
fi

# ──────────────────────────────────────────────────────────────────────────────
# LOGICA DE PARÁMETROS DE KERNEL (GRUB) PARA VFIO
# ──────────────────────────────────────────────────────────────────────────────
setup_vfio_grub_params() {
  info "Configurando parámetros de kernel en GRUB para VFIO (Intel Kaby Lake)..."

  local current
  current="$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub | cut -d'"' -f2)"

  for p in $VFIO_KERNEL_PARAMS; do
    if ! grep -qF -- "$p" <<< "$current"; then
      current+=" ${p}"
    fi
  done
  current="$(echo "$current" | sed 's/  */ /g' | sed 's/^ //; s/ $//')"

  sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${current}\"|" /etc/default/grub
  update-grub

  info "Instalando regla udev para /dev/vfio/*..."
  tee /etc/udev/rules.d/10-vfio.rules > /dev/null << 'EOF'
SUBSYSTEM=="vfio", OWNER="root", GROUP="kvm"
EOF

  info "Parámetros de kernel aplicados: ${VFIO_KERNEL_PARAMS}"
}

# ──────────────────────────────────────────────────────────────────────────────
# LOGICA DE OPTIMIZACIÓN DEL SISTEMA (COREDUMPS Y PERMISOS)
# ──────────────────────────────────────────────────────────────────────────────
optimize_system_vfio() {
  info "Configurando persistencia (Linger) para lanzar VMs sin sudo..."
  loginctl enable-linger "$USUARIO"

  info "Configurando Systemd-Coredump para descartar volcados de memoria pesados..."
  mkdir -p /etc/systemd/coredump.conf.d
  tee /etc/systemd/coredump.conf.d/99-vfio-disable.conf > /dev/null << 'EOF'
[Coredump]
Storage=none
ProcessSizeMax=0
EOF
  systemctl daemon-reload
}

# ──────────────────────────────────────────────────────────────────────────────
# LOGICA DE CONFIGURACIÓN DE APPARMOR PARA PASSTHROUGH
# ──────────────────────────────────────────────────────────────────────────────
setup_apparmor_passthrough() {
  info "Iniciando configuración de AppArmor para Passthrough..."

  if ! command -v apparmor_parser &>/dev/null; then
      info "Instalando herramientas requeridas de AppArmor..."
      apt-get -y install apparmor apparmor-utils
  fi

  info "Instalando overrides locales de AppArmor en ${LIBVIRT_LOCAL_DIR}..."
  rm -rf "${LIBVIRT_LOCAL_DIR}"
  mkdir -p "${LIBVIRT_LOCAL_DIR}"

  tee "${LIBVIRT_LOCAL_DIR}/10-vfio-tuf" > /dev/null << EOF
${LIBVIRT_FILES}/ rw,
${LIBVIRT_FILES}/* rw,
/dev/input/ rw,
/dev/input/* rw,
EOF
  chmod 644 "${LIBVIRT_LOCAL_DIR}"/*

  if [ -d "$ROOTDIR/apparmor-local" ]; then
      cp -r "$ROOTDIR/apparmor-local/"* "${LIBVIRT_LOCAL_DIR}/"
      chmod 644 "${LIBVIRT_LOCAL_DIR}"/*
  fi

  info "Recargando perfiles de AppArmor..."
  systemctl restart apparmor

  info "Verificando que los perfiles de dominio activos cargan sin error..."
  for profile in /etc/apparmor.d/libvirt/libvirt-*; do
      [ -e "$profile" ] || continue
      if ! apparmor_parser -r "$profile" 2>/tmp/apparmor_err; then
          warn "Fallo al recargar $profile:"
          cat /tmp/apparmor_err
      fi
  done
}

desktop_entry(){
  cat << EOF > /home/${USUARIO}/.local/share/applications/win11-vfio.desktop
[Desktop Entry]
Name=Windows 11 (VFIO)
Comment=Arrancar VM con Single GPU Passthrough
Exec=bash -c "\$HOME/.local/bin/vfio-start-vm win11"
Icon=distributor-logo-windows
Terminal=false
Type=Application
Categories=System;Emulator;
Keywords=virtual;kvm;qemu;win11;vfio;
EOF
}

# ──────────────────────────────────────────────────────────────────────────────
# LOGICA PRINCIPAL DE INSTALACIÓN VIRTUALIZACIÓN
# ──────────────────────────────────────────────────────────────────────────────
install_virt(){
  info "Instalando virtualización Debian..."
  apt-get update
  apt-get -y install qemu-kvm libvirt-clients libvirt-daemon-system bridge-utils virt-manager ovmf swtpm

  info "Activando daemon libvirtd..."
  systemctl enable --now libvirtd

  info "Añadiendo usuario '$USUARIO' a grupos de sistema..."
  for g in libvirt kvm input libvirt-qemu; do
      getent group "$g" >/dev/null || groupadd "$g"
      usermod -aG "$g" "$USUARIO"
  done

  info "Configurando grupo 'spice' para passthrough de USB..."
  getent group spice >/dev/null || groupadd spice
  usermod -aG spice "$USUARIO"
  tee /etc/udev/rules.d/50-spice.rules > /dev/null << 'EOF'
SUBSYSTEM=="usb", GROUP="spice", MODE="0660"
SUBSYSTEM=="usb_device", GROUP="spice", MODE="0660"
EOF
  tee /usr/share/polkit-1/actions/org.spice-space.lowlevelusbaccess.policy > /dev/null << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE policyconfig PUBLIC
          "-//freedesktop//DTD PolicyKit Policy Configuration 1.0//EN"
          "http://www.freedesktop.org/standards/PolicyKit/1.0/policyconfig.dtd">
<policyconfig>
  <vendor>The Spice Project</vendor>
  <vendor_url>http://spice-space.org/</vendor_url>
  <icon_name>spice</icon_name>
  <action id="org.spice-space.lowlevelusbaccess">
    <description>Low level USB device access</description>
    <message>Privileges are required for low level USB device access (for usb device pass through).</message>
    <defaults>
      <allow_any>yes</allow_any>
      <allow_inactive>no</allow_inactive>
      <allow_active>yes</allow_active>
    </defaults>
  </action>
</policyconfig>
EOF

  info "Configurando acceso sin sudo a qemu:///system (Polkit)..."
  tee /etc/polkit-1/rules.d/50-libvirt.rules > /dev/null << 'EOF'
polkit.addRule(function(action, subject) {
    if (action.id == "org.libvirt.unix.manage" &&
        subject.isInGroup("libvirt")) {
        return polkit.Result.YES;
    }
});
EOF

  info "Exportando URI por defecto en .bashrc.d/06_libvirt..."
  BASHRC_D_DIR="/home/${USUARIO}/.bashrc.d"
  sudo -u "$USUARIO" mkdir -p "$BASHRC_D_DIR"
  sudo -u "$USUARIO" tee "$BASHRC_D_DIR/06_libvirt" > /dev/null << 'EOF'
#!/bin/bash

export LIBVIRT_DEFAULT_URI="qemu:///system"
EOF
  sudo -u "$USUARIO" chmod +x "$BASHRC_D_DIR/06_libvirt"

  sudo -u "$USUARIO" mkdir -p "/home/${USUARIO}/.config/libvirt"
  echo 'uri_default = "qemu:///system"' | sudo -u "$USUARIO" tee "/home/${USUARIO}/.config/libvirt/libvirt.conf" > /dev/null

  info "Instalando hooks de libvirt..."
  mkdir -p /etc/libvirt/hooks
  if [ -d "$ROOTDIR/hooks" ]; then
      cp -r "$ROOTDIR/hooks/"* /etc/libvirt/hooks
      chmod +x /etc/libvirt/hooks/qemu 2>/dev/null || true
  fi

  if [ -d "$ROOTDIR/misc" ]; then
      cp -r "$ROOTDIR/misc" "${LIBVIRT_FILES}"
      chown -R "$USUARIO:$USUARIO" "${LIBVIRT_FILES}"
  fi

  if [ -f "$ROOTDIR/qemu.conf" ]; then
      mv /etc/libvirt/qemu.conf /etc/libvirt/qemu.conf.old 2>/dev/null || true
      cp "$ROOTDIR/qemu.conf" /etc/libvirt/qemu.conf
  fi

  info "Definiendo red virtual personalizada..."
  if [ -f "$ROOTDIR/network-xml/win-vms.xml" ]; then
      virsh net-define "$ROOTDIR/network-xml/win-vms.xml" || true
      virsh net-autostart win_vms || true
      virsh net-start win_vms || true
  fi

  info "Instalando XML de VMs..."
  if [ -d "$ROOTDIR/vm-xml" ]; then
      for vm in "$ROOTDIR"/vm-xml/*.xml; do
          [ -e "$vm" ] && virsh define "$vm" || true
      done
  fi

  info "Configurando puertos de red para VMs..."
  if [ -f "$ROOTDIR/scripts/vfio-network-forward-setup.sh" ]; then
      bash "$ROOTDIR/scripts/vfio-network-forward-setup.sh"
  fi

  # ────────────────────────────────────────────────────────────────────────────
  # LLAMADAS A SUB-MÓDULOS UNIFICADOS
  # ────────────────────────────────────────────────────────────────────────────
  setup_vfio_grub_params
  setup_apparmor_passthrough
  optimize_system_vfio

  echo ""
  info "=== Verificación Final ==="
  echo -n "  Overrides locales de AppArmor: "
  if [ -d "${LIBVIRT_LOCAL_DIR}" ] && [ -n "$(ls -A "${LIBVIRT_LOCAL_DIR}" 2>/dev/null)" ]; then
      echo -e "${GREEN}OK${NC}"
  else
      echo -e "${RED}FALLO${NC}"
  fi
  echo -n "  Servicio apparmor activo: "
  if systemctl is-active --quiet apparmor; then
      echo -e "${GREEN}OK${NC}"
  else
      echo -e "${RED}FALLO${NC}"
  fi
  echo -n "  Parámetros VFIO en GRUB: "
  if grep -q "intel_iommu=on" /etc/default/grub; then
      echo -e "${GREEN}OK${NC}"
  else
      echo -e "${RED}FALLO${NC}"
  fi

  desktop_entry

  info "Instalación completada con éxito."
  warn "Reinicia el equipo imperativamente para aplicar el aislamiento de la GPU y los cambios de grupo."
}


case "${1:-}" in
  --uninstall|-u) remove_virt ;;
  *) install_virt ;;
esac