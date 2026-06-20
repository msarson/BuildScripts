#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Build automation script for Accura Clarion project
.DESCRIPTION
    Fetches latest changes, switches to the highest version branch, and configures TPS or SQL mode
.PARAMETER Mode
    Database mode: TPS or SQL (case insensitive). If not specified, will prompt user.
.PARAMETER DebugBuild
    Pass -DebugBuild to compile in Debug mode. Default is Release.
    If a project fails in Debug (e.g. CLW too large), it will automatically retry in Release.
.EXAMPLE
    .\build.ps1 -Mode TPS
.EXAMPLE
    .\build.ps1 -Mode SQL -BuildConfig Debug
.EXAMPLE
    .\build.ps1
#>

[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [ValidateSet('TPS', 'SQL', 'tps', 'sql', 'Tps', 'Sql', IgnoreCase=$true)]
    [string]$Mode,
    
    [Parameter()]
    [switch]$ImportApps,
    
    [Parameter()]
    [switch]$GenerateAll,
    
    [Parameter()]
    [switch]$BuildAll,
    
    [Parameter()]
    [switch]$GenerateBuildAll,
    
    [Parameter()]
    [switch]$SkipGitOperations,  # Skip git operations (for CI/Jenkins)

    [Parameter()]
    [switch]$DebugBuild,  # Pass -DebugBuild for debug mode; default is Release

    [Parameter()]
    [string]$ClarionPath  # Explicit Clarion path (CI). When set, skips config.json/prompt.
)

$ErrorActionPreference = "Stop"

# Colors for output
function Write-Info { param($Message) Write-Host "i  $Message" -ForegroundColor Cyan }
function Write-Success { param($Message) Write-Host "+ $Message" -ForegroundColor Green }
function Write-Warning { param($Message) Write-Host "!  $Message" -ForegroundColor Yellow }
function Write-Error-Custom { param($Message) Write-Host "X $Message" -ForegroundColor Red }

# Load or create configuration
function Get-BuildConfig {
    $configPath = Join-Path $PSScriptRoot "config.json"
    
    if (Test-Path $configPath) {
        try {
            return Get-Content $configPath | ConvertFrom-Json
        } catch {
            Write-Warning "Failed to read config.json: $_"
            return $null
        }
    }
    return $null
}

function Save-BuildConfig {
    param($Config)
    $configPath = Join-Path $PSScriptRoot "config.json"
    $Config | ConvertTo-Json | Set-Content $configPath
    Write-Success "Configuration saved to config.json"
}

function Get-Clarion10Path {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Mode
    )
    
    $config = Get-BuildConfig
    
    # Try mode-specific path first (new config structure)
    if ($config -and $config.clarion10Paths -and $config.clarion10Paths.$Mode) {
        return $config.clarion10Paths.$Mode
    }
    
    # Fallback to legacy single path (backward compatibility)
    if ($config -and $config.clarion10Path) {
        return $config.clarion10Path
    }
    
    # Prompt user for path
    Write-Host "`n--- Clarion10 Repository Configuration ---" -ForegroundColor Yellow
    Write-Info "The Clarion10 IDE repository is required for building"
    Write-Info "Repository: https://github.com/accuramis/Clarion10"
    
    do {
        $path = Read-Host "`nEnter the local path where Clarion10 repository should be located"
        $path = $path.Trim('"').Trim("'")
        
        if ([string]::IsNullOrWhiteSpace($path)) {
            Write-Warning "Path cannot be empty"
            continue
        }
        
        # Save configuration
        $newConfig = @{
            clarion10Path = $path
        }
        Save-BuildConfig $newConfig
        return $path
        
    } while ($true)
}

function Get-VcOutputFolder {
    param([string]$SolutionDir)
    # up_vcSettings.ini is gitignored and only exists where the Clarion VC interface
    # has run, so a clean/concurrent workspace (e.g. AccuraBuild@2) may not have it.
    # Fall back to the conventional relative folder rather than failing the build.
    $default = "vcDevelopment"
    if ([string]::IsNullOrWhiteSpace($SolutionDir)) {
        Write-Warning "  Get-VcOutputFolder: no solution dir supplied; using default '$default'"
        return $default
    }
    $ini = Join-Path $SolutionDir "up_vcSettings.ini"
    if (-not (Test-Path $ini)) {
        Write-Warning "  up_vcSettings.ini not found in '$SolutionDir'; using default VC output folder '$default'"
        return $default
    }
    Write-Info "  Reading VC settings from: $ini"
    $line = Get-Content $ini | Where-Object { $_ -match '^OutputFolder\s*=' } | Select-Object -First 1
    $folder = if ($line) { ($line -split '=', 2)[1].Trim() } else { '' }
    if (-not $folder) {
        Write-Warning "  OutputFolder missing/empty in '$ini'; using default '$default'"
        return $default
    }
    Write-Info "  VC OutputFolder: $folder"
    return $folder
}

