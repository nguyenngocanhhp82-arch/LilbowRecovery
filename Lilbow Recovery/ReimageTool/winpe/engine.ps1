# X:\engine.ps1 — Chay trong WinPE
# TRANG THAI: Ban khoi dau — chua thu nghiem tren may that (Phu luc A.3)
# Moi thong bao trong file nay PHAI la tieng Viet KHONG dau
# (console WinPE co the khong hien thi dau tieng Viet)
#
# CANH BAO: KHONG chay file nay tren may phat trien Windows.
#           Chi chay trong WinPE (VM hoac may lab).

$ErrorActionPreference = "Stop"
$reportUrl = ""   # Dien URL webhook nhan trang thai, de trong thi bo qua
$script:job       = $null
$script:base      = $null
$script:pastPoint = $false          # True = da qua diem format, khong quay lai duoc
$log = "X:\engine.log"

# ── Tien ich ─────────────────────────────────────────────────────────────────

# Chuan hoa chuoi: xoa ky tu dac biet, chuyen uppercase
# Dung de so sanh serial dia (NVMe co the co dinh dang khac giua Windows va WinPE)
function Norm($s) { ("$s" -replace "[^A-Za-z0-9]", "").ToUpper() }

function Log($m) {
    $line = "$(Get-Date -Format s)  $m"
    Write-Host $line
    $line | Add-Content -LiteralPath $log -Encoding UTF8
}

function Report($s) {
    if (-not $reportUrl) { return }
    try {
        $body = @{ host = $script:job.hostname; status = $s } | ConvertTo-Json
        Invoke-RestMethod -Uri $reportUrl -Method Post -ContentType "application/json" -Body $body -TimeoutSec 10 | Out-Null
    }
    catch { Log "Canh bao: Khong gui duoc webhook: $_" }
}

# Ghi ket qua vao result.json va copy log
function Finish($status, $msg) {
    Log "$status — $msg"
    Report "$status $msg"
    if ($script:base) {
        @{
            status  = $status
            message = $msg
            action  = if ($script:job) { $script:job.action } else { "unknown" }
            time    = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
        } | ConvertTo-Json | Set-Content -LiteralPath "$($script:base)\result.json" -Encoding UTF8
        $logDest = "$($script:base)\logs\engine-$(Get-Date -Format yyyyMMdd-HHmmss).log"
        Copy-Item -LiteralPath $log -Destination $logDest -ErrorAction SilentlyContinue
    }
}

# Dung an toan TRUOC diem format: ghi DUNG, reboot ve Windows cu
function Stop-Safe($m) {
    Finish "DUNG" $m
    Log "Dung an toan. Reboot sau 10 giay..."
    Start-Sleep 10
    wpeutil reboot
    exit 1
}

# Dam bao phan vung co chu cai o dia, tra ve "X:"
function Ensure-Letter($p) {
    if (-not $p.DriveLetter) {
        try {
            $p | Add-PartitionAccessPath -AssignDriveLetter -ErrorAction Stop | Out-Null
            $p = Get-Partition -DiskNumber $p.DiskNumber -PartitionNumber $p.PartitionNumber
        }
        catch {
            Log "Canh bao: Khong gan duoc chu cai cho phan vung Disk $($p.DiskNumber) Part $($p.PartitionNumber): $_"
            return $null
        }
    }
    return "$($p.DriveLetter):"
}

# Tim phan vung chua \Reimage\job.json (quet moi phan vung Basic)
function Find-Store {
    foreach ($p in @(Get-Partition | Where-Object { $_.Type -eq "Basic" })) {
        $letter = Ensure-Letter $p
        if (-not $letter) { continue }
        if (Test-Path "$letter\Reimage\job.json") {
            Log "Tim thay job.json tren phan vung $letter (Disk $($p.DiskNumber) Part $($p.PartitionNumber) GUID $($p.Guid))"
            return $p
        }
    }
    return $null
}

# ── Luong chinh ───────────────────────────────────────────────────────────────

