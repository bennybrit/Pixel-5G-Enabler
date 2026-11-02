#!/usr/bin/env python3
"""Build the installable module zip: dist/Pixel-5G-Enabler-<version>.zip

Steps: modem profiles (profiles/*.txt -> module/profiles/), the sqlite3 tool from the official
SQLite source (static, arm64, compiled with zig), then the zip (module files, LICENSE, NOTICE and the
license notices of what sqlite3 contains).
Needs: Python 3.8+, zig (on PATH or in the ZIG environment variable), internet for the first build.
"""
import hashlib
import os
import re
import shutil
import subprocess
import sys
import urllib.request
import zipfile
from pathlib import Path

ZIP_NAME = "Pixel-5G-Enabler"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODULE = os.path.join(ROOT, "module")
CACHE = os.path.join(ROOT, "build")

# Official SQLite amalgamation; sqlite.org publishes the SHA3-256 of each download.
SQLITE_URL = "https://www.sqlite.org/2026/sqlite-amalgamation-3540100.zip"
SQLITE_SHA3_256 = "92281c86e2957f9b9305890f9ac04204caa7b677cc868dc326d942689df28e30"
SQLITE_FLAGS = ["-O2", "-s", "-DSQLITE_THREADSAFE=0", "-DSQLITE_OMIT_LOAD_EXTENSION", "-DSQLITE_DEFAULT_MEMSTATUS=0"]

TEXT_FILES = (".sh", ".prop", ".conf", ".txt", ".md")
TEXT_NAMES = ("update-binary", "updater-script")


def build_profiles():
    sys.path.insert(0, os.path.dirname(__file__))
    import build_profile
    out = os.path.join(MODULE, "profiles")
    shutil.rmtree(out, ignore_errors=True)
    for name in sorted(os.listdir(os.path.join(ROOT, "profiles"))):
        if name.endswith(".txt"):
            family = name[:-4]
            print(f"profile {family}:")
            build_profile.build(os.path.join(ROOT, "profiles", name), os.path.join(out, family))


def find_zig():
    zig = os.environ.get("ZIG") or shutil.which("zig")
    if not zig:
        sys.exit("zig not found: install it (https://ziglang.org/download/) or set ZIG=/path/to/zig")
    return zig


def build_sqlite():
    target = os.path.join(MODULE, "bin", "sqlite3")
    archive = os.path.join(CACHE, os.path.basename(SQLITE_URL))
    os.makedirs(CACHE, exist_ok=True)
    if not os.path.exists(archive):
        print(f"downloading {SQLITE_URL}")
        urllib.request.urlretrieve(SQLITE_URL, archive)
    if hashlib.sha3_256(Path(archive).read_bytes()).hexdigest() != SQLITE_SHA3_256:
        sys.exit(f"{archive}: SHA3-256 does not match the pinned value")
    with zipfile.ZipFile(archive) as z:
        z.extractall(CACHE)
    src = os.path.join(CACHE, os.path.basename(SQLITE_URL)[:-4])
    os.makedirs(os.path.dirname(target), exist_ok=True)
    cmd = [find_zig(), "cc", "-target", "aarch64-linux-musl", "-static", *SQLITE_FLAGS, "-o", target,
           os.path.join(src, "shell.c"), os.path.join(src, "sqlite3.c")]
    print("compiling sqlite3 (arm64, static)")
    subprocess.run(cmd, check=True)


def third_party_notices():
    """Text for the zip: the static sqlite3 contains musl libc and Zig's runtime (both MIT); SQLite is public domain.
    The license texts come from the zig installation that compiled it."""
    env = subprocess.run([find_zig(), "env"], check=True, capture_output=True, text=True).stdout
    found = {key: re.search(rf'\b{key}"?\s*[=:]\s*"([^"]*)"', env) for key in ("lib_dir", "version")}   # ZON or JSON
    if not all(found.values()):
        sys.exit("zig env: lib_dir or version not found")
    lib_dir, zig_version = found["lib_dir"].group(1), found["version"].group(1)
    digits = re.search(r"-(\d)(\d\d)(\d\d)\d\d\.zip$", SQLITE_URL).groups()    # 3540100 -> 3.54.1
    text = (f"Third-party software in bin/sqlite3\n\n"
            f"bin/sqlite3 is the SQLite {'.'.join(str(int(d)) for d in digits)} command-line program "
            f"(https://sqlite.org), compiled with Zig {zig_version}\ninto a static arm64 program. SQLite is in the "
            f"public domain (https://sqlite.org/copyright.html). The program\nalso contains parts of musl libc and "
            f"of Zig's runtime library, under the licenses below.\n")
    for title, path in (("musl libc", os.path.join(lib_dir, "libc", "musl", "COPYRIGHT")),
                        ("Zig", os.path.join(os.path.dirname(lib_dir), "LICENSE"))):
        if not os.path.isfile(path):
            sys.exit(f"{path} not found: its text goes into the zip with sqlite3")
        text += f"\n\n{title}\n{'=' * len(title)}\n\n{Path(path).read_text(encoding='utf-8').strip()}\n"
    return text


def build_zip():
    prop_lines = Path(MODULE, "module.prop").read_text(encoding="utf-8").splitlines()
    props = dict(line.strip().split("=", 1) for line in prop_lines if "=" in line)
    notices = third_party_notices()
    os.makedirs(os.path.join(ROOT, "dist"), exist_ok=True)
    out = os.path.join(ROOT, "dist", f"{ZIP_NAME}-{props['version']}.zip")
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for folder, _, files in os.walk(MODULE):
            for name in sorted(files):
                path = os.path.join(folder, name)
                arc = os.path.relpath(path, MODULE).replace(os.sep, "/")
                data = Path(path).read_bytes()
                if name.endswith(TEXT_FILES) or name in TEXT_NAMES:
                    data = data.replace(b"\r\n", b"\n")      # Android shells need LF line endings
                z.writestr(arc, data)
        for name in ("LICENSE", "NOTICE"):                    # the license travels with every copy of the zip
            z.writestr(name, Path(ROOT, name).read_bytes())
        z.writestr("THIRD-PARTY-NOTICES.txt", notices)
    print(f"built {out} ({os.path.getsize(out)} bytes)")


if __name__ == "__main__":
    build_profiles()
    build_sqlite()
    build_zip()