function Get-SolutionApps {
    param([string]$SolutionFile)

    $solutionDir = Split-Path $SolutionFile -Parent
    if (-not $solutionDir) {
        # Bare filename (no directory component) -- resolve against current working dir
        $solutionDir = (Get-Location).Path
    }
    Write-Info "  Solution file: $SolutionFile"
    Write-Info "  Solution directory: $solutionDir"
    $vcBase = Get-VcOutputFolder $solutionDir

    $apps = @()
    Get-Content $SolutionFile | ForEach-Object {
        if ($_ -match 'Project\(".*?"\)\s*=\s*"(.*?)",\s*"(.*?\.cwproj)"') {
            $appName = $Matches[1]
            $projectFile = $Matches[2]
            
            # Add app (we'll create .app files during import)
            $appFile = $appName + ".app"
            $apps += [PSCustomObject]@{
                Name = $appName
                AppFile = $appFile
                ProjectFile = $projectFile
                VCFolder = Join-Path $vcBase $appName
            }
        }
    }
    return $apps
}

function Setup-ModeSpecificConfig {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Mode,
        [Parameter(Mandatory=$true)]
        [string]$ClarionPath,
        [switch]$DebugBuild
    )
    
    $baseConfigDir = "$PSScriptRoot\ClarionConfig"
    # Put config in workspace so it's isolated per build and never shared between TPS/SQL
    $modeConfigDir = Join-Path (Get-Location) "ClarionConfig"

    # Always recreate fresh to prevent ClarionCL appending and bloating the file
    if (Test-Path $modeConfigDir) {
        Remove-Item $modeConfigDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $modeConfigDir -Force | Out-Null

    # Resolve the base ClarionProperties.xml. The real file carries the Clarion
    # license SERIAL, which must never be committed to the (public) repo - so it is
    # gitignored and only the placeholder .example template is tracked. Priority:
    #   1. This location's real file (local run from C:\BuildScripts)
    #   2. The machine-provisioned licensed config (env CLARION_CONFIG_XML, else the
    #      conventional C:\BuildScripts copy) - used when running from a fresh checkout
    #   3. The .example template - has a placeholder serial, so Clarion licensing WILL
    #      fail; last resort only, with a clear warning.
    $sourceXml = Join-Path $baseConfigDir "ClarionProperties.xml"
    if (-not (Test-Path $sourceXml)) {
        $machineXml = if ($env:CLARION_CONFIG_XML) { $env:CLARION_CONFIG_XML } else { "C:\BuildScripts\ClarionConfig\ClarionProperties.xml" }
        if (Test-Path $machineXml) {
            $sourceXml = $machineXml
        } else {
            $sourceXml = Join-Path $baseConfigDir "ClarionProperties.xml.example"
            Write-Warning "  No licensed ClarionProperties.xml found ($machineXml); using placeholder template - Clarion licensing will fail. Provision the license on this agent."
        }
    }
    $destXml = Join-Path $modeConfigDir "ClarionProperties.xml"
    Copy-Item $sourceXml $destXml -Force
    Write-Info "  Created fresh ClarionConfig in workspace (base: $sourceXml)"
    
    # Update ClarionProperties.xml with correct version path
    $propsFile = Join-Path $modeConfigDir "ClarionProperties.xml"
    
    if (Test-Path $propsFile) {
        Write-Info "Updating ClarionProperties.xml for $Mode mode..."
        
        # Read the XML
        [xml]$xml = Get-Content $propsFile
        
        # Resolve Clarion path (may be relative like ..\Clarion)
        $resolvedClarionPath = if ([System.IO.Path]::IsPathRooted($ClarionPath)) {
            $ClarionPath
        } else {
            # Resolve relative to current working directory, not script location
            Join-Path (Get-Location) $ClarionPath | Resolve-Path | Select-Object -ExpandProperty Path
        }
        
        # Find or create the Clarion.Versions section
        $versionsNode = $xml.ClarionProperties.Properties | Where-Object { $_.name -eq "Clarion.Versions" }
        
        if ($versionsNode) {
            # Get Clarion version info
            $clarionBinPath = Join-Path $resolvedClarionPath "bin"
            $clarionExe = Join-Path $clarionBinPath "Clarion.exe"
            
            if (Test-Path $clarionExe) {
                $versionInfo = (Get-Item $clarionExe).VersionInfo
                $versionString = "Clarion $($versionInfo.ProductVersion)"
                
                Write-Info "  Setting Clarion version: $versionString"
                Write-Info "  Path: $clarionBinPath"
                
                # Remove all existing Clarion version nodes
                $versionsNode.Properties | ForEach-Object {
                    $versionsNode.RemoveChild($_) | Out-Null
                }
                
                # Create new version node
                $versionNode = $xml.CreateElement("Properties")
                $versionNode.SetAttribute("name", $versionString)
                
                # Add path
                $pathNode = $xml.CreateElement("path")
                $pathNode.SetAttribute("value", $clarionBinPath)
                $versionNode.AppendChild($pathNode) | Out-Null
                
                # Add IsWindowsVersion
                $isWinNode = $xml.CreateElement("IsWindowsVersion")
                $isWinNode.SetAttribute("value", "True")
                $versionNode.AppendChild($isWinNode) | Out-Null
                
                # Add IsClarion62
                $isC62Node = $xml.CreateElement("IsClarion62")
                $isC62Node.SetAttribute("value", "False")
                $versionNode.AppendChild($isC62Node) | Out-Null
                
                # Add RedirectionFile section
                $redirNode = $xml.CreateElement("Properties")
                $redirNode.SetAttribute("name", "RedirectionFile")
                
                $nameNode = $xml.CreateElement("Name")
                $nameNode.SetAttribute("value", "Clarion100.red")
                $redirNode.AppendChild($nameNode) | Out-Null
                
                $supportsNode = $xml.CreateElement("SupportsInclude")
                $supportsNode.SetAttribute("value", "True")
                $redirNode.AppendChild($supportsNode) | Out-Null
                
                # Add Macros
                $macrosNode = $xml.CreateElement("Properties")
                $macrosNode.SetAttribute("name", "Macros")
                
                $rootNode = $xml.CreateElement("root")
                $rootNode.SetAttribute("value", $ClarionPath)
                $macrosNode.AppendChild($rootNode) | Out-Null
                
                $reddirNode = $xml.CreateElement("reddir")
                $reddirNode.SetAttribute("value", $clarionBinPath)
                $macrosNode.AppendChild($reddirNode) | Out-Null
                
                $redirNode.AppendChild($macrosNode) | Out-Null
                $versionNode.AppendChild($redirNode) | Out-Null
                
                # Add libsrc
                $libsrcPath = "$ClarionPath\libsrc\win;$ClarionPath\Accessory\libsrc\win"
                $libsrcNode = $xml.CreateElement("libsrc")
                $libsrcNode.SetAttribute("value", $libsrcPath)
                $versionNode.AppendChild($libsrcNode) | Out-Null
                
                # Add Compilers section
                $compilersNode = $xml.CreateElement("Properties")
                $compilersNode.SetAttribute("name", "Compilers")
                
                $clwNode = $xml.CreateElement("clw")
                $clwNode.SetAttribute("value", "Claclw.dll")
                $compilersNode.AppendChild($clwNode) | Out-Null
                
                $cppNode = $xml.CreateElement("cpp")
                $cppNode.SetAttribute("value", "Clacpp.dll")
                $compilersNode.AppendChild($cppNode) | Out-Null
                
                $versionNode.AppendChild($compilersNode) | Out-Null
                
                # Add the version node to versions section
                $versionsNode.AppendChild($versionNode) | Out-Null
                
                # Save the XML
                $xml.Save($propsFile)
                Write-Success "  Updated ClarionProperties.xml"
            } else {
                Write-Warning "  Clarion.exe not found at: $clarionExe"
            }
        } else {
            Write-Warning "  Clarion.Versions section not found in XML"
        }
    } else {
        Write-Warning "  ClarionProperties.xml not found at: $propsFile"
    }
    
    # Set UseReleaseAsDefault so ClarionCL generation respects the Debug configuration
    # This controls Win32App.BuildingDebug which gates %ApplicationDebug in templates (e.g. DEBUGHOOK)
    $useRelease = if ($DebugBuild) { 'False' } else { 'True' }
    $propsXml = [xml](Get-Content $propsFile)
    $node = $propsXml.SelectSingleNode("//SharpDevelop.UseReleaseAsDefault")
    if ($node) {
        $node.SetAttribute("value", $useRelease)
    } else {
        $newNode = $propsXml.CreateElement("SharpDevelop.UseReleaseAsDefault")
        $newNode.SetAttribute("value", $useRelease)
        $propsXml.DocumentElement.AppendChild($newNode) | Out-Null
    }
    $propsXml.Save($propsFile)
    Write-Info "  Set SharpDevelop.UseReleaseAsDefault = $useRelease"

    # Ensure the template Registry option "Reregister templates if changed" is ON
    # (Tools > Application Options > Registry tab). Without it, ClarionCL will not
    # re-register a template that has changed on disk, so generation can run against
    # a stale registered template chain and emit out-of-date source.
    $regXml = [xml](Get-Content $propsFile)
    $registryNode = $regXml.SelectSingleNode("//Properties[@name='Registry']")
    if (-not $registryNode) {
        $registryNode = $regXml.CreateElement("Properties")
        $registryNode.SetAttribute("name", "Registry")
        $regXml.DocumentElement.AppendChild($registryNode) | Out-Null
    }
    $reregNode = $registryNode.SelectSingleNode("Reregister_if_changed")
    if (-not $reregNode) {
        $reregNode = $regXml.CreateElement("Reregister_if_changed")
        $registryNode.AppendChild($reregNode) | Out-Null
    }
    $reregNode.SetAttribute("value", "on")
    $regXml.Save($propsFile)
    Write-Info "  Set Registry > Reregister_if_changed = on"

    return $modeConfigDir
}

