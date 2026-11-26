import lzma
import re
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

USAGE = "usage: build.py [-o OUT_DIR] [name ...] -- FXC_COMMAND..."

ROOT = Path(__file__).resolve().parent.parent
SHADERS = ROOT / "shaders"
NATIVE = SHADERS / "dx12"

INCLUDE = re.compile(r'^[ \t]*#include[ \t]+"([^"]+)"', re.M)
COMMENTS = re.compile(r"//[^\n]*|/\*.*?\*/", re.S)
ENTRY = re.compile(r"\b(\w+)\s+main\s*\(([^)]*)\)\s*(?::\s*(\w+))?\s*\{")
STRUCT = r"\bstruct\s+{}\s*\{{([^}}]*)\}}"
FIELD = re.compile(r"(\w+)\s+(\w+)\s*:\s*(\w+)\s*;")
PARAM = re.compile(r"\s*(?:in\s+)?(\w+)\s+(\w+)\s*(?::\s*(\w+))?\s*")
SAMPLER = re.compile(r"(\bsampler\w*\s+\w+\s*:\s*register\s*\(\s*s(\d+)\s*\))")
TEXCOORD = re.compile(r"TEXCOORD(\d*)")
STAGE = re.compile(r"^(.+)_(ps|vs)\d+\w*$")
WIDTH = {"float": 1, "float2": 2, "float3": 3, "float4": 4}
SWIZZLE = {1: ".x", 2: ".xy", 3: ".xyz", 4: ""}


class Unsupported(Exception):
	pass


def flatten(path, seen=None):
	seen = seen if seen is not None else set()
	if path in seen:
		return ""
	seen.add(path)
	text = COMMENTS.sub("", path.read_text())

	return INCLUDE.sub(lambda m: flatten(SHADERS / m.group(1), seen), text)


def struct_fields(text, name):
	found = re.findall(STRUCT.format(re.escape(name)), text)
	if len(found) != 1:
		raise Unsupported(f"struct {name} is defined {len(found)} times")

	return FIELD.findall(found[0])


def width(type_name):
	if type_name not in WIDTH:
		raise Unsupported(f"unsupported varying type {type_name}")

	return WIDTH[type_name]


def texcoord(semantic):
	m = TEXCOORD.fullmatch(semantic.upper())
	if not m:
		raise Unsupported(f"unsupported varying semantic {semantic}")

	return int(m.group(1) or 0)


def pixel_wrapper(text, ret, params, semantic):
	used, lines, args = set(), [], []

	def source(type_name, sem):
		w = width(type_name)
		if sem.upper() == "VPOS":
			return f"(s.sm3_pos{SWIZZLE[w]} - 0.5)"
		n = texcoord(sem)
		used.add(n)
		return f"s.sm3_t{n}{SWIZZLE[w]}"

	for param in filter(str.strip, params.split(",")):
		m = PARAM.fullmatch(param)
		if not m:
			raise Unsupported(f"cannot parse parameter '{param.strip()}'")
		type_name, name, sem = m.groups()
		if sem:
			args.append(source(type_name, sem))
			continue
		lines.append(f"\t{type_name} {name};")
		for field_type, field, field_sem in struct_fields(text, type_name):
			lines.append(f"\t{name}.{field} = {source(field_type, field_sem)};")
		args.append(name)

	inputs = ["\tfloat4 sm3_pos : SV_Position;"]
	inputs += [f"\tfloat4 sm3_t{n} : TEXCOORD{n};" for n in range(max(used) + 1 if used else 0)]
	head = f"{ret} main(SM3_PS_IN s)" + (f" : {semantic}" if semantic else "")

	return "\n".join([
		"struct SM3_PS_IN", "{", *inputs, "};", "",
		head, "{", *lines, f"\treturn sm3_main({', '.join(args)});", "}", "",
	])


def vertex_wrapper(text, ret, params):
	names = []
	for param in filter(str.strip, params.split(",")):
		m = PARAM.fullmatch(param)
		if not m:
			raise Unsupported(f"cannot parse parameter '{param.strip()}'")
		names.append(m.group(2))

	used, lines = set(), []
	for field_type, field, sem in struct_fields(text, ret):
		w = width(field_type)
		if sem.upper() in ("POSITION", "POSITION0"):
			lines.append(f"\to.sm3_pos{SWIZZLE[w]} = r.{field};")
			continue
		n = texcoord(sem)
		used.add(n)
		lines.append(f"\to.sm3_t{n}{SWIZZLE[w]} = r.{field};")

	outputs = ["\tfloat4 sm3_pos : SV_Position;"]
	outputs += [f"\tfloat4 sm3_t{n} : TEXCOORD{n};" for n in range(max(used) + 1 if used else 0)]

	return "\n".join([
		"struct SM3_VS_OUT", "{", *outputs, "};", "",
		f"SM3_VS_OUT main({params.strip()})", "{",
		f"\t{ret} r = sm3_main({', '.join(names)});",
		"\tSM3_VS_OUT o = (SM3_VS_OUT)0;", *lines, "\treturn o;", "}", "",
	])


