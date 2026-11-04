#!/usr/bin/env python3
"""Checks a built ModelThumbs.app before it is installed.

usage: verify.py <ModelThumbs.app>
       verify.py --malformed-only <renderer binary>

Bundle checks: signatures, extension sandbox entitlements, no references to libraries
outside the bundle or the OS, and no networking or process-launching imports.
Render checks: every sample must render, and every malformed file must be rejected
cleanly. The renderer runs under sandbox-exec with no network and no writes outside a
temporary folder.
"""
import os
import plistlib
import struct
import subprocess
import sys
import tempfile
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
EXT = "Contents/PlugIns/ModelThumbsThumbnailer.appex"
PREVIEW = "Contents/PlugIns/ModelThumbsPreviewer.appex"
EXPECTED_ENTITLEMENTS = {"com.apple.security.app-sandbox": True,
                         "com.apple.security.files.user-selected.read-only": True}
FORBIDDEN = {"_socket", "_connect", "_getaddrinfo", "_posix_spawn", "_posix_spawnp", "_execve", "_execv",
             "_execvp", "_fork", "_vfork", "_system", "_popen", "_dlopen", "_dlsym",
             "_OBJC_CLASS_$_NSURLSession", "_OBJC_CLASS_$_NSURLConnection", "_OBJC_CLASS_$_NSTask",
             "_OBJC_CLASS_$_NSAppleScript"}
# The host app's "Refresh thumbnails" button runs qlmanage and killall.
ALLOWED = {"ModelThumbs": {"_OBJC_CLASS_$_NSTask"}}
# True: must be rejected with an error. False: either outcome is fine, but no crash.
MALFORMED = {"badcolors.3mf": False, "bomb.3mf": True, "hugeqoi.bgcode": True, "truncqoi.gcode": True,
             "negoffset.gltf": True, "negstride.gltf": True, "scalarpos.gltf": True,
             "traversal.gltf": True, "negsize.pcd": True, "shortbody.pcd": True, "trunc.ply": False}
failures = []


def report(ok, label, detail=""):
    print(f"  {'ok  ' if ok else 'FAIL'}  {label}{': ' + detail if detail else ''}")
    if not ok:
        failures.append(label)


def out(*args):
    return subprocess.run(args, capture_output=True, text=True, check=True).stdout


def check_bundle(app):
    print("Bundle")
    ext = os.path.join(app, EXT)
    preview = os.path.join(app, PREVIEW)
    binaries = {"ModelThumbs": os.path.join(app, "Contents/MacOS/ModelThumbs"),
                "modelthumbs-render": os.path.join(app, "Contents/MacOS/modelthumbs-render"),
                "ModelThumbsThumbnailer": os.path.join(ext, "Contents/MacOS/ModelThumbsThumbnailer"),
                "ModelThumbsPreviewer": os.path.join(preview, "Contents/MacOS/ModelThumbsPreviewer")}
    for path in (ext, preview, app):
        result = subprocess.run(["codesign", "--verify", "--strict", path], capture_output=True, text=True)
        report(result.returncode == 0, f"signature {os.path.basename(path)}", result.stderr.strip())

    for path in (ext, preview):
        xml = subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", path], capture_output=True).stdout
        entitlements = plistlib.loads(xml) if xml else {}
        report(entitlements == EXPECTED_ENTITLEMENTS, f"{os.path.basename(path)} is sandboxed, read-only, no network",
               "" if entitlements == EXPECTED_ENTITLEMENTS else str(entitlements))

    frameworks = os.path.join(ext, "Contents/Frameworks")
    libs = [os.path.join(frameworks, n) for n in sorted(os.listdir(frameworks))] if os.path.isdir(frameworks) else []
    outside = []
    for path in list(binaries.values()) + libs:
        for line in out("otool", "-L", path).splitlines()[1:]:
            ref = line.strip().split(" (compatibility")[0]
            if not ref.startswith(("/usr/lib/", "/System/", "@rpath/", "@executable_path/", "@loader_path/")):
                outside.append(f"{os.path.basename(path)} -> {ref}")
    report(not outside, f"libraries stay inside the bundle or the OS ({len(libs)} bundled)", "; ".join(outside[:5]))

    missing = []
    for name, path in binaries.items():
        base = os.path.dirname(path)
        lines = out("otool", "-l", path).splitlines()
        rpaths = [lines[i + 2].strip().split()[1] for i, l in enumerate(lines) if "LC_RPATH" in l]
        dirs = [r.replace("@executable_path", base).replace("@loader_path", base) for r in rpaths]
        for line in out("otool", "-L", path).splitlines()[1:]:
            ref = line.strip().split(" (compatibility")[0]
            if ref.startswith("@rpath/") and not ref.startswith("@rpath/libswift"):
                lib = ref[len("@rpath/"):]
                if not any(os.path.exists(os.path.join(d, lib)) for d in dirs):
                    missing.append(f"{name} -> {lib}")
    report(not missing, "bundled libraries resolve from each binary", "; ".join(missing[:5]))

    for name, path in binaries.items():
        imports = set(out("nm", "-u", path).split())
        bad = (imports & FORBIDDEN) - ALLOWED.get(name, set())
        report(not bad, f"no network or process imports in {name}", ", ".join(sorted(bad)))
    return binaries["modelthumbs-render"], bool(libs)


