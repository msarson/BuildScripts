#requires -Version 5.1
<#
.SYNOPSIS
    Clarion Solution Compilation Script
    
.DESCRIPTION
    Handles generation and compilation of Clarion solutions with dependency-aware build order.
    Parses .cwproj files to determine project dependencies and builds in correct topological order.
    
.PARAMETER GenerateOnly
    Only generate source code from .app files (ClarionCL /ag)
    
.PARAMETER BuildOnly
    Only compile projects (MSBuild), assumes source already generated
    
.PARAMETER GenerateBuild
    Generate and build (default behavior)
    
.PARAMETER Configuration
    Build configuration (Debug or Release). Default: Release
    
.PARAMETER StopOnError
    Stop building on first project error. Default: true
    
.PARAMETER SolutionPath
    Path to .sln file. Default: accura.sln in current directory
    
.PARAMETER ClarionPath
    Path to Clarion installation. Default: from config.json
    
.EXAMPLE
    .\compile.ps1 -GenerateOnly
    
.EXAMPLE
    .\compile.ps1 -Configuration Release
    
.EXAMPLE
    .\compile.ps1 -BuildOnly -StopOnError:$false
#>

[CmdletBinding(DefaultParameterSetName='GenerateBuild')]
param(
    [Parameter(ParameterSetName='GenerateOnly')]
    [switch]$GenerateOnly,
    
    [Parameter(ParameterSetName='BuildOnly')]
    [switch]$BuildOnly,
    
    [Parameter(ParameterSetName='GenerateBuild')]
    [switch]$GenerateBuild,
    
    [Parameter()]
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',
    
    [Parameter()]
    [bool]$StopOnError = $true,
    
    [Parameter()]
    [string]$SolutionPath = "accura.sln",
    
    [Parameter()]
    [string]$ClarionPath,

    [Parameter()]
    [string]$ConfigDir,

    [Parameter()]
    [ValidateSet('TPS','SQL','')]
    [string]$Mode = ''
)

# If no mode specified, default to GenerateBuild
if (-not $GenerateOnly -and -not $BuildOnly) {
    $GenerateBuild = $true
}
#region Shared helpers
. "$PSScriptRoot\common.ps1"
#endregion

#region Main Execution

