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
    [switch]$DebugBuild  # Pass -DebugBuild for debug mode; default is Release
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

function Get-SolutionApps {
    param([string]$SolutionFile)
    
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
                VCFolder = "vcDevelopment\$appName"
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
        [string]$ClarionPath
    )
    
    $baseConfigDir = "C:\BuildScripts\ClarionConfig"
    $modeConfigDir = "C:\BuildScripts\ClarionConfig$Mode"  # ClarionConfigTPS or ClarionConfigSQL
    
    # Create mode-specific config directory if it doesn't exist
    if (-not (Test-Path $modeConfigDir)) {
        Write-Info "Creating $Mode-specific Clarion config directory..."
        
        # Create directory
        New-Item -ItemType Directory -Path $modeConfigDir -Force | Out-Null
        
        # Copy ONLY ClarionProperties.xml (not entire directory - 45x faster!)
        $sourceXml = Join-Path $baseConfigDir "ClarionProperties.xml"
        $destXml = Join-Path $modeConfigDir "ClarionProperties.xml"
        Copy-Item $sourceXml $destXml -Force
        
        Write-Success "  + Created $modeConfigDir (1 file, <1 second)"
    }
    
    # Always refresh ClarionProperties.xml from base before each build to prevent
    # ClarionCL appending to it repeatedly and causing OutOfMemoryException
    $sourceXml = Join-Path $baseConfigDir "ClarionProperties.xml"
    $destXml = Join-Path $modeConfigDir "ClarionProperties.xml"
    Copy-Item $sourceXml $destXml -Force
    Write-Info "  Refreshed ClarionProperties.xml from base config"
    
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
    
    return $modeConfigDir
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
    
    # Always delete existing TRF to force fresh registration (ensures clean builds)
    $trfFile = Join-Path $ClarionPath "template\win\TemplateRegistry10.trf"
    if (Test-Path $trfFile) {
        Remove-Item $trfFile -Force
        Write-Info "  Deleted existing template registry for fresh registration"
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
        
        # Register templates by directory
        foreach ($dir in $mappingData) {
            $dirPath = Join-Path $ClarionPath $dir.directory
            
            foreach ($template in $dir.templates) {
                $templatePath = Join-Path $dirPath $template.file
                
                if (Test-Path $templatePath) {
                    $result = & $clarionCL "/ConfigDir" $ConfigDir "/tr" $templatePath 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        $registered++
                    } else {
                        $failed++
                        Write-Warning "  Failed to register $($template.name)"
                    }
                } else {
                    $failed++
                    Write-Warning "  Template file not found: $($dir.directory)\$($template.file)"
                }
            }
        }
        
        Write-Success "  + Registered $registered templates (failed: $failed)"
        return ($failed -eq 0)
    }
    catch {
        Write-Warning "  Failed to register templates: $_"
        return $false
    }
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
    
    try {
        # Step 1: Build TXA from APV files
        Write-Info "  Building TXA for $AppName..."
        $vcFolderFull = Join-Path (Get-Location) $VCFolder
        $upstxaFull = Join-Path (Get-Location) $upstxaFile
        
        if (-not (Test-Path $vcFolderFull)) {
            Write-Warning "  VC folder not found: $vcFolderFull"
            return $false
        }
        
        $buildArgs = "/quiet /ConfigDir `"$ConfigDir`" COMMAND=BUILDTXA INPUT=`"$vcFolderFull`" OUTPUT=`"$upstxaFull`" APPNAME=`"$AppName`""
        $process = Start-Process -FilePath $claInterfacePath -ArgumentList $buildArgs -Wait -NoNewWindow -PassThru
        
        if ($process.ExitCode -ne 0) {
            Write-Warning "  Failed to build TXA for $AppName (exit code: $($process.ExitCode))"
            return $false
        }
        
        if (-not (Test-Path $upstxaFull)) {
            Write-Warning "  TXA file not created for $AppName"
            return $false
        }
        
        # Step 2: Import TXA into APP
        Write-Info "  Importing $AppName..."
        $importArgs = "/ConfigDir `"$ConfigDir`" /ai $AppFile $upstxaFile"
        $process = Start-Process -FilePath $clarionCLPath -ArgumentList $importArgs -Wait -NoNewWindow -PassThru
        
        if ($process.ExitCode -ne 0) {
            Write-Warning "  Failed to import $AppName (exit code: $($process.ExitCode))"
            return $false
        }
        
        # Step 3: Clean up TXA file
        if (Test-Path $upstxaFull) {
            Remove-Item $upstxaFull -Force
        }
        
        Write-Success "  + $AppName imported successfully"
        return $true
        
    } catch {
        Write-Warning "  Error importing ${AppName}: $_"
        return $false
    }
}

