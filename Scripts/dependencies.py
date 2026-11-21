"""Prepare pinned Tree-sitter sources and the ripgrep helper for an Xcode build."""
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / ".vendor"
CACHE.mkdir(exist_ok=True)
LOCK = json.loads(Path(__file__).with_name("dependencies.json").read_text())
ARCHS = os.environ.get("ARCHS", os.uname().machine).split()

def fetch(item):
    name, url, checksum = item
    dest = CACHE / (name + "-" + checksum.split(":", 1)[1][:16])
    if dest.exists():
        return name, dest
    with tempfile.TemporaryDirectory(dir=CACHE) as tmp:
        archive = Path(tmp) / "archive"
        subprocess.run(["curl", "-fsSL", "--retry", "3", url, "-o", archive], check=True)
        algorithm, expected = checksum.split(":", 1)
        actual = hashlib.new(algorithm, archive.read_bytes()).hexdigest()
        if actual != expected:
            raise ValueError(f"Checksum mismatch: {name}")
        extracted = Path(tmp) / "unpacked"
        extracted.mkdir()
        subprocess.run(["/usr/bin/tar", "-xf", archive, "-C", extracted], check=True)
        entries = list(extracted.iterdir())
        root = entries[0] if len(entries) == 1 and entries[0].is_dir() else extracted
        root.rename(dest)
    return name, dest

def run(*args):
    subprocess.run(args, check=True)

items = [item for item in LOCK if not item[0].startswith("rg-") or item[0][3:] in ARCHS]
with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
    sources = dict(pool.map(fetch, items))

core = sources["tree-sitter"] / "vendor/tree-sitter/lib"
includes = CACHE / "include"
includes.mkdir(exist_ok=True)
shutil.copy2(core / "include/tree_sitter/api.h", includes / "api.h")
libraries = []
for arch in ARCHS:
    obj = CACHE / arch
    obj.mkdir(exist_ok=True)
    jobs = [("runtime", core / "src/lib.c")]
    for name, path in sources.items():
        if name.startswith("rg-") or name == "tree-sitter":
            continue
        for file in path.rglob("src/parser.c"):
            grammar = file.parent.parent
            lang = name if grammar == path else grammar.name
            for src in [file, file.with_name("scanner.c")]:
                if src.exists():
                    jobs.append((lang + "-" + src.stem, src))
    def compile_job(job):
        stem, src = job
        out = obj / (stem + ".o")
        if not out.exists() or out.stat().st_mtime < Path(__file__).with_name("dependencies.json").stat().st_mtime:
            run("xcrun", "clang", "-arch", arch, "-mmacosx-version-min=14.0", "-O2", "-w",
                "-I", src.parent, "-I", core / "include", "-c", src, "-o", out)
        return out
    with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
        objects = list(pool.map(compile_job, jobs))
    library = obj / "libSyntax.a"
    if not library.exists() or any(p.stat().st_mtime > library.stat().st_mtime for p in objects):
        run("xcrun", "libtool", "-static", "-o", library, *objects)
    libraries.append(library)

def combine(inputs, output):
    stamp = output.with_suffix(".inputs")
    signature = str([(str(p), p.stat().st_mtime_ns) for p in inputs])
    if output.exists() and stamp.exists() and stamp.read_text() == signature:
        return
    if len(inputs) == 1:
        shutil.copy2(inputs[0], output)
    else:
        run("lipo", "-create", *inputs, "-output", output)
    stamp.write_text(signature)

combine(libraries, CACHE / "libSyntax.a")
combine([sources["rg-" + a] / "rg" for a in ARCHS], CACHE / "rg")
licenses = CACHE / "Licenses"
licenses.mkdir(exist_ok=True)
for name, directory in sources.items():
    for license_file in directory.glob("LICENSE*"):
        if license_file.is_file():
            shutil.copy2(license_file, licenses / (name + "-" + license_file.name))
