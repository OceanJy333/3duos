#!/usr/bin/env python3
# Input: an IPA produced locally or downloaded from a release.
# Output: ZIP integrity, local-header compatibility and app entry validation.
# Pos: release packaging check, run before publishing or signing.
import plistlib
from pathlib import Path
import struct
import sys
import zipfile


def check_ipa(path: Path) -> None:
    with zipfile.ZipFile(path) as archive, path.open("rb") as raw:
        assert archive.testzip() is None, "ZIP CRC check failed"
        names = archive.namelist()
        assert all(name.startswith("Payload/") for name in names), "Unexpected ZIP root"
        apps = {name.split("/")[1] for name in names if name != "Payload/"}
        assert len(apps) == 1 and next(iter(apps)).endswith(".app"), "Expected one Payload/*.app"
        root = f"Payload/{next(iter(apps))}/"
        info = plistlib.loads(archive.read(root + "Info.plist"))
        assert info["CFBundlePackageType"] == "APPL", "Invalid app bundle"
        assert "iPhoneOS" in info["CFBundleSupportedPlatforms"], "Not an iOS device build"
        executable = archive.read(root + info["CFBundleExecutable"])
        assert executable[:4] == b"\xcf\xfa\xed\xfe", "Expected a 64-bit Mach-O executable"

        # Some importers scan local headers when their ZIP library fails to open the central directory.
        # Store CRC and sizes here, rather than only in trailing data descriptors.
        for entry in archive.infolist():
            raw.seek(entry.header_offset)
            header = struct.unpack("<4s5H3I2H", raw.read(30))
            signature, _, flags, method, _, _, crc, packed, unpacked, name_size, extra_size = header
            assert signature == b"PK\x03\x04", f"Invalid local header: {entry.filename}"
            assert not flags & 9, f"Encrypted entry or trailing descriptor: {entry.filename}"
            assert method in (0, 8), f"Unsupported ZIP method: {entry.filename}"
            assert (crc, packed, unpacked) == (entry.CRC, entry.compress_size, entry.file_size), entry.filename
            raw.seek(name_size + extra_size + packed, 1)
            assert raw.tell() <= archive.start_dir, f"Entry outside payload: {entry.filename}"

    print(f"IPA valid: {path.name}, {path.stat().st_size:,} bytes, {info['CFBundleShortVersionString']}, {len(names)} ZIP entries")


if __name__ == "__main__":
    check_ipa(Path(sys.argv[1]))