Write-Host "`n=== Accura Build Automation ===" -ForegroundColor Magenta
Write-Host ("Started: " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + "`n") -ForegroundColor Gray

# Get Clarion10 path from config (needed for both mode switching and building)
$clarion10Path = Get-Clarion10Path -Mode $Mode

# Apply SQL-specific Clarion templates (only 2 files are different from TPS)
# IMPORTANT: This must happen BEFORE template registration so Clarion can update the TRF automatically
if ($Mode -and $Mode.ToUpper() -eq 'SQL') {
    Write-Host "`n--- Applying SQL Clarion Templates ---" -ForegroundColor Magenta
    
    # Copy from SQLChanges backup folder in the Clarion installation
    # Clarion is at ..\Clarion relative to Accura workspace (current directory)
    $clarionRoot = if ([System.IO.Path]::IsPathRooted($clarion10Path)) {
        $clarion10Path
    } else {
        # Resolve relative to current working directory, not script location
        Join-Path (Get-Location) $clarion10Path | Resolve-Path | Select-Object -ExpandProperty Path
    }
    
    $sqlChangesDir = Join-Path $clarionRoot "SQLChanges\accessory\template\win"
    $destDir = Join-Path $clarionRoot "accessory\template\win"
    
    $sqlFiles = @("CTSQW10ABC.tpl", "CTSQW10ABC.tpw")
    $copyCount = 0
    
    foreach ($file in $sqlFiles) {
        $source = Join-Path $sqlChangesDir $file
        $dest = Join-Path $destDir $file
        
        if (Test-Path $source) {
            Copy-Item $source $dest -Force
            Write-Info "  + $file (from SQLChanges backup)"
            $copyCount++
        } else {
            Write-Warning "SQL template file not found in SQLChanges: $file"
        }
    }
    
    if ($copyCount -eq $sqlFiles.Count) {
        Write-Success "Applied $copyCount SQL-specific templates (Clarion will auto-update TRF)"
    } else {
        Write-Warning "Applied $copyCount of $($sqlFiles.Count) SQL templates"
    }
}

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
    
    # Pull latest changes
    Write-Info "Pulling latest changes..."
    try {
        git pull origin $currentBranch
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
    
    # Switch to the latest branch
    try {
        git checkout $latestBranch.FullName 2>&1 | Out-Null
        Write-Success "Switched to branch: $($latestBranch.FullName)"
        
        # Pull latest changes
        git pull origin $latestBranch.FullName 2>&1 | Out-Null
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
            
            $tpsRed = "C:\BuildScripts\RedFiles\Clarion100_tps.red"
            if (Test-Path $tpsRed) {
                Copy-Item $tpsRed "Clarion100.red" -Force
                Write-Success "  + Clarion100.red (from BuildScripts\RedFiles\)"
            } elseif (Test-Path "versions\tps\Clarion100.red") {
                Copy-Item "versions\tps\Clarion100.red" "Clarion100.red" -Force
                Write-Success "  + Clarion100.red (from versions\tps\)"
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

            $sqlRed = "C:\BuildScripts\RedFiles\Clarion100_accura.red"
            if (Test-Path $sqlRed) {
                Copy-Item $sqlRed "Clarion100.red" -Force
                Write-Success "  + Clarion100.red (from BuildScripts\RedFiles\)"
            } elseif (Test-Path "versions\sql\Clarion100.red") {
                Copy-Item "versions\sql\Clarion100.red" "Clarion100.red" -Force
                Write-Success "  + Clarion100.red (from versions\sql\)"
            }
        }
        
        Write-Success "Switched to $Mode mode"
        
    } catch {
        Write-Error-Custom "Failed to switch mode: $_"
        exit 1
    }
}

