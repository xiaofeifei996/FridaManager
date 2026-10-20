#!/usr/bin/env python3
"""Verify a RootHide .deb without installing it (requires Python 3 + dpkg-deb).

Usage: python3 scripts/verify-package.py packages/package_iphoneos-arm64e.deb
Exit 0 means all static checks passed; exit 1 means invalid package. This does
not prove code signing, entitlements, dyld loading or on-device functionality.
"""

import argparse
import json
from pathlib import Path
import plistlib
import re
import shutil
import stat
import struct
import subprocess
import sys
import tempfile

LABEL = "com.b1tbreaker.fridamanager"
DAEMON = "usr/local/bin/fridamgr"
BUNDLE = "Library/PreferenceBundles/FridaManagerPrefs.bundle"
LAUNCH = "Library/LaunchDaemons/" + LABEL + ".plist"
SANDY = "Library/libSandy/" + LABEL + ".socket.plist"
ENTRY = "Library/PreferenceLoader/Preferences/FridaManagerPrefs.plist"
CPU_ARM64 = 0x0100000C


def macho_slices(data):
    """Parse thin/FAT/FAT64 Mach-O headers, including masked arm64e subtype."""
    thin = {b"\xcf\xfa\xed\xfe": ("<", 32), b"\xfe\xed\xfa\xcf": (">", 32),
            b"\xce\xfa\xed\xfe": ("<", 28), b"\xfe\xed\xfa\xce": (">", 28)}
    fat = {b"\xca\xfe\xba\xbe": (">", False), b"\xbe\xba\xfe\xca": ("<", False),
           b"\xca\xfe\xba\xbf": (">", True), b"\xbf\xba\xfe\xca": ("<", True)}

    def parse_header(offset, size):
        if size < 4 or offset < 0 or offset + size > len(data):
            raise ValueError("slice is outside the Mach-O file")
        magic = data[offset:offset + 4]
        if magic not in thin:
            raise ValueError("slice has no Mach-O header")
        endian, header_size = thin[magic]
        if size < header_size:
            raise ValueError("truncated Mach-O header")
        cpu, subtype, kind, ncmds, command_size = struct.unpack_from(endian + "5I", data, offset + 4)
        if ncmds > command_size // 8 or header_size + command_size > size:
            raise ValueError("invalid Mach-O load-command bounds")
        cursor = offset + header_size
        end = cursor + command_size
        for _ in range(ncmds):
            if cursor + 8 > end:
                raise ValueError("truncated load command")
            _, length = struct.unpack_from(endian + "2I", data, cursor)
            if length < 8 or length % 4 or cursor + length > end:
                raise ValueError("invalid load-command size")
            cursor += length
        if cursor != end:
            raise ValueError("load commands do not fill sizeofcmds")
        return {"cpu": cpu, "subtype": subtype, "arm64e": cpu == CPU_ARM64 and (subtype & 0x00FFFFFF) == 2,
                "bits": 64 if header_size == 32 else 32, "filetype": kind,
                "offset": offset, "size": size}

    magic = data[:4]
    if magic in thin:
        return [parse_header(0, len(data))]
    if magic not in fat or len(data) < 8:
        raise ValueError("not a Mach-O or universal binary")
    endian, fat64 = fat[magic]
    count, = struct.unpack_from(endian + "I", data, 4)
    entry_size = 32 if fat64 else 20
    table_end = 8 + count * entry_size
    if not 1 <= count <= 128 or table_end > len(data):
        raise ValueError("invalid FAT architecture table")
    slices, ranges = [], []
    for index in range(count):
        at = 8 + index * entry_size
        values = struct.unpack_from(endian + ("IIQQII" if fat64 else "5I"), data, at)
        cpu, subtype, offset, size, alignment = values[:5]
        if offset < table_end or size == 0 or alignment > 63 or offset % (1 << alignment):
            raise ValueError("invalid FAT slice offset, size or alignment")
        if any(offset < end and offset + size > start for start, end in ranges):
            raise ValueError("overlapping FAT slices")
        header = parse_header(offset, size)
        if header["cpu"] != cpu or header["subtype"] != subtype:
            raise ValueError("FAT architecture disagrees with the slice header")
        ranges.append((offset, offset + size))
        slices.append(header)
    return slices