function Get-TemplateCacheKey {
    param(
        [string]$ClarionPath,
        [string]$TemplatePatchDir
    )

    # Get Clarion repo commit SHA
    $clarionSHA = git -C $ClarionPath rev-parse HEAD 2>$null
    if (-not $clarionSHA) { return $null }

    # Hash contents of any template patches (file names + last-write times)
    $patchHash = ""
    if (Test-Path $TemplatePatchDir) {
        $patches = Get-ChildItem $TemplatePatchDir -Filter "*.tpl" | Sort-Object Name
        if ($patches.Count -gt 0) {
            $patchString = ($patches | ForEach-Object { "$($_.Name)=$($_.LastWriteTimeUtc.Ticks)" }) -join ";"
            $patchHash = [System.BitConverter]::ToString(
                [System.Security.Cryptography.MD5]::Create().ComputeHash(
                    [System.Text.Encoding]::UTF8.GetBytes($patchString)
                )
            ).Replace("-","").Substring(0,8)
        }
    }

    return "$clarionSHA|$patchHash"
}

function Register-Templates {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ClarionPath,
        [Parameter(Mandatory=$true)]
        [string]$ConfigDir
    )
    
    # Resolve relative path if needed
    if (-not [System.IO.Path]::IsPathRooted($ClarionPath)) {
        $ClarionPath = Join-Path (Get-Location) $ClarionPath
        $ClarionPath = [System.IO.Path]::GetFullPath($ClarionPath)
    }
    
    $trfFile   = Join-Path $ClarionPath "template\win\TemplateRegistry10.trf"
    $cacheFile = Join-Path $ClarionPath "template\win\.trf-cache-key"

    # Keep the TRF warm across builds. *.trf is gitignored in the Clarion repo and the
    # Clarion checkout is never reset/cleaned, so the registry persists between builds.
    # Combined with Reregister_if_changed=on (set in ClarionProperties), ClarionCL
    # auto-reregisters any CHANGED template during generation, so here we only need to
    # register templates that are MISSING from the registry -- not all of them every
    # build -- which makes the registration phase near-instant when the TRF is warm.
    if (Test-Path $trfFile) {
        Write-Info ("  Warm TRF found ({0:N0} MB) -- will register only missing templates" -f ((Get-Item $trfFile).Length / 1MB))
    } else {
        Write-Info "  No TRF found -- cold start, will register all templates"
    }

    # Use template-mapping.json from workspace Clarion/Jenkins folder
    $mappingFile = Join-Path $ClarionPath "Jenkins\template-mapping.json"
    $clarionCL = Join-Path $ClarionPath "bin\ClarionCL.exe"
    
    if (-not (Test-Path $mappingFile)) {
        Write-Warning "  Template mapping file not found: $mappingFile"
        return $false
    }
    
    if (-not (Test-Path $clarionCL)) {
        Write-Warning "  ClarionCL not found: $clarionCL"
        return $false
    }
    
    try {
        # Load template mapping
        $mappingData = Get-Content $mappingFile | ConvertFrom-Json
        $totalCount = 0
        
        # Count total templates
        foreach ($dir in $mappingData) {
            $totalCount += $dir.templates.Count
        }
        
        Write-Info "  Registering $totalCount templates from $($mappingData.Count) directories..."
        
        $registered = 0
        $failed = 0
        $skipped = 0
        $timings = @()
        $totalStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        # Ask the registry which templates are already registered (/tl returns one
        # template name per line). Anything already present is skipped here;
        # Reregister_if_changed=on refreshes changed ones during generation. If /tl
        # returns nothing (cold or unresolved registry), $registeredSet stays empty
        # and we fall back to registering every template, as before.
        $registeredSet = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
        if (Test-Path $trfFile) {
            $tlOut = & $clarionCL "/ConfigDir" $ConfigDir "/tl" 2>$null
            foreach ($line in $tlOut) {
                $name = "$line".Trim()
                if ($name -and $name -ne 'None') { [void]$registeredSet.Add($name) }
            }
            Write-Info "  /tl reports $($registeredSet.Count) templates already registered"
        }

        # Register templates by directory
        foreach ($dir in $mappingData) {
            $dirPath = Join-Path $ClarionPath $dir.directory

            foreach ($template in $dir.templates) {
                if ($registeredSet.Contains($template.name)) {
                    $skipped++
                    continue
                }

                $templatePath = Join-Path $dirPath $template.file

                if (Test-Path $templatePath) {
                    $sw = [System.Diagnostics.Stopwatch]::StartNew()
                    $result = & $clarionCL "/ConfigDir" $ConfigDir "/tr" $templatePath 2>&1
                    $sw.Stop()
                    $elapsed = $sw.Elapsed.TotalSeconds
                    $timings += [PSCustomObject]@{ Name = $template.name; File = $template.file; Seconds = $elapsed; OK = ($LASTEXITCODE -eq 0) }
                    if ($LASTEXITCODE -eq 0) {
                        $registered++
                        Write-Host ("  [{0,6:F2}s] {1}" -f $elapsed, $template.name) -ForegroundColor $(if ($elapsed -gt 5) { 'Yellow' } else { 'DarkGray' })
                    } else {
                        $failed++
                        Write-Warning ("  [{0,6:F2}s] FAILED: {1}" -f $elapsed, $template.name)
                    }
                } else {
                    $failed++
                    Write-Warning "  Template file not found: $($dir.directory)\$($template.file)"
                }
            }
        }
        
        $totalStopwatch.Stop()
        
        # Show slowest templates
        Write-Host "`n  Top 5 slowest templates:" -ForegroundColor Cyan
        $timings | Sort-Object Seconds -Descending | Select-Object -First 5 | ForEach-Object {
            Write-Host ("    {0,6:F2}s  {1}" -f $_.Seconds, $_.Name) -ForegroundColor Cyan
        }
        
        Write-Success ("  + Registered $registered, skipped $skipped already-registered (failed: $failed) in {0:F1}s total" -f $totalStopwatch.Elapsed.TotalSeconds)

        return ($failed -eq 0)
    }
    catch {
        Write-Warning "  Failed to register templates: $_"
        return $false
    }
}

