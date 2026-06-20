# generate.ps1 - PHASE: generate Clarion source from .app files (ClarionCL /ag).
# Split out of compile.ps1 so the generate phase can be run/tested on its own.
param(
    [Parameter()] [ValidateSet('Debug','Release')] [string]$Configuration = 'Release',
    [Parameter()] [bool]$StopOnError = $true,
    [Parameter()] [string]$SolutionPath = "accura.sln",
    [Parameter()] [string]$ClarionPath,
    [Parameter()] [string]$ConfigDir,
    [Parameter()] [ValidateSet('TPS','SQL','')] [string]$Mode = ''
)

. "$PSScriptRoot\common.ps1"

Write-Host "`n=== Generate Source ===" -ForegroundColor Magenta
Write-Host ("Started: " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss")) -ForegroundColor Gray

# Resolve shared paths / ensure build-output exists
$paths          = Resolve-BuildPaths -ClarionPath $ClarionPath -SolutionPath $SolutionPath
$ClarionPath    = $paths.ClarionPath
$clarionCL      = $paths.ClarionCL
$solutionDir    = $paths.SolutionDir
$buildOutputDir = $paths.BuildOutputDir
$failedLogsDir  = $paths.FailedLogsDir

# Generation resolves files via the Clarion bin redirection; ensure it is current.
$clarionBinRed = Join-Path $ClarionPath "bin\Clarion100.red"
if (Test-Path "C:\BuildScripts\RedFiles\Clarion100_bin.red") {
    Copy-Item "C:\BuildScripts\RedFiles\Clarion100_bin.red" $clarionBinRed -Force
    Write-Info "Deployed Clarion100.red to Clarion bin"
}
Write-Host "`n--- Step 1: Generating Source Code ---" -ForegroundColor Magenta
Write-Host "=============================================" -ForegroundColor Gray

# Ensure genfiles\Version directory exists and copy version files
$versionDir = "genfiles\Version"
if (-not (Test-Path $versionDir)) {
    New-Item -ItemType Directory -Path $versionDir -Force | Out-Null
    Write-Info "Created $versionDir directory"
}

# Copy .version files from BuildScripts backup
$versionBackup = "C:\BuildScripts\VersionFiles"
if (Test-Path $versionBackup) {
    Copy-Item "$versionBackup\*.Version" -Destination $versionDir -Force
    $copiedCount = (Get-ChildItem "$versionDir\*.Version").Count
    Write-Info "Copied $copiedCount .version files to workspace"
} else {
    Write-Warning "Version file backup not found at: $versionBackup"
}

# Get all app files from solution
Write-Info "Parsing solution for app files..."
$apps = Get-AppFilesFromSolution $SolutionPath
Write-Info "Found $($apps.Count) application files"

$generateLog = Join-Path $buildOutputDir "generate.log"
$successCount = 0
$failCount = 0

# Clear previous log
if (Test-Path $generateLog) {
    Remove-Item $generateLog -Force
}

Write-Host ""
foreach ($app in $apps) {
    $appName = $app.Name
    Write-Host "  [$($successCount + $failCount + 1)/$($apps.Count)] Generating: " -NoNewline -ForegroundColor Gray
    Write-Host "$appName.app" -ForegroundColor Cyan
    
    try {
        $appLog = Join-Path $buildOutputDir "generate_$appName.log"
        $effectiveConfigDir = if ($ConfigDir) { $ConfigDir } else { "C:\BuildScripts\ClarionConfig" }
        
        $appErrLog = Join-Path $buildOutputDir "generate_$appName.err.log"
        $genProcess = Start-Process -FilePath $clarionCL `
            -ArgumentList "/ConfigDir", "`"$effectiveConfigDir`"", "/win", "/rs", $Configuration, "/ag", "`"$($app.AppFile)`"" `
            -WorkingDirectory $solutionDir `
            -NoNewWindow `
            -Wait `
            -PassThru `
            -RedirectStandardOutput $appLog `
            -RedirectStandardError $appErrLog
        
        # Append to master log (stdout + stderr)
        if (Test-Path $appLog) {
            Add-Content -Path $generateLog -Value "=== $appName.app ==="
            Get-Content $appLog | Add-Content -Path $generateLog
            Add-Content -Path $generateLog -Value ""
        }
        if ((Test-Path $appErrLog) -and (Get-Item $appErrLog).Length -gt 0) {
            Add-Content -Path $generateLog -Value "=== $appName.app (stderr) ==="
            Get-Content $appErrLog | Add-Content -Path $generateLog
            Add-Content -Path $generateLog -Value ""
        }
        
        if ($genProcess.ExitCode -eq 0) {
            Write-Host "    + " -NoNewline -ForegroundColor Green
            Write-Host "Generated successfully" -ForegroundColor Gray
            $successCount++
        } else {
            Write-Host "    x " -NoNewline -ForegroundColor Red
            Write-Host "Generation failed (exit code: $($genProcess.ExitCode))" -ForegroundColor Yellow

            # Show errors and last lines from stdout log (last lines captures stack traces)
            if (Test-Path $appLog) {
                $genLines = Get-Content $appLog
                $genErrors = $genLines | Where-Object { $_ -match "error" } | Select-Object -First 5
                if ($genErrors) {
                    foreach ($line in $genErrors) {
                        if ($line.Trim()) {
                            Write-Host "      $($line.Trim())" -ForegroundColor Yellow
                        }
                    }
                }
                # Also show last 20 lines for stack trace / procedure context
                $lastLines = $genLines | Select-Object -Last 20
                if ($lastLines) {
                    Write-Host "      [last lines of log]:" -ForegroundColor DarkYellow
                    $lastLines | ForEach-Object { if ($_.Trim()) { Write-Host "      $($_.Trim())" -ForegroundColor Yellow } }
                }
            }
            # Show stderr (captures dialog text / unhandled exceptions)
            if ((Test-Path $appErrLog) -and (Get-Item $appErrLog).Length -gt 0) {
                Write-Host "      [stderr]:" -ForegroundColor DarkYellow
                Get-Content $appErrLog | Select-Object -First 10 | ForEach-Object {
                    if ($_.Trim()) { Write-Host "      $($_.Trim())" -ForegroundColor Yellow }
                }
            }

            # If the .app could not be opened, try re-importing from vcDevelopment then retry generation once
            $vcFolder = Join-Path (Get-VcOutputFolder $solutionDir) $appName
            $claInterfacePath = "C:\Program Files (x86)\UpperParkSolutions\claInterface\ClaInterface.exe"
            $upstxaFile = Join-Path $solutionDir "$appName.upstxa"
            $retried = $false

            if ((Test-Path $vcFolder) -and (Test-Path $claInterfacePath)) {
                Write-Host "      Attempting re-import from vcDevelopment and retrying..." -ForegroundColor DarkYellow

                $buildTxaArgs = "/quiet /ConfigDir `"$effectiveConfigDir`" COMMAND=BUILDTXA INPUT=`"$vcFolder`" OUTPUT=`"$upstxaFile`" APPNAME=`"$appName`""
                $txaProc = Start-Process -FilePath $claInterfacePath -ArgumentList $buildTxaArgs -Wait -NoNewWindow -PassThru

                if ($txaProc.ExitCode -eq 0 -and (Test-Path $upstxaFile)) {
                    $importArgs = "/ConfigDir `"$effectiveConfigDir`" /ai `"$($app.AppFile)`" `"$upstxaFile`""
                    $importProc = Start-Process -FilePath $clarionCL -ArgumentList $importArgs -Wait -NoNewWindow -PassThru

                    if (Test-Path $upstxaFile) { Remove-Item $upstxaFile -Force }

                    if ($importProc.ExitCode -eq 0) {
                        # Retry generation
                        $retryLog    = Join-Path $buildOutputDir "generate_${appName}_retry.log"
                        $retryErrLog = Join-Path $buildOutputDir "generate_${appName}_retry.err.log"
                        $retryProcess = Start-Process -FilePath $clarionCL `
                            -ArgumentList "/ConfigDir", "`"$effectiveConfigDir`"", "/win", "/rs", $Configuration, "/ag", "`"$($app.AppFile)`"" `
                            -WorkingDirectory $solutionDir `
                            -NoNewWindow -Wait -PassThru `
                            -RedirectStandardOutput $retryLog `
                            -RedirectStandardError $retryErrLog

                        if ($retryProcess.ExitCode -eq 0) {
                            Write-Host "    + " -NoNewline -ForegroundColor Green
                            Write-Host "Generated successfully (after re-import)" -ForegroundColor Gray
                            $successCount++
                            $retried = $true
                        } else {
                            Write-Host "      Re-import retry also failed (exit code: $($retryProcess.ExitCode))" -ForegroundColor Yellow
                            if (Test-Path $retryLog) {
                                $retryLines = Get-Content $retryLog
                                $retryErrors = $retryLines | Where-Object { $_ -match "error" } | Select-Object -First 5
                                if ($retryErrors) {
                                    $retryErrors | ForEach-Object { if ($_.Trim()) { Write-Host "      $($_.Trim())" -ForegroundColor Yellow } }
                                }
                                $retryLast = $retryLines | Select-Object -Last 20
                                if ($retryLast) {
                                    Write-Host "      [last lines of retry log]:" -ForegroundColor DarkYellow
                                    $retryLast | ForEach-Object { if ($_.Trim()) { Write-Host "      $($_.Trim())" -ForegroundColor Yellow } }
                                }
                            }
                            if ((Test-Path $retryErrLog) -and (Get-Item $retryErrLog).Length -gt 0) {
                                Get-Content $retryErrLog | Select-Object -First 5 | ForEach-Object {
                                    if ($_.Trim()) { Write-Host "      [stderr] $($_.Trim())" -ForegroundColor Yellow }
                                }
                            }
                        }
                    } else {
                        Write-Host "      Re-import failed (exit code: $($importProc.ExitCode))" -ForegroundColor Yellow
                    }
                } else {
                    Write-Host "      Failed to build TXA for re-import (exit code: $($txaProc.ExitCode))" -ForegroundColor Yellow
                    if (Test-Path $upstxaFile) { Remove-Item $upstxaFile -Force }
                }
            }

            if (-not $retried) {
                $failCount++
                if ($StopOnError) {
                    Write-Error-Custom "Generation failed for $appName. Stopping."
                    exit 1
                }
            }
        }
        
    } catch {
        Write-Host "    x " -NoNewline -ForegroundColor Red
        Write-Host "Generation failed: $_" -ForegroundColor Yellow
        $failCount++
        
        if ($StopOnError) {
            Write-Error-Custom "Generation failed for $appName. Stopping."
            exit 1
        }
    }
}

Write-Host ""
Write-Host "=============================================" -ForegroundColor Gray
if ($failCount -eq 0) {
    Write-Success "All $successCount apps generated successfully"
} else {
    Write-Warning "Generation complete: $successCount succeeded, $failCount failed"
    Write-Host "Full generation log: $generateLog" -ForegroundColor Gray
    
    if ($StopOnError) {
        Write-Error-Custom "Generation had failures. Stopping."
        exit 1
    }
}

Write-Host "
Generate phase complete." -ForegroundColor Magenta
exit 0

