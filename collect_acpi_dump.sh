#!/usr/bin/env bash
set -euo pipefail

# Cross-distro ACPI dump collector (Cachy/Arch, Fedora, Debian/Ubuntu)
# Usage:
#   sudo ./collect_acpi_dump.sh [output_dir]
#
# Example:
#   sudo ./collect_acpi_dump.sh acpi_dump_16_4

detect_model_tag() {
  local product_name="" tag=""

  if [[ -r /sys/devices/virtual/dmi/id/product_name ]]; then
    product_name="$(tr -d '\n' </sys/devices/virtual/dmi/id/product_name)"
  fi

  # Apple desktop/laptop compact forms:
  #   MacBookPro16,4 -> 16_4
  #   MacBookAir9,1  -> 9_1
  #   MacBook10,1    -> 10_1
  #   iMac20,2       -> 20_2
  #   Macmini8,1     -> 8_1
  #   MacPro7,1      -> 7_1
  if [[ "${product_name}" =~ ^(MacBookPro|MacBookAir|MacBook|iMac|Macmini|MacPro)([0-9]+),([0-9]+)$ ]]; then
    tag="${BASH_REMATCH[2]}_${BASH_REMATCH[3]}"
  elif [[ -n "${product_name}" ]]; then
    # Generic safe fallback
    tag="$(printf '%s' "${product_name}" | tr ' /,' '_' | tr -cd '[:alnum:]_.-')"
  else
    tag="unknown_model"
  fi

  printf '%s' "${tag}"
}

MODEL_TAG="$(detect_model_tag)"
OUT="${1:-acpi_dump_${MODEL_TAG}_$(date +%Y%m%d_%H%M%S)}"
BASE_DIR="${PWD}"
OUT_DIR="${BASE_DIR}/${OUT}"
ARCHIVE="${BASE_DIR}/${OUT}.tar.gz"

if [[ "${EUID}" -ne 0 ]]; then
  if ! command -v sudo >/dev/null 2>&1; then
    echo "sudo not found. Run as root." >&2
    exit 1
  fi
  sudo -v
  exec sudo --preserve-env=PWD bash "$0" "$@"
fi

rm -rf "${OUT_DIR}" "${ARCHIVE}"
mkdir -p "${OUT_DIR}/dynamic"

# 1) Raw ACPI tables from sysfs
cp -a /sys/firmware/acpi/tables/. "${OUT_DIR}/"
cp -a /sys/firmware/acpi/tables/dynamic/. "${OUT_DIR}/dynamic/" 2>/dev/null || true

# 2) List ACPI override AMLs found in initramfs image
VMLINUX_IMG="$(ls -1 /boot/initramfs-*.img 2>/dev/null | head -n1 || true)"
if [[ -n "${VMLINUX_IMG}" ]]; then
  if command -v lsinitcpio >/dev/null 2>&1; then
    lsinitcpio "${VMLINUX_IMG}" | grep -E 'kernel/firmware/acpi/.*\.aml' > "${OUT_DIR}/initramfs_acpi.txt" || true
  elif command -v lsinitrd >/dev/null 2>&1; then
    lsinitrd "${VMLINUX_IMG}" | grep -E 'kernel/firmware/acpi/.*\.aml' > "${OUT_DIR}/initramfs_acpi.txt" || true
  elif command -v lsinitramfs >/dev/null 2>&1; then
    lsinitramfs "${VMLINUX_IMG}" | grep -E 'kernel/firmware/acpi/.*\.aml' > "${OUT_DIR}/initramfs_acpi.txt" || true
  else
    printf "No initramfs listing tool found (lsinitcpio/lsinitrd/lsinitramfs)\n" > "${OUT_DIR}/initramfs_acpi.txt"
  fi
else
  printf "No /boot/initramfs-*.img found\n" > "${OUT_DIR}/initramfs_acpi.txt"
fi

# 3) Resume/smpboot + ACPI error log (includes _OSC/buffer failures)
journalctl -b -k | grep -E \
  'ACPI: PM:|smpboot: Booting|CPU[0-9]+ is up|Marking method|AE_ALREADY_EXISTS|AE_AML_BUFFER_LIMIT|AE_BUFFER_OVERFLOW|_OSC|Aborting method' \
  > "${OUT_DIR}/resume_smpboot.txt" || true

# 4) Also keep a broader ACPI log for deeper triage
journalctl -b -k | grep -E 'ACPI:|AE_' > "${OUT_DIR}/acpi_errors_full.txt" || true

tar -C "${BASE_DIR}" -czf "${ARCHIVE}" "${OUT}"

if [[ -n "${SUDO_USER:-}" ]]; then
  chown -R "${SUDO_USER}:${SUDO_USER}" "${OUT_DIR}" "${ARCHIVE}" || true
fi

echo "Dump created:"
echo "  ${OUT_DIR}"
echo "  ${ARCHIVE}"
echo "Model tag: ${MODEL_TAG}"
