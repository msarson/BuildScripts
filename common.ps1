# common.ps1 - shared helpers for the Accura build pipeline.
# Dot-source this from each phase script:  . "$PSScriptRoot\common.ps1"
# Contains logging, path/solution/project/dependency helpers, and Resolve-BuildPaths.
# NOTE: helper bodies below were extracted verbatim from compile.ps1 to guarantee
# identical behaviour; edit them here once the phase scripts dot-source this file.

function Write-Warning { param($Message) Write-Host "!  $Message" -ForegroundColor Yellow }
function Write-Info($message) {
    Write-Host "i  $message" -ForegroundColor Cyan
}

function Write-Success($message) {
    Write-Host "+ $message" -ForegroundColor Green
}

function Write-Error-Custom($message) {
    Write-Host "X $message" -ForegroundColor Red
}

function Get-ClarionPathFromConfig {
    $configPath = Join-Path $PSScriptRoot "config.json"
    if (Test-Path $configPath) {
        $config = Get-Content $configPath | ConvertFrom-Json
        return $config.clarion10Path
    }
    return $null
}

function Get-VcOutputFolder {
    param([string]$SolutionDir)
    # up_vcSettings.ini is gitignored / may be absent in a clean workspace.
    # Fall back to the conventional relative folder rather than throwing.
    $default = "vcDevelopment"
    if ([string]::IsNullOrWhiteSpace($SolutionDir)) { return $default }
    $ini = Join-Path $SolutionDir "up_vcSettings.ini"
    if (-not (Test-Path $ini)) { return $default }
    $line = Get-Content $ini | Where-Object { $_ -match '^OutputFolder\s*=' } | Select-Object -First 1
    $folder = if ($line) { ($line -split '=', 2)[1].Trim() } else { '' }
    if (-not $folder) { return $default }
    return $folder
}

function Get-ProjectFileData {
    param(
        [string]$ProjectFilePath
    )
    
    if (-not (Test-Path $ProjectFilePath)) {
        Write-Warning "Project file not found: $ProjectFilePath"
        return $null
    }
    
    try {
        [xml]$projectXml = Get-Content $ProjectFilePath
        
        # Extract ProjectGuid
        $guid = $projectXml.Project.PropertyGroup.ProjectGuid | 
            Where-Object { $_ } | 
            Select-Object -First 1
        
        if ($guid) {
            $guid = $guid -replace '[{}]', ''
        }
        
        # Extract OutputType
        $outputType = $projectXml.Project.PropertyGroup.OutputType | 
            Where-Object { $_ } | 
            Select-Object -First 1
        
        # Extract ProjectReference elements
        $references = @()
        $projectXml.Project.ItemGroup.ProjectReference | ForEach-Object {
            if ($_) {
                $refGuid = $_.Project -replace '[{}]', ''
                $refName = $_.Name
                $refFile = $_.Include
                
                if ($refGuid) {
                    $references += @{
                        Guid = $refGuid
                        Name = $refName
                        File = $refFile
                    }
                }
            }
        }
        
        return @{
            Guid = $guid
            OutputType = $outputType
            References = $references
        }
        
    } catch {
        Write-Warning "Failed to parse project file ${ProjectFilePath}: $_"
        return $null
    }
}

function Get-ProjectsFromSolution {
    param([string]$SolutionFile)
    
    $projects = @()
    $solutionDir = Split-Path $SolutionFile -Parent
    if ([string]::IsNullOrEmpty($solutionDir)) {
        $solutionDir = Get-Location
    }
    
    Get-Content $SolutionFile | ForEach-Object {
        if ($_ -match 'Project\(".*?"\)\s*=\s*"(.*?)",\s*"(.*?\.cwproj)"') {
            $projectName = $Matches[1]
            $projectRelativePath = $Matches[2]
            $projectFile = Join-Path $solutionDir $projectRelativePath
            $projectDir = Split-Path $projectFile -Parent
            
            if (Test-Path $projectFile) {
                $projects += @{
                    Name = $projectName
                    Path = $projectDir
                    File = $projectFile
                    RelativePath = $projectRelativePath
                }
            }
        }
    }
    
    return $projects
}

function Get-AppFilesFromSolution {
    param([string]$SolutionFile)
    
    $apps = @()
    $solutionDir = Split-Path $SolutionFile -Parent
    if ([string]::IsNullOrEmpty($solutionDir)) {
        $solutionDir = Get-Location
    }
    
    # Get all projects first
    $projects = Get-ProjectsFromSolution $SolutionFile
    
    # For each project, look for the corresponding .app file
    foreach ($project in $projects) {
        $appFile = Join-Path $project.Path "$($project.Name).app"
        if (Test-Path $appFile) {
            $apps += @{
                Name = $project.Name
                AppFile = $appFile
                RelativePath = "$($project.Name).app"
            }
        }
    }
    
    return $apps
}