function Get-VCFolderHash {
    param([string]$FolderPath)
    $files = Get-ChildItem $FolderPath -Filter "*.APV" -Recurse | Sort-Object FullName
    if ($files.Count -eq 0) { return $null }
    $md5 = [System.Security.Cryptography.MD5]::Create()
    # Hash file paths + content so renames and edits both trigger re-import
    $combined = [System.Text.StringBuilder]::new()
    foreach ($file in $files) {
        [void]$combined.Append($file.FullName)
        [void]$combined.Append("=")
        [void]$combined.Append([System.BitConverter]::ToString($md5.ComputeHash([System.IO.File]::ReadAllBytes($file.FullName))).Replace("-",""))
        [void]$combined.Append(";")
    }
    return [System.BitConverter]::ToString($md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($combined.ToString()))).Replace("-","")
}

function Import-AppFromVC {
    param(
        [string]$AppName,
        [string]$AppFile,
        [string]$VCFolder,
        [string]$ClarionPath,
        [string]$ConfigDir
    )
    
    $upstxaFile = "$AppName.upstxa"
    $claInterfacePath = "C:\Program Files (x86)\UpperParkSolutions\claInterface\ClaInterface.exe"
    $clarionCLPath = Join-Path $ClarionPath "bin\ClarionCL.exe"
    
    $vcFolderFull = if ([System.IO.Path]::IsPathRooted($VCFolder)) { $VCFolder } else { Join-Path (Get-Location) $VCFolder }
    $upstxaFull = Join-Path (Get-Location) $upstxaFile

    if (-not (Test-Path $vcFolderFull)) {
        Write-Warning "  VC folder not found: $vcFolderFull"
        return $false
    }

    # Clarion intermittently fails the TXA import with a bogus
    # "You need a more recent version of Clarion" (GENE000 / GENE003).
    # It is transient (not an actual version mismatch), so retry the
    # build-TXA + import a couple of times before giving up.
    $maxAttempts = 3   # initial attempt + 2 retries
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            if ($attempt -gt 1) {
                Write-Warning "  Retrying $AppName import (attempt $attempt of $maxAttempts)..."
                Start-Sleep -Seconds 2
            }

            # Step 1: Build TXA from APV files
            Write-Info "  Building TXA for $AppName..."
            $buildArgs = "/quiet /ConfigDir `"$ConfigDir`" COMMAND=BUILDTXA INPUT=`"$vcFolderFull`" OUTPUT=`"$upstxaFull`" APPNAME=`"$AppName`""
            $process = Start-Process -FilePath $claInterfacePath -ArgumentList $buildArgs -Wait -NoNewWindow -PassThru
            if ($process.ExitCode -ne 0) {
                Write-Warning "  Failed to build TXA for $AppName (exit code: $($process.ExitCode))"
                continue
            }
            if (-not (Test-Path $upstxaFull)) {
                Write-Warning "  TXA file not created for $AppName"
                continue
            }

            # Step 2: Import TXA into APP - capture output so we can detect the
            # transient GENE000/GENE003 error (ClarionCL may still exit 0).
            Write-Info "  Importing $AppName..."
            $importOut = [System.IO.Path]::GetTempFileName()
            $importErr = [System.IO.Path]::GetTempFileName()
            $importArgs = "/ConfigDir `"$ConfigDir`" /ai $AppFile $upstxaFile"
            $process = Start-Process -FilePath $clarionCLPath -ArgumentList $importArgs -Wait -NoNewWindow -PassThru -RedirectStandardOutput $importOut -RedirectStandardError $importErr

            $importText = ''
            if (Test-Path $importOut) { $importText += (Get-Content -Raw $importOut -ErrorAction SilentlyContinue) }
            if (Test-Path $importErr) { $importText += (Get-Content -Raw $importErr -ErrorAction SilentlyContinue) }
            Remove-Item $importOut, $importErr -Force -ErrorAction SilentlyContinue
            if ($importText -and $importText.Trim()) { Write-Host $importText }

            $transientError = $importText -match 'GENE000|GENE003|more recent version of Clarion|Error importing txa'

            if ($process.ExitCode -ne 0 -or $transientError) {
                if ($transientError) {
                    Write-Warning "  Transient Clarion import error for $AppName (GENE000/GENE003) - will retry"
                } else {
                    Write-Warning "  Failed to import $AppName (exit code: $($process.ExitCode))"
                }
                continue
            }

            # Step 3: Success - clean up TXA file
            if (Test-Path $upstxaFull) { Remove-Item $upstxaFull -Force }
            Write-Success "  + $AppName imported successfully"
            return $true

        } catch {
            Write-Warning "  Error importing ${AppName} (attempt ${attempt}): $_"
            continue
        }
    }

    Write-Warning "  Import failed for $AppName after $maxAttempts attempts"
    return $false
}

