# ACPI Fixes for T2 Macs running Linux

This repo contains ACPI table patches for T2 Intel Macs running Linux.
Apple's ACPI tables were never meant for Linux, resulting in a range of issues.
Two confirmed fixes are documented here.

## Fixes in this repo

- [Slow S3 resume (10-17s smpboot): CpuSsdt SDTL fix](#guide-on-fixing-the-smpboot-times-issue): pre-initializes `\SDTL` so `_PDC` is never serialized, bringing all CPUs online in ~1.6s
- [ACPI boot errors: DSDT `_OSC` buffer overflow fix](#guide-on-fixing-the-dsdt-_osc-buffer-overflow): removes out-of-bounds `CDW3` field, eliminating `AE_AML_BUFFER_LIMIT` errors and restoring PCIe capability negotiation

---

## The SMPBOOT-time issue

On Linux, resuming from S3 sleep takes 10-17+ seconds before all CPUs are online.
The cause is in Apple's `CpuSsdt`: the `GCAP` method tries to `Load()`
IST/CST sub-tables that are already loaded from the XSDT at boot. Every `Load()`
returns `AE_ALREADY_EXISTS`, the method aborts, and Linux dynamically marks `_PDC`
and `_OSC` as Serialized. On resume, the APs that are first threads of non-BSP
physical cores queue behind that mutex sequentially instead of waking in parallel.

`CpuSsdt` uses a global bitmask `\SDTL` to track which sub-tables have been loaded.
It initializes to `Zero`. `GCAP` checks each bit before calling `Load()`:

```
If (!(SDTL & 0x08)) { Load(CPU0IST) }   already in XSDT -> AE_ALREADY_EXISTS
If (!(SDTL & 0x02)) { Load(CPU0CST) }   already in XSDT -> AE_ALREADY_EXISTS
If (!(SDTL & 0x10)) { Load(APIST)   }   already in XSDT -> AE_ALREADY_EXISTS
If (!(SDTL & 0x20)) { Load(APCST)   }   already in XSDT -> AE_ALREADY_EXISTS
```

Because `Load()` fails, the SDTL bits are never set, so the same failure repeats
on every resume. Linux serializes `_PDC` in response.

Linux is the only mainstream OS that pre-loads all static SSDTs from the XSDT at
boot. Other OSes load them on demand via `Load()`, so the calls in `GCAP` succeed
and `SDTL` is set correctly. This is why Windows and macOS do not have this problem.

## A SSDT overlay to the rescue

We extract the faulty SSDT table and patch it. We override `CpuSsdt` with a patched version that pre-initializes `\SDTL = 0x3A`
(bits for the four already-loaded tables). `GCAP` then skips those `Load()` calls,
runs to completion, and `_PDC` is never serialized.

```
0x3A = 0x02 | 0x08 | 0x10 | 0x20
```

All `_PDC`, `_OSC`, and `GCAP` methods are left completely unchanged.

## Results (MacBookAir9,1 / i5-1030NG7)

**Without patch** (~11 s):
```
[58.334] Booting CPU1 -> [60.993] up  (2.66s)
[61.008] Booting CPU2 -> [63.189] up  (2.18s)
[63.202] Booting CPU3 -> [65.168] up  (1.97s)
[65.202] Booting CPU4 -> [65.208] up  (6ms)
[65.208] Booting CPU5 -> [66.785] up  (1.58s)
[66.805] Booting CPU6 -> [68.594] up  (1.79s)
[68.617] Booting CPU7 -> [70.473] up  (1.86s)
```

**With patch** (~1.6 s):
```
[71.261] Booting CPU1 -> [71.338] up  (77ms)
[71.338] Booting CPU2 -> [71.412] up  (74ms)
[71.412] Booting CPU3 -> [71.544] up  (132ms)
[71.544] Booting CPU4 -> [71.547] up  (3ms)
[71.547] Booting CPU5 -> [71.874] up  (327ms)
[71.875] Booting CPU6 -> [72.298] up  (423ms)
[72.299] Booting CPU7 -> [72.843] up  (544ms)
```

## Contribution / Pre-patched overlays

The repo contains confirmed working `.aml` files contributed by
users for specific T2 Intel Mac models. If your model is listed, you can use the
pre-built overlay directly instead of patching manually.

If you successfully apply the fix on a model not yet listed, please open an issue or pull
request with your patched `.aml`. Name the file after your model, replacing the comma
in the model identifier with an underscore to avoid shell quoting issues:

```
MacBookAir9_1-CpuSsdt-sdtl-fix.aml
MacBookPro16_1-CpuSsdt-sdtl-fix.aml
```

## Applicability

Tested on MacBookAir9,1. The `\SDTL` bitmask and bit assignments come from Intel's
PMRef reference firmware and should be consistent across T2 Intel Macs with the
same CpuSsdt structure.

The `SSDT` package inside CpuSsdt contains machine-specific physical addresses for
the HWP/PSD sub-tables. Do **not** copy a pre-built `.aml` from a different machine
model. Either use a contributed overlay for your exact model or patch your own.

---

## Guide on fixing the SMPBOOT times issue

### 1. Verify the problem

```
journalctl -b 0 -k --grep='Marking method'
```

Expected output:
```
Marking method _PDC as Serialized because of AE_ALREADY_EXISTS error
```

### 2. Find CpuSsdt

The ACPI table number varies by machine. On MacBookAir9,1 it is SSDT5.
To find it on your machine:

```
sudo grep -rl "CpuSsdt" /sys/firmware/acpi/tables/
```

This prints the path of the SSDT that contains `CpuSsdt`.

### 3. Extract and disassemble

```
sudo cp /sys/firmware/acpi/tables/SSDTx ./SSDTx
iasl -d SSDTx
```

Replace `x` with the number you found in the path. This decompiles the file to a human readable `SSDTx.dsl`.

### 4. Patch

In `SSDTx.dsl`, make two changes:

Bump the OEM revision so the kernel accepts the override:
```
DefinitionBlock ("", "SSDT", 2, "CpuRef", "CpuSsdt", 0x00003000)
```
becomes:
```
DefinitionBlock ("", "SSDT", 2, "CpuRef", "CpuSsdt", 0x00003001)
```

Pre-initialize SDTL:
```
Name (\SDTL, Zero)
```
becomes:
```
Name (\SDTL, 0x0000003A)
```

### 5. Compile

```
iasl -tc SSDTx.dsl
```

Must produce `0 Errors, 0 Warnings`.

### 6. Deploy via dracut (Fedora)

I am on Fedora. Other distros may use different deploy methods. If anyone wants to contribute how to deploy on other distros, please PR.

```
sudo mkdir -p /usr/local/lib/firmware/acpi
sudo cp SSDTx.aml /usr/local/lib/firmware/acpi/YourModel_x_y-CpuSsdt-sdtl-fix.aml
```

Create `/etc/dracut.conf.d/acpi-cpussdt-fix.conf`:
```
acpi_override="yes"
acpi_table_dir="/usr/local/lib/firmware/acpi"
```

Rebuild initramfs and reboot:
```
sudo dracut --force
sudo reboot
```

### 7. Verify

```
journalctl -b 0 -k --grep='Marking method'
```

Should return nothing. Then suspend/resume and:

```
sudo dmesg
```

Go up till you find smpboot. Should show all CPUs online within 1-2 seconds.

---

## Guide on fixing the DSDT `_OSC` buffer overflow

Apple's DSDT contains two `_OSC` methods that trigger `AE_AML_BUFFER_LIMIT` on
every boot. The error prevents Linux from properly negotiating PCIe capabilities.


Both `\_SB._OSC` and `\_SB.PCI0._OSC` create a DWord field (`CDW3`) at byte
offset 8 of an 8-byte buffer:

```
CreateDWordField (Local0, 0x08, CDW3)   // reads bytes 8-11 of a 8-byte buffer
```

This overflows the buffer. Linux logs:

```
ACPI Error: AE_AML_BUFFER_LIMIT, Index (0x00000008) is beyond end of object
ACPI Error: Method parse/execution failed \_SB._OSC, AE_AML_BUFFER_LIMIT
ACPI Error: Method parse/execution failed \_SB.PCI0._OSC, AE_AML_BUFFER_LIMIT
```

When `_OSC` fails, Linux cannot claim PCIe capabilities (PCIeHotplug, AER, LTR,
DPC). The capability negotiation is skipped entirely.

Additionally, `CDW1` (which signals an unsupported UUID back to the OS) was only
created inside the `If` branch, so the `Else` branch (`CDW1 |= 0x04`) would
reference an undefined object. This bug was hidden in the original code because
the `CDW3` overflow aborted the method before reaching the `Else` branch.

`CDW3` is never read or used after creation. The fix removes it and moves
`Local0` assignment and `CDW1` creation before the `If` block so both branches
have access to `CDW1`.

After applying the patch:
- Zero `AE_AML_BUFFER_LIMIT` errors at boot
- Better overall compatibility and stability
- Linux successfully negotiates new PCIe capabilities:
  ```
  _OSC: OS assumes control of [PCIeHotplug SHPCHotplug AER PCIeCapability LTR DPC]
  ```

### Step-by-step

#### 1. Verify the problem

```
journalctl -b 0 -k --grep='AE_AML_BUFFER_LIMIT'
```

Expected output contains lines referencing `\_SB._OSC` and `\_SB.PCI0._OSC`.

#### 2. Extract and disassemble DSDT

```
sudo cp /sys/firmware/acpi/tables/DSDT ./DSDT
iasl -d DSDT
```

This produces human readable `DSDT.dsl`.

#### 3. Patch

Make three changes in `DSDT.dsl`.

**Bump OEM revision** so the kernel accepts the override:
```
DefinitionBlock ("", "DSDT", 2, "APPLE ", "MacBook", 0x00080001)
```
becomes:
```
DefinitionBlock ("", "DSDT", 2, "APPLE ", "MacBook", 0x00080002)
```

**Patch `\_SB._OSC`** (original):
```
Method (_OSC, 4, Serialized)
{
    If ((Arg0 == ToUUID ("0811b06e-4a27-44f9-8d60-3cbbc22e7b48")))
    {
        Local0 = Arg3
        CreateDWordField (Local0, Zero, CDW1)
        CreateDWordField (Local0, 0x04, CDW2)
        CreateDWordField (Local0, 0x08, CDW3)
    }
    Else
    {
        CDW1 |= 0x04
    }
    Return (Local0)
}
```

becomes:
```
Method (_OSC, 4, Serialized)
{
    Local0 = Arg3
    CreateDWordField (Local0, Zero, CDW1)
    If ((Arg0 == ToUUID ("0811b06e-4a27-44f9-8d60-3cbbc22e7b48")))
    {
        CreateDWordField (Local0, 0x04, CDW2)
    }
    Else
    {
        CDW1 |= 0x04
    }
    Return (Local0)
}
```

**Patch `\_SB.PCI0._OSC`** (original):
```
Method (_OSC, 4, Serialized)
{
    If ((Arg0 == ToUUID ("33db4d5b-1ff7-401c-9657-7441c03dd766")))
    {
        Local0 = Arg3
        CreateDWordField (Local0, Zero, CDW1)
        CreateDWordField (Local0, 0x04, CDW2)
        CreateDWordField (Local0, 0x08, CDW3)
    }
    Else
    {
        CDW1 |= 0x04
    }
    Return (Local0)
}
```

becomes:
```
Method (_OSC, 4, Serialized)
{
    Local0 = Arg3
    CreateDWordField (Local0, Zero, CDW1)
    If ((Arg0 == ToUUID ("33db4d5b-1ff7-401c-9657-7441c03dd766")))
    {
        CreateDWordField (Local0, 0x04, CDW2)
    }
    Else
    {
        CDW1 |= 0x04
    }
    Return (Local0)
}
```

#### 4. Compile

```
iasl -tc DSDT.dsl
```

Must produce `0 Errors, 0 Warnings`.

#### 5. Deploy via dracut (Fedora)

A DSDT override is deployed as `dsdt.aml` (fixed name, no table-ID matching).
The same `acpi_table_dir` used for the SSDT overlay works here.

```
sudo cp DSDT.aml /usr/local/lib/firmware/acpi/dsdt.aml
```

If you have not already created the dracut config from the CpuSsdt section:

```
sudo mkdir -p /usr/local/lib/firmware/acpi
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

#### 6. Verify

```
journalctl -b 0 -k --grep='AE_AML_BUFFER_LIMIT'
```

Should return nothing. Then:

```
journalctl -b 0 -k --grep='_OSC'
```

Should show:

```
_OSC: OS assumes control of [PCIeHotplug SHPCHotplug AER PCIeCapability LTR DPC]
```

### Note on DSDT overrides

A DSDT override replaces the entire DSDT, not just a single table. It is more
invasive than an SSDT overlay. The patched file must come from your own machine;
do not copy a pre-built `dsdt.aml` from a different model.
