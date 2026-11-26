import json
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from pathlib import Path

RED, YELLOW, GREEN, RESET = "\033[1;31m", "\033[1;33m", "\033[1;32m", "\033[0m"

source = Path(sys.argv[1] if len(sys.argv) > 1 else "shaders")
textures = Path(sys.argv[2] if len(sys.argv) > 2 else "materials")
report = sys.argv[3] if len(sys.argv) > 3 else "junit.xml"

STAGES = {"ps": "pixel shader", "vs": "vertex shader"}


def stage(path):
	if path.suffix == ".vtf":
		return "texture"
	suffix = path.stem.rsplit("_", 1)[-1]
	return STAGES.get(suffix[:2], "shader")


def check(file):
	start = time.monotonic()
	verify = ["--verify", str(source / "fxc")] if file.suffix == ".hlsl" else []
	proc = subprocess.run(["gm_shadercompat", "--format", "json", "--patch-togl", *verify, str(file)], stdout=subprocess.PIPE, text=True)
	elapsed = time.monotonic() - start
	lines = [json.loads(line) for line in proc.stdout.splitlines() if line.strip()]
	diagnostics = [l for l in lines if l["type"] == "diagnostic"]
	status = next((l["status"] for l in lines if l["type"] in ("shader", "texture")), "error")
	summary = next((l for l in lines if l["type"] == "summary"), {})
	if file.suffix != ".vtf" and not summary.get("glsl_compiled"):
		status = "error"
		diagnostics.append({"code": "glslang", "rendered": "error[glslang]: glslangValidator did not run, install glslang-tools\n"})
	return status, diagnostics, elapsed


suite = ET.Element("testsuite", name="shaders")
counts = {"ok": 0, "fail": 0, "error": 0}
warnings = 0
printed = set()
total = 0.0


def record(name, file, status, diagnostics, elapsed):
	global total, warnings
	counts[status] += 1
	total += elapsed
	case = ET.SubElement(suite, "testcase", classname=stage(file), name=name, file=str(file), time=f"{elapsed:.3f}")

	for d in diagnostics:
		if d.get("level") == "warning":
			warnings += 1
		if d["rendered"] in printed:
			continue
		printed.add(d["rendered"])
		head, _, body = d["rendered"].partition("\n")
		if status == "error":
			print(f"{RED}{head}{RESET}\n{body}")
		else:
			print(f"{YELLOW}{head.replace('error', 'warning', 1)}{RESET}\n{body}")

	if status == "ok":
		return
	kind = "error" if status == "error" else "failure"
	message = ", ".join(sorted({d["code"] for d in diagnostics})) or status
	ET.SubElement(case, kind, type=message, message=message).text = "\n".join(d["rendered"] for d in diagnostics)


for file in sorted(source.glob("*.hlsl")):
	record(file.stem, file, *check(file))

for file in sorted((source / "fxc").glob("*.vcs")):
	if file.stem.endswith(("_ps64", "_vs64")):
		continue
	record(f"{file.stem} (togl)", file, *check(file))

for file in sorted(textures.rglob("*.vtf")):
	record(str(file.relative_to(textures).with_suffix("")), file, *check(file))

files = sum(counts.values())
suite.set("tests", str(files))
suite.set("failures", str(counts["fail"]))
suite.set("errors", str(counts["error"]))
suite.set("time", f"{total:.3f}")
ET.ElementTree(suite).write(report, encoding="utf-8", xml_declaration=True)

if counts["error"]:
	print(f"{RED}error: {counts['error']} of {files} files failed to compile or could not be checked{RESET}")
if counts["fail"]:
	print(f"{YELLOW}warning: ToGL translation failed for {counts['fail']} of {files} files{RESET}")
if warnings:
	print(f"{YELLOW}warning: {warnings} texture warnings{RESET}")
if not counts["error"] and not counts["fail"]:
	print(f"{GREEN}ok: {files} files compile and translate{RESET}")
sys.exit(2 if counts["error"] else 1 if counts["fail"] else 0)