def sandboxed(renderer, workdir, source, dest, timeout=120):
    profile = ('(version 1)(allow default)(deny network*)(deny file-write*)'
               f'(allow file-write* (subpath "{workdir}") (literal "/dev/null") (subpath "/dev/fd"))')
    return subprocess.run(["sandbox-exec", "-p", profile, renderer, source, dest, "256"],
                          capture_output=True, text=True, timeout=timeout)


def crashed(result):
    return result.returncode < 0 or result.returncode >= 128


def has_content(path):
    """False for a missing or fully transparent PNG. A blank render is still a valid file."""
    if not os.path.exists(path):
        return False
    with open(path, "rb") as f:
        data = f.read()
    if not data.startswith(b"\x89PNG"):
        return len(data) > 0  # embedded JPEG preview
    pos, idat = 8, b""
    while pos + 8 <= len(data):
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        if kind == b"IDAT":
            idat += data[pos + 8:pos + 8 + length]
        pos += 12 + length
    return any(zlib.decompress(idat))


def check_samples(renderer, workdir, has_cad):
    print("Samples")
    samples = os.path.join(ROOT, "Samples")
    for name in sorted(os.listdir(samples)):
        if name.endswith((".step", ".igs")) and not has_cad:
            print(f"  skip  {name} (built without CAD)")
            continue
        dest = os.path.join(workdir, name + ".png")
        result = sandboxed(renderer, workdir, os.path.join(samples, name), dest)
        ok = result.returncode == 0 and has_content(dest)
        report(ok, name, "" if ok else f"exit {result.returncode}, blank or missing image {result.stderr.strip()[:120]}")


def check_malformed(renderer, workdir):
    print("Malformed files")
    models = os.path.join(workdir, "models")
    subprocess.run([sys.executable, "-I", os.path.join(ROOT, "Tests/make_malformed.py"), workdir], check=True)
    for name, must_fail in sorted(MALFORMED.items()):
        result = sandboxed(renderer, workdir, os.path.join(models, name), os.path.join(workdir, name + ".png"))
        ok = not crashed(result) and (result.returncode != 0 or not must_fail)
        report(ok, name, f"exit {result.returncode} {result.stderr.strip()[:100]}")
    # A buffer beside the model must keep working now that traversal is blocked.
    result = sandboxed(renderer, workdir, os.path.join(models, "sibling.gltf"), os.path.join(workdir, "sibling.png"))
    report(result.returncode == 0, "sibling.gltf", f"exit {result.returncode} {result.stderr.strip()[:100]}")


def main():
    args = sys.argv[1:]
    malformed_only = "--malformed-only" in args
    args = [a for a in args if a != "--malformed-only"]
    if len(args) != 1 or not os.path.exists(args[0]):
        sys.exit("Nothing to verify. Run: make build")
    with tempfile.TemporaryDirectory() as tmp:
        workdir = os.path.realpath(tmp)
        if malformed_only:
            check_malformed(os.path.abspath(args[0]), workdir)
        else:
            renderer, has_cad = check_bundle(args[0])
            renderer = os.path.abspath(renderer)
            check_samples(renderer, workdir, has_cad)
            check_malformed(renderer, workdir)
    if failures:
        sys.exit(f"\n{len(failures)} check(s) failed. Don't install this build.")
    print("\nAll checks passed.")


if __name__ == "__main__":
    main()