Write-Host "`n=== Accura Build Automation ===" -ForegroundColor Magenta
Write-Host ("Started: " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + "`n") -ForegroundColor Gray

# Get Clarion10 path: explicit -ClarionPath wins (CI), else config.json / prompt.
$clarion10Path = if ($ClarionPath) { $ClarionPath } else { Get-Clarion10Path -Mode $Mode }

# If mode is not specified, try to read from config.json
if ([string]::IsNullOrWhiteSpace($Mode)) {
    $config = Get-BuildConfig
    if ($config -and $config.mode) {
        $Mode = $config.mode
        Write-Info "Using mode from config.json: $Mode"
    } elseif ($ImportApps -or (-not ($GenerateAll -or $BuildAll -or $GenerateBuildAll))) {
        # Need mode for import - fail with error message
        Write-Error-Custom "Database mode not specified and not found in config.json"
        Write-Host "Please add 'mode' to config.json (TPS or SQL)" -ForegroundColor Yellow
        exit 1
    } else {
        Write-Info "Build-only mode (no database mode switch)"
    }
}

if ($Mode) {
    # Normalize mode to uppercase
    $Mode = $Mode.ToUpper()
    Write-Info "Mode: $Mode"
}

# Repository operations (only if mode specified)
if ($Mode -and -not $SkipGitOperations) {
    # Check if we're in a git repository
    if (-not (Test-Path ".git")) {
        Write-Error-Custom "Not a git repository. Please run this script from the repository root."
        exit 1
    }

# Fetch latest changes from remote
Write-Info "Fetching latest changes from remote..."
try {
    git fetch --all --prune 2>&1 | Out-Null
    Write-Success "Fetch completed"
} catch {
    Write-Error-Custom "Failed to fetch from remote: $_"
    exit 1
}

# Get all remote branches matching version pattern (v###_Build#)
Write-Info "Analyzing version branches..."
$branches = git branch -r | Where-Object { $_ -match 'origin/(v\d+_Build\d+)' } | ForEach-Object {
    if ($_ -match 'origin/(v(\d+)_Build(\d+))') {
        $branchName = $Matches[1]
        
        # Get last commit date for this branch
        $commitDate = git log -1 --format="%ai" "origin/$branchName" 2>$null
        $commitDateTime = if ($commitDate) {
            [DateTime]::Parse($commitDate.Split('+')[0].Trim())
        } else {
            [DateTime]::MinValue
        }
        
        [PSCustomObject]@{
            FullName = $branchName
            Version = [int]$Matches[2]
            Build = [int]$Matches[3]
            Remote = $_
            LastCommit = $commitDateTime
            LastCommitString = $commitDate
        }
    }
}

if ($branches.Count -eq 0) {
    Write-Error-Custom "No version branches found matching pattern v###_Build#"
    exit 1
}

# Sort by last commit date descending (most recent first)
$latestBranch = $branches | Sort-Object @{Expression={$_.LastCommit}; Descending=$true} | Select-Object -First 1

Write-Info "Found $($branches.Count) version branches"
Write-Success "Selected branch: $($latestBranch.FullName) (v$($latestBranch.Version) Build $($latestBranch.Build))"
Write-Info "Last commit: $($latestBranch.LastCommit.ToString("yyyy-MM-dd HH:mm:ss"))"

# Get current branch
$currentBranch = git branch --show-current

if ($currentBranch -eq $latestBranch.FullName) {
    Write-Info "Already on latest branch: $currentBranch"
    
    # Ensure upstream tracking is set (Jenkins checkouts often omit this)
    git branch --set-upstream-to="origin/$currentBranch" $currentBranch 2>&1 | Out-Null

    # Discard any local modifications (e.g. Clarion IDE touching .cwproj files)
    git reset --hard HEAD 2>&1 | Out-Null
    Write-Info "Reset local modifications"

    # Pull latest changes
    Write-Info "Pulling latest changes..."
    try {
        git pull
        Write-Success "Updated to latest commit"
    } catch {
        Write-Warning "Failed to pull changes: $_"
    }
} else {
    Write-Info "Switching from '$currentBranch' to '$($latestBranch.FullName)'..."
    
    # Check for uncommitted changes
    $status = git status --porcelain
    if ($status) {
        Write-Warning "You have uncommitted changes:"
        Write-Host $status
        $response = Read-Host "Stash changes and continue? (y/n)"
        if ($response -ne 'y') {
            Write-Info "Build cancelled by user"
            exit 0
        }
        git stash push -m "Auto-stash before switching to $($latestBranch.FullName)"
        Write-Success "Changes stashed"
    }
    
    # Switch to the latest branch and ensure upstream tracking is set
    try {
        git checkout -B $latestBranch.FullName --track "origin/$($latestBranch.FullName)" 2>&1 | Out-Null
        Write-Success "Switched to branch: $($latestBranch.FullName)"
        
        # Pull latest changes
        git pull 2>&1 | Out-Null
        Write-Success "Updated to latest commit"
    } catch {
        Write-Error-Custom "Failed to switch branch: $_"
        exit 1
    }
}

} # End of mode-specific git operations

