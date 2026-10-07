<#
.SYNOPSIS
    Detects the engine of an installed game, decompiles / unpacks it with the
    appropriate open-source tools, and builds an AI-friendly study bundle.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\extract.ps1
    powershell -ExecutionPolicy Bypass -File .\extract.ps1 -GameDir "E:\Games\Slots and Daggers" -OutDir .\out

.NOTES
    Output contains copyrighted game code/assets. Keep it local / private.
#>
[CmdletBinding()]
param(
    [string]$GameDir = "D:\Steam\steamapps\common\Slots and Daggers",
    [string]$OutDir  = "",                # default: .\sd_extract next to this script
    [switch]$SkipTools,          # only inventory + bundle, no downloads/decompile
    [int]$MaxBundleMB = 40       # cap for ALL_SOURCE.txt
)

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# $PSScriptRoot is empty inside param() defaults on Windows PowerShell 5.1.
if (-not $OutDir) {
    $base = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    $OutDir = Join-Path $base "sd_extract"
}
if (-not (Test-Path $GameDir)) { throw "Game directory not found: $GameDir" }
$GameDir = (Resolve-Path $GameDir).Path
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$OutDir   = (Resolve-Path $OutDir).Path
$ToolsDir = Join-Path $OutDir "_tools"
$SrcDir   = Join-Path $OutDir "decompiled"
$LogFile  = Join-Path $OutDir "extract.log"
New-Item -ItemType Directory -Force -Path $ToolsDir, $SrcDir | Out-Null

function Log($msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $msg
    Write-Host $line
    Add-Content -Path $LogFile -Value $line
}

function Get-GitHubReleaseAsset {
    param([string]$Repo, [string]$Pattern, [string]$Dest)
    if (Test-Path $Dest) { return $Dest }
    Log "Fetching latest release of $Repo ..."
    $rel   = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest" -Headers @{ "User-Agent" = "sd-extract" }
    $asset = $rel.assets | Where-Object { $_.name -match $Pattern } | Select-Object -First 1
    if (-not $asset) { throw "No asset matching '$Pattern' in $Repo $($rel.tag_name)" }
    $zip = Join-Path $ToolsDir $asset.name
    Invoke-WebRequest $asset.browser_download_url -OutFile $zip
    if ($zip -like "*.zip") {
        Expand-Archive -Path $zip -DestinationPath $Dest -Force
    } else {
        New-Item -ItemType Directory -Force -Path $Dest | Out-Null
        Copy-Item $zip $Dest
    }
    return $Dest
}

# ---------------------------------------------------------------------------
# 1. Inventory
# ---------------------------------------------------------------------------
Log "Inventorying $GameDir"
$files = Get-ChildItem -Path $GameDir -Recurse -File -Force
$files | ForEach-Object {
    [pscustomobject]@{
        RelPath = $_.FullName.Substring($GameDir.Length + 1)
        Bytes   = $_.Length
        SHA256  = (Get-FileHash $_.FullName -Algorithm SHA256).Hash
    }
} | Export-Csv (Join-Path $OutDir "inventory.csv") -NoTypeInformation
$files | ForEach-Object { $_.FullName.Substring($GameDir.Length + 1) } |
    Set-Content (Join-Path $OutDir "file_tree.txt")

# ---------------------------------------------------------------------------
# 2. Engine detection
# ---------------------------------------------------------------------------
function Find-First($filter) { $files | Where-Object { $_.Name -like $filter } | Select-Object -First 1 }

$exe = $files | Where-Object { $_.Extension -eq ".exe" -and $_.Name -notmatch "UnityCrashHandler|crashpad|unins" } |
       Sort-Object Length -Descending | Select-Object -First 1

$engine = "unknown"
if     (Find-First "global-metadata.dat")                   { $engine = "unity-il2cpp" }
elseif (Find-First "Assembly-CSharp.dll")                   { $engine = "unity-mono" }
elseif (Find-First "*.pck")                                 { $engine = "godot" }
elseif (Find-First "data.win")                              { $engine = "gamemaker" }
elseif (Find-First "app.asar")                              { $engine = "electron" }
elseif ($files | Where-Object { $_.Extension -eq ".pak" -and $_.FullName -match "Content\\Paks" }) { $engine = "unreal" }
elseif ((Find-First "*.rgss*a") -or (Find-First "*.rpgmvp")) { $engine = "rpgmaker" }
elseif ($exe) {
    # Godot can embed the .pck in the exe; Love2D appends a zip.
    $bytes = [IO.File]::ReadAllBytes($exe.FullName)
    $tail  = [Text.Encoding]::ASCII.GetString($bytes, [Math]::Max(0, $bytes.Length - 64), [Math]::Min(64, $bytes.Length))
    $ascii = [Text.Encoding]::ASCII.GetString($bytes)
    if     ($tail -match "GDPC" -or $ascii.Contains("GDPC"))  { $engine = "godot-embedded" }
    elseif ($ascii.Contains("love.boot") -or $ascii.Contains("LOVE")) { $engine = "love2d" }
    elseif ($ascii.Contains("Godot Engine"))                 { $engine = "godot-embedded" }
    elseif ($ascii.Contains("GameMaker"))                    { $engine = "gamemaker" }
}
Log "Detected engine: $engine"
Set-Content (Join-Path $OutDir "engine.txt") $engine

