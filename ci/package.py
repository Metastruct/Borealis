import fnmatch
import json
import struct
import subprocess
import sys
import time
import zlib
from pathlib import Path

USAGE = "usage: package.py <out.gma>"

WHITELIST = [
	"lua/*.lua",
	"scenes/*.vcd",
	"particles/*.pcf",
	"resource/fonts/*.ttf",
	"scripts/vehicles/*.txt",
	"resource/localization/*/*.properties",
	"maps/*.bsp",
	"maps/*.lmp",
	"maps/*.nav",
	"maps/*.ain",
	"maps/thumb/*.png",
	"sound/*.wav",
	"sound/*.mp3",
	"sound/*.ogg",
	"materials/*.vmt",
	"materials/*.vtf",
	"materials/*.png",
	"materials/*.jpg",
	"materials/*.jpeg",
	"materials/colorcorrection/*.raw",
	"models/*.mdl",
	"models/*.phy",
	"models/*.ani",
	"models/*.vvd",
	"models/*.vtx",
	"data_static/*.txt",
	"data_static/*.dat",
	"data_static/*.json",
	"data_static/*.xml",
	"data_static/*.csv",
	"shaders/fxc/*.vcs",
]

NOTICES = [
	("fonts-OFL.txt", "fonts-OFL.txt"),
]

TITLE = "Borealis"
DESCRIPTION = {
	"description": "Description",
	"type": "effects",
	"tags": ["scenic", "realism"],
}


def cstr(text):
	return text.encode() + b"\0"


if len(sys.argv) != 2:
	sys.exit(USAGE)

root = Path(__file__).resolve().parent.parent
out = Path(sys.argv[1]).resolve()

files = subprocess.run(["git", "ls-files", "-z"], cwd=root, stdout=subprocess.PIPE, check=True).stdout.decode().split("\0")
contents, skipped = {}, []
for name in filter(None, files):
	if any(fnmatch.fnmatchcase(name, pattern) for pattern in WHITELIST):
		contents[name] = (root / name).read_bytes()
	else:
		skipped.append(name)

for source, target in NOTICES:
	contents["data_static/borealis/" + target] = (root / source).read_bytes()

entries = sorted((name.lower(), data) for name, data in contents.items())

gma = bytearray(b"GMAD")
gma += struct.pack("<BQQB", 3, 0, int(time.time()), 0)
gma += cstr(TITLE) + cstr(json.dumps(DESCRIPTION, indent="\t")) + cstr("Author Name")
gma += struct.pack("<i", 1)
for index, (name, data) in enumerate(entries, 1):
	gma += struct.pack("<I", index) + cstr(name) + struct.pack("<qI", len(data), zlib.crc32(data))
gma += struct.pack("<I", 0)
for _, data in entries:
	gma += data
gma += struct.pack("<I", zlib.crc32(gma))

out.parent.mkdir(parents=True, exist_ok=True)
out.write_bytes(gma)

print(f"{out}: {len(entries)} files, {len(gma) / 1048576:.1f} MB")
print(f"left out {len(skipped)} files: {', '.join(n for n in skipped if not n.endswith('.hlsl'))} and the HLSL sources")
