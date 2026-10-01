<#
.SYNOPSIS
    Start-Job.ps1 — CLI khoi dong tac vu backup/restore ReimageTool

.DESCRIPTION
    Ghi job.json, kiem tra an toan (S9, S11), dat boot mot lan vao WinPE,
    roi khoi dong lai may.

    CANH BAO: KHONG chay tren may phat trien.
              Chi chay trong VM Hyper-V hoac tren may lab.

    TRANG THAI: Ban khoi dau — chua thu nghiem tren may that (Phu luc A.2)

.PARAMETER Action
    backup hoac restore

.PARAMETER Store
    Chu cai o luu anh (mac dinh: D)

.PARAMETER Image
    Ten file anh WIM (khong can duong dan day du). Chi can khi Action=restore.
    De trong se hien danh sach de chon.

.PARAMETER Compress
    Muc nen: fast hoac maximum (mac dinh: fast)

.PARAMETER WhatIf
    Hien thi nhung gi se lam nhung KHONG ghi job.json, KHONG dat boot, KHONG reboot.

.EXAMPLE
    .\Start-Job.ps1 -Action backup
    .\Start-Job.ps1 -Action restore -Image "PC01_20261101-0930.wim"
    .\Start-Job.ps1 -Action backup -WhatIf
#>
param(
    [Parameter(Mandatory)]
    [ValidateSet("backup", "restore")]
    [string]$Action,

    [string]$Store    = "D",
    [string]$Image,
    [ValidateSet("fast", "maximum")]
    [string]$Compress = "fast",
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"
$logDir = "$env:ProgramData\ReimageTool\logs"
New-Item -ItemType Directory -Force $logDir | Out-Null
$logFile = Join-Path $logDir "startjob-$(Get-Date -Format yyyyMMdd-HHmmss).log"

function Log($m) {
    $line = "$(Get-Date -Format s)  $m"
    Write-Host $line
    $line | Add-Content -LiteralPath $logFile -Encoding UTF8
}

if ($WhatIf) { Log "[WHATIF] Che do WhatIf: se hien thi nhung gi se lam, khong thay doi he thong." }

# ── S9: Kiem tra BitLocker ────────────────────────────────────────────────────
Log "Kiem tra BitLocker..."
foreach ($d in @("C:", "$($Store):")) {
    $bl = Get-BitLockerVolume -MountPoint $d -ErrorAction SilentlyContinue
    if ($bl -and $bl.VolumeStatus -ne "FullyDecrypted") {
        throw "BitLocker dang bat tren $d (Trang thai: $($bl.VolumeStatus)). Giai ma hoan toan truoc khi chay."
    }
}
Log "BitLocker: OK (tat tren C: va $($Store):)"

# ── S11: Kiem tra nguon dien (may xach tay) ──────────────────────────────────
Log "Kiem tra nguon dien..."
$battery = Get-WmiObject Win32_Battery -ErrorAction SilentlyContinue
if ($battery) {
    # BatteryStatus: 1=Discharging, 2=AC, 6=Charging, ...
    if ($battery.BatteryStatus -eq 1 -and $battery.EstimatedChargeRemaining -lt 30) {
        throw "May xach tay dang dung pin (con $($battery.EstimatedChargeRemaining)%). Cam dien truoc khi chay."
    }
    if ($battery.BatteryStatus -eq 1) {
        Log "[CANH BAO] May dang dung pin. Nen cam dien de an toan hon."
    } else {
        Log "Nguon dien: OK (cam dien hoac dang sac)"
    }
} else {
    Log "Nguon dien: May de ban, bo qua kiem tra pin."
}

# ── Kiem tra o luu anh ───────────────────────────────────────────────────────
$storePath  = "$($Store):"
$base       = "$storePath\Reimage"
$guidFile   = "$base\bootguid.txt"

if ($Action -ne "restore" -or $PSBoundParameters.ContainsKey("Image")) {
    if (-not (Test-Path $guidFile)) {
        throw "Chua chay Setup-Machine.bat hoac Setup WinPE. Khong tim thay: $guidFile"
    }
}

# ── Lay thong tin phan vung ───────────────────────────────────────────────────
$os    = Get-Partition -DriveLetter C
$st    = Get-Partition -DriveLetter $Store
$disk  = Get-Disk -Number $os.DiskNumber
$osVol = Get-Volume -DriveLetter C

if ($os.Guid -ieq $st.Guid) { throw "O luu anh trung voi o Windows. Chon o khac." }

Log "Phan vung Windows: Disk $($os.DiskNumber) Part $($os.PartitionNumber) GUID $($os.Guid) Nhan='$($osVol.FileSystemLabel)'"
Log "Phan vung luu anh : Disk $($st.DiskNumber) Part $($st.PartitionNumber) GUID $($st.Guid)"

# ── Xac dinh file anh ────────────────────────────────────────────────────────
if ($Action -eq "backup") {
    $imageName = "$($env:COMPUTERNAME)_$(Get-Date -Format yyyyMMdd-HHmm).wim"
    $usedBytes  = $osVol.Size - $osVol.SizeRemaining
    $freeBytes  = (Get-Volume -DriveLetter $Store).SizeRemaining
    $neededBytes = [long]($usedBytes * 0.7)
    Log "Phan vung Windows su dung: $([math]::Round($usedBytes/1GB, 1)) GB"
    Log "Cho trong tren $($Store):: $([math]::Round($freeBytes/1GB, 1)) GB"
    Log "Can khoang: $([math]::Round($neededBytes/1GB, 1)) GB"
    if ($freeBytes -lt $neededBytes) {
        throw "Khong du cho trong tren $($Store): (can $([math]::Round($neededBytes/1GB,1)) GB, con $([math]::Round($freeBytes/1GB,1)) GB)"
    }
}
else {
    # restore: chon file anh
    if (-not $Image) {
        $list = @(Get-ChildItem "$base\images\*.wim" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
        if ($list.Count -eq 0) { throw "Khong co anh nao trong $base\images" }
        Write-Host ""
        Write-Host "Danh sach anh backup:"
        for ($i = 0; $i -lt $list.Count; $i++) {
            Write-Host ("  {0}. {1,-40}  {2,6:F1} GB  {3}" -f ($i+1), $list[$i].Name, ($list[$i].Length/1GB), $list[$i].LastWriteTime.ToString("yyyy-MM-dd HH:mm"))
        }
        Write-Host ""
        $choice = [int](Read-Host "Chon so anh (1-$($list.Count))")
        $Image  = $list[$choice - 1].Name
    }
    $imageName = $Image

    $imgPath    = "$base\images\$imageName"
    $sha256Path = "$imgPath.sha256"
    if (-not (Test-Path $imgPath))    { throw "Khong tim thay anh: $imgPath" }
    if (-not (Test-Path $sha256Path)) { throw "Thieu file .sha256: $sha256Path" }
    Log "Anh restore: $imageName"
}

# ── Hien thi tom tat va xac nhan ─────────────────────────────────────────────
Write-Host ""
if ($Action -eq "restore") {
    Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Red
    Write-Host "║  SE XOA VA BUNG LAI:                                         ║" -ForegroundColor Red
    Write-Host "║  Disk   : $($os.DiskNumber)" -ForegroundColor Red
    Write-Host "║  Part   : $($os.PartitionNumber)" -ForegroundColor Red
    Write-Host "║  Dung luong: $([math]::Round($os.Size/1GB)) GB" -ForegroundColor Red
    Write-Host "║  Nhan   : '$($osVol.FileSystemLabel)'" -ForegroundColor Red
    Write-Host "║  Anh    : $imageName" -ForegroundColor Red
    Write-Host "╠══════════════════════════════════════════════════════════════╣" -ForegroundColor Yellow
    Write-Host "║  O $($Store): KHONG bi dong toi.                               ║" -ForegroundColor Yellow
    Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Yellow
    Write-Host ""
    if ($WhatIf) {
        Log "[WHATIF] Se hoi xac nhan: go XOA"
    } else {
        $confirm = Read-Host "Go XOA de tiep tuc (hay bam Enter de huy)"
        if ($confirm -ne "XOA") {
            Write-Host "Da huy. Khong co thay doi."
            exit 0
        }
    }
}
else {
    Write-Host "Se backup phan vung Windows thanh: $imageName"
    Write-Host "Anh se luu tai: $base\images\$imageName"
    if ($WhatIf) {
        Log "[WHATIF] Se hoi xac nhan: go OK"
    } else {
        $confirm = Read-Host "Go OK de tiep tuc (hay bam Enter de huy)"
        if ($confirm -ne "OK") {
            Write-Host "Da huy. Khong co thay doi."
            exit 0
        }
    }
}

# ── Ghi job.json ──────────────────────────────────────────────────────────────
$jobContent = @{
    action               = $Action
    hostname             = $env:COMPUTERNAME
    os_partition_guid    = $os.Guid
    os_label             = $osVol.FileSystemLabel
    os_size              = $os.Size
    disk_serial          = "$($disk.SerialNumber)".Trim()
    store_partition_guid = $st.Guid
    image                = "images\$imageName"
    image_index          = 1
    image_name           = "Win $($env:COMPUTERNAME) $(Get-Date -Format 'yyyy-MM-dd')"
    compress             = $Compress
}

if ($WhatIf) {
    Log "[WHATIF] Noi dung job.json se ghi:"
    $jobContent | ConvertTo-Json | Write-Host
} else {
    $jobContent | ConvertTo-Json | Set-Content "$base\job.json" -Encoding UTF8
    Log "Da ghi job.json"
}

# ── Dat boot mot lan vao WinPE ────────────────────────────────────────────────
$bootGuid = (Get-Content $guidFile -Encoding UTF8).Trim()
Log "Boot GUID: $bootGuid"

if ($WhatIf) {
    Log "[WHATIF] Se chay: bcdedit /bootsequence $bootGuid"
    Log "[WHATIF] Se chay: Restart-Computer -Force"
    Log "[WHATIF] Xong. He thong KHONG khoi dong lai."
} else {
    bcdedit /bootsequence $bootGuid
    Log "Da dat bootsequence. Khoi dong lai trong 5 giay..."
    Start-Sleep 5
    Restart-Computer -Force
}
