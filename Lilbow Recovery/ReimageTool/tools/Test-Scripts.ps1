param([string[]]$Files = @("ReimageTool.ps1", "winpe/engine.ps1"))
# Kiem tra cu phap + ma hoa + xuong dong cho cac script PowerShell cua LilbowRecovery.
# Quy tac: engine.ps1 = ASCII thuan + CRLF. ReimageTool.ps1 = UTF-8 CO BOM + CRLF.
# Chay: pwsh -NoProfile -File tools/Test-Scripts.ps1
#       pwsh -NoProfile -File tools/Test-Scripts.ps1 -Files ReimageTool.ps1,engine.ps1

$latin1 = [Text.Encoding]::GetEncoding(28591)
$cp1252  = [Text.Encoding]::GetEncoding(1252)
$script:failed = $false

function Test-Parse([string]$text, [string]$label) {
    $tokens = $null; $errs = $null
    [void][Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errs)
    if ($errs.Count -gt 0) {
        Write-Host "  [LOI] $label : $($errs.Count) loi cu phap" -ForegroundColor Red
        $errs | Select-Object -First 20 | ForEach-Object {
            Write-Host ("        dong {0}, cot {1}: {2}" -f `
                $_.Extent.StartLineNumber, $_.Extent.StartColumnNumber, $_.Message)
        }
        $script:failed = $true
    } else {
        Write-Host "  [OK]  $label : khong co loi cu phap" -ForegroundColor Green
    }
}

function Fail([string]$msg) {
    Write-Host "  [LOI] $msg" -ForegroundColor Red
    $script:failed = $true
}

function Pass([string]$msg) {
    Write-Host "  [OK]  $msg" -ForegroundColor Green
}

foreach ($f in $Files) {
    $path = if ([IO.Path]::IsPathRooted($f)) { $f } else {
        Join-Path (Split-Path $PSScriptRoot -Parent) $f
    }
    if (-not (Test-Path $path)) { Fail "Khong tim thay file: $path"; continue }
    Write-Host ""
    Write-Host "== $([IO.Path]::GetFileName($path))" -ForegroundColor Cyan

    $bytes  = [IO.File]::ReadAllBytes($path)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $raw    = $latin1.GetString($bytes)
    $lf     = ([regex]::Matches($raw, "(?<!\r)\n")).Count
    $crlf   = ([regex]::Matches($raw, "\r\n")).Count
    $nonAscii = @($bytes | Where-Object { $_ -gt 127 }).Count

    # Kiem tra xuong dong
    if ($crlf -eq 0 -and $lf -gt 0) {
        Fail "Toan bo xuong dong la LF (can CRLF) — $lf dong LF"
    } elseif ($lf -gt 0) {
        Fail "Co $lf dong LF don xen ke voi $crlf CRLF — can 100% CRLF"
    } else {
        Pass "Xuong dong CRLF ($crlf dong)"
    }

    $isEngine = ([IO.Path]::GetFileName($path)) -match "engine"

    # Kiem tra ma hoa
    if ($isEngine) {
        if ($nonAscii -gt 0) {
            Fail "engine.ps1 con $nonAscii byte ngoai ASCII (phai la ASCII thuan)"
            # Hien thi mot so dong co van de
            $lines = $raw -split "`n"
            $count = 0
            for ($i = 0; $i -lt $lines.Count -and $count -lt 5; $i++) {
                if ($lines[$i] -match '[^\x00-\x7F]') {
                    Write-Host ("        dong {0}: {1}" -f ($i+1), ($lines[$i].Substring(0, [Math]::Min(80,$lines[$i].Length))))
                    $count++
                }
            }
        } else {
            Pass "ASCII thuan (0 byte ngoai ASCII)"
        }
        if ($hasBom) { Fail "engine.ps1 co BOM — can la ASCII thuan khong BOM" }
    } else {
        if ($nonAscii -gt 0 -and -not $hasBom) {
            Fail "Co $nonAscii byte ngoai ASCII nhung THIEU BOM UTF-8"
        } elseif ($hasBom) {
            Pass "UTF-8 co BOM"
        } else {
            Pass "Khong co ky tu ngoai ASCII (ASCII thuan, khong can BOM)"
        }
    }

    # Kiem tra cu phap — doc UTF-8
    $utf8clean = if ($hasBom) {
        (New-Object Text.UTF8Encoding $false).GetString($bytes).TrimStart([char]0xFEFF)
    } else {
        (New-Object Text.UTF8Encoding $false).GetString($bytes)
    }
    Test-Parse $utf8clean "$([IO.Path]::GetFileName($path)) (doc UTF-8)"

    # Kiem tra cu phap — doc ANSI cp1252 (mo phong PowerShell 5.1 doc file khong BOM)
    if (-not $hasBom) {
        Test-Parse ($cp1252.GetString($bytes)) "$([IO.Path]::GetFileName($path)) (doc ANSI cp1252, kieu PowerShell 5.1)"
    }
}

Write-Host ""
if ($script:failed) {
    Write-Host "KET QUA: THAT BAI" -ForegroundColor Red -BackgroundColor DarkRed
    exit 1
} else {
    Write-Host "KET QUA: DAT" -ForegroundColor Green -BackgroundColor DarkGreen
    exit 0
}
