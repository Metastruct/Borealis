param(
	[Parameter(Mandatory)][string]$GmodDir,
	[Parameter(Mandatory)][string[]]$Names,
	[Parameter(Mandatory)][string[]]$Compiler,
	[switch]$Stamp
)

$src = Join-Path $PSScriptRoot "shaders"
$out = Join-Path $GmodDir "garrysmod/shaders/fxc"
$built = Join-Path $src "shaders/fxc"

if (-not (Test-Path (Join-Path $GmodDir "garrysmod") -PathType Container)) {
	Write-Host "$GmodDir has no garrysmod folder"
	exit 1
}

New-Item -ItemType Directory -Force -Path $out | Out-Null

$exe = $Compiler[0]
$exeArgs = @($Compiler | Select-Object -Skip 1)
$status = 0

try {
	foreach ($n in $Names) {
		$name = $n -replace '\.hlsl$', ''
		$hlsl = Join-Path $src "$name.hlsl"
		if (-not (Test-Path $hlsl -PathType Leaf)) {
			Write-Host "missing $hlsl"
			$status = 1
			continue
		}

		$vcs = Join-Path $built "$name.vcs"
		Remove-Item $vcs -ErrorAction SilentlyContinue
		$log = & $exe @exeArgs /O 3 -ver 30 -shaderpath $src $hlsl 2>&1 | Out-String
		if (-not (Test-Path $vcs)) {
			Write-Host "FAILED $name"
			Write-Host $log
			$status = 1
			continue
		}

		$target = $name
		if ($Stamp) { $target = "${name}_$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())" }
		$dest = Join-Path $out "$target.vcs"
		Move-Item -Force $vcs $dest
		Write-Host "$name -> $dest"
	}
}
finally {
	foreach ($dir in @($built, (Join-Path $src "shaders"))) {
		if ((Test-Path $dir) -and -not (Get-ChildItem $dir -Force)) { Remove-Item $dir }
	}
}

exit $status
