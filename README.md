# ACPI Fixes for T2 Macs running Linux

This repo contains SSDT overlays to fix ACPI issues on T2 Macs running Linux.
The ACPI tables provided by Apple were never meant for Linux, resulting in uncommon behaviour.
One of them being slow resume times caused by CPU cores coming up slowly after sleep, which is explained below.
We also observe other issues like WiFi not able to transition from D0 to D3 on suspend. Or dGPUs not transitioning from D3 to D0 on resume. Again ACPI could be the root cause, but requires further investigation. This is a first step into fixing SSDTs for T2 Macs using overlays. I will begin with with fixing the smpboot time issue and explain how I solved it in the guide below.

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

## Step-by-step

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
for f in /sys/firmware/acpi/tables/SSDT*; do
    sudo strings "$f" | grep -q CpuSsdt && echo "$f"
done
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
