#!/usr/bin/env bash
set -u

usage() {
	echo "usage: $0 [-s] GMOD_DIR name [name ...] -- COMPILER_COMMAND..." >&2
	echo "  GMOD_DIR          your GarrysMod folder (the one with garrysmod/ in it)" >&2
	echo "  COMPILER_COMMAND  the command you use to run ShaderCompile, e.g. 'ShaderCompile.exe'" >&2
	echo "  -s                add a timestamp to the name: <name>_<unix>.vcs" >&2
	exit 1
}

STAMP=0
if [ "${1:-}" = "-s" ]; then
	STAMP=1
	shift
fi

[ $# -ge 1 ] || usage
GMOD="$(cd "$1" 2>/dev/null && pwd)" || { echo "no such folder: $1" >&2; exit 1; }
shift

NAMES=()
while [ $# -gt 0 ] && [ "$1" != "--" ]; do
	NAMES+=("${1%.hlsl}")
	shift
done
[ "${1:-}" = "--" ] || usage
shift
COMPILER=("$@")
[ ${#NAMES[@]} -gt 0 ] && [ ${#COMPILER[@]} -gt 0 ] || usage

OUT="$GMOD/garrysmod/shaders/fxc"
SRC="$(cd "$(dirname "$0")" && pwd)/shaders"

[ -d "$GMOD/garrysmod" ] || { echo "$GMOD has no garrysmod folder" >&2; exit 1; }
mkdir -p "$OUT"

trap 'rmdir "$SRC/shaders/fxc" "$SRC/shaders" 2>/dev/null' EXIT

status=0
for name in "${NAMES[@]}"; do
	if [ ! -f "$SRC/$name.hlsl" ]; then
		echo "missing $SRC/$name.hlsl" >&2
		status=1
		continue
	fi

	built="$SRC/shaders/fxc/$name.vcs"
	rm -f "$built"
	log="$("${COMPILER[@]}" /O 3 -ver 30 -shaderpath "$SRC" "$SRC/$name.hlsl" 2>&1)"
	if [ ! -f "$built" ]; then
		echo "FAILED $name" >&2
		echo "$log" >&2
		status=1
		continue
	fi

	target="$name"
	[ $STAMP -eq 1 ] && target="${name}_$(date +%s)"
	mv "$built" "$OUT/$target.vcs"
	echo "$name -> $OUT/$target.vcs"
done

exit $status
