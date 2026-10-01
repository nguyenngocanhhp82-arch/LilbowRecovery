# X:\engine.ps1 - Chay trong WinPE
# TRANG THAI: Ban v1.2 - F4 (B1-B5) safety overhaul
# Moi thong bao trong file nay PHAI la tieng Viet KHONG dau va ASCII thuan.
# (console WinPE co the khong hien thi dau tieng Viet)
#
# CANH BAO: KHONG chay file nay tren may phat trien Windows.
#           Chi chay trong WinPE (VM hoac may lab).
#
# Lop bao ve da tich hop:
#   S13 - job_id, token, os_offset, expires_at, disk_guid (bat buoc)
#   S14 - selftest-ok.json bat buoc cho restore
#   S15 - state.json may trang thai, resume sau mat dien (B1)
#   S16 - WinPE lam mac dinh TRUOC format (xac nhan), Windows mac dinh SAU bcdboot (B4/B5/B8)
#   S17 - snapshot phan vung truoc/sau, sentinel.txt
#   S18 - chi restore anh co verified:true trong meta.json
#   S19 - toi da 3 lan thu, sau do vao che do cuu ho
#   S20 - kiem tra dia Healthy, pin/AC, khong phai USB
#   B2  - Assert-TargetSafe: kiem tra day du truoc format
#   B3  - Get-EfiForDisk: EFI dung dia chua Windows
#   B5  - BCD: backup truoc, so sanh truoc/sau bcdboot, KHONG xoa WinPE khoi displayorder
#   B6  - Backup: ghi vao _tmp, loi thi ve Windows (Stop-Safe)
#   B7  - Assert-DiskHealth: so sanh DeviceId chinh xac

$ErrorActionPreference = "Stop"
$reportUrl  = ""   # Dien URL webhook/Telegram, de trong thi bo qua
$script:job          = $null
$script:base         = $null
$script:pastPoint    = $false   # True = da qua diem format, STOP-SAFE bi cam
$script:attempts     = 0
$script:origDefault  = $null    # GUID mac dinh goc, chi doc 1 lan tu state.json hoac BCD
$script:winpeGuid    = $null    # GUID WinPE doc tu bootguid.txt
$script:efiLetter    = $null
$script:bcdStore     = $null
$log = "X:\engine.log"

# -- Tien ich co ban ----------------------------------------------------------

function Norm($s) { ("$s" -replace "[^A-Za-z0-9]", "").ToUpper() }

function Log($m) {
    $line = "$(Get-Date -Format s)  $m"
    Write-Host $line
    $line | Add-Content -LiteralPath $log -Encoding UTF8
}

function Report($s) {
    if (-not $reportUrl) { return }
    try {
        $body = @{ host=$env:COMPUTERNAME; job_id=if($script:job){$script:job.job_id}else{"?"}
                   phase=if($script:state){$script:state}else{"?"}; status=$s } | ConvertTo-Json
        Invoke-RestMethod -Uri $reportUrl -Method Post -ContentType "application/json" -Body $body -TimeoutSec 8 | Out-Null
    } catch { Log "Canh bao: Khong gui duoc report: $_" }
}

function Finish($status, $msg) {
    Log "$status - $msg"
    Report "$status $msg"
    if ($script:base) {
        @{ status=$status; message=$msg
           action=if($script:job){$script:job.action}else{"unknown"}
           time=(Get-Date -Format "yyyy-MM-ddTHH:mm:ss") } |
            ConvertTo-Json | Set-Content -LiteralPath "$($script:base)\result.json" -Encoding UTF8
        $logDest = "$($script:base)\logs\engine-$(Get-Date -Format yyyyMMdd-HHmmss).log"
        New-Item -ItemType Directory -Force "$($script:base)\logs" | Out-Null
        Copy-Item -LiteralPath $log -Destination $logDest -ErrorAction SilentlyContinue
    }
}

# Dung TRUOC diem format - ghi DUNG, dat boot ve Windows cu, reboot (B1: bi cam khi pastPoint=true)
function Stop-Safe($m) {
    if ($script:pastPoint) {
        # B1: Sau diem format, Stop-Safe bi cam, chuyen sang Stop-Danger
        Log "CANH BAO: Stop-Safe bi goi sau pastPoint - chuyen sang Stop-Danger"
        Stop-Danger "Kiem tra that bai sau diem format: $m"
        return
    }
    Finish "DUNG" $m
    # B5: Khi dung an toan, KHONG xoa WinPE khoi displayorder
    # Chi doi boot ve Windows cu, giu WinPE trong menu F12
    Set-WindowsAsDefault-Safe
    Log "Dung an toan. Reboot sau 10 giay..."
    Start-Sleep 10
    wpeutil reboot
    exit 1
}

# Dung NGUY HIEM (sau format) - vao che do cuu ho, KHONG reboot
function Stop-Danger($m) {
    Finish "LOI" $m
    Set-State "failed"
    Log "Trang thai NGUY HIEM. Vao che do cuu ho..."
    Enter-RescueMode
    exit 1
}

# -- May trang thai (S15/B1) ---------------------------------------------------

$script:state = "init"