# ---------------------------------------------------------------------------
# 3. Decompile / unpack
# ---------------------------------------------------------------------------
$manual = New-Object System.Collections.Generic.List[string]

if (-not $SkipTools) {
    try {
        switch -Wildcard ($engine) {
            "godot*" {
                $gdre = Get-GitHubReleaseAsset "GDRETools/gdsdecomp" "windows.*\.zip$" (Join-Path $ToolsDir "gdre")
                $gdreExe = Get-ChildItem $gdre -Recurse -Filter "gdre_tools*.exe" | Select-Object -First 1
                $pck = Find-First "*.pck"
                $target = if ($pck) { $pck.FullName } else { $exe.FullName }
                Log "Recovering Godot project from $target"
                & $gdreExe.FullName --headless "--recover=$target" "--output=$SrcDir" 2>&1 | Tee-Object -Append $LogFile
            }
            "unity-mono" {
                if (-not (Get-Command ilspycmd -ErrorAction SilentlyContinue)) {
                    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
                        throw "dotnet SDK not found. Install .NET 8 SDK (winget install Microsoft.DotNet.SDK.8) and re-run."
                    }
                    Log "Installing ilspycmd"
                    dotnet tool install -g ilspycmd | Tee-Object -Append $LogFile
                    $env:PATH += ";$env:USERPROFILE\.dotnet\tools"
                }
                $managed = (Find-First "Assembly-CSharp.dll").DirectoryName
                $skip = '^(System|Mono|mscorlib|netstandard|UnityEngine|Unity\.|Microsoft|Newtonsoft|DOTween|Sirenix|TextMeshPro)'
                Get-ChildItem $managed -Filter *.dll | Where-Object { $_.BaseName -notmatch $skip } | ForEach-Object {
                    $dst = Join-Path $SrcDir $_.BaseName
                    Log "ILSpy -> $($_.Name)"
                    ilspycmd -p -o $dst $_.FullName 2>&1 | Tee-Object -Append $LogFile
                }
                $manual.Add("Assets (sprites/audio/scenes): open the game folder in AssetRipper GUI (github.com/AssetRipper/AssetRipper) and export to $OutDir\assets")
            }
            "unity-il2cpp" {
                $dumper = Get-GitHubReleaseAsset "Perfare/Il2CppDumper" "win.*\.zip$" (Join-Path $ToolsDir "il2cppdumper")
                $dumperExe = Get-ChildItem $dumper -Recurse -Filter "Il2CppDumper.exe" | Select-Object -First 1
                $meta = Find-First "global-metadata.dat"
                $ga   = Find-First "GameAssembly.dll"
                $dst  = Join-Path $SrcDir "il2cpp_dump"
                New-Item -ItemType Directory -Force -Path $dst | Out-Null
                Log "Il2CppDumper"
                "`n" | & $dumperExe.FullName $ga.FullName $meta.FullName $dst 2>&1 | Tee-Object -Append $LogFile
                $manual.Add("IL2CPP gives signatures only (dump.cs, DummyDll). Method bodies need Ghidra/IDA + il2cpp script.json from $dst.")
                $manual.Add("Assets: AssetRipper GUI on the game folder.")
            }
            "gamemaker" {
                $manual.Add("GameMaker: open data.win in UndertaleModTool (github.com/UnderminersTeam/UndertaleModTool), run Scripts > Resource Exporters > ExportAllCode.csx and ExportAllSprites.csx into $SrcDir, then re-run this script with -SkipTools.")
            }
            "electron" {
                $asar = Find-First "app.asar"
                Log "Extracting app.asar"
                npx --yes @electron/asar extract $asar.FullName (Join-Path $SrcDir "app") 2>&1 | Tee-Object -Append $LogFile
            }
            "love2d" {
                Add-Type -AssemblyName System.IO.Compression.FileSystem
                Log "Extracting appended .love zip"
                [IO.Compression.ZipFile]::ExtractToDirectory($exe.FullName, (Join-Path $SrcDir "love"))
            }
            "unreal" {
                $manual.Add("Unreal: open Content\Paks with FModel (fmodel.app). Blueprint logic needs UAssetGUI / KismetKompiler; native code needs Ghidra on the exe.")
            }
            "rpgmaker" {
                $manual.Add("RPG Maker: use RPGMakerDecrypter (github.com/uuksu/RPGMakerDecrypter) on the .rgss archive into $SrcDir.")
            }
            default {
                $manual.Add("Engine not recognised. Check file_tree.txt; for native code, load the main exe into Ghidra.")
            }
        }
    } catch {
        Log "Tool step failed: $_"
        $manual.Add("Automatic decompile failed ($_). See extract.log.")
    }
}