# Apply project patches (temporary fixes until client updates)
$patchDir = "C:\BuildScripts\ProjectPatches"
if (Test-Path $patchDir) {
    Write-Host "`n--- Applying Project Patches ---" -ForegroundColor Magenta
    $patchCount = 0
    
    # NOTE: dataM0.CLW must be excluded for SQL builds to compile successfully.
    # For TPS builds, Clarion generation automatically adds dataM0.CLW back to the .cwproj,
    # so this patch doesn't affect TPS builds negatively.
    if (Test-Path "$patchDir\data.cwproj") {
        Copy-Item "$patchDir\data.cwproj" -Destination "data.cwproj" -Force
        Write-Info "Applied data.cwproj patch (excludes dataM0.CLW from build)"
        $patchCount++
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
    $modeConfigDir = Setup-ModeSpecificConfig -Mode $Mode -ClarionPath $clarion10Path
    Write-Info "Using config directory: $modeConfigDir"

    # Apply any local template patches (temporary fixes until upstream Clarion repo is corrected)
    $templatePatchDir = "C:\BuildScripts\TemplatePatches"
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
    Register-Templates -ClarionPath $clarion10Path -ConfigDir $modeConfigDir
    
    $solutionFile = "accura.sln"
    if (-not (Test-Path $solutionFile)) {
        Write-Error-Custom "Solution file not found: $solutionFile"
        exit 1
    }
    
    $apps = Get-SolutionApps $solutionFile
    Write-Info "Found $($apps.Count) apps in solution"
    
    $successCount = 0
    $failCount = 0
    
    foreach ($app in $apps) {
        if (Import-AppFromVC -AppName $app.Name -AppFile $app.AppFile -VCFolder $app.VCFolder -ClarionPath $clarion10Path -ConfigDir $modeConfigDir) {
            $successCount++
        } else {
            $failCount++
        }
    }
    
    Write-Host "`nImport Summary:" -ForegroundColor Magenta
    Write-Success "  $successCount apps imported successfully"
    if ($failCount -gt 0) {
        Write-Warning "  $failCount apps failed to import"
    }
}

# Generate and/or build if requested
if ($GenerateAll -or $BuildAll -or $GenerateBuildAll) {
    Write-Host "`n--- Compilation ---" -ForegroundColor Magenta
    
    # Prepare compile.ps1 arguments
    $compileArgs = @()
    
    if ($GenerateAll) {
        $compileArgs += "-GenerateOnly"
    } elseif ($BuildAll) {
        $compileArgs += "-BuildOnly"
    } elseif ($GenerateBuildAll) {
        $compileArgs += "-GenerateBuild"
    }
    
    # Pass Configuration
    $compileArgs += "-Configuration"
    $compileArgs += if ($DebugBuild) { 'Debug' } else { 'Release' }
    
    # Pass Clarion path
    $compileArgs += "-ClarionPath"
    $compileArgs += "`"$clarion10Path`""

    # Pass ConfigDir (mode-specific)
    $compileArgs += "-ConfigDir"
    $compileArgs += "`"$modeConfigDir`""
    
    # Call compile.ps1
    $compileScript = Join-Path $PSScriptRoot "compile.ps1"
    
    if (-not (Test-Path $compileScript)) {
        Write-Error-Custom "compile.ps1 not found at: $compileScript"
        exit 1
    }
    
    Write-Info "Calling compile.ps1..."
    
    $compileCommand = "& `"$compileScript`" $($compileArgs -join " ")"
    Invoke-Expression $compileCommand
    
    if ($LASTEXITCODE -ne 0) {
        Write-Error-Custom "Compilation failed"
        exit 1
    }
}

Write-Host "`n=== Build Complete ===" -ForegroundColor Magenta
Write-Host ("Finished: " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss")) -ForegroundColor Gray