try {
    Log "============================================================"
    Log "Bat dau ReimageTool engine"
    Log "============================================================"

    # ── Buoc 1: Tim o luu anh chua job.json ──────────────────────────────────
    $store = Find-Store
    if (-not $store) {
        Stop-Safe "Khong tim thay \Reimage\job.json. Khong co job, hoac o luu anh bi BitLocker khoa."
    }

    $R = Ensure-Letter $store
    $script:base = "$R\Reimage"

    # ── Buoc 2: Doc job, chuyen job.json vao logs NGAY (S8) ──────────────────
    $rawJob = Get-Content "$($script:base)\job.json" -Raw -Encoding UTF8
    $job    = $rawJob | ConvertFrom-Json
    $script:job = $job

    New-Item -ItemType Directory -Force "$($script:base)\logs" | Out-Null

    # Chuyen job.json vao logs ngay de tranh chay lai ngoai y muon (S8)
    $archivedJob = "$($script:base)\logs\job-$(Get-Date -Format yyyyMMdd-HHmmss).json"
    Move-Item "$($script:base)\job.json" $archivedJob -Force
    Log "Da chuyen job.json vao: $archivedJob (S8)"

    Report "Vao WinPE: $($job.action)"
    Log "Action: $($job.action)  Host: $($job.hostname)"

    # ── Buoc 3: Kiem tra GUID o luu anh khop job (S3) ────────────────────────
    if ($job.store_partition_guid -ine $store.Guid) {
        Stop-Safe "GUID o luu anh khong khop job. job=$($job.store_partition_guid) thuc=$($store.Guid)"
    }

    # ── Buoc 4: Xac dinh phan vung Windows theo S1, S2, S3 ───────────────────
    Log "Xac dinh phan vung Windows..."

    # S1: Dung GUID, khong dung chu cai
    $tp = Get-Partition | Where-Object { $_.Guid -ieq $job.os_partition_guid }
    if (-not $tp) {
        Stop-Safe "Khong tim thay phan vung Windows theo GUID: $($job.os_partition_guid)"
    }

    # S3: Phan vung Windows khong duoc trung phan vung luu anh
    if ($tp.Guid -ieq $store.Guid) {
        Stop-Safe "Phan vung Windows trung voi phan vung luu anh. Dung vi muc dich bao ve du lieu."
    }

    # S2: Kiem tra serial dia
    $disk = Get-Disk -Number $tp.DiskNumber
    if ((Norm $disk.SerialNumber) -ne (Norm $job.disk_serial)) {
        Stop-Safe "Sai o dia (serial khong khop). job=$(Norm $job.disk_serial) thuc=$(Norm $disk.SerialNumber)"
    }

    # S2: Kiem tra dung luong (sai lech khong qua 100 MB)
    $sizeDiff = [math]::Abs([int64]$tp.Size - [int64]$job.os_size)
    if ($sizeDiff -gt 100MB) {
        Stop-Safe "Sai dung luong phan vung ($([math]::Round($sizeDiff/1MB)) MB lech, cho phep 100 MB)."
    }

    # S2: Kiem tra NTFS va nhan
    $vol = Get-Volume -Partition $tp
    if ($vol.FileSystem -ne "NTFS") {
        Stop-Safe "He thong tap tin khong phai NTFS: $($vol.FileSystem). Co the BitLocker dang bat?"
    }
    if ($vol.FileSystemLabel -ne $job.os_label) {
        Stop-Safe "Nhan phan vung khong khop. job='$($job.os_label)' thuc='$($vol.FileSystemLabel)'"
    }

    # S2: Kiem tra thu muc \Windows\System32 ton tai
    $W = Ensure-Letter $tp
    if (-not $W) { Stop-Safe "Khong gan duoc chu cai cho phan vung Windows." }
    if (-not (Test-Path "$W\Windows\System32")) {
        Stop-Safe "Phan vung dich khong chua $W\Windows\System32. Khong phai phan vung Windows hop le."
    }

    Log "Phan vung Windows hop le: $W (Disk $($tp.DiskNumber) Part $($tp.PartitionNumber) GUID $($tp.Guid))"
    Log "Toan bo kiem tra S1/S2/S3 da qua."

    # ── Duong dan anh ─────────────────────────────────────────────────────────
    $img = Join-Path $script:base $job.image

    # ── NHANH BACKUP ─────────────────────────────────────────────────────────
    if ($job.action -eq "backup") {

        # S6: Khong ghi de anh da co
        if (Test-Path $img) {
            Stop-Safe "File anh da ton tai: $img. Khong ghi de (S6)."
        }

        # Kiem tra cho trong
        $usedBytes = [int64]$vol.Size - [int64]$vol.SizeRemaining
        $freeBytes  = [int64](Get-Volume -Partition $store).SizeRemaining
        Log "Su dung: $([math]::Round($usedBytes/1GB, 1)) GB  Cho trong tren o luu anh: $([math]::Round($freeBytes/1GB, 1)) GB"
        if ($freeBytes -lt ($usedBytes * 0.7)) {
            Stop-Safe "Khong du cho trong tren o luu anh (can ~$([math]::Round($usedBytes*0.7/1GB, 1)) GB, con $([math]::Round($freeBytes/1GB, 1)) GB)."
        }

        # S6: Ghi vao _tmp truoc
        $tmpDir = "$($script:base)\images\_tmp"
        New-Item -ItemType Directory -Force $tmpDir | Out-Null
        $tmpFile = Join-Path $tmpDir (Split-Path $img -Leaf)
        Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue

        Log "Bat dau backup $W\ -> $tmpFile"
        Report "Dang backup..."

        $dismArgs = @(
            "/Capture-Image",
            "/ImageFile:$tmpFile",
            "/CaptureDir:$W\",
            "/Name:$($job.image_name)",
            "/Compress:$($job.compress)",
            "/CheckIntegrity"
        )
        & dism.exe $dismArgs
        if ($LASTEXITCODE -ne 0) { throw "DISM Capture-Image that bai (exit $LASTEXITCODE)" }

        # Xac nhan anh hop le
        & dism.exe /Get-WimInfo "/WimFile:$tmpFile" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "File anh vua tao bi loi (Get-WimInfo)" }

        # Tinh SHA256 va luu
        $hash = (Get-FileHash $tmpFile -Algorithm SHA256).Hash
        $hash | Set-Content "$img.sha256" -Encoding UTF8
        Log "SHA256: $hash"

        # S6: Chuyen anh ra images\ sau khi xac nhan xong
        Move-Item $tmpFile $img
        Log "Da chuyen anh sang: $img"

        Finish "XONG" "Backup hoan tat: $($job.image)"
        Log "Reboot ve Windows..."
        Start-Sleep 5
        wpeutil reboot
    }

    # ── NHANH RESTORE ────────────────────────────────────────────────────────
    elseif ($job.action -eq "restore") {

        # S5: Kiem tra anh TRUOC khi format bat ky thu gi
        if (-not (Test-Path $img)) { Stop-Safe "Khong tim thay file anh: $img" }
        if (-not (Test-Path "$img.sha256")) { Stop-Safe "Thieu file SHA256: $img.sha256" }

        # S5: Kiem tra hash
        Log "Dang kiem tra SHA256..."
        $expected = ((Get-Content "$img.sha256" -Raw -Encoding UTF8).Trim() -split "\s+")[0]
        $actual   = (Get-FileHash $img -Algorithm SHA256).Hash
        if ($actual -ne $expected) {
            Stop-Safe "Hash anh SAI. Expected=$expected Actual=$actual"
        }
        Log "SHA256 hop le."

        # S5: Kiem tra anh WIM hop le
        & dism.exe /Get-WimInfo "/WimFile:$img" | Out-Null
        if ($LASTEXITCODE -ne 0) { Stop-Safe "File WIM bi loi (kiem tra bang Get-WimInfo that bai)" }
        Log "File WIM hop le."

        # S5: Kiem tra phan vung EFI ton tai
        $efi = Get-Partition -DiskNumber $tp.DiskNumber |
               Where-Object { $_.GptType -eq "{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}" } |
               Select-Object -First 1
        if (-not $efi) { Stop-Safe "Khong tim thay phan vung EFI tren Disk $($tp.DiskNumber)" }
        Log "Phan vung EFI tim thay: Part $($efi.PartitionNumber)"

        Log "Toan bo kiem tra S5 da qua. Chuan bi format..."

        # ══ DIEM KHONG QUAY LAI (S7) ══════════════════════════════════════════
        Report "Bat dau xoa va bung anh..."
        $script:pastPoint = $true
        Log ">>> DIEM KHONG QUAY LAI: BAT DAU FORMAT <<<"

        # S4: Chi Format-Volume dung mot phan vung Windows
        Format-Volume -DriveLetter $W.Substring(0, 1) -FileSystem NTFS -NewFileSystemLabel $job.os_label -Force -Confirm:$false | Out-Null
        Log "Da format $W thanh cong."

        # Bung anh
        $dismArgs = @(
            "/Apply-Image",
            "/ImageFile:$img",
            "/Index:$($job.image_index)",
            "/ApplyDir:$W\"
        )
        & dism.exe $dismArgs
        if ($LASTEXITCODE -ne 0) { throw "DISM Apply-Image that bai (exit $LASTEXITCODE)" }
        Log "Da bung anh thanh cong."

        # Phuc hoi boot EFI
        $S = Ensure-Letter $efi
        & bcdboot.exe "$W\Windows" /s $S /f UEFI
        if ($LASTEXITCODE -ne 0) { throw "bcdboot that bai (exit $LASTEXITCODE)" }
        Log "bcdboot hoan tat. Windows la muc boot."

        Finish "XONG" "Restore hoan tat: $($job.image)"
        Log "Reboot ve Windows..."
        Start-Sleep 5
        wpeutil reboot
    }

    else {
        Stop-Safe "Action khong hop le trong job.json: '$($job.action)'. Chi chap nhan 'backup' hoac 'restore'."
    }
}
catch {
    # Xu ly loi theo S7
    if ($script:pastPoint) {
        # Da qua diem format: o lai WinPE de xu ly thu cong
        Finish "LOI" "SAU KHI DA XOA — $_"
        Log "=== O LAI WinPE. Can xu ly thu cong. ==="
        Log "Goi hotline IT de duoc ho tro."
    }
    else {
        # Chua format gi: reboot ve Windows cu
        Finish "LOI" "$_"
        Log "Reboot ve Windows cu sau 10 giay..."
        Start-Sleep 10
        wpeutil reboot
    }
}