function Set-State($phase) {
    $script:state = $phase
    if ($script:base) {
        @{ job_id      = if($script:job){$script:job.job_id}else{"?"}
           phase       = $phase
           attempts    = $script:attempts
           action      = if($script:job){$script:job.action}else{"?"}
           orig_default= $script:origDefault    # B1: luu orig_default vao state
           winpe_guid  = $script:winpeGuid
           efi_letter  = $script:efiLetter
           updated     = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss") } |
            ConvertTo-Json | Set-Content -LiteralPath "$($script:base)\state.json" -Encoding UTF8
    }
    Log "[STATE] $phase (lan thu $($script:attempts))"
}

# -- Che do cuu ho (S19) -------------------------------------------------------

function Enter-RescueMode {
    Log "=== CHE DO CUU HO ==="
    Log "Qua 3 lan thu that bai. WinPE o lai cho lenh tu xa."
    Log "Kiem tra log tai: $log"
    Log "Co the dung nut nguon tai cho de khoi dong lai may."
    $waited = 0
    while ($true) {
        Start-Sleep 30
        $waited += 30
        Report "rescue waited=${waited}s"
        $cmdFile = if ($script:base) { "$($script:base)\remote-cmd.txt" } else { $null }
        if ($cmdFile -and (Test-Path $cmdFile)) {
            $cmd = (Get-Content $cmdFile -Raw -EA SilentlyContinue).Trim()
            Remove-Item $cmdFile -Force -EA SilentlyContinue
            Log "Nhan lenh tu xa: $cmd"
            switch ($cmd) {
                "retry" {
                    # B(C5): retry phai goi lai Invoke-Restore, khong chi set state
                    $script:attempts = 0
                    Log "Lenh retry: chay lai restore..."
                    Set-State "checking"
                    return  # Thoat rescue loop, caller (Stop-Danger) da exit 1
                    # Ghi chu: vong lap chinh can goi lai Invoke-Restore sau Enter-RescueMode
                }
                "reboot"          { wpeutil reboot; exit }
                "reboot-windows"  {
                    # B5: reboot-windows phai qua duong B5 an toan
                    Set-WindowsAsDefault-Safe
                    Start-Sleep 3; wpeutil reboot; exit
                }
                "abort"           { Log "Lenh abort: tiep tuc o lai WinPE" }
                default           { Log "Lenh khong ro: $cmd" }
            }
        }
    }
}

# -- Quan ly boot EFI (S16/B3/B5) ---------------------------------------------

$script:efiLetter  = $null
$script:bcdStore   = $null

# B3: Tim EFI dung dia chua Windows, khong lay EFI dau tien cua ca may
function Get-EfiForDisk([int]$diskNumber) {
    $efi = Get-Partition -DiskNumber $diskNumber |
           Where-Object { $_.GptType -eq "{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}" } |
           Select-Object -First 1
    return $efi
}

# Fallback: tim EFI bao gom BCD store co GUID WinPE (dung cho selftest/stop-safe khi khong biet dia)
function Find-EFI-WithBCD {
    $candidates = @(Get-Partition | Where-Object { $_.GptType -eq "{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}" })
    foreach ($p in $candidates) {
        $letter = Ensure-Letter $p
        if (-not $letter) { continue }
        $bcd = "$letter\EFI\Microsoft\Boot\BCD"
        if (Test-Path $bcd) {
            # Uu tien EFI co BCD chua WinPE GUID
            if ($script:winpeGuid) {
                $out = & bcdedit /store $bcd /enum all 2>&1 | Out-String
                if ($out -match [regex]::Escape($script:winpeGuid)) {
                    $script:efiLetter = $letter
                    $script:bcdStore  = $bcd
                    Log "Tim thay EFI co BCD chua WinPE: $letter"
                    return
                }
            }
            # Fallback: BCD dau tien tim duoc
            if (-not $script:efiLetter) {
                $script:efiLetter = $letter
                $script:bcdStore  = $bcd
            }
        }
    }
    if ($script:efiLetter) { Log "EFI (fallback): $script:efiLetter" }
}

function Init-BcdStore {
    if (-not $script:efiLetter) { Find-EFI-WithBCD }
    if (-not $script:efiLetter) { Log "Canh bao: Khong tim thay EFI"; return }
    if (-not $script:bcdStore) { $script:bcdStore = "$($script:efiLetter)\EFI\Microsoft\Boot\BCD" }
    try {
        $out = & bcdedit /store $script:bcdStore /enum "{bootmgr}" 2>&1 | Out-String
        if ($out -match "default\s+\{([0-9a-f\-]+)\}") {
            # B1: Chi ghi origDefault neu chua co (khong doc lai sau moi lan khoi dong)
            if (-not $script:origDefault) {
                $script:origDefault = "{$($Matches[1])}"
                Log "BCD origDefault (doc lan dau): $($script:origDefault)"
            }
        }
        Log "BCD store: $($script:bcdStore)"
    } catch { Log "Canh bao: Khong doc duoc BCD store: $_" }
}

# B5: Lay BCD_DISPLAYORDER truoc khi goi bcdboot (de so sanh sau)
function Get-BcdDisplayOrder {
    if (-not $script:bcdStore -or -not (Test-Path $script:bcdStore)) { return @() }
    try {
        $out = & bcdedit /store $script:bcdStore /enum "{bootmgr}" 2>&1 | Out-String
        $guids = [regex]::Matches($out, "\{[0-9a-f\-]+\}") | ForEach-Object { $_.Value }
        return $guids
    } catch { return @() }
}

# B5: Backup BCD truoc khi chinh sua
function Backup-Bcd($jobId) {
    if (-not $script:bcdStore -or -not $script:base) { return }
    try {
        $bkDir  = "$($script:base)\bcd-backups"
        New-Item -ItemType Directory -Force $bkDir | Out-Null
        $bkFile = "$bkDir\bcd-before-$jobId.bcd"
        & bcdedit /store $script:bcdStore /export $bkFile 2>&1 | Out-Null
        if (Test-Path $bkFile) { Log "Backup BCD: $bkFile (B5)" }
        else { Log "Canh bao: Khong backup duoc BCD (B5)" }
    } catch { Log "Canh bao: Loi backup BCD: $_" }
}

# Dat WinPE lam mac dinh (S16/B4 - phai xac nhan thanh cong truoc format)
function Set-WinPE-AsDefault {
    if (-not $script:bcdStore) { Init-BcdStore }
    if (-not $script:bcdStore -or -not (Test-Path $script:bcdStore)) {
        Stop-Safe "Khong tim thay BCD store - khong the dam bao an toan (B4/S16)"
        return $false
    }
    if (-not $script:winpeGuid) {
        Stop-Safe "Khong co bootguid.txt - khong the dat WinPE lam mac dinh (B4/S16)"
        return $false
    }
    try {
        & bcdedit /store $script:bcdStore /default $script:winpeGuid 2>&1 | Out-Null
        & bcdedit /store $script:bcdStore /timeout 3                 2>&1 | Out-Null
        # B4: Xac nhan lai - doc lai BCD kiem tra mac dinh dung la WinPE
        $verify = & bcdedit /store $script:bcdStore /enum "{bootmgr}" 2>&1 | Out-String
        if ($verify -match "default\s+\{([0-9a-f\-]+)\}" -and "{$($Matches[1])}" -eq $script:winpeGuid) {
            Log "Dat WinPE lam mac dinh boot: $($script:winpeGuid) - XAC NHAN OK (S16/B4)"
            return $true
        } else {
            Stop-Safe "Dat WinPE lam mac dinh THAT BAI khi xac nhan - khong the tiep tuc (B4)"
            return $false
        }
    } catch {
        Stop-Safe "Loi dat WinPE lam mac dinh: $_ (B4)"
        return $false
    }
}

# B5: Dat Windows lam mac dinh - KHONG xoa WinPE khoi displayorder
function Set-WindowsAsDefault-Safe {
    if (-not $script:bcdStore -or -not (Test-Path $script:bcdStore)) { return }
    try {
        $target = $null
        # B5: Dung origDefault neu khac WinPE
        if ($script:origDefault -and $script:origDefault -ne $script:winpeGuid) {
            $target = $script:origDefault
            Log "Phuc hoi mac dinh goc: $target (B5)"
        } else {
            # B5: Tim muc Windows con ton tai (khac WinPE)
            $bcdOut = & bcdedit /store $script:bcdStore /enum all 2>&1 | Out-String
            $entries = [regex]::Matches($bcdOut, "identifier\s+\{([0-9a-f\-]+)\}")
            foreach ($e in $entries) {
                $g = "{$($e.Groups[1].Value)}"
                if ($g -notin @("{bootmgr}","{current}","{default}","{ramdiskoptions}") -and
                    $g -ne $script:winpeGuid -and
                    $bcdOut -match [regex]::Escape($g) + "[\s\S]+?osdevice") {
                    $target = $g; break
                }
            }
            if ($target) { Log "Tim thay muc Windows: $target (B5)" }
        }
        if ($target) {
            & bcdedit /store $script:bcdStore /default $target 2>&1 | Out-Null
            & bcdedit /store $script:bcdStore /timeout 5       2>&1 | Out-Null
            Log "Mac dinh boot = Windows ($target) (S16/B5)"
        } else {
            Log "Canh bao: Khong tim duoc muc Windows trong BCD - giu nguyen (B5)"
        }
        # B5: KHONG xoa WinPE khoi displayorder - giu trong menu F12
    } catch { Log "Canh bao: Loi dat Windows default: $_" }
}

# B5/B8: Dat Windows moi lam mac dinh sau bcdboot (so sanh truoc/sau)
function Set-NewWindowsDefault($displayOrderBefore) {
    if (-not $script:bcdStore -or -not (Test-Path $script:bcdStore)) {
        Stop-Danger "Khong tim thay BCD store sau bcdboot (B8)"
        return $false
    }
    try {
        $after  = Get-BcdDisplayOrder
        $newGuids = $after | Where-Object { $_ -notin $displayOrderBefore -and $_ -ne $script:winpeGuid }
        if ($newGuids.Count -eq 1) {
            $winGuid = $newGuids[0]
            Log "Xac dinh muc Windows moi sau bcdboot: $winGuid (B5)"
            & bcdedit /store $script:bcdStore /default $winGuid 2>&1 | Out-Null
            & bcdedit /store $script:bcdStore /timeout 5        2>&1 | Out-Null
            # B8: Xac nhan mac dinh
            $verify = & bcdedit /store $script:bcdStore /enum "{bootmgr}" 2>&1 | Out-String
            if ($verify -match "default\s+\{([0-9a-f\-]+)\}" -and "{$($Matches[1])}" -eq $winGuid) {
                Log "Mac dinh boot = Windows moi $winGuid - XAC NHAN OK (S16/B8)"
                return $true
            } else {
                Stop-Danger "Dat Windows moi lam mac dinh THAT BAI khi xac nhan (B8)"
                return $false
            }
        } elseif ($newGuids.Count -eq 0) {
            Log "Canh bao: Khong co muc moi trong displayorder sau bcdboot - thu fallback (B5)"
            Set-WindowsAsDefault-Safe
            return $true
        } else {
            Stop-Danger "Co $($newGuids.Count) muc moi sau bcdboot - khong xac dinh duoc Windows (B5)"
            return $false
        }
    } catch {
        Stop-Danger "Loi xac dinh Windows sau bcdboot: $_ (B5/B8)"
        return $false
    }
}

# Xac nhan mac dinh KHONG con la WinPE (S16/B8)
function Assert-WindowsIsDefault {
    if (-not $script:bcdStore -or -not (Test-Path $script:bcdStore)) {
        Stop-Danger "Khong kiem tra duoc BCD sau bcdboot (B8)"
        return $false
    }
    try {
        $out = & bcdedit /store $script:bcdStore /enum "{bootmgr}" 2>&1 | Out-String
        if ($out -match "default\s+\{([0-9a-f\-]+)\}") {
            $cur = "{$($Matches[1])}"
            if ($cur -eq $script:winpeGuid) {
                Log "LOI NGHIEM TRONG: Mac dinh van la WinPE sau bcdboot! (B8)"
                Stop-Danger "Mac dinh boot van la WinPE sau khi bcdboot - S16 vi pham (B8)"
                return $false
            }
            Log "Xac nhan: Mac dinh la Windows ($cur) - dung (S16/B8)"
            return $true
        }
    } catch {
        Stop-Danger "Khong kiem tra duoc BCD default sau bcdboot: $_ (B8)"
        return $false
    }
    return $true
}

# -- Tien ich phan vung --------------------------------------------------------

function Ensure-Letter($p) {
    if (-not $p.DriveLetter) {
        try {
            $p | Add-PartitionAccessPath -AssignDriveLetter -EA Stop | Out-Null
            $p = Get-Partition -DiskNumber $p.DiskNumber -PartitionNumber $p.PartitionNumber
        } catch {
            Log "Canh bao: Khong gan duoc chu cai: Disk $($p.DiskNumber) Part $($p.PartitionNumber): $_"
            return $null
        }
    }
    return "$($p.DriveLetter):"
}

function Find-Store {
    foreach ($p in @(Get-Partition | Where-Object { $_.Type -eq "Basic" })) {
        $letter = Ensure-Letter $p
        if (-not $letter) { continue }
        $candidate = "$letter\LilbowRecovery"
        if (Test-Path "$candidate\job.json") { return $candidate }
        if (Test-Path "$letter\Reimage\job.json") { return "$letter\Reimage" }
    }
    return $null
}

# -- Kiem tra suc khoe dia (S20/B7) -------------------------------------------

function Assert-DiskHealth($diskNum) {
    try {
        # B7: So sanh DeviceId chinh xac (khong dung -match de tranh khop nham)
        $pd = @(Get-PhysicalDisk | Where-Object { "$($_.DeviceId)" -eq "$diskNum" })
        if ($pd.Count -ne 1) {
            # Fallback qua Get-Disk
            $d = Get-Disk -Number $diskNum -EA SilentlyContinue
            if ($d -and $d.HealthStatus -ne "Healthy") {
                Stop-Safe "Dia Disk$diskNum khong Healthy ($($d.HealthStatus)) - S20"
            }
            Log "Canh bao: Khong xac dinh duoc PhysicalDisk cho Disk $diskNum ($($pd.Count) ket qua) - bo qua kiem tra suc khoe (B7)"
            return
        }
        if ($pd[0].HealthStatus -ne "Healthy") {
            Stop-Safe "Dia $($pd[0].FriendlyName) khong Healthy ($($pd[0].HealthStatus)) - S20"
        }
        Log "Dia OK: $($pd[0].FriendlyName) - $($pd[0].HealthStatus) (S20/B7)"
    } catch { Log "Canh bao: Khong kiem tra duoc suc khoe dia: $_" }
}

function Assert-Power {
    try {
        $bat = Get-WmiObject Win32_Battery -EA SilentlyContinue
        if ($bat) {
            if ($bat.BatteryStatus -eq 1 -and $bat.EstimatedChargeRemaining -lt 50) {
                Stop-Safe "May xach tay: pin $($bat.EstimatedChargeRemaining)% < 50% va khong cam dien - S20"
            }
            Log "Nguon dien: Pin $($bat.EstimatedChargeRemaining)% Status=$($bat.BatteryStatus)"
        } else {
            Log "Nguon dien: May ban, bo qua kiem tra pin"
        }
    } catch { Log "Canh bao: Khong kiem tra duoc nguon dien: $_" }
}

# -- Kiem tra dich an toan truoc format (B2) -----------------------------------

function Assert-TargetSafe($osPart, $storePart, $job, [bool]$isResume) {
    # B2: Kiem tra cac truong bat buoc
    if (-not $job.token -or -not $job.os_offset -or -not $job.expires_at) {
        Stop-Safe "Job thieu truong bat buoc (token/os_offset/expires_at) - S13/B2"
    }
    # B2: Dich khac phan vung luu anh (S3)
    if ($osPart.Guid -ieq $storePart.Guid) {
        Stop-Safe "Phan vung dich trung voi phan vung luu anh - S3/B2"
    }
    # B2: Dich khong phai phan vung EFI
    if ($osPart.GptType -eq "{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}") {
        Stop-Safe "Phan vung dich la EFI - S3/B2"
    }
    # B2: Dich phai la phan vung du lieu Basic
    if ($osPart.GptType -ne "{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}") {
        Stop-Safe "Phan vung dich khong phai Basic data (GPT type: $($osPart.GptType)) - S3/B2"
    }
    # B2: Khong cho restore len o USB
    $disk = Get-Disk -Number $osPart.DiskNumber
    if ($disk.BusType -eq "USB") {
        Stop-Safe "Phan vung dich nam tren o USB - S3/B2"
    }
    # B2: Kiem tra dung luong
    if ([int64]$osPart.Size -ne [int64]$job.os_size) {
        Stop-Safe "Dung luong phan vung khong khop: $([int64]$osPart.Size) != $([int64]$job.os_size) - S2/B2"
    }
    # B2: Kiem tra offset
    if ([int64]$osPart.Offset -ne [int64]$job.os_offset) {
        Stop-Safe "Offset phan vung khong khop: $([int64]$osPart.Offset) != $([int64]$job.os_offset) - S13/B2"
    }
    # B2: Kiem tra disk_guid neu co
    if ($job.disk_guid -and $disk.Guid -and $disk.Guid -ne $job.disk_guid) {
        Stop-Safe "GUID dia khong khop: $($disk.Guid) != $($job.disk_guid) - B2"
    }
    # B2: Khi khong phai resume, kiem tra nhan va Windows con ton tai
    if (-not $isResume) {
        try {
            $vol = Get-Volume -Partition $osPart -EA SilentlyContinue
            if ($vol) {
                if ($vol.FileSystem -ne "NTFS") {
                    Stop-Safe "Phan vung dich khong phai NTFS ($($vol.FileSystem)) - co the dang ma hoa BitLocker? - S2/B2"
                }
                if ($job.os_label -and $vol.FileSystemLabel -ne $job.os_label) {
                    Log "Canh bao: Nhan phan vung khac job: '$($vol.FileSystemLabel)' != '$($job.os_label)' - B2 (canh bao, khong dung)"
                }
            }
            # Kiem tra co Windows
            $osL = Ensure-Letter $osPart
            if ($osL -and -not (Test-Path "$osL\Windows\System32")) {
                Stop-Safe "Phan vung dich khong chua Windows (S2/B2)"
            }
        } catch { Log "Canh bao: Khong kiem tra duoc NTFS/label: $_" }
    }
    Log "Assert-TargetSafe: OK (isResume=$isResume) - B2"
}

# -- Snapshot phan vung (S17) --------------------------------------------------

function Save-PartitionSnapshot {
    if (-not $script:base) { return }
    $snap = @(Get-Partition | Select-Object DiskNumber, PartitionNumber, Guid, Offset, Size, GptType)
    $snap | ConvertTo-Json | Set-Content -LiteralPath "$($script:base)\partitions-before.json" -Encoding UTF8
    Log "Chup bang phan vung truoc khi chay (S17): $($snap.Count) phan vung"
}

function Assert-OtherPartitionsIntact($osGuid) {
    if (-not $script:base) { return }
    $snapFile = "$($script:base)\partitions-before.json"
    if (-not (Test-Path $snapFile)) { Log "Canh bao: Khong co partitions-before.json - bo qua kiem tra S17"; return }
    try {
        $before = Get-Content $snapFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $after  = @(Get-Partition | Select-Object DiskNumber, PartitionNumber, Guid, Offset, Size)
        $errs   = @()
        foreach ($b in $before) {
            if ($b.Guid -ieq $osGuid) { continue }
            $a = $after | Where-Object { $_.Guid -ieq $b.Guid }
            if (-not $a) { $errs += "Mat phan vung $($b.Guid)" }
            elseif ([int64]$a.Offset -ne [int64]$b.Offset) { $errs += "Phan vung $($b.Guid) doi offset" }
            elseif ([int64]$a.Size   -ne [int64]$b.Size)   { $errs += "Phan vung $($b.Guid) doi size" }
        }
        if ($errs.Count -gt 0) {
            Stop-Danger "PHAN VUNG NGOAI BI THAY DOI (S17): $($errs -join '; ')"
        }
        if (-not (Test-Path "$($script:base)\sentinel.txt")) {
            Stop-Danger "Mat sentinel.txt tren o luu anh (S17)"
        }
        Log "Kiem tra phan vung ngoai: OK (S17)"
    } catch {
        if ($script:pastPoint) { Stop-Danger "Loi kiem tra phan vung (S17): $_" }
        else { Log "Canh bao S17: $_" }
    }
}

# -- Selftest (M4a / Lop 1) ----------------------------------------------------

function Run-Selftest {
    Log "=== BAT DAU SELFTEST ==="
    $result = @{
        time               = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
        model              = ""
        bios_version       = ""
        secure_boot        = $false
        disks_seen         = 0
        store_found        = $false
        os_partition_found = $false
        network_ok         = $false
        status             = "DANG_KIEM_TRA"
    }
    try { $cs = Get-WmiObject Win32_ComputerSystem -EA SilentlyContinue; $result.model = "$($cs.Manufacturer) $($cs.Model)".Trim() } catch {}
    try { $bios = Get-WmiObject Win32_BIOS -EA SilentlyContinue; $result.bios_version = $bios.SMBIOSBIOSVersion } catch {}
    try { $sb = Confirm-SecureBootUEFI -EA SilentlyContinue; $result.secure_boot = ($sb -eq $true) } catch { $result.secure_boot = $false }
    try { $result.disks_seen = (Get-Disk).Count } catch {}

    Log "  Model  : $($result.model)"
    Log "  BIOS   : $($result.bios_version)"
    Log "  Dia    : $($result.disks_seen)"

    $base = Find-Store
    if ($base) {
        $result.store_found = $true
        Log "  O luu anh: $base"
        $wims = @(Get-ChildItem "$base\images\*.wim" -EA SilentlyContinue | Select-Object -First 1)
        if ($wims.Count -gt 0) {
            try {
                $fs = [IO.File]::OpenRead($wims[0].FullName)
                $buf = New-Object byte[] 4096
                $fs.Read($buf, 0, 4096) | Out-Null
                $fs.Close()
                Log "  Doc thu anh WIM: OK ($($wims[0].Name))"
            } catch { Log "  Canh bao: Khong doc duoc anh WIM: $_" }
        }
    } else {
        Log "  CANH BAO: Khong tim thay o luu anh"
    }

    $reqFile = if ($base) { "$base\selftest-request.json" } else { $null }
    if ($reqFile -and (Test-Path $reqFile)) {
        try {
            $req = Get-Content $reqFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $op  = Get-Partition | Where-Object { $_.Guid -ieq $req.os_partition_guid } | Select-Object -First 1
            $result.os_partition_found = ($op -ne $null)
            Log "  Phan vung OS (GUID $($req.os_partition_guid)): $(if($result.os_partition_found){'Tim thay'}else{'KHONG tim thay'})"
        } catch { Log "  Canh bao: Khong doc selftest-request.json: $_" }
    } else {
        Log "  Khong co selftest-request.json - bo qua kiem tra phan vung OS"
        $result.os_partition_found = $true
    }

    if ($reportUrl) {
        try {
            $body = @{ host=$env:COMPUTERNAME; phase="selftest"; status="ping" } | ConvertTo-Json
            Invoke-RestMethod -Uri $reportUrl -Method Post -ContentType "application/json" -Body $body -TimeoutSec 8 | Out-Null
            $result.network_ok = $true
            Log "  Mang: OK"
        } catch { Log "  Canh bao: Khong gui duoc report (mang?): $_" }
    } else {
        try {
            $ping = Test-Connection -ComputerName "8.8.8.8" -Count 1 -Quiet -EA SilentlyContinue
            $result.network_ok = $ping
            Log "  Mang: $(if($ping){'Co mang'}else{'Khong co mang'})"
        } catch { Log "  Canh bao: Khong kiem tra duoc mang" }
    }

    $ok = $result.store_found -and $result.os_partition_found -and $result.disks_seen -gt 0
    $result.status = if ($ok) { "OK" } else { "THAT_BAI" }
    Log "  Ket qua selftest: $($result.status)"

    if ($base) {
        $result | ConvertTo-Json | Set-Content -LiteralPath "$base\selftest-ok.json" -Encoding UTF8
        Log "  Da ghi selftest-ok.json"
        if ($reqFile -and (Test-Path $reqFile)) { Remove-Item $reqFile -Force -EA SilentlyContinue }
    }

    # B5: Selftest khong xoa WinPE khoi displayorder
    Set-WindowsAsDefault-Safe
    Log "Selftest hoan tat. Reboot ve Windows sau 5 giay..."
    Start-Sleep 5
    wpeutil reboot
    exit 0
}

# -- Kiem tra selftest-ok.json (S14) ------------------------------------------

function Assert-SelftestValid {
    $sf = "$($script:base)\selftest-ok.json"
    if (-not (Test-Path $sf)) { Stop-Safe "Chua chay selftest - restore bi tu choi (S14)" }
    try {
        $st = Get-Content $sf -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($st.status -ne "OK") { Stop-Safe "Selftest that bai ($($st.status)) - restore bi tu choi (S14)" }
        $stTime = [datetime]$st.time
        if ((Get-Date) - $stTime -gt [TimeSpan]::FromDays(7)) {
            Stop-Safe "Selftest da qua 7 ngay - chay lai selftest truoc (S14)"
        }
        # B1: Khi resume, canh bao selftest het han nhung khong dung
        # (da xu ly o tang on - Assert-SelftestValid chi goi khi isResume=false)
        try {
            $cs    = Get-WmiObject Win32_ComputerSystem -EA SilentlyContinue
            $curM  = "$($cs.Manufacturer) $($cs.Model)".Trim()
            $bios  = Get-WmiObject Win32_BIOS -EA SilentlyContinue
            $curB  = $bios.SMBIOSBIOSVersion
            if ($st.model -and $st.model -ne $curM) {
                Stop-Safe "Model may thay doi ($($st.model) -> $curM) - S14"
            }
            if ($st.bios_version -and $st.bios_version -ne $curB) {
                Stop-Safe "BIOS thay doi ($($st.bios_version) -> $curB) - S14"
            }
        } catch { Log "Canh bao: Khong kiem tra duoc model/BIOS - cho qua (S14)" }
        Log "Selftest hop le: $($st.time) - $($st.model) (S14)"
    } catch {
        Stop-Safe "Khong doc duoc selftest-ok.json: $_ (S14)"
    }
}

# -- Kiem tra job (S13) --------------------------------------------------------

function Assert-JobValid($job) {
    if (-not $job.job_id) { Stop-Safe "Job thieu job_id (S13)" }
    if ($job.expires_at) {
        try {
            $exp = [datetime]$job.expires_at
            if ((Get-Date) -gt $exp) { Stop-Safe "Job het han luc $($job.expires_at) (S13)" }
            Log "Job het han: $($job.expires_at) - con han (S13)"
        } catch { Log "Canh bao: Khong parse duoc expires_at - bo qua" }
    } else {
        Log "Canh bao: Job khong co expires_at (S13)"
    }
}

# Kiem tra token tren phan vung OS (S13 - chi dung TRUOC format)
function Assert-TokenOnPartition($osDriveLetter, $job) {
    if (-not $job.token) { Stop-Safe "Job khong co token - S13 bat buoc (B2)" }
    $tokPath = "$osDriveLetter\ProgramData\LilbowRecovery\token.txt"
    if (-not (Test-Path $tokPath)) {
        Stop-Safe "Khong tim thay token.txt tren $osDriveLetter - S13"
    }
    $tok = (Get-Content $tokPath -Raw -EA SilentlyContinue).Trim()
    if ($tok -ne $job.token) {
        Stop-Safe "Token khong khop tren $osDriveLetter (S13)"
    }
    Log "Token xac nhan hop le tren $osDriveLetter (S13)"
}

# -- Kiem tra anh da xac minh (S18) -------------------------------------------

function Assert-ImageVerified($imagePath) {
    $metaPath = "$imagePath.meta.json"
    if (-not (Test-Path $metaPath)) {
        Stop-Safe "Anh '$imagePath' chua co meta.json - S18"
    }
    try {
        $meta = Get-Content $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($meta.verified -ne $true) {
            Stop-Safe "Anh '$imagePath' chua duoc xac minh (verified=$($meta.verified)) - S18"
        }
        Log "Anh da xac minh: $($meta.source_host) / Build $($meta.windows_build) (S18)"
    } catch { Stop-Safe "Khong doc duoc meta.json: $_ (S18)" }
}

# Xac minh anh sau khi backup (B6: ghi meta cho file tam)
function Verify-Image($imagePath) {
    Log "Xac minh anh sau backup (S18)..."
    $mnt   = "X:\mnt_verify"
    New-Item -ItemType Directory -Force $mnt | Out-Null
    $verif = $false
    $build = ""
    try {
        & dism.exe /Mount-Image /ImageFile:"$imagePath" /Index:1 /MountDir:"$mnt" /ReadOnly 2>&1 | ForEach-Object { Log "  [DISM-MNT] $_" }
        if ($LASTEXITCODE -ne 0) {
            Log "Canh bao: Mount anh that bai (exitcode $LASTEXITCODE) - verified=false"
        } else {
            $ok1 = Test-Path "$mnt\Windows\System32\winload.efi"
            $ok2 = Test-Path "$mnt\Windows\System32\config\SYSTEM"
            Log "  winload.efi: $ok1  config\SYSTEM: $ok2"
            $verif = $ok1 -and $ok2
            try { $build = (Get-Item "$mnt\Windows\System32\ntoskrnl.exe" -EA SilentlyContinue).VersionInfo.ProductVersion } catch {}
        }
    } catch {
        Log "Canh bao: Loi khi xac minh anh: $_"
    } finally {
        try { & dism.exe /Unmount-Image /MountDir:"$mnt" /Discard 2>&1 | Out-Null } catch {}
        Remove-Item $mnt -Force -EA SilentlyContinue
    }
    # Ghi meta.json
    @{  sha256        = (Get-FileHash $imagePath -Algorithm SHA256 -EA SilentlyContinue).Hash
        created       = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
        source_host   = $env:COMPUTERNAME
        windows_build = $build
        verified      = $verif } |
        ConvertTo-Json | Set-Content -LiteralPath "$imagePath.meta.json" -Encoding UTF8
    Log "  Ghi meta.json - verified=$verif build=$build"
    return $verif
}

# -- Nap driver theo model (M5a) -----------------------------------------------

function Inject-Drivers($windowsLetter) {
    $model = ""
    try { $cs = Get-WmiObject Win32_ComputerSystem -EA SilentlyContinue; $model = $cs.Model.Trim() } catch {}
    if (-not $model) { Log "Canh bao: Khong doc duoc model may - bo qua inject driver"; return }
    $drvDir = "$($script:base)\drivers\$model"
    if (-not (Test-Path $drvDir)) {
        Log "Khong co driver cho model '$model' - bo qua (M5a)"
        return
    }
    Log "Nap driver cho model '$model' tu $drvDir..."
    try {
        & dism.exe /Image:"$windowsLetter\" /Add-Driver /Driver:"$drvDir" /Recurse 2>&1 | ForEach-Object { Log "  [DISM-DRV] $_" }
        Log "Nap driver hoan tat (M5a)"
    } catch { Log "Canh bao: Loi nap driver: $_" }
}

# -- Kiem tra sau khi bung (M5a/B8) -------------------------------------------

function Assert-PostRestore($windowsLetter) {
    Log "Kiem tra sau khi bung anh (M5a)..."
    $ok = $true
    if (-not (Test-Path "$windowsLetter\Windows\System32\winload.efi")) {
        Log "THAT BAI: Khong tim thay winload.efi tren $windowsLetter"; $ok = $false
    } else { Log "  winload.efi: OK" }
    if (-not (Test-Path "$windowsLetter\Windows\System32\config\SYSTEM")) {
        Log "THAT BAI: Khong tim thay config\SYSTEM tren $windowsLetter"; $ok = $false
    } else { Log "  config\SYSTEM: OK" }
    if (-not $ok) { Stop-Danger "Kiem tra sau khi bung THAT BAI - Windows co the khong boot duoc (M5a/B8)" }
    Log "Kiem tra sau khi bung: OK"
}

# -- Tien ich ------------------------------------------------------------------

function Find-Partition-ByGuid($guid) {
    return Get-Partition | Where-Object { $_.Guid -ieq $guid } | Select-Object -First 1
}

function Assert-SerialMatch($disk, $job) {
    $norm = Norm $disk.SerialNumber
    $njob = Norm $job.disk_serial
    if ($norm -ne $njob) { return $false }
    return $true
}

function Compute-Sha256($path) {
    return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
}

# -----------------------------------------------------------------------------
#  MAIN
# -----------------------------------------------------------------------------

Log "=== LilbowRecovery engine v1.2 (F4: B1-B8) ==="
Log "  Thoi diem: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Log "  May: $env:COMPUTERNAME"

# -- Tim store -----------------------------------------------------------------
$script:base = Find-Store
if (-not $script:base) {
    Log "Khong tim thay thu muc LilbowRecovery voi job.json."
    # Khi khong co job/state, Init-BcdStore truoc roi dat lai mac dinh
    Init-BcdStore
    Set-WindowsAsDefault-Safe
    Log "Dat lai boot ve Windows. Reboot sau 10 giay..."
    Start-Sleep 10; wpeutil reboot; exit 0
}
Log "Store: $($script:base)"
New-Item -ItemType Directory -Force "$($script:base)\logs" | Out-Null

# -- Doc bootguid.txt (can truoc moi thu) -------------------------------------
if (Test-Path "$($script:base)\bootguid.txt") {
    $script:winpeGuid = (Get-Content "$($script:base)\bootguid.txt" -Raw).Trim()
    Log "WinPE GUID: $($script:winpeGuid)"
} else {
    Log "Canh bao: Khong co bootguid.txt"
}

# -- Kiem tra selftest action -------------------------------------------------
$selftestReq = "$($script:base)\selftest-request.json"
if (Test-Path $selftestReq) {
    Log "Phat hien selftest-request.json - chay selftest..."
    Init-BcdStore
    Run-Selftest
}

# ============================================================================
#  B1: DOC STATE TRUOC, QUYET DINH RESUME TRUOC KHI GHI BAT KY THU GI
# ============================================================================
$stateFile = "$($script:base)\state.json"
$isResume  = $false
$savedOrigDefault = $null

if (Test-Path $stateFile) {
    try {
        $st = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        # B1: Chi resume khi phase dang nguy hiem VA cung job
        $resumePhases = @("formatting","applying","boot-config","verifying","backup-running")
        if ($st.phase -in $resumePhases) {
            $script:attempts = [int]$st.attempts + 1
            Log "Phat hien state.json: phase=$($st.phase), lan thu=$($script:attempts) (S15/B1)"
            if ($script:attempts -gt 3) {
                Set-State "failed"
                Log "Qua 3 lan thu - vao che do cuu ho (S19)"
                Init-BcdStore
                Enter-RescueMode
                exit 1
            }
            $isResume = $true
            $script:pastPoint = $true  # B1: Bat pastPoint ngay khi resume
            # B1: Phuc hoi orig_default tu state.json (KHONG doc lai BCD)
            if ($st.orig_default) {
                $savedOrigDefault = $st.orig_default
                Log "B1: Phuc hoi orig_default tu state.json: $savedOrigDefault"
            }
            # B1: Phuc hoi efi_letter tu state.json
            if ($st.efi_letter) {
                $script:efiLetter = $st.efi_letter
                $script:bcdStore  = "$($st.efi_letter)\EFI\Microsoft\Boot\BCD"
                Log "B1: Phuc hoi efi_letter tu state.json: $($script:efiLetter)"
            }
            Log "RESUME: lan thu $($script:attempts) tu phase $($st.phase) (S15/B1)"
        } elseif ($st.phase -eq "done") {
            Log "State = done. Khoi dong chuan."
        } elseif ($st.phase -eq "failed") {
            # B1: State failed chi chan neu cung job_id - se kiem tra sau khi doc job
            Log "State = failed - kiem tra job_id truoc khi quyet dinh"
            $failedJobId = $st.job_id
        }
    } catch { Log "Canh bao: Khong doc duoc state.json: $_" }
}

# -- Khoi tao BCD store (neu chua co) -----------------------------------------
if (-not $script:efiLetter) { Init-BcdStore }

# B1: Ghi origDefault sau Init-BcdStore, nhung chi khi chua co tu state
if ($savedOrigDefault) {
    $script:origDefault = $savedOrigDefault
} elseif (-not $script:origDefault) {
    Log "origDefault doc tu BCD lan dau: $($script:origDefault)"
}

# -- Doc job.json --------------------------------------------------------------
$jobPath = "$($script:base)\job.json"
if (-not (Test-Path $jobPath)) {
    Log "Khong co job.json."
    Set-WindowsAsDefault-Safe
    Log "Reboot ve Windows sau 10 giay..."
    Start-Sleep 10; wpeutil reboot; exit 0
}

try {
    $script:job = Get-Content -LiteralPath $jobPath -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    Log "Khong doc duoc job.json: $_"
    Set-WindowsAsDefault-Safe; Start-Sleep 10; wpeutil reboot; exit 1
}

Log "Doc job: action=$($script:job.action)  job_id=$($script:job.job_id)"

# B1: Kiem tra state failed co cung job_id khong
if ($failedJobId -and $failedJobId -eq $script:job.job_id) {
    Log "State failed cung job_id $failedJobId - vao che do cuu ho (S19/B1)"
    Enter-RescueMode
    exit 1
} elseif ($failedJobId) {
    Log "State failed khac job_id ($failedJobId vs $($script:job.job_id)) - chay job moi"
    Remove-Item $stateFile -Force -EA SilentlyContinue
}

# B1: Khi resume, cac kiem tra het han KHONG dung
if (-not $isResume) {
    # -- Kiem tra job hop le (S13) -------------------------------------------
    Set-State "checking"
    Assert-JobValid $script:job
    # -- Kiem tra nguon dien va dia (S20) -------------------------------------
    Assert-Power
} else {
    Log "Resume mode: bo qua kiem tra het han / nguon dien (B1)"
    Set-State "resuming"
}

# -- Tim phan vung luu anh ----------------------------------------------------
$storePart = Find-Partition-ByGuid $script:job.store_partition_guid
if (-not $storePart) { Stop-Safe "Khong tim thay phan vung luu anh (GUID: $($script:job.store_partition_guid))" }
$storeL = Ensure-Letter $storePart
if (-not $storeL) { Stop-Safe "Khong gan duoc chu cai cho o luu anh" }

# ============================================================================
#  BACKUP
# ============================================================================
if ($script:job.action -eq "backup") {
    Log "=== BACKUP ==="

    # Tim phan vung OS
    $osPart = Find-Partition-ByGuid $script:job.os_partition_guid
    if (-not $osPart) { Stop-Safe "Khong tim thay phan vung OS (GUID: $($script:job.os_partition_guid))" }
    $osDisk = Get-Disk -Number $osPart.DiskNumber
    if (-not (Assert-SerialMatch $osDisk $script:job)) { Stop-Safe "Serial dia OS khong khop" }
    $osL = Ensure-Letter $osPart
    if (-not $osL -or -not (Test-Path "$osL\Windows\System32")) { Stop-Safe "Phan vung OS khong co Windows" }
    Assert-DiskHealth $osPart.DiskNumber

    $imgName   = $script:job.image
    # B2: Khong cho '..' hoac duong dan tuyet doi trong ten anh
    if ($imgName -match "\.\." -or [IO.Path]::IsPathRooted($imgName)) {
        Stop-Safe "Ten file anh khong hop le: $imgName (B2)"
    }

    $imagesDir = "$storeL\LilbowRecovery\images"
    $tmpDir    = "$imagesDir\_tmp"
    $imagePath = "$imagesDir\$imgName"
    $tmpPath   = "$tmpDir\$imgName"

    if (Test-Path $imagePath) { Stop-Safe "Anh da ton tai, khong ghi de (S6): $imagePath" }
    New-Item -ItemType Directory -Force $imagesDir | Out-Null
    New-Item -ItemType Directory -Force $tmpDir    | Out-Null
    Remove-Item $tmpPath -Force -EA SilentlyContinue  # Don anh do dang cu

    # B6: Kiem tra cho trong (uoc luong 70% dung luong da dung tren OS)
    try {
        $osVol  = Get-Volume -Partition $osPart -EA SilentlyContinue
        $storeVol = Get-Volume -Partition $storePart -EA SilentlyContinue
        if ($osVol -and $storeVol) {
            $used = [int64]$osVol.Size - [int64]$osVol.SizeRemaining
            $free = [int64]$storeVol.SizeRemaining
            if ($free -lt ($used * 0.65)) {
                Stop-Safe "Khong du cho trong: can khoang $([math]::Round($used*0.65/1GB,1)) GB, con $([math]::Round($free/1GB,1)) GB (B6)"
            }
            Log "Cho trong: $([math]::Round($free/1GB,1)) GB - du (B6)"
        }
    } catch { Log "Canh bao: Khong kiem tra duoc cho trong: $_" }

    Log "[1/4] Bat dau DISM /Capture-Image -> $tmpPath"
    # B6: Ghi vao _tmp truoc, khong ghi thang vao imagePath
    Set-State "backup-running"
    $compress = if ($script:job.compress) { $script:job.compress } else { "fast" }
    & dism.exe /Capture-Image /ImageFile:"$tmpPath" /CaptureDir:"$osL\" `
              /Name:"$($script:job.image_name)" /Description:"LilbowRecovery backup" `
              /Compress:$compress /CheckIntegrity 2>&1 | ForEach-Object { Log "  [DISM] $_" }
    if ($LASTEXITCODE -ne 0) {
        Remove-Item $tmpPath -Force -EA SilentlyContinue
        # B6: Loi backup -> Stop-Safe (ve Windows), khong phai Stop-Danger
        Stop-Safe "DISM Capture-Image that bai (exitcode $LASTEXITCODE) - B6"
    }

    Log "[2/4] Tinh SHA256..."
    $hash = Compute-Sha256 $tmpPath
    Set-Content "$tmpPath.sha256" $hash -Encoding UTF8
    Log "  SHA256: $hash"

    Log "[3/4] Xac minh anh (mount thu - S18)..."
    $verified = Verify-Image $tmpPath  # Ghi meta.json cho $tmpPath.meta.json

    if (-not $verified) {
        Remove-Item $tmpPath -Force -EA SilentlyContinue
        Remove-Item "$tmpPath.sha256"    -Force -EA SilentlyContinue
        Remove-Item "$tmpPath.meta.json" -Force -EA SilentlyContinue
        Stop-Safe "Anh backup khong xac minh duoc (verified=false) - xoa va dung lai (B6)"
    }

    Log "[4/4] Chuyen anh ra ten cuoi..."
    Move-Item -LiteralPath $tmpPath          -Destination $imagePath            -Force
    Move-Item -LiteralPath "$tmpPath.sha256" -Destination "$imagePath.sha256"   -Force -EA SilentlyContinue
    # Meta.json: cap nhat duong dan chinh xac
    @{  sha256        = $hash
        created       = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
        source_host   = $env:COMPUTERNAME
        windows_build = ""
        verified      = $verified } |
        ConvertTo-Json | Set-Content -LiteralPath "$imagePath.meta.json" -Encoding UTF8

    Set-State "done"
    Move-Item -LiteralPath $jobPath -Destination "$($script:base)\logs\job-$(Get-Date -Format yyyyMMdd-HHmmss).json" -Force -EA SilentlyContinue
    Remove-Item $stateFile -Force -EA SilentlyContinue

    Finish "XONG" "Sao luu hoan tat: $imgName (verified=$verified)"
    # B6: Sau backup thanh cong, B5: giu WinPE trong displayorder
    Set-WindowsAsDefault-Safe
    Log "Reboot ve Windows sau 10 giay..."
    Start-Sleep 10; wpeutil reboot; exit 0
}

# ============================================================================
#  RESTORE
# ============================================================================
if ($script:job.action -eq "restore") {
    Log "=== RESTORE ==="

    # S14: Chi kiem tra selftest khi KHONG phai resume (B1)
    if (-not $isResume) {
        Assert-SelftestValid
    } else {
        Log "Resume: bo qua Assert-SelftestValid (B1)"
    }

    $imgName = $script:job.image
    if ($imgName -match "\.\." -or [IO.Path]::IsPathRooted($imgName)) {
        Stop-Safe "Ten file anh khong hop le: $imgName (B2)"
    }
    $imagePath = "$storeL\LilbowRecovery\images\$imgName"
    if (-not (Test-Path $imagePath)) { Stop-Safe "Khong tim thay file anh: $imagePath" }

    # S18
    Assert-ImageVerified $imagePath

    # Tim phan vung OS dich
    $osPart = Find-Partition-ByGuid $script:job.os_partition_guid
    if (-not $osPart) { Stop-Safe "Khong tim thay phan vung dich (GUID: $($script:job.os_partition_guid))" }

    $osDisk = Get-Disk -Number $osPart.DiskNumber
    if (-not (Assert-SerialMatch $osDisk $script:job)) { Stop-Safe "Serial dia dich khong khop" }

    # S20/B7
    Assert-DiskHealth $osPart.DiskNumber

    # B2: Assert-TargetSafe - kiem tra day du truoc format
    Assert-TargetSafe $osPart $storePart $script:job $isResume

    # B3: Tim EFI dung dia chua Windows (KHONG lay EFI dau tien cua ca may)
    $efiPart = Get-EfiForDisk $osPart.DiskNumber
    if (-not $efiPart) {
        Log "Canh bao: Khong tim thay EFI tren cung dia - thu EFI bat ky (B3)"
        $efiPart = Get-Partition | Where-Object { $_.GptType -eq "{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}" } | Select-Object -First 1
    }
    if (-not $efiPart) { Stop-Safe "Khong tim thay phan vung EFI (B3)" }
    $efiL = Ensure-Letter $efiPart

    # Ghi nhan EFI de resume dung lai
    $script:efiLetter = $efiL
    $script:bcdStore  = "$efiL\EFI\Microsoft\Boot\BCD"
    Log "EFI: $efiL (cung dia $($osPart.DiskNumber) - B3)"

    # S13: Kiem tra token (chi khi khong phai resume)
    if (-not $isResume) {
        $osL_pre = Ensure-Letter $osPart
        Assert-TokenOnPartition $osL_pre $script:job
        # Chup snapshot phan vung (S17)
        Save-PartitionSnapshot
        # B5: Backup BCD truoc khi chinh sua
        Backup-Bcd $script:job.job_id
    } else {
        Log "Resume: bo qua Assert-TokenOnPartition, Save-PartitionSnapshot, Backup-Bcd (B1)"
        # B1: Kiem tra muc 2 khi resume
        if ([int64]$osPart.Size -ne [int64]$script:job.os_size) {
            Stop-Danger "Dung luong phan vung khong khop khi resume: $([int64]$osPart.Size) != $([int64]$script:job.os_size) (B1)"
        }
    }

    # B5: Doc displayorder TRUOC bcdboot de so sanh sau
    $displayOrderBefore = Get-BcdDisplayOrder

    # =========================================================================
    #  DAT WINPE LAM MAC DINH BOOT TRUOC FORMAT (S16/B4) - PHAI THANH CONG
    # =========================================================================
    if (-not $isResume) {
        # B4: Set-WinPE-AsDefault se goi Stop-Safe neu that bai -> ve Windows an toan
        Set-WinPE-AsDefault
    } else {
        Log "Resume: bo qua Set-WinPE-AsDefault (B4 - WinPE da la mac dinh)"
    }

    # Sau day la vung nguy hiem (B1: pastPoint da duoc bat khi isResume=true)
    if (-not $script:pastPoint) { $script:pastPoint = $true }

    # -- Format phan vung dich -------------------------------------------------
    Log "[1/5] Format phan vung dich (GUID: $($script:job.os_partition_guid))..."
    Set-State "formatting"
    try {
        $label = if ($script:job.os_label) { $script:job.os_label } else { "WINDOWS" }
        Format-Volume -Partition $osPart -FileSystem NTFS -NewFileSystemLabel $label -Force -Confirm:$false
        Log "  Format hoan tat (nhan: $label)"
    } catch {
        Stop-Danger "Format that bai: $_"
    }

    # Gan lai chu cai sau format
    $osPart = Get-Partition -DiskNumber $osPart.DiskNumber -PartitionNumber $osPart.PartitionNumber
    $osL = Ensure-Letter $osPart
    if (-not $osL) { Stop-Danger "Khong gan duoc chu cai sau format" }

    # -- Bung anh -------------------------------------------------------------
    Log "[2/5] DISM /Apply-Image <- $imagePath"
    Set-State "applying"
    $imgIndex = if ($script:job.image_index) { $script:job.image_index } else { 1 }
    & dism.exe /Apply-Image /ImageFile:"$imagePath" /Index:$imgIndex /ApplyDir:"$osL\" /CheckIntegrity 2>&1 |
        ForEach-Object { Log "  [DISM] $_" }
    if ($LASTEXITCODE -ne 0) { Stop-Danger "DISM Apply-Image that bai (exitcode $LASTEXITCODE)" }

    # -- Nap driver (M5a) -----------------------------------------------------
    Log "[3/5] Nap driver theo model (M5a)..."
    Inject-Drivers $osL

    # -- Dung BCD (S16/B5/B8) -------------------------------------------------
    Log "[4/5] Dung boot voi bcdboot..."
    Set-State "boot-config"
    $bcdbootOk = $false
    & bcdboot "$osL\Windows" /s "$efiL" /f UEFI /l vi-VN 2>&1 | ForEach-Object { Log "  [BCDBOOT] $_" }
    if ($LASTEXITCODE -eq 0) {
        $bcdbootOk = $true
        Log "  bcdboot vi-VN: thanh cong"
    } else {
        Log "  bcdboot vi-VN that bai (exit=$LASTEXITCODE) - thu en-US..."
        & bcdboot "$osL\Windows" /s "$efiL" /f UEFI /l en-US 2>&1 | ForEach-Object { Log "  [BCDBOOT-EN] $_" }
        if ($LASTEXITCODE -eq 0) {
            $bcdbootOk = $true
            Log "  bcdboot en-US: thanh cong"
        } else {
            # B8: Ca hai lan deu that bai
            Stop-Danger "bcdboot that bai ca vi-VN va en-US (exit=$LASTEXITCODE) - B8"
        }
    }

    # B5/B8: Dat Windows moi lam mac dinh (so sanh truoc/sau bcdboot)
    Set-NewWindowsDefault $displayOrderBefore

    # B8: Xac nhan mac dinh la Windows, KHONG phai WinPE
    Assert-WindowsIsDefault

    # -- Kiem tra sau khi bung (M5a/B8) ----------------------------------------
    Log "[5/5] Kiem tra sau khi bung..."
    Set-State "verifying"
    Assert-PostRestore $osL

    # Kiem tra phan vung ngoai nguyen ven (S17)
    Assert-OtherPartitionsIntact $script:job.os_partition_guid

    # -- Hoan tat -------------------------------------------------------------
    Set-State "done"
    Move-Item -LiteralPath $jobPath -Destination "$($script:base)\logs\job-$(Get-Date -Format yyyyMMdd-HHmmss).json" -Force -EA SilentlyContinue
    Remove-Item $stateFile -Force -EA SilentlyContinue
    Finish "XONG" "Khoi phuc hoan tat: $imgName"
    Log "Reboot ve Windows sau 10 giay..."
    Start-Sleep 10; wpeutil reboot; exit 0
}

# -- Action khong ro -----------------------------------------------------------
Log "Action khong xac dinh: '$($script:job.action)'"
Set-WindowsAsDefault-Safe; Start-Sleep 10; wpeutil reboot; exit 1
