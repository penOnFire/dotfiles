# FocalTech 2808:c6d5 driver notes

## Root cause found

The old c6d5 path was running the 9e65 sensor-template protocol. Its `0xA3`/`0xAA` commands and 32-byte template assumptions do not match the FT9366 device in the official MEGABOOK K14S driver package. That caused the final enrollment steps to fail and could never produce useful verification matches.

The official package identifies USB `2808:c6d5` as FT9366 `newarch` and supplies `ftWbioEngineAdapter.dll`. The official flow captures 152 × 40 signed 16-bit images and passes converted 8-bit frames to the host-side WinBio engine. Enrollment templates are opaque matcher data stored by libfprint; no 32-byte sensor template or custom crypto key is involved.

## Protocol recovered from the official UMDF binary

- Send a framed command on bulk OUT endpoint `0x01` using the FocalTech XOR checksum format.
- For finger status, send `0x82` with arguments `73 01`, then read exactly one raw byte from bulk IN endpoint `0x82`. `0x05` means a finger is present; the status is not a framed response packet.
- For a normal image, send `0x82` with arguments `76 01`, then read `2 × 152 × 40` raw bytes directly from endpoint `0x82`. There is no framed acknowledgement between the command and image.
- A distinct rescan path uses `0x81` and data type 7; the Linux driver does not mix it into normal image capture.
- The UMDF binary also uses `0x80` for one-byte sensor queries/modes and `0x87` for GPIO writes. The basic scan path is implemented without the unrelated old reset command.
- The official image conversion negates signed 16-bit samples, clamps below zero, smooths a 256-bin histogram, selects an adaptive upper contrast threshold, and scales to 8-bit grayscale. The port implements the recovered histogram conversion. Its exact spatial prefilter still needs comparison against a real captured frame if the matcher rejects good quality captures.

## Implementation

- `bin/libfprint-c6d5/` contains the c6d5 driver and FT9366 WinBio engine wrapper.
- `bin/focaltech-driver-c6d5.patch` removes c6d5 from the legacy driver and registers the dedicated driver in Meson.
- The standalone driver handles raw status/image reads, waits for finger lift between samples, runs host-side enrollment and verification, and stores the vendor template as opaque `FpPrint` data.
- `bin/setup-fingerprint.sh` installs the rebuilt library and extracts `ftWbioEngineAdapter.dll` from the official archive in `~/Downloads` (or uses an already extracted copy). The proprietary DLL is not included in dotfiles.
- `bin/test-fingerprint` no longer sends the old `0x82 78` reset command or displays the old extra final-capture prompt.

## Build and hardware validation

Build the pinned libfprint source with:

```sh
ninja -C /tmp/libfprint-1.94.9/build
```

After installing with `sudo bash ~/dotfiles/bin/setup-fingerprint.sh`, check whether fprintd has a saved print. Delete it only if one is listed, because a template from the old c6d5 flow is incompatible:

```sh
test-fingerprint list
# If the old right-index-finger print is listed:
test-fingerprint delete
test-fingerprint enroll
test-fingerprint
```

The enrollment should report ten stages and finish without a final sensor-template capture. Verification must be checked physically with both the enrolled finger and a non-enrolled finger. The current build and code checks do not substitute for those two hardware checks.