def wrapped_source(path, stage):
	text = flatten(path)
	entries = ENTRY.findall(text)
	if len(entries) != 1:
		raise Unsupported(f"found {len(entries)} entry points")
	ret, params, semantic = entries[0]

	if stage == "ps":
		wrapper = pixel_wrapper(text, ret, params, semantic)
	else:
		wrapper = vertex_wrapper(text, ret, params)

	return f'#define DX12\n#define main sm3_main\n#include "{path.name}"\n#undef main\n\n{wrapper}'


def pack(container):
	if container[:4] != b"DXBC":
		raise Unsupported("compiler output is not a DXBC container")

	payload = struct.pack("<II", 0, len(container)) + container
	dict_size = 1 << 24
	filters = [{"id": lzma.FILTER_LZMA1, "lc": 3, "lp": 0, "pb": 2, "dict_size": dict_size}]
	packed = lzma.compress(payload, format=lzma.FORMAT_RAW, filters=filters)
	props = bytes([(2 * 5 + 0) * 9 + 3]) + struct.pack("<I", dict_size)
	block = b"LZMA" + struct.pack("<II", len(payload), len(packed)) + props + packed

	end = 0x34 + len(block) + 4
	header = struct.pack("<7I", 6, 1, 1, 0, 0, 2, 0)
	records = struct.pack("<IIIII", 0, 0x30, 0xFFFFFFFF, end, 0)
	combo = struct.pack("<I", len(block) | 0x40000000)

	return header + records + combo + block + b"\xff\xff\xff\xff"


def parse_args(argv):
	if "--" not in argv:
		sys.exit(USAGE)
	split = argv.index("--")
	args, compiler = argv[:split], argv[split + 1:]
	if not compiler:
		sys.exit(USAGE)

	out = SHADERS / "fxc"
	if args[:1] == ["-o"]:
		if len(args) < 2:
			sys.exit(USAGE)
		out = Path(args[1])
		args = args[2:]

	return out, [a.removesuffix(".hlsl") for a in args], compiler


def jobs(names):
	found = {}
	for path in sorted(SHADERS.glob("*.hlsl")):
		m = STAGE.match(path.stem)
		if m:
			found[f"{m.group(1)}_{m.group(2)}64"] = (path, m.group(2), True)
	for path in sorted(NATIVE.glob("*.hlsl")):
		m = STAGE.match(path.stem)
		if m:
			found[f"{m.group(1)}_{m.group(2)}64"] = (path, m.group(2), False)

	if not names:
		return found

	selected = {}
	for name in names:
		match = {k: v for k, v in found.items() if name in (k, v[0].stem)}
		if not match:
			print(f"no shader source named {name}", file=sys.stderr)
		selected.update(match)

	return selected


def main():
	out, names, compiler = parse_args(sys.argv[1:])
	out.mkdir(parents=True, exist_ok=True)
	selected = jobs(names)
	status = 0 if selected else 1

	with tempfile.TemporaryDirectory() as tmp:
		tmp = Path(tmp)
		shutil.copytree(SHADERS, tmp, dirs_exist_ok=True, ignore=shutil.ignore_patterns("fxc", "dx12"))
		for path in tmp.rglob("*.hlsl"):
			path.write_text(SAMPLER.sub(r"\1 : register(t\2)", path.read_text()))
		for path in NATIVE.glob("*.hlsl"):
			shutil.copy(path, tmp / f"native_{path.name}")

		for target, (path, stage, translate) in sorted(selected.items()):
			try:
				if translate:
					source = f"dx12_{path.name}"
					(tmp / source).write_text(wrapped_source(path, stage))
				else:
					source = f"native_{path.name}"
			except Unsupported as e:
				print(f"SKIPPED {path.stem}: {e}", file=sys.stderr)
				status = 1
				continue

			built = tmp / f"{target}.dxbc"
			proc = subprocess.run([*compiler, "/nologo", "/Gec", "/O3", "/T", f"{stage}_5_0", "/E", "main", "/Fo", built.name, source], cwd=tmp, capture_output=True, text=True, errors="replace")
			if proc.returncode != 0 or not built.exists():
				log = "\n".join(l for l in (proc.stdout + proc.stderr).splitlines() if "error" in l.lower())
				print(f"FAILED {path.stem}\n{log}", file=sys.stderr)
				status = 1
				continue

			try:
				data = pack(built.read_bytes())
			except Unsupported as e:
				print(f"FAILED {path.stem}: {e}", file=sys.stderr)
				status = 1
				continue

			(out / f"{target}.vcs").write_bytes(data)
			print(f"{path.stem} -> {out / target}.vcs")

	sys.exit(status)


main()
