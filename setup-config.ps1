# Create config.json if it doesn't exist
if (-not (Test-Path '.\config.json')) {
    $config = @{
        clarion10Path = 'C:\Clarion\Clarion10Accura'
        mode = 'TPS'
    }
    
    $config | ConvertTo-Json | Set-Content '.\config.json' -Encoding UTF8
    Write-Host "Created config.json" -ForegroundColor Green
} else {
    Write-Host "config.json already exists" -ForegroundColor Cyan
}
