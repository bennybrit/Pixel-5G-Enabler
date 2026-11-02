#!/usr/bin/env python3
"""Build (or import) an Exynos modem carrier profile.

  build_profile.py profiles/g5123.txt module/profiles/g5123
      Text definition -> manifest + step files, as read by the Pixel radio daemon from
      /vendor/firmware/carrierconfig/{manifests,confseqs}/.
  build_profile.py --import <dir with manifests/ and confseqs/> [--names nvnames.txt] > out.txt
      Existing manifest + steps -> text definition.

Format of the files (protobuf):
  step:     1="v1.0"  2=step name  4=entry{1=crc32(setting name)  2=value{3=int} (repeated for arrays, empty = reset)}
  manifest: 1="v0.1"  2=profile name  3=carrier ID  5=entry{1=slot (1 SIM1, 2 SIM2, 3 both; absent = common)  2=sha256[:20] of a step}
  file name = first 40 hex digits of the sha256 of the file.
"""
import argparse
import hashlib
import os
import re
import sys
import zlib
from pathlib import Path

SLOTS = {"common": None, "sim1": 1, "sim2": 2, "multislot": 3}
CARRIER_ID = 1911          # the stock "Test Network" carrier ID: the modem only accepts IDs it knows
PROFILE_NAME = "pixel-5g-enabler"   # name inside the files; the step names are <name>.<slot>.<n>


# --- protobuf helpers -------------------------------------------------------------------------------------------
def varint(n):
    out = b""
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out += bytes([b | 0x80])
        else:
            return out + bytes([b])


def field(num, value):
    """Encode one field: int -> varint, bytes -> length-delimited."""
    if isinstance(value, int):
        return varint(num << 3) + varint(value)
    return varint(num << 3 | 2) + varint(len(value)) + value


def parse(data):
    """Decode one message into a list of (field, value); value is int or bytes."""
    i, out = 0, []
    while i < len(data):
        key, i = read_varint(data, i)
        num, wire = key >> 3, key & 7
        if wire == 0:
            val, i = read_varint(data, i)
        elif wire == 2:
            size, i = read_varint(data, i)
            val, i = bytes(data[i:i + size]), i + size
        else:
            raise ValueError(f"unsupported wire type {wire}")
        out.append((num, val))
    return out


def read_varint(data, i):
    shift = result = 0
    while True:
        b = data[i]
        i += 1
        result |= (b & 0x7F) << shift
        shift += 7
        if not b & 0x80:
            return result, i


def file_name(data):
    return hashlib.sha256(data).hexdigest()[:40]


# --- text definition -> files --------------------------------------------------------------------------------
def setting_id(name):
    """A setting is given by its name, or as id:0x... when the name is not known."""
    if name.startswith("id:"):
        return int(name[3:], 0)
    return zlib.crc32(name.encode())


def read_definition(path):
    """Return a list of steps: (slot name, [(setting, [values] or None for reset)])."""
    steps = []
    for lineno, raw in enumerate(Path(path).read_text(encoding="utf-8").splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        section = re.fullmatch(r"\[(\w+)\]", line)
        if section:
            if section.group(1) not in SLOTS:
                sys.exit(f"{path}:{lineno}: unknown section [{section.group(1)}]")
            steps.append((section.group(1), []))
            continue
        if "=" not in line or not steps:
            sys.exit(f"{path}:{lineno}: expected 'setting = value' inside a [section]")
        name, value = (s.strip() for s in line.split("=", 1))
        values = None if value == "reset" else [int(v.strip(), 0) for v in value.split(",")]
        steps[-1][1].append((name, values))
    return steps


def build(definition, outdir):
    steps = read_definition(definition)
    os.makedirs(os.path.join(outdir, "confseqs"), exist_ok=True)
    os.makedirs(os.path.join(outdir, "manifests"), exist_ok=True)
    for sub in ("confseqs", "manifests"):
        for f in os.listdir(os.path.join(outdir, sub)):
            os.remove(os.path.join(outdir, sub, f))

    manifest = field(1, b"v0.1") + field(2, PROFILE_NAME.encode()) + field(3, CARRIER_ID)
    for n, (slot, entries) in enumerate(steps, 1):
        step = field(1, b"v1.0") + field(2, f"{PROFILE_NAME}.{slot}.{n}".encode())
        for name, values in entries:
            body = field(1, setting_id(name))
            body += field(2, b"") if values is None else b"".join(field(2, field(3, v)) for v in values)
            step += field(4, body)
        step_name = file_name(step)
        with open(os.path.join(outdir, "confseqs", step_name), "wb") as f:
            f.write(step)
        entry = (field(1, SLOTS[slot]) if SLOTS[slot] else b"") + field(2, bytes.fromhex(step_name))
        manifest += field(5, entry)
        print(f"step {n}: [{slot}] {len(entries)} settings -> {step_name}")
    name = file_name(manifest)
    with open(os.path.join(outdir, "manifests", name), "wb") as f:
        f.write(manifest)
    print(f"manifest -> {name}")


# --- files -> text definition --------------------------------------------------------------------------------
def import_profile(srcdir, names_file):
    names = {}
    if names_file:
        for line in Path(names_file).read_text(encoding="utf-8", errors="replace").splitlines():
            line = line.strip()
            if line:
                names[zlib.crc32(line.encode())] = line
    slots = {v: k for k, v in SLOTS.items()}
    (manifest,) = os.listdir(os.path.join(srcdir, "manifests"))
    print(f"# imported from {os.path.basename(os.path.normpath(srcdir))}, manifest {manifest}")
    for num, entry in parse(Path(srcdir, "manifests", manifest).read_bytes()):
        if num != 5:
            continue
        fields = dict(parse(entry))
        step = Path(srcdir, "confseqs", fields[2].hex()).read_bytes()
        step_fields = parse(step)
        label = dict(step_fields).get(2, b"").decode()
        print(f"\n[{slots[fields.get(1)]}]  # was step '{label}'")
        for snum, svalue in step_fields:
            if snum != 4:
                continue
            item = parse(svalue)
            sid = dict(item)[1]
            values = [v for f, v in item if f == 2]
            if values == [b""]:
                text = "reset"
            else:
                ints = []
                for v in values:
                    sub = parse(v)
                    if len(sub) != 1 or sub[0][0] != 3:
                        sys.exit(f"setting {sid:#x}: unsupported value {v.hex()}")
                    ints.append(hex(sub[0][1]))
                text = ", ".join(ints)
            print(f"{names.get(sid, f'id:{sid:#010x}')} = {text}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("source", help="profile definition (.txt), or a directory with --import")
    ap.add_argument("outdir", nargs="?", help="output directory (build mode)")
    ap.add_argument("--import", dest="do_import", action="store_true", help="decode existing files into a definition")
    ap.add_argument("--names", help="file with known setting names, one per line (import mode)")
    args = ap.parse_args()
    if args.do_import:
        import_profile(args.source, args.names)
    elif args.outdir:
        build(args.source, args.outdir)
    else:
        ap.error("outdir is required to build a profile")


if __name__ == "__main__":
    main()