class Report:
    def __init__(self, package):
        self.package = str(package)
        self.checks = []

    def check(self, name, condition, detail=""):
        self.checks.append({"name": name, "ok": bool(condition), "detail": str(detail)})
        return bool(condition)

    @property
    def ok(self):
        return all(item["ok"] for item in self.checks)

    def output(self, as_json):
        if as_json:
            print(json.dumps({"package": self.package, "ok": self.ok, "checks": self.checks}, indent=2))
        else:
            for item in self.checks:
                print(f"{'PASS' if item['ok'] else 'FAIL'} {item['name']}" +
                      (f": {item['detail']}" if item["detail"] else ""))
            failed = sum(not item["ok"] for item in self.checks)
            print(f"REPORT: {len(self.checks) - failed} passed, {failed} failed; {self.package}")
            print("Static verification only; on-device launch, sandbox access and signing still need testing.")


def verify_extracted(control, data, report):
    def regular(root, name):
        path = root / name
        valid = path.is_file() and not path.is_symlink() and path.resolve().is_relative_to(root.resolve())
        report.check("regular file " + name, valid)
        return path if valid else None

    metadata = regular(control, "control")
    fields = {}
    if metadata:
        for line in metadata.read_text().splitlines():
            if line and not line[0].isspace() and ":" in line:
                key, value = line.split(":", 1)
                fields[key.lower()] = value.strip()
    report.check("DEB Architecture", fields.get("architecture") == "iphoneos-arm64e", fields.get("architecture", "missing"))
    report.check("Package identifier", fields.get("package") == LABEL, fields.get("package", "missing"))
    paths = list(data.rglob("*"))
    prefixed = [str(path.relative_to(data)) for path in paths
                if "var/jb" in path.relative_to(data).as_posix().split("/")[:0]]  # populated below
    prefixed = [str(path.relative_to(data)) for path in paths
                if path.relative_to(data).as_posix() == "var/jb" or path.relative_to(data).as_posix().startswith("var/jb/")]
    report.check("unprefixed RootHide layout", not prefixed, ", ".join(prefixed[:8]))
    stale = [str(path.relative_to(data)) for path in paths if path.is_symlink() and
             ("/var/jb" in str(path.readlink()) or ".jbroot-" in str(path.readlink()))]
    report.check("no fixed jailbreak-root symlinks", not stale, ", ".join(stale))
    report.check("no legacy extrainst_", not (control / "extrainst_").exists() and not (control / "extrainst_").is_symlink())
    for relative, kinds in [(DAEMON, {2}), (BUNDLE + "/FridaManagerPrefs", {6, 8})]:
        binary = regular(data, relative)
        if not binary:
            continue
        report.check(relative + " executable mode", stat.S_IMODE(binary.stat().st_mode) & 0o111 == 0o111,
                     oct(stat.S_IMODE(binary.stat().st_mode)))
        try:
            slices = macho_slices(binary.read_bytes())
            matches = [item for item in slices if item["arm64e"] and item["bits"] == 64 and item["filetype"] in kinds]
            report.check(relative + " arm64e slice", bool(matches), json.dumps(slices))
        except (OSError, ValueError, struct.error) as error:
            report.check(relative + " arm64e slice", False, error)

    plists = {}
    for path in paths:
        if path.suffix != ".plist" or not path.is_file():
            continue
        name = path.relative_to(data).as_posix()
        if not regular(data, name):
            continue
        try:
            with path.open("rb") as stream:
                plists[name] = plistlib.load(stream)
            report.check("valid plist " + name, isinstance(plists[name], (dict, list)))
        except (OSError, ValueError, plistlib.InvalidFileException) as error:
            report.check("valid plist " + name, False, error)

    def dictionary(name):
        value = plists.get(name)
        report.check("required plist " + name, isinstance(value, dict))
        return value if isinstance(value, dict) else {}

    launch = dictionary(LAUNCH)
    report.check("launchd entry", launch.get("Label") == LABEL and launch.get("ProgramArguments") == ["/" + DAEMON]
                 and "Program" not in launch and "__Patched" not in launch)
    report.check("launchd root/RunAtLoad/KeepAlive", launch.get("UserName") == "root" and launch.get("RunAtLoad") is True
                 and launch.get("KeepAlive") is True)
    info = dictionary(BUNDLE + "/Info.plist")
    report.check("prefs executable / NSPrincipalClass", info.get("CFBundleExecutable") == "FridaManagerPrefs" and
                 info.get("NSPrincipalClass") == "FMRootListController" and info.get("CFBundlePackageType") == "BNDL")
    entry = dictionary(ENTRY).get("entry", {})
    report.check("PreferenceLoader entry", isinstance(entry, dict) and entry.get("bundle") == "FridaManagerPrefs"
                 and entry.get("detail") == "FMRootListController" and entry.get("cell") == "PSLinkCell" and entry.get("isController") is True)
    root = dictionary(BUNDLE + "/Root.plist")
    items = root.get("items")
    report.check("Root specifiers", isinstance(items, list) and bool(items) and
                 all(isinstance(item, dict) and isinstance(item.get("cell"), str) for item in items or []))
    sandy = dictionary(SANDY)
    report.check("libSandy Preferences signing identifier", sandy.get("AllowedProcesses") == ["com.apple.Preferences"])
    report.check("libSandy logical socket / actual schema", sandy.get("Extensions") == [{"type": "file",
                 "extension_class": "com.apple.app-sandbox.read-write", "path": "/var/run/fridamgr.sock"}])

    # Compare the complete scripts, not merely a marker a stale script can copy.
    # Never execute package maintenance scripts on the CI host.
    from stage import maintenance_script
    for role in ("postinst", "prerm"):
        script = regular(control, role)
        if not script:
            continue
        mode = stat.S_IMODE(script.stat().st_mode)
        report.check(role + " executable mode", mode == 0o755, oct(mode))
        text = script.read_text()
        report.check(role + " RootHide paths/lifecycle/data retention", text == maintenance_script("roothide", role))
        report.check(role + " no fixed /var/jb or UUID", "/var/jb" not in text and ".jbroot-" not in text)
        syntax = subprocess.run(["sh", "-n", str(script)], capture_output=True, text=True)
        report.check(role + " POSIX shell syntax", syntax.returncode == 0, syntax.stderr.strip())
    report.check("RootHide jbroot native resolver / 104-byte guard",
                 (control / "postinst").is_file() and
                 '/usr/bin/jbroot "$1"' in (control / "postinst").read_text() and
                 '"${#SOCKET_NATIVE}" -ge 104' in (control / "postinst").read_text())


def verify(package, report):
    if not report.check("dpkg-deb available", shutil.which("dpkg-deb") is not None):
        return
    if not report.check("input .deb exists", package.is_file(), package):
        return
    with tempfile.TemporaryDirectory(prefix="fridamanager-verify-") as temporary:
        root = Path(temporary)
        control, data = root / "control", root / "data"
        for option, destination in [("--control", control), ("--extract", data)]:
            result = subprocess.run(["dpkg-deb", option, str(package), str(destination)], capture_output=True, text=True)
            if not report.check("dpkg-deb " + option, result.returncode == 0, result.stderr.strip()):
                return
        verify_extracted(control, data, report)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("deb", type=Path)
    parser.add_argument("--json", action="store_true", help="emit a machine-readable report")
    args = parser.parse_args()
    report = Report(args.deb)
    try:
        verify(args.deb.resolve(), report)
    except (OSError, ValueError, KeyError, TypeError, ImportError) as error:
        report.check("verification completed", False, error)
    report.output(args.json)
    return 0 if report.ok else 1


if __name__ == "__main__":
    sys.exit(main())