# ---------------------------------------------------------------------------
# 4. Study bundle for another AI
# ---------------------------------------------------------------------------
Log "Building study bundle"
$codeExt = '\.(cs|gd|gdshader|shader|tscn|tres|godot|cfg|json|lua|js|ts|gml|yy|ini|xml|csv|txt|py|hlsl|glsl)$'
$srcFiles = Get-ChildItem $SrcDir -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match $codeExt -and $_.FullName -notmatch '\\(\.godot|\.import|obj|bin)\\' -and $_.Length -lt 2MB }

$bundle = Join-Path $OutDir "ALL_SOURCE.txt"
$sb = New-Object System.Text.StringBuilder
$index = foreach ($f in ($srcFiles | Sort-Object FullName)) {
    $rel  = $f.FullName.Substring($SrcDir.Length + 1)
    $text = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
    if ($null -eq $text) { continue }
    $lines = ($text -split "`n").Count
    if ($sb.Length + $text.Length -lt $MaxBundleMB * 1MB) {
        [void]$sb.AppendLine("`n===== FILE: $rel ($lines lines) =====")
        [void]$sb.AppendLine($text)
    }
    [pscustomobject]@{ File = $rel; Lines = $lines; Bytes = $f.Length }
}
[IO.File]::WriteAllText($bundle, $sb.ToString())
$index | Export-Csv (Join-Path $OutDir "source_index.csv") -NoTypeInformation

# Keyword hits that usually point to core game logic of a slot-machine roguelike.
$keywords = 'reel|spin|symbol|slot|payline|jackpot|damage|shield|heal|potion|spell|enemy|boss|relic|item|upgrade|gold|coin|rng|random|seed|level|shop|save'
$hits = $srcFiles | Select-String -Pattern $keywords -AllMatches -ErrorAction SilentlyContinue |
    Group-Object Path | Sort-Object Count -Descending | Select-Object -First 40

$top = ($hits | ForEach-Object { "| {0} | {1} |" -f $_.Name.Substring($SrcDir.Length + 1), $_.Count }) -join "`n"
$ext = ($files | Group-Object Extension | Sort-Object Count -Descending | Select-Object -First 20 |
        ForEach-Object { "| {0} | {1} |" -f ($(if ($_.Name) { $_.Name } else { "(none)" })), $_.Count }) -join "`n"
$todo = if ($manual.Count) { ($manual | ForEach-Object { "- $_" }) -join "`n" } else { "- none" }

@"
# Slots & Daggers: Reverse-Engineering Study Bundle

Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm")
Source:    $GameDir
Engine:    **$engine**
Main exe:  $($exe.Name)

## Contents of this folder
| Path | What |
|---|---|
| file_tree.txt / inventory.csv | Every shipped file, size, SHA256 |
| decompiled/ | Output of the decompiler/unpacker |
| source_index.csv | Every recovered source/data file with line counts |
| ALL_SOURCE.txt | All recovered text sources concatenated (capped at $MaxBundleMB MB); give this to the AI |
| extract.log | Full tool output |

## Shipped file types
| Ext | Count |
|---|---|
$ext

## Files most likely to hold core game logic
(ranked by hits for: $keywords)

| File | Hits |
|---|---|
$top

## Manual steps remaining
$todo

## Suggested prompt for the studying AI
> You are given ALL_SOURCE.txt, the decompiled source of the roguelike slot-machine game
> "Slots & Daggers" ($engine). Map the architecture: entry point / scene flow, the reel/spin
> resolution algorithm (symbol weights, paylines, combos), combat & damage formulas, enemy AI,
> item/relic/upgrade system, economy, RNG and seeding, save format. Cite file names for every claim,
> and list data tables (symbols, enemies, items) as structured JSON.
"@ | Set-Content (Join-Path $OutDir "STUDY_GUIDE.md") -Encoding UTF8

Log "Done. Open $OutDir\STUDY_GUIDE.md"
