$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Get-NugetDll([string]$id,[string]$ver,[string]$dll) {
    $dir=Join-Path $env:TEMP ("mtpo_"+$id+"_"+$ver)
    $pkg=$dir+".nupkg"
    if(Test-Path $dir){Remove-Item $dir -Recurse -Force}
    if(Test-Path $pkg){Remove-Item $pkg -Force}
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Invoke-WebRequest -UseBasicParsing -Uri "https://www.nuget.org/api/v2/package/$id/$ver" -OutFile $pkg
    [System.IO.Compression.ZipFile]::ExtractToDirectory($pkg,$dir)
    $hits=@(Get-ChildItem -LiteralPath $dir -Recurse -File -Filter $dll)
    if($hits.Count -eq 0){throw "$dll não encontrado em $id $ver"}
    $preferred=@($hits | Where-Object {$_.FullName -match 'netstandard2\.0|net4'} | Select-Object -First 1)
    if($preferred.Count -gt 0){return $preferred[0].FullName}
    return $hits[0].FullName
}

$cw=Get-NugetDll 'CodeWalker.Core' '1.0.3' 'CodeWalker.Core.dll'
$sdx=Get-NugetDll 'SharpDX' '4.2.0' 'SharpDX.dll'
$sdxm=Get-NugetDll 'SharpDX.Mathematics' '4.2.0' 'SharpDX.Mathematics.dll'
[Reflection.Assembly]::LoadFrom($sdx) | Out-Null
[Reflection.Assembly]::LoadFrom($sdxm) | Out-Null
[Reflection.Assembly]::LoadFrom($cw) | Out-Null

$netstd=@(
 "$env:ProgramFiles(x86)\Reference Assemblies\Microsoft\Framework\.NETFramework\v4.8\Facades\netstandard.dll",
 "$env:ProgramFiles(x86)\Reference Assemblies\Microsoft\Framework\.NETFramework\v4.7.2\Facades\netstandard.dll",
 "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\Facades\netstandard.dll",
 "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\Facades\netstandard.dll"
) | Where-Object {Test-Path $_} | Select-Object -First 1
if(-not $netstd){$netstd=Get-NugetDll 'NETStandard.Library' '2.0.3' 'netstandard.dll'}

$source=Join-Path $PSScriptRoot '..\src\MT_Pack_Organizer.ps1'
$src=Get-Content -Raw -LiteralPath $source
if($src -notmatch "\$script:AppVersion = '0\.9\.13'"){throw 'A fonte não está em 0.9.13.'}

$marker='$builderCs=@'''
$start=$src.IndexOf($marker)
if($start -lt 0){throw 'Bloco C# do gerador YMT não encontrado.'}
$start += $marker.Length
while($start -lt $src.Length -and ($src[$start] -eq [char]13 -or $src[$start] -eq [char]10)){$start++}
$finish=$src.IndexOf([Environment]::NewLine+"'@",$start)
if($finish -lt 0){$finish=$src.IndexOf([char]10+"'@",$start)}
if($finish -lt 0){throw 'Fim do bloco C# do gerador YMT não encontrado.'}
$builderCs=$src.Substring($start,$finish-$start).TrimEnd([char]13,[char]10)

$refs=@($cw,$sdx,$sdxm,$netstd,'System.dll','System.Core.dll','System.Xml.dll','System.Xml.Linq.dll')
Add-Type -TypeDefinition $builderCs -Language CSharp -ReferencedAssemblies $refs -IgnoreWarnings

$component=New-Object MtAddonPiece
$component.TypeNumeric=8
$component.IsProp=$false
$component.Number=0
$component.TextureCount=2
$component.HasSkin=$false

$prop=New-Object MtAddonPiece
$prop.TypeNumeric=0
$prop.IsProp=$true
$prop.Number=0
$prop.TextureCount=2
$prop.EnableHairScale=$true
$prop.HairScaleValue=1.0

$pieces=New-Object 'System.Collections.Generic.List[MtAddonPiece]'
$pieces.Add($component)
$pieces.Add($prop)
$out=Join-Path $env:TEMP 'mt_pack_organizer_smoke.ymt'
if(Test-Path $out){Remove-Item $out -Force}
[MtAddonYmtBuilder]::Build($out,'mtstudio_smoke',$pieces.ToArray())

if(-not (Test-Path $out)){throw 'O gerador não criou o YMT de teste.'}
$size=(Get-Item $out).Length
if($size -lt 64){throw "YMT de teste inválido: $size bytes."}
Write-Host "OK - C# compilou contra CodeWalker.Core 1.0.3 e gerou YMT ($size bytes)."
