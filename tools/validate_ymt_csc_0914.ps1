$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
function Get-Dll([string]$id,[string]$ver,[string]$dll){
  $d=Join-Path $env:TEMP ("cv_"+$id+"_"+$ver); $p=$d+".nupkg"
  if(Test-Path $d){Remove-Item $d -Recurse -Force}; if(Test-Path $p){Remove-Item $p -Force}
  New-Item -ItemType Directory -Force -Path $d|Out-Null
  Invoke-WebRequest -UseBasicParsing -Uri "https://www.nuget.org/api/v2/package/$id/$ver" -OutFile $p
  [IO.Compression.ZipFile]::ExtractToDirectory($p,$d)
  $h=@(Get-ChildItem $d -Recurse -File -Filter $dll)
  if(!$h){throw "$dll ausente"}
  $q=@($h|Where-Object{$_.FullName -match 'netstandard2\.0|net4'}|Select-Object -First 1)
  if($q){return $q[0].FullName}; return $h[0].FullName
}
$cw=Get-Dll 'CodeWalker.Core' '1.0.3' 'CodeWalker.Core.dll'
$sdx=Get-Dll 'SharpDX' '4.2.0' 'SharpDX.dll'
$sdxm=Get-Dll 'SharpDX.Mathematics' '4.2.0' 'SharpDX.Mathematics.dll'
$netstd=Get-ChildItem -Path 'C:\Program Files (x86)\Reference Assemblies\Microsoft\Framework\.NETFramework' -Recurse -File -Filter netstandard.dll -ErrorAction SilentlyContinue|Sort-Object FullName -Descending|Select-Object -First 1 -ExpandProperty FullName
if(!$netstd){throw 'Facade netstandard ausente'}
$src=Get-Content -Raw (Join-Path $PSScriptRoot '..\src\MT_Pack_Organizer_0.9.14.ps1')
$m='$builderCs=@'''; $a=$src.IndexOf($m); if($a -lt 0){throw 'builder ausente'}; $a+=$m.Length
while($src[$a] -eq [char]13 -or $src[$a] -eq [char]10){$a++}
$b=$src.IndexOf([Environment]::NewLine+"'@",$a); if($b -lt 0){$b=$src.IndexOf([char]10+"'@",$a)}
$cs=$src.Substring($a,$b-$a).TrimEnd([char]13,[char]10)
$csfile=Join-Path $env:TEMP 'mtpo_builder.cs'; $dll=Join-Path $env:TEMP 'mtpo_builder.dll'
[IO.File]::WriteAllText($csfile,$cs,(New-Object Text.UTF8Encoding($false)))
$csc="$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if(!(Test-Path $csc)){$csc="$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"}
& $csc /nologo /target:library "/out:$dll" "/reference:$cw" "/reference:$sdx" "/reference:$sdxm" "/reference:$netstd" $csfile
if($LASTEXITCODE -ne 0){throw "C# inválido: $LASTEXITCODE"}
[Reflection.Assembly]::LoadFrom($sdx)|Out-Null
[Reflection.Assembly]::LoadFrom($sdxm)|Out-Null
[Reflection.Assembly]::LoadFrom($cw)|Out-Null
[Reflection.Assembly]::LoadFrom($dll)|Out-Null
$c=New-Object MtAddonPiece; $c.TypeNumeric=8; $c.IsProp=$false; $c.Number=0; $c.TextureCount=2
$p=New-Object MtAddonPiece; $p.TypeNumeric=0; $p.IsProp=$true; $p.Number=0; $p.TextureCount=2; $p.EnableHairScale=$true; $p.HairScaleValue=1
$list=New-Object 'System.Collections.Generic.List[MtAddonPiece]'; $list.Add($c); $list.Add($p)
$out=Join-Path $env:TEMP 'mtpo_smoke.ymt'; if(Test-Path $out){Remove-Item $out -Force}
[MtAddonYmtBuilder]::Build($out,'mtstudio_smoke',$list.ToArray())
if(!(Test-Path $out) -or (Get-Item $out).Length -lt 64){throw 'YMT smoke inválido'}
Write-Host "YMT real gerado: $((Get-Item $out).Length) bytes"