Write-Host "`n=== Clarion Compilation ===" -ForegroundColor Magenta
Write-Host ("Started: " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss")) -ForegroundColor Gray
Write-Host ""

# Apply project patches (temporary fixes until client updates)
$patchDir = "C:\BuildScripts\ProjectPatches"
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

# Resolve Clarion path
if (-not $ClarionPath) {
    $ClarionPath = Get-ClarionPathFromConfig
    if (-not $ClarionPath) {
        Write-Error-Custom "Clarion path not specified and not found in config.json"
        exit 1
    }
}

# Resolve relative paths (e.g., ..\Clarion) relative to current working directory
if (-not [System.IO.Path]::IsPathRooted($ClarionPath)) {
    $ClarionPath = Join-Path (Get-Location) $ClarionPath | Resolve-Path | Select-Object -ExpandProperty Path
}

$clarionCL = Join-Path $ClarionPath "bin\ClarionCL.exe"
$clarionBinPath = Join-Path $ClarionPath "bin"
$msBuildPath = "C:\Windows\Microsoft.NET\Framework\v4.0.30319\msbuild.exe"

# Validate paths
if (-not (Test-Path $SolutionPath)) {
    Write-Error-Custom "Solution file not found: $SolutionPath"
    exit 1
}

if (-not (Test-Path $clarionCL)) {
    Write-Error-Custom "ClarionCL.exe not found at: $clarionCL"
    exit 1
}

if (-not (Test-Path $msBuildPath)) {
    Write-Error-Custom "MSBuild not found at: $msBuildPath"
    exit 1
}

$solutionDir = Split-Path $SolutionPath -Parent
if ([string]::IsNullOrEmpty($solutionDir)) {
    $solutionDir = Get-Location
}

# Deploy the managed Clarion bin red file from BuildScripts.
# This removes the debug/release folder split so both configs share
# common genfiles\obj, genfiles\lib, genfiles\exp etc. folders.
# The Accura local red is handled by build.ps1 (from BuildScripts\RedFiles\).
$clarionBinRed = Join-Path $ClarionPath "bin\Clarion100.red"
if (Test-Path "C:\BuildScripts\RedFiles\Clarion100_bin.red") {
    Copy-Item "C:\BuildScripts\RedFiles\Clarion100_bin.red" $clarionBinRed -Force
    Write-Info "Deployed Clarion100.red to Clarion bin"
}

# Create build-output directory if it doesn't exist
$buildOutputDir = Join-Path $solutionDir "build-output"
$failedLogsDir = Join-Path $buildOutputDir "failed"
if (-not (Test-Path $buildOutputDir)) {
    New-Item -ItemType Directory -Path $buildOutputDir -Force | Out-Null
    Write-Info "Created build-output directory"
} else {
}
if (-not (Test-Path $failedLogsDir)) {
    New-Item -ItemType Directory -Path $failedLogsDir -Force | Out-Null
} else {
}

# STEP 2: BUILD WITH DEPENDENCY ORDER
if ($BuildOnly -or $GenerateBuild) {
    Write-Host "`n--- Step 2: Building Projects ---" -ForegroundColor Magenta
    Write-Host "=============================================" -ForegroundColor Gray
    
    # Parse solution for projects
    Write-Info "Parsing solution file..."
    $projects = Get-ProjectsFromSolution $SolutionPath
    Write-Info "Found $($projects.Count) projects in solution"
    
    # Build dependency graph
    Write-Info "Analyzing project dependencies..."
    $dependencyGraph = Build-DependencyGraph $projects
    
    # Calculate build order
    Write-Info "Calculating build order..."
    $buildOrder = @()
    $hasCircularDeps = $false
    $hasCircularDepsRef = [ref]$hasCircularDeps
    
    $buildOrder = Get-TopologicalOrder $dependencyGraph $hasCircularDepsRef
    $hasCircularDeps = $hasCircularDepsRef.Value

    # TEMP FIX: every app links classes.lib via <Library Include>, but none declare a
    # <ProjectReference> to classes, so the topological sort can place 'classes' AFTER
    # the apps that depend on it (notably 'data'), causing unresolved-external link
    # failures against a stale classes.lib. Force 'classes' to the front of the build
    # order so its .lib is always fresh before anything links it.
    # TODO: remove once the apps declare a proper ProjectReference to classes.
    if ($buildOrder -contains 'classes') {
        $buildOrder = @('classes') + ($buildOrder | Where-Object { $_ -ne 'classes' })
        Write-Info "Forced 'classes' to build first (links-everywhere base library)"
    }

    if ($hasCircularDeps) {
        Write-Warning "Circular dependencies detected in solution"
        Write-Warning "Will build all projects in two passes to resolve circular dependencies"
    }
    
    Write-Host ""
    Write-Host "=============================================" -ForegroundColor Gray
    Write-Host "BUILD ORDER ($($buildOrder.Count) projects)" -ForegroundColor Cyan
    Write-Host "=============================================" -ForegroundColor Gray
    
    # Display build order
    if (-not $hasCircularDeps) {
        for ($i = 0; $i -lt $buildOrder.Count; $i++) {
            $projectName = $buildOrder[$i]
            $node = $dependencyGraph[$projectName]
            $type = if ($node.OutputType -eq "Library") { "[LIB]" } else { "[EXE]" }
            $deps = if ($node.Dependencies.Count -gt 0) { "-> $($node.Dependencies -join ", ")" } else { "(no dependencies)" }
            Write-Host "  $($i+1). " -NoNewline -ForegroundColor Gray
            Write-Host "$type " -NoNewline -ForegroundColor $(if ($node.OutputType -eq "Library") { "Cyan" } else { "Yellow" })
            Write-Host "$projectName " -NoNewline -ForegroundColor White
            Write-Host "$deps" -ForegroundColor DarkGray
        }
    } else {
        Write-Host "  (Dependency order - two-pass build due to circular dependencies)" -ForegroundColor Yellow
        $columns = 4
        for ($i = 0; $i -lt $buildOrder.Count; $i += $columns) {
            $row = ""
            for ($j = 0; $j -lt $columns -and ($i + $j) -lt $buildOrder.Count; $j++) {
                $idx = $i + $j
                $row += "  $($idx+1). $($buildOrder[$idx])".PadRight(20)
            }
            Write-Host $row -ForegroundColor Gray
        }
    }
    Write-Host "=============================================" -ForegroundColor Gray
    Write-Host ""
    
    # Determine number of passes
    $maxPasses = if ($hasCircularDeps) { 2 } else { 1 }
    
    # Build projects (possibly multiple passes)
    $overallSuccess = $false
    $builtSuccessfully = @{}  # Track projects that built successfully in pass 1
    
    for ($pass = 1; $pass -le $maxPasses; $pass++) {
        if ($maxPasses -gt 1) {
            Write-Host ""
            Write-Host "=============================================" -ForegroundColor Magenta
            Write-Host "        BUILD PASS $pass of $maxPasses        " -ForegroundColor Magenta
            Write-Host "=============================================" -ForegroundColor Magenta
            Write-Host ""
        }
        
        $successCount = 0
        $failCount = 0
        $failedProjects = @()
        $skippedCount = 0

        function Copy-FailedLog($projectName) {
            $src = Join-Path $buildOutputDir "build_${projectName}.log"
            if (Test-Path $src) {
                Copy-Item $src (Join-Path $failedLogsDir "build_${projectName}.log") -Force
            }
        }
        
        for ($i = 0; $i -lt $buildOrder.Count; $i++) {
            $projectName = $buildOrder[$i]
            
            # Skip projects that already built successfully in pass 1
            if ($pass -gt 1 -and $builtSuccessfully.ContainsKey($projectName)) {
                $skippedCount++
                continue
            }
            
            $node = $dependencyGraph[$projectName]
            $project = $node.Project
            
            # Show progress with visual indicator
            $progressBar = "=" * [Math]::Min(40, [Math]::Floor(($i / $buildOrder.Count) * 40))
            $progressPercent = [Math]::Floor(($i / $buildOrder.Count) * 100)
            Write-Host ("`r[$progressBar$(" " * (40 - $progressBar.Length))] $progressPercent% ") -NoNewline -ForegroundColor DarkGray
            
            Write-Host "[$($i+1)/$($buildOrder.Count)] " -NoNewline -ForegroundColor Cyan
            Write-Host "Building: " -NoNewline -ForegroundColor Gray
            Write-Host "$projectName" -ForegroundColor White
            
            $projectBuildLog = Join-Path $buildOutputDir "build_${projectName}.log"
            
            $effectiveConfigDir = if ($ConfigDir) { $ConfigDir } else { "C:\BuildScripts\ClarionConfig" }
            $buildArgs = @(
                "/property:GenerateFullPaths=true"
                "/t:Rebuild"
                "/property:Configuration=$Configuration"
                "/property:clarion_Sections=$Configuration"
                "/property:ClarionBinPath=`"$clarionBinPath`""
                "/property:ConfigDir=`"$effectiveConfigDir`""
                "/property:NoDependency=true"
                "/verbosity:normal"
                "/nologo"
                "/fileLogger"
                "/fileLoggerParameters:LogFile=`"$projectBuildLog`""
                "`"$($project.File)`""
            )
            
            try {
                $buildProcess = Start-Process -FilePath $msBuildPath `
                    -ArgumentList $buildArgs `
                    -WorkingDirectory $solutionDir `
                    -NoNewWindow `
                    -Wait `
                    -PassThru `
                    -RedirectStandardOutput "$env:TEMP\msbuild_console_${projectName}.txt"
                
                if ($buildProcess.ExitCode -eq 0) {
                    Write-Host "  + " -NoNewline -ForegroundColor Green
                    Write-Host "$projectName " -NoNewline -ForegroundColor White
                    Write-Host "built successfully" -ForegroundColor Gray
                    $successCount++
                    
                    # Track successful builds in pass 1 to skip in pass 2
                    if ($pass -eq 1) {
                        $builtSuccessfully[$projectName] = $true
                    }
                } else {
                    if ($hasCircularDeps -and $pass -lt $maxPasses) {
                        # First pass of circular dependency build - failures are expected
                        Write-Host "  ! " -NoNewline -ForegroundColor Yellow
                        Write-Host "$projectName " -NoNewline -ForegroundColor White
                        Write-Host "waiting for dependencies (will retry in pass $($pass + 1))" -ForegroundColor DarkYellow
                        $failCount++
                        $failedProjects += $projectName
                    } elseif ($Configuration -eq 'Debug') {
                        # Debug build failed - fall back to Release for this project
                        Write-Host "  ~ " -NoNewline -ForegroundColor Yellow
                        Write-Host "$projectName " -NoNewline -ForegroundColor White
                        Write-Host "Debug build failed - retrying in Release mode..." -ForegroundColor Yellow

                        # Preserve debug log before Release overwrites it
                        $debugBuildLog = Join-Path $buildOutputDir "build_${projectName}_debug_failed.log"
                        if (Test-Path $projectBuildLog) {
                            Copy-Item $projectBuildLog $debugBuildLog -Force
                        }

                        # Re-generate this app in Release mode before building.
                        # Generation in Debug mode writes MAP/source to debug paths;
                        # the Release build needs them in release paths.
                        $appFile = Join-Path $solutionDir "$projectName.app"
                        if (Test-Path $appFile) {
                            $regenLog = Join-Path $buildOutputDir "generate_${projectName}_release_regen.log"
                            $regenErrLog = Join-Path $buildOutputDir "generate_${projectName}_release_regen.err.log"
                            $regenProcess = Start-Process -FilePath $clarionCL `
                                -ArgumentList "/ConfigDir", "`"$effectiveConfigDir`"", "/win", "/rs", "Release", "/ag", "`"$appFile`"" `
                                -WorkingDirectory $solutionDir `
                                -NoNewWindow `
                                -Wait `
                                -PassThru `
                                -RedirectStandardOutput $regenLog `
                                -RedirectStandardError $regenErrLog
                            if ($regenProcess.ExitCode -ne 0) {
                                Write-Host "      (Release re-generation failed, build may still be attempted)" -ForegroundColor DarkYellow
                                if ((Test-Path $regenErrLog) -and (Get-Item $regenErrLog).Length -gt 0) {
                                    Get-Content $regenErrLog | Select-Object -First 5 | ForEach-Object {
                                        if ($_.Trim()) { Write-Host "      [stderr] $($_.Trim())" -ForegroundColor DarkYellow }
                                    }
                                }
                            }
                        }

                        $releaseBuildArgs = @(
                            "/property:GenerateFullPaths=true"
                            "/t:Rebuild"
                            "/property:Configuration=Release"
                            "/property:clarion_Sections=Release"
                            "/property:ClarionBinPath=`"$clarionBinPath`""
                            "/property:ConfigDir=`"$effectiveConfigDir`""
                            "/property:NoDependency=true"
                            "/verbosity:normal"
                            "/nologo"
                            "/fileLogger"
                            "/fileLoggerParameters:LogFile=`"$projectBuildLog`""
                            "`"$($project.File)`""
                        )

                        $releaseProcess = Start-Process -FilePath $msBuildPath `
                            -ArgumentList $releaseBuildArgs `
                            -WorkingDirectory $solutionDir `
                            -NoNewWindow `
                            -Wait `
                            -PassThru `
                            -RedirectStandardOutput "$env:TEMP\msbuild_console_${projectName}.txt"

                        if ($releaseProcess.ExitCode -eq 0) {
                            Write-Host "  + " -NoNewline -ForegroundColor Green
                            Write-Host "$projectName " -NoNewline -ForegroundColor White
                            Write-Host "built in Release mode (Debug too large)" -ForegroundColor Yellow
                            $successCount++
                            if ($pass -eq 1) {
                                $builtSuccessfully[$projectName] = $true
                            }
                        } else {
                            Write-Host "  x " -NoNewline -ForegroundColor Red
                            Write-Host "$projectName " -NoNewline -ForegroundColor White
                            Write-Host "FAILED in both Debug and Release (exit code: $($releaseProcess.ExitCode))" -ForegroundColor Red
                            $failCount++
                            $failedProjects += $projectName
                            if ($projectName -in @('classes', 'data')) {
                                Write-Host ""
                                Write-Host "  *** CRITICAL: $projectName failed - all other apps depend on this. Aborting build. ***" -ForegroundColor Red
                                Write-Error-Custom "`nBuild aborted: critical project '$projectName' failed"
                                break
                            }
                        }
                    } else {
                        # Final pass or no circular deps - this is a real failure
                        Write-Host "  x " -NoNewline -ForegroundColor Red
                        Write-Host "$projectName " -NoNewline -ForegroundColor White
                        Write-Host "FAILED (exit code: $($buildProcess.ExitCode))" -ForegroundColor Red
                        $failCount++
                        $failedProjects += $projectName
                    }
                    
                    # Only show errors on last pass or if stopping on error
                    if ($failedProjects -contains $projectName) {
                        Copy-FailedLog $projectName
                        if (($StopOnError -and -not $hasCircularDeps) -or ($pass -eq $maxPasses)) {
                            # Show errors
                            if (Test-Path $projectBuildLog) {
                                $buildOutput = Get-Content $projectBuildLog -Raw
                                $errorLines = $buildOutput -split "`n" | Where-Object { $_ -match "\): error " } | Select-Object -First 5
                                
                                if ($errorLines) {
                                    Write-Host "  Build Errors:" -ForegroundColor Red
                                    foreach ($line in $errorLines) {
                                        if ($line.Trim()) {
                                            Write-Host "    $($line.Trim())" -ForegroundColor Yellow
                                        }
                                    }
                                    Write-Host "  Full log: build-output\build_${projectName}.log" -ForegroundColor Gray
                                }
                            }
                        }
                        
                        # On the final pass of a multi-pass (circular-dependency) build a
                        # compile failure cannot resolve -- every dependency has already
                        # been built by now -- so the project is never going to compile.
                        # Terminate immediately instead of grinding through the rest.
                        if ($maxPasses -gt 1 -and $pass -eq $maxPasses) {
                            Write-Host ""
                            Write-Host "  *** $projectName failed on the final pass ($pass of $maxPasses) - it will not compile. Aborting build. ***" -ForegroundColor Red
                            Write-Error-Custom "`nBuild aborted: '$projectName' failed on pass $pass and cannot be resolved"
                            exit 1
                        }

                        # Critical projects - fail immediately regardless of other settings
                        if ($projectName -in @('classes', 'data')) {
                            Write-Host ""
                            Write-Host "  *** CRITICAL: $projectName failed - all other apps depend on this. Aborting build. ***" -ForegroundColor Red
                            Write-Error-Custom "`nBuild aborted: critical project '$projectName' failed in pass $pass"
                            break
                        }

                        # Only stop on error if not dealing with circular dependencies
                        if ($StopOnError -and -not $hasCircularDeps) {
                            Write-Error-Custom "`nStopping build due to error in $projectName"
                            break
                        }
                    }
                }
                
            } catch {
                Write-Host "  x " -NoNewline -ForegroundColor Red
                Write-Host "$projectName " -NoNewline -ForegroundColor White  
                Write-Host "exception: $_" -ForegroundColor Red
                $failCount++
                $failedProjects += $projectName
                Copy-FailedLog $projectName
                
                if ($projectName -in @('classes', 'data')) {
                    Write-Host ""
                    Write-Host "  *** CRITICAL: $projectName failed - all other apps depend on this. Aborting build. ***" -ForegroundColor Red
                    Write-Error-Custom "`nBuild aborted: critical project '$projectName' failed"
                    break
                }

                if ($StopOnError -and -not $hasCircularDeps) {
                    break
                }
            } finally {
                # Clean up temp console output
                $tempConsole = "$env:TEMP\msbuild_console_${projectName}.txt"
                if (Test-Path $tempConsole) {
                    Remove-Item $tempConsole -Force -ErrorAction SilentlyContinue
                }
            }
        }
        
        # Pass summary
        Write-Host "`n--- Pass $pass Summary ---" -ForegroundColor Magenta
        Write-Host "  Total projects: $($buildOrder.Count)" -ForegroundColor Gray
        if ($skippedCount -gt 0) {
            Write-Host "  Skipped (already built): $skippedCount" -ForegroundColor Cyan
        }
        Write-Success "  Succeeded: $successCount"
        if ($failCount -gt 0) {
            Write-Warning "  Failed: $failCount"
            if ($failedProjects.Count -le 10) {
                Write-Host "  Failed projects: $($failedProjects -join ", ")" -ForegroundColor Gray
            }
        }
        
        # Check if we can stop early
        if ($failCount -eq 0) {
            $overallSuccess = $true
            Write-Success "`n+ All projects built successfully!"
            break
        }
        
        # If this is not the last pass, continue
        if ($pass -lt $maxPasses) {
            Write-Info "`nProceeding to pass $($pass + 1) to resolve circular dependencies..."
            Start-Sleep -Seconds 2
        }
    }
    
    # Final summary
    Write-Host "`n--- Final Build Summary ---" -ForegroundColor Magenta
    if ($overallSuccess) {
        Write-Success "All projects built successfully"
    } else {
        Write-Error-Custom "Build completed with errors"
        exit 1
    }
}

Write-Host "`n=== Compilation Complete ===" -ForegroundColor Magenta
Write-Host ("Finished: " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss")) -ForegroundColor Gray
exit 0

#endregion