# Switch to TPS or SQL mode (always needed, even when skipping git operations)
if ($Mode) {
    Write-Host "`n--- Switching to $Mode Mode ---" -ForegroundColor Magenta
    
    try {
        if ($Mode -eq 'TPS') {
            # TPS Mode: Copy AccuraTPS.dct to accura.dct
            if (Test-Path "AccuraTPS.dct") {
                Write-Info "Copying AccuraTPS.dct to accura.dct..."
                Copy-Item "AccuraTPS.dct" "accura.dct" -Force
                Write-Success "  + accura.dct (from AccuraTPS.dct)"
            } else {
                Write-Warning "AccuraTPS.dct not found!"
            }
            
            # Copy version files
            if (Test-Path "versions\tps\Version.ini") {
                Copy-Item "versions\tps\Version.ini" "Version.ini" -Force
                Write-Success "  + Version.ini (from versions\tps\)"
            }
            
        } else {
            # SQL Mode: Copy AccuraMSQL.DCT to Accura.DCT
            if (Test-Path "AccuraMSQL.DCT") {
                Write-Info "Copying AccuraMSQL.DCT to Accura.DCT..."
                Copy-Item "AccuraMSQL.DCT" "Accura.DCT" -Force
                Write-Success "  + accura.dct (from AccuraMSQL.DCT)"
            } else {
                Write-Warning "AccuraMSQL.DCT not found!"
            }
            
            # Copy version files
            if (Test-Path "versions\sql\Version.ini") {
                Copy-Item "versions\sql\Version.ini" "Version.ini" -Force
                Write-Success "  + Version.ini (from versions\sql\)"
            }
        }
        
        Write-Success "Switched to $Mode mode"
        
    } catch {
        Write-Error-Custom "Failed to switch mode: $_"
        exit 1
    }
}

