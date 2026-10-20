<#
.SYNOPSIS
    Package the ADO Work Map VS Code extension as a .vsix, using only Windows PowerShell 5.1.

.DESCRIPTION
    Copies the current ado_work_map.ps1 into the extension, then writes the .vsix
    (a zip with an OPC manifest) the same way the official vsce tool lays it out.
    No Node.js needed.

.EXAMPLE
    .\vscode-extension\build.ps1
    Writes vscode-extension\ado-work-map-<version>.vsix
#>
param([string]$OutFile)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$ext = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent $ext
$pkg = Get-Content (Join-Path $ext 'package.json') -Raw | ConvertFrom-Json
if (-not $OutFile) { $OutFile = Join-Path $ext "$($pkg.name)-$($pkg.version).vsix" }

# Bundle the script and license
[void](New-Item -ItemType Directory -Force -Path (Join-Path $ext 'resources'))
Copy-Item (Join-Path $repo 'ado_work_map.ps1') (Join-Path $ext 'resources\ado_work_map.ps1') -Force
Copy-Item (Join-Path $repo 'LICENSE') (Join-Path $ext 'LICENSE.txt') -Force

$files = @('package.json', 'extension.js', 'README.md', 'CHANGELOG.md', 'LICENSE.txt', 'media/icon.png', 'media/activity.svg', 'resources/ado_work_map.ps1')
foreach ($f in $files) { if (-not (Test-Path (Join-Path $ext $f))) { throw "Missing $f" } }

$esc = { param($s) [Security.SecurityElement]::Escape([string]$s) }
$manifest = @"
<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011" xmlns:d="http://schemas.microsoft.com/developer/vsx-schema-design/2011">
  <Metadata>
    <Identity Language="en-US" Id="$($pkg.name)" Version="$($pkg.version)" Publisher="$($pkg.publisher)" />
    <DisplayName>$(& $esc $pkg.displayName)</DisplayName>
    <Description xml:space="preserve">$(& $esc $pkg.description)</Description>
    <Tags>$(& $esc (($pkg.keywords + 'vscode-extension') -join ','))</Tags>
    <Categories>$(& $esc ($pkg.categories -join ','))</Categories>
    <GalleryFlags>Public</GalleryFlags>
    <Properties>
      <Property Id="Microsoft.VisualStudio.Code.Engine" Value="$($pkg.engines.vscode)" />
      <Property Id="Microsoft.VisualStudio.Code.ExtensionDependencies" Value="" />
      <Property Id="Microsoft.VisualStudio.Code.ExtensionPack" Value="" />
      <Property Id="Microsoft.VisualStudio.Code.ExtensionKind" Value="$($pkg.extensionKind -join ',')" />
      <Property Id="Microsoft.VisualStudio.Code.LocalizedLanguages" Value="" />
      <Property Id="Microsoft.VisualStudio.Services.Links.Source" Value="$($pkg.repository.url)" />
      <Property Id="Microsoft.VisualStudio.Services.Links.Getstarted" Value="$($pkg.repository.url)" />
      <Property Id="Microsoft.VisualStudio.Services.Links.GitHub" Value="$($pkg.repository.url)" />
      <Property Id="Microsoft.VisualStudio.Services.Links.Support" Value="$($pkg.bugs.url)" />
      <Property Id="Microsoft.VisualStudio.Services.Links.Learn" Value="$($pkg.homepage)" />
      <Property Id="Microsoft.VisualStudio.Services.GitHubFlavoredMarkdown" Value="true" />
      <Property Id="Microsoft.VisualStudio.Services.Content.Pricing" Value="Free" />
    </Properties>
    <License>extension/LICENSE.txt</License>
    <Icon>extension/media/icon.png</Icon>
  </Metadata>
  <Installation>
    <InstallationTarget Id="Microsoft.VisualStudio.Code" />
  </Installation>
  <Dependencies />
  <Assets>
    <Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true" />
    <Asset Type="Microsoft.VisualStudio.Services.Content.Details" Path="extension/README.md" Addressable="true" />
    <Asset Type="Microsoft.VisualStudio.Services.Content.Changelog" Path="extension/CHANGELOG.md" Addressable="true" />
    <Asset Type="Microsoft.VisualStudio.Services.Content.License" Path="extension/LICENSE.txt" Addressable="true" />
    <Asset Type="Microsoft.VisualStudio.Services.Icons.Default" Path="extension/media/icon.png" Addressable="true" />
  </Assets>
</PackageManifest>
"@
$types = @'
<?xml version="1.0" encoding="utf-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension=".json" ContentType="application/json" /><Default Extension=".vsixmanifest" ContentType="text/xml" /><Default Extension=".js" ContentType="application/javascript" /><Default Extension=".md" ContentType="text/markdown" /><Default Extension=".png" ContentType="image/png" /><Default Extension=".svg" ContentType="image/svg+xml" /><Default Extension=".ps1" ContentType="text/plain" /><Default Extension=".txt" ContentType="text/plain" /></Types>
'@

if (Test-Path $OutFile) { Remove-Item $OutFile -Force }
$zip = [IO.Compression.ZipFile]::Open($OutFile, 'Create')
try {
    $utf8 = New-Object Text.UTF8Encoding $false
    $addText = { param($name, $text) $e = $zip.CreateEntry($name); $w = New-Object IO.StreamWriter($e.Open(), $utf8); $w.Write($text); $w.Dispose() }
    & $addText 'extension.vsixmanifest' $manifest
    & $addText '[Content_Types].xml' $types
    foreach ($f in $files) {
        # Entry names always use forward slashes (VS Code's installer expects them)
        [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, (Join-Path $ext $f), "extension/$f")
    }
}
finally { $zip.Dispose() }
"{0} ({1:N0} KB)" -f $OutFile, ((Get-Item $OutFile).Length / 1KB)
