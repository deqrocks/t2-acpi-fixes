# ACPI Fixes for T2 Macs running Linux

This repo contains ACPI table patches for T2 Intel Macs running Linux.

- [CpuSsdt SDTL fix](#guide-on-fixing-the-smpboot-times-issue): pre-initializes `\SDTL` so `_PDC` is never serialized
- [ACPI boot errors: DSDT `_OSC` buffer overflow fix](#guide-on-fixing-the-dsdt-_osc-buffer-overflow): removes out-of-bounds `CDW3` field, eliminating `AE_AML_BUFFER_LIMIT` errors and restoring PCIe capability negotiation

---

## Deploy example

Copy the .aml files

```
sudo mkdir -p /usr/local/lib/firmware/acpi
sudo cp DSDT.aml /usr/local/lib/firmware/acpi/DSDT.aml
```

Create or update `/etc/dracut.conf.d/acpi-cpussdt-fix.conf` to include:
```
acpi_override="yes"
acpi_table_dir="/usr/local/lib/firmware/acpi"
```

Rebuild initramfs and reboot:
```
sudo dracut --force
sudo reboot
```

### Note on DSDT overrides

A DSDT override replaces the entire DSDT, not just a single table. It is more
invasive than an SSDT overlay. The patched file must come from your own machine;
do not copy a pre-built `dsdt.aml` from a different model.