# Apply project patches (temporary fixes until client updates)
$patchDir = "$PSScriptRoot\ProjectPatches"
if (Test-Path $patchDir) {
    Write-Host "`n--- Applying Project Patches ---" -ForegroundColor Magenta
    $patchCount = 0
    
    # dataM0.CLW must be excluded for SQL builds to compile successfully.
    # Do this surgically on the repo's own data.cwproj instead of stamping a
    # hand-maintained copy over it - that copy went stale and dragged in modules
    # for procedures that no longer exist. The repo file stays authoritative.
    # TPS keeps dataM0 (the repo lists it and generation regenerates it), so we
    # only touch the file for SQL.
    if ($Mode -eq 'SQL' -and (Test-Path "data.cwproj")) {
        $cwproj = Get-Content -Raw "data.cwproj"
        $pattern = '(?s)\r?\n\s*<Compile Include="dataM0\.CLW">.*?</Compile>'
        if ($cwproj -match $pattern) {
            ($cwproj -replace $pattern, '') | Set-Content -NoNewline "data.cwproj"
            Write-Info "SQL build: removed dataM0.CLW from data.cwproj"
            $patchCount++
        } else {
            Write-Info "SQL build: dataM0.CLW not present in data.cwproj (nothing to remove)"
        }
    }
    
    # Client has added ODBC driver and classes reference to repo - patch no longer needed
    # if (Test-Path "$patchDir\licviewer.cwproj") {
    #     Copy-Item "$patchDir\licviewer.cwproj" -Destination "licviewer.cwproj" -Force
    #     Write-Info "Applied licviewer.cwproj patch (adds classes reference for MD5)"
    #     $patchCount++
    # }
    
    if ($patchCount -gt 0) {
        Write-Success "Applied $patchCount project patch(es)"
    }
}