function Build-DependencyGraph {
    param([array]$Projects)
    
    $nodes = @{}
    $guidToName = @{}
    
    # First pass: Create nodes with metadata
    foreach ($project in $Projects) {
        $projectData = Get-ProjectFileData $project.File
        
        if ($projectData -and $projectData.Guid) {
            $nodes[$project.Name] = @{
                Project = $project
                Guid = $projectData.Guid
                OutputType = $projectData.OutputType
                References = $projectData.References
                Dependencies = @()  # Will be populated in second pass
            }
            
            $guidToName[$projectData.Guid] = $project.Name
        }
    }
    
    # Second pass: Resolve references to project names
    foreach ($nodeName in $nodes.Keys) {
        $node = $nodes[$nodeName]
        
        foreach ($reference in $node.References) {
            if ($guidToName.ContainsKey($reference.Guid)) {
                $dependencyName = $guidToName[$reference.Guid]
                $node.Dependencies += $dependencyName
            }
        }
    }
    
    return $nodes
}

function Get-TopologicalOrder {
    param(
        [hashtable]$DependencyGraph,
        [ref]$HasCircularDeps
    )
    
    $script:sorted = New-Object System.Collections.ArrayList
    $visited = @{}
    $visiting = @{}
    $script:cyclesDetected = @()
    
    function Visit($nodeName, $path) {
        if ($visiting[$nodeName]) {
            # Circular dependency - record it but don't fail
            $cycleStart = $path.IndexOf($nodeName)
            if ($cycleStart -ge 0) {
                $cycle = $path[$cycleStart..($path.Count-1)] + $nodeName
                $script:cyclesDetected += ,($cycle)
            }
            return
        }
        
        if ($visited[$nodeName]) {
            return
        }
        
        $visiting[$nodeName] = $true
        $newPath = $path + $nodeName
        
        if ($DependencyGraph.ContainsKey($nodeName)) {
            $node = $DependencyGraph[$nodeName]
            foreach ($dep in $node.Dependencies) {
                Visit $dep $newPath
            }
        }
        
        $visiting[$nodeName] = $false
        $visited[$nodeName] = $true
        [void]$script:sorted.Add($nodeName)
    }
    
    # Visit all nodes
    foreach ($nodeName in ($DependencyGraph.Keys | Sort-Object)) {
        if (-not $visited[$nodeName]) {
            Visit $nodeName @()
        }
    }
    
    # Report circular dependencies if found
    if ($script:cyclesDetected.Count -gt 0) {
        $HasCircularDeps.Value = $true
    }
    
    return $script:sorted.ToArray()
}

function Resolve-BuildPaths {
    # Resolves and validates the paths every phase needs, and ensures the
    # build-output dirs exist. Returns an object the caller destructures.
    param(
        [string]$ClarionPath,
        [string]$SolutionPath = "accura.sln"
    )
    if (-not $ClarionPath) {
        $ClarionPath = Get-ClarionPathFromConfig
        if (-not $ClarionPath) { Write-Error-Custom "Clarion path not specified and not found in config.json"; exit 1 }
    }
    if (-not [System.IO.Path]::IsPathRooted($ClarionPath)) {
        $ClarionPath = Join-Path (Get-Location) $ClarionPath | Resolve-Path | Select-Object -ExpandProperty Path
    }
    $clarionCL      = Join-Path $ClarionPath "bin\ClarionCL.exe"
    $clarionBinPath = Join-Path $ClarionPath "bin"
    $msBuildPath    = "C:\Windows\Microsoft.NET\Framework\v4.0.30319\msbuild.exe"

    if (-not (Test-Path $SolutionPath)) { Write-Error-Custom "Solution file not found: $SolutionPath"; exit 1 }
    if (-not (Test-Path $clarionCL))    { Write-Error-Custom "ClarionCL.exe not found at: $clarionCL"; exit 1 }

    $solutionDir = Split-Path $SolutionPath -Parent
    if ([string]::IsNullOrEmpty($solutionDir)) { $solutionDir = (Get-Location).Path }

    $buildOutputDir = Join-Path $solutionDir "build-output"
    $failedLogsDir  = Join-Path $buildOutputDir "failed"
    if (-not (Test-Path $buildOutputDir)) { New-Item -ItemType Directory -Path $buildOutputDir -Force | Out-Null }
    if (-not (Test-Path $failedLogsDir))  { New-Item -ItemType Directory -Path $failedLogsDir  -Force | Out-Null }

    return [pscustomobject]@{
        ClarionPath = $ClarionPath; ClarionCL = $clarionCL; ClarionBinPath = $clarionBinPath
        MsBuildPath = $msBuildPath; SolutionDir = $solutionDir
        BuildOutputDir = $buildOutputDir; FailedLogsDir = $failedLogsDir
    }
}

