# Test script: clean source, then generate + build classes in Release then Debug
# Usage: .\test-classes-build.ps1

$accuraDir   = "F:\jenkins-workspaces\AccuraBuild-SQL\Accura"
$clarionBin  = "F:\jenkins-workspaces\AccuraBuild-SQL\Clarion\bin"
$clarionCL   = "$clarionBin\ClarionCL.exe"
$msBuild     = "C:\Windows\Microsoft.NET\Framework\v4.0.30319\msbuild.exe"
$configDir   = "C:\BuildScripts\ClarionConfigSQL"
$appFile     = "$accuraDir\classes.app"
$cwproj      = "$accuraDir\classes.cwproj"
$sourceDir   = "$accuraDir\genfiles\sqlsource"
$logDir      = "$accuraDir\build-output"

function Run-Config($config) {
    Write-Host ""
    Write-Host "=========================================" -ForegroundColor Cyan
    Write-Host "  $config BUILD" -ForegroundColor Cyan
    Write-Host "=========================================" -ForegroundColor Cyan

    # Clean source dir
    Write-Host "Cleaning $sourceDir..." -ForegroundColor Gray
    if (Test-Path $sourceDir) { Remove-Item "$sourceDir\*" -Recurse -Force }

    # Generate
    Write-Host "Generating classes.app with /rs $config..." -ForegroundColor Gray
    $genLog = "$logDir\test_generate_classes_$config.log"
    $p = Start-Process -FilePath $clarionCL `
        -ArgumentList "/ConfigDir", "`"$configDir`"", "/win", "/rs", $config, "/ag", "`"$appFile`"" `
        -WorkingDirectory $accuraDir `
        -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $genLog
    if ($p.ExitCode -ne 0) {
        Write-Host "  GENERATION FAILED (exit $($p.ExitCode))" -ForegroundColor Red
        return
    }
    Write-Host "  Generation OK" -ForegroundColor Green

    # Show exp dir state before build
    $expDir = "$accuraDir\genfiles\$($config.ToLower())\exp"
    Write-Host "  exp dir exists: $(Test-Path $expDir)" -ForegroundColor Gray
    if (Test-Path $expDir) {
        $expFiles = Get-ChildItem $expDir -Filter "classes*" -ErrorAction SilentlyContinue
        Write-Host "  classes*.exp present: $($expFiles.Count -gt 0)" -ForegroundColor Gray
    }

    # Build
    Write-Host "Building classes.cwproj ($config)..." -ForegroundColor Gray
    $buildLog = "$logDir\test_build_classes_$config.log"
    $buildArgs = @(
        "/property:GenerateFullPaths=true"
        "/t:Rebuild"
        "/property:Configuration=$config"
        "/property:ClarionBinPath=`"$clarionBin`""
        "/verbosity:normal"
        "/nologo"
        "/fileLogger"
        "/fileLoggerParameters:LogFile=`"$buildLog`""
        "`"$cwproj`""
    )
    $b = Start-Process -FilePath $msBuild `
        -ArgumentList $buildArgs `
        -WorkingDirectory $accuraDir `
        -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput "$env:TEMP\test_msbuild_classes_$config.txt"

    if ($b.ExitCode -eq 0) {
        Write-Host "  BUILD OK" -ForegroundColor Green
    } else {
        Write-Host "  BUILD FAILED (exit $($b.ExitCode))" -ForegroundColor Red
        Get-Content $buildLog | Where-Object { $_ -match "\): error " } | Select-Object -First 5 | ForEach-Object {
            Write-Host "  $_" -ForegroundColor Red
        }
    }

    # Show exp dir state after build
    Write-Host "  exp dir exists after build: $(Test-Path $expDir)" -ForegroundColor Gray
    if (Test-Path $expDir) {
        Get-ChildItem $expDir -Filter "classes*" | ForEach-Object { Write-Host "  Found: $($_.Name)" -ForegroundColor DarkGray }
    }
}

New-Item -ItemType Directory -Path $logDir -Force | Out-Null

Run-Config "Release"
Run-Config "Debug"

Write-Host ""
Write-Host "Done. Logs in $logDir" -ForegroundColor Cyan