# Import apps if requested
if ($ImportApps) {
    Write-Host "`n--- Importing Apps from Version Control ---" -ForegroundColor Magenta
    
    # Setup mode-specific Clarion configuration
    $modeConfigDir = Setup-ModeSpecificConfig -Mode $Mode -ClarionPath $clarion10Path -DebugBuild:$DebugBuild
    Write-Info "Using config directory: $modeConfigDir"

    # Apply any local template patches (temporary fixes until upstream Clarion repo is corrected)
    $templatePatchDir = "$PSScriptRoot\TemplatePatches"
    $templateDestDir = Join-Path $clarion10Path "accessory\template\win"
    if (Test-Path $templatePatchDir) {
        $patches = Get-ChildItem $templatePatchDir -Filter "*.tpl"
        if ($patches.Count -gt 0) {
            Write-Host "`n--- Applying Template Patches ---" -ForegroundColor Magenta
            foreach ($patch in $patches) {
                Copy-Item $patch.FullName (Join-Path $templateDestDir $patch.Name) -Force
                Write-Info "  + Patched $($patch.Name)"
            }
        }
    }

    # Register all templates from mapping file
    Write-Host "`n--- Registering Templates ---" -ForegroundColor Magenta
    Register-Templates -ClarionPath $clarion10Path -ConfigDir $modeConfigDir | Out-Null

    Write-Host "`n--- Discovering Solution Apps ---" -ForegroundColor Magenta
    Write-Info "  Working directory: $((Get-Location).Path)"
    $solutionFile = "accura.sln"
    Write-Info "  Looking for solution: $solutionFile"
    if (-not (Test-Path $solutionFile)) {
        Write-Error-Custom "Solution file not found: $solutionFile (cwd: $((Get-Location).Path))"
        exit 1
    }
    Write-Success "  Solution found"

    $apps = Get-SolutionApps $solutionFile
    Write-Success "  Found $($apps.Count) app(s) in solution"
    foreach ($a in $apps) {
        Write-Host ("    - {0,-30} -> {1}" -f $a.Name, $a.VCFolder) -ForegroundColor DarkGray
    }
    
    # Load import cache
    $importCacheFile = Join-Path (Get-Location) "vcDevelopment\.import-cache.json"
    $importCache = @{}
    if (Test-Path $importCacheFile) {
        try {
            $json = Get-Content $importCacheFile | ConvertFrom-Json
            # ConvertFrom-Json returns PSCustomObject in PS 5.1 - convert to hashtable manually
            $importCache = @{}
            $json.PSObject.Properties | ForEach-Object { $importCache[$_.Name] = $_.Value }
        } catch {
            Write-Warning "  Could not read import cache, will re-import all apps"
            $importCache = @{}
        }
    }
    
    $successCount = 0
    $failCount = 0
    $skippedCount = 0
    
    foreach ($app in $apps) {
        $vcFolderFull = if ([System.IO.Path]::IsPathRooted($app.VCFolder)) { $app.VCFolder } else { Join-Path (Get-Location) $app.VCFolder }
        $currentHash = if (Test-Path $vcFolderFull) { Get-VCFolderHash $vcFolderFull } else { $null }
        $cachedHash = $importCache[$app.Name]

        if ($currentHash -and $cachedHash -eq $currentHash -and (Test-Path $app.AppFile)) {
            Write-Host "  [skipped] $($app.Name) (no changes)" -ForegroundColor DarkGray
            $skippedCount++
            $successCount++
            continue
        }

        if (Import-AppFromVC -AppName $app.Name -AppFile $app.AppFile -VCFolder $app.VCFolder -ClarionPath $clarion10Path -ConfigDir $modeConfigDir) {
            $successCount++
            if ($currentHash) { $importCache[$app.Name] = $currentHash }
        } else {
            $failCount++
            # Remove from cache so it retries next build
            $importCache.Remove($app.Name)
            # A failed import (after retries) means a broken/stale .app - continuing
            # would only cascade into confusing generation/compile errors, so stop now.
            $importCache | ConvertTo-Json | Set-Content $importCacheFile
            Write-Error-Custom "Import failed for $($app.Name) after retries - aborting build"
            exit 1
        }
    }

    # Save updated cache
    $importCache | ConvertTo-Json | Set-Content $importCacheFile
    
    Write-Host "`nImport Summary:" -ForegroundColor Magenta
    Write-Success "  $successCount apps OK ($skippedCount skipped, $($successCount - $skippedCount) imported)"
    if ($failCount -gt 0) {
        Write-Warning "  $failCount apps failed to import"
    }
}

# Generate and/or build if requested
if ($GenerateAll -or $BuildAll -or $GenerateBuildAll) {
    Write-Host "`n--- Compilation ---" -ForegroundColor Magenta

    $buildConfiguration = if ($DebugBuild) { 'Debug' } else { 'Release' }
    $doGenerate = $GenerateAll -or $GenerateBuildAll
    $doBuild    = $BuildAll   -or $GenerateBuildAll

    # Clear previous build logs ONCE here. The phase scripts (generate.ps1 /
    # compile.ps1) no longer clear logs, so the build phase cannot wipe the
    # generate phase's logs.
    $boDir = Join-Path (Get-Location) "build-output"
    if (Test-Path $boDir) {
        Get-ChildItem -Path $boDir -Recurse -Filter "*.log" -File -ErrorAction SilentlyContinue | ForEach-Object { [System.IO.File]::Delete($_.FullName) }
    }

    # Each phase runs as its own child process: exit codes are isolated and
    # reported cleanly, and the phase output streams to the console.
    function Invoke-Phase {
        param([string]$ScriptName, [string[]]$PhaseArgs)
        $script = Join-Path $PSScriptRoot $ScriptName
        if (-not (Test-Path $script)) { Write-Error-Custom "$ScriptName not found at: $script"; exit 1 }
        $psArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$script) + $PhaseArgs
        $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs -WorkingDirectory (Get-Location).Path -NoNewWindow -Wait -PassThru
        return $p.ExitCode
    }

    $commonArgs = @('-Configuration',$buildConfiguration,'-ClarionPath',$clarion10Path,'-ConfigDir',$modeConfigDir)
    if ($Mode) { $commonArgs += @('-Mode',$Mode) }

    if ($doGenerate) {
        Write-Info "Calling generate.ps1..."
        $code = Invoke-Phase 'generate.ps1' $commonArgs
        if ($code -ne 0) { Write-Error-Custom "Generation failed (exit $code)"; exit 1 }
    }

    if ($doBuild) {
        Write-Info "Calling compile.ps1..."
        $code = Invoke-Phase 'compile.ps1' (@('-BuildOnly') + $commonArgs)
        if ($code -ne 0) { Write-Error-Custom "Compilation failed (exit $code)"; exit 1 }
    }
}

Write-Host "`n=== Build Complete ===" -ForegroundColor Magenta
Write-Host ("Finished: " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss")) -ForegroundColor Gray
