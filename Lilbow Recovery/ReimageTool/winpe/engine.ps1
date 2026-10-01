# X:\engine.ps1 — Chay trong WinPE
# TRANG THAI: Ban v1.1 — tich hop risk-mitigation addendum v0.2
# Moi thong bao trong file nay PHAI la tieng Viet KHONG dau
# (console WinPE co the khong hien thi dau tieng Viet)
#
# CANH BAO: KHONG chay file nay tren may phat trien Windows.
#           Chi chay trong WinPE (VM hoac may lab).
#
# Lop bao ve da tich hop:
#   S13 - job_id, token, os_offset, expires_at
#   S14 - selftest-ok.json bat buoc cho restore
#   S15 - state.json may trang thai, resume sau mat dien
#   S16 - WinPE lam mac dinh truoc format, Windows mac dinh sau bcdboot
#   S17 - snapshot phan vung truoc/sau, sentinel.txt
#   S18 - chi restore anh co verified:true trong meta.json
#   S19 - toi da 3 lan thu, sau do vao che do cuu ho
#   S20 - kiem tra dia Healthy, pin/AC

$ErrorActionPreference = "Stop"
$reportUrl  = ""   # Dien URL webhook/Telegram, de trong thi bo qua
$script:job          = $null
$script:base         = $null
$script:pastPoint    = $false   # True = da qua diem format, khong quay lai duoc
$script:attempts     = 0
$log = "X:\engine.log"

# ── Tien ich co ban ──────────────────────────────────────────────────────────

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
    Log "$status — $msg"
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

# Dung TRUOC diem format — ghi DUNG, dat boot ve Windows cu, reboot
function Stop-Safe($m) {
    Finish "DUNG" $m
    Restore-WindowsBoot
    Log "Dung an toan. Reboot sau 10 giay..."
    Start-Sleep 10
    wpeutil reboot
    exit 1
}

# Dung NGUY HIEM (sau format) — vao che do cuu ho, KHONG reboot
function Stop-Danger($m) {
    Finish "LOI" $m
    Set-State "failed"
    Log "Trang thai NGUY HIEM. Vao che do cuu ho..."
    Enter-RescueMode
    exit 1
}

# ── May trang thai (S15) ──────────────────────────────────────────────────────

$script:state = "init"

function Set-State($phase) {
    $script:state = $phase
    if ($script:base) {
        @{ job_id=if($script:job){$script:job.job_id}else{"?"}
           phase=$phase; attempts=$script:attempts
           updated=(Get-Date -Format "yyyy-MM-ddTHH:mm:ss") } |
            ConvertTo-Json | Set-Content -LiteralPath "$($script:base)\state.json" -Encoding UTF8
    }
    Log "[STATE] $phase (lan thu $($script:attempts))"
}

# ── Che do cuu ho (S19) ───────────────────────────────────────────────────────

function Enter-RescueMode {
    Log "=== CHE DO CUU HO ==="
    Log "Qua 3 lan thu that bai. WinPE o lai cho lenh tu xa."
    Log "Kiem tra log tai: $log"
    Log "Co the dung nut nguon tai chỗ de khoi dong lai may."
    # Gui heartbeat va cho lenh
    $waited = 0
    while ($true) {
        Start-Sleep 30
        $waited += 30
        Report "rescue waited=${waited}s"
        # Kiem tra lenh tu remote (neu co file lenh)
        $cmdFile = if ($script:base) { "$($script:base)\remote-cmd.txt" } else { $null }
        if ($cmdFile -and (Test-Path $cmdFile)) {
            $cmd = (Get-Content $cmdFile -Raw -EA SilentlyContinue).Trim()
            Remove-Item $cmdFile -Force -EA SilentlyContinue
            Log "Nhan lenh tu xa: $cmd"
            switch ($cmd) {
                "retry"           { $script:attempts = 0; Set-State "formatting"; return }
                "reboot"          { wpeutil reboot; exit }
                "reboot-windows"  { Restore-WindowsBoot; Start-Sleep 3; wpeutil reboot; exit }
                "abort"           { Log "Lenh abort: tiep tuc o lai WinPE" }
                default           { Log "Lenh khong ro: $cmd" }
            }
        }
    }
}

# ── Quan ly boot EFI (S16) ────────────────────────────────────────────────────

$script:efiLetter  = $null
$script:bcdStore   = $null
$script:origDefault= $null

function Find-EFI {
    foreach ($p in @(Get-Partition | Where-Object { $_.GptType -eq "{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}" })) {
        $letter = Ensure-Letter $p
        if ($letter) { $script:efiLetter = $letter; break }
    }
}

function Init-BcdStore {
    if (-not $script:efiLetter) { Find-EFI }
    if (-not $script:efiLetter) { Log "Canh bao: Khong tim thay EFI"; return }
    $script:bcdStore = "$($script:efiLetter)\EFI\Microsoft\Boot\BCD"
    try {
        $out = &bcdedit /store $script:bcdStore /enum "{bootmgr}" 2>&1 | Out-String
        if ($out -match "default\s+\{([0-9a-f\-]+)\}") { $script:origDefault = "{$($Matches[1])}" }
        Log "BCD store: $($script:bcdStore)  Mac dinh hien tai: $($script:origDefault)"
    } catch { Log "Canh bao: Khong doc duoc BCD store: $_" }
}

# Dat WinPE lam mac dinh (S16 - truoc format)
function Set-WinPE-AsDefault {
    if (-not $script:bcdStore) { Init-BcdStore }
    if (-not $script:bcdStore -or -not (Test-Path $script:bcdStore)) { Log "Canh bao: Khong tim thay BCD store"; return }
    $winpeGuid = $null
    if ($script:base -and (Test-Path "$($script:base)\bootguid.txt")) {
        $winpeGuid = (Get-Content "$($script:base)\bootguid.txt" -Raw).Trim()
    }
    if (-not $winpeGuid) { Log "Canh bao: Khong co bootguid.txt — bo qua set WinPE default"; return }
    try {
        &bcdedit /store $script:bcdStore /default $winpeGuid 2>&1 | Out-Null
        &bcdedit /store $script:bcdStore /timeout 3            2>&1 | Out-Null
        Log "Dat WinPE lam mac dinh boot: $winpeGuid (S16)"
    } catch { Log "Canh bao: Khong dat duoc WinPE default: $_" }
}

# Dat Windows moi lam mac dinh (S16 - sau bcdboot)
function Restore-WindowsBoot {
    if (-not $script:bcdStore) { Init-BcdStore }
    if (-not $script:bcdStore -or -not (Test-Path $script:bcdStore)) { return }
    try {
        # Tim GUID Windows moi (khac WinPE)
        $winpeGuid = $null
        if ($script:base -and (Test-Path "$($script:base)\bootguid.txt")) {
            $winpeGuid = (Get-Content "$($script:base)\bootguid.txt" -Raw).Trim()
        }
        $bcdOut = &bcdedit /store $script:bcdStore /enum all 2>&1 | Out-String
        $entries = [regex]::Matches($bcdOut, "identifier\s+\{([0-9a-f\-]+)\}")
        $winGuid = $null
        foreach ($e in $entries) {
            $g = "{$($e.Groups[1].Value)}"
            if ($g -notin @("{bootmgr}","{current}","{default}","{ramdiskoptions}") -and
                $g -ne $winpeGuid -and
                $bcdOut -match [regex]::Escape($g) + "[\s\S]+?osdevice") {
                $winGuid = $g; break
            }
        }
        if ($winGuid) {
            &bcdedit /store $script:bcdStore /default $winGuid 2>&1 | Out-Null
            &bcdedit /store $script:bcdStore /timeout 5         2>&1 | Out-Null
            Log "Dat Windows ($winGuid) lam mac dinh boot (S16)"
        } elseif ($script:origDefault) {
            &bcdedit /store $script:bcdStore /default $script:origDefault 2>&1 | Out-Null
            Log "Phuc hoi mac dinh goc: $($script:origDefault)"
        }
        # Xoa WinPE khoi displayorder
        if ($winpeGuid) {
            &bcdedit /store $script:bcdStore /displayorder $winpeGuid /remove 2>&1 | Out-Null
        }
    } catch { Log "Canh bao: Khong dat duoc Windows default: $_" }
}

# Xac nhan mac dinh khong con la WinPE (S16)
function Assert-WindowsIsDefault {
    if (-not $script:bcdStore -or -not (Test-Path $script:bcdStore)) { return $true }
    $winpeGuid = $null
    if ($script:base -and (Test-Path "$($script:base)\bootguid.txt")) {
        $winpeGuid = (Get-Content "$($script:base)\bootguid.txt" -Raw).Trim()
    }
    if (-not $winpeGuid) { return $true }
    try {
        $out = &bcdedit /store $script:bcdStore /enum "{bootmgr}" 2>&1 | Out-String
        if ($out -match "default\s+\{([0-9a-f\-]+)\}") {
            $cur = "{$($Matches[1])}"
            if ($cur -eq $winpeGuid) {
                Log "Canh bao: Mac dinh van la WinPE! Dang sua..."
                Restore-WindowsBoot
            } else {
                Log "Xac nhan: Mac dinh la Windows ($cur) — dung (S16)"
            }
        }
    } catch { Log "Canh bao: Khong kiem tra duoc mac dinh: $_" }
    return $true
}

# ── Tien ich phan vung ────────────────────────────────────────────────────────

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
        # Ket tuong thich v0.1
        if (Test-Path "$letter\Reimage\job.json") { return "$letter\Reimage" }
    }
    return $null
}

# ── Kiem tra suc khoe dia (S20) ───────────────────────────────────────────────

function Assert-DiskHealth($diskNum) {
    try {
        $pd = Get-PhysicalDisk | Where-Object { $_.DeviceId -eq $diskNum -or $_.FriendlyName -match $diskNum }
        if (-not $pd) {
            # Thu qua Get-Disk
            $d = Get-Disk -Number $diskNum -EA SilentlyContinue
            if ($d -and $d.HealthStatus -ne "Healthy") {
                Stop-Safe "Dia Disk$diskNum khong Healthy ($($d.HealthStatus)) — S20"
            }
            Log "Khong kiem tra duoc PhysicalDisk — bo qua kiem tra suc khoe"
            return
        }
        if ($pd.HealthStatus -ne "Healthy") {
            Stop-Safe "Dia $($pd.FriendlyName) khong Healthy ($($pd.HealthStatus)) — S20"
        }
        Log "Dia OK: $($pd.FriendlyName) — $($pd.HealthStatus)"
    } catch { Log "Canh bao: Khong kiem tra duoc suc khoe dia: $_" }
}

function Assert-Power {
    try {
        $bat = Get-WmiObject Win32_Battery -EA SilentlyContinue
        if ($bat) {
            if ($bat.BatteryStatus -eq 1 -and $bat.EstimatedChargeRemaining -lt 50) {
                Stop-Safe "May xach tay: pin $($bat.EstimatedChargeRemaining)% < 50% va khong cam dien — S20"
            }
            Log "Nguon dien: Pin $($bat.EstimatedChargeRemaining)% Status=$($bat.BatteryStatus)"
        } else {
            Log "Nguon dien: May ban, bo qua kiem tra pin"
        }
    } catch { Log "Canh bao: Khong kiem tra duoc nguon dien: $_" }
}

# ── Snapshot phan vung (S17) ──────────────────────────────────────────────────

function Save-PartitionSnapshot {
    if (-not $script:base) { return }
    $snap = @(Get-Partition | Select-Object DiskNumber, PartitionNumber, Guid, Offset, Size, GptType)
    $snap | ConvertTo-Json | Set-Content -LiteralPath "$($script:base)\partitions-before.json" -Encoding UTF8
    Log "Chup bang phan vung truoc khi chay (S17): $($snap.Count) phan vung"
}

function Assert-OtherPartitionsIntact($osGuid) {
    if (-not $script:base) { return }
    $snapFile = "$($script:base)\partitions-before.json"
    if (-not (Test-Path $snapFile)) { Log "Canh bao: Khong co partitions-before.json — bo qua kiem tra S17"; return }
    try {
        $before = Get-Content $snapFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $after  = @(Get-Partition | Select-Object DiskNumber, PartitionNumber, Guid, Offset, Size)
        $errs   = @()
        foreach ($b in $before) {
            if ($b.Guid -ieq $osGuid) { continue }  # Phan vung OS duoc phep thay doi
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

# ── Selftest (M4a / Lop 1) ────────────────────────────────────────────────────

function Run-Selftest {
    Log "=== BAT DAU SELFTEST ==="
    $result = @{
        time              = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
        model             = ""
        bios_version      = ""
        secure_boot       = $false
        disks_seen        = 0
        store_found       = $false
        os_partition_found= $false
        network_ok        = $false
        status            = "DANG_KIEM_TRA"
    }
    try { $cs = Get-WmiObject Win32_ComputerSystem -EA SilentlyContinue; $result.model = "$($cs.Manufacturer) $($cs.Model)".Trim() } catch {}
    try { $bios = Get-WmiObject Win32_BIOS -EA SilentlyContinue; $result.bios_version = $bios.SMBIOSBIOSVersion } catch {}
    try { $sb = Confirm-SecureBootUEFI -EA SilentlyContinue; $result.secure_boot = ($sb -eq $true) } catch { $result.secure_boot = $false }
    try { $result.disks_seen = (Get-Disk).Count } catch {}

    Log "  Model  : $($result.model)"
    Log "  BIOS   : $($result.bios_version)"
    Log "  Dia    : $($result.disks_seen)"

    # Tim o luu anh
    $base = Find-Store
    if ($base) {
        $result.store_found = $true
        Log "  O luu anh: $base"
        # Doc thu vài MB dau cua ảnh WIM dau tien
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

    # Tim phan vung Windows theo GUID tu selftest-request.json
    $reqFile = if ($base) { "$base\selftest-request.json" } else { $null }
    if ($reqFile -and (Test-Path $reqFile)) {
        try {
            $req = Get-Content $reqFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $op  = Get-Partition | Where-Object { $_.Guid -ieq $req.os_partition_guid } | Select-Object -First 1
            $result.os_partition_found = ($op -ne $null)
            Log "  Phan vung OS (GUID $($req.os_partition_guid)): $(if($result.os_partition_found){'Tim thay'}else{'KHONG tim thay'})"
        } catch { Log "  Canh bao: Khong doc selftest-request.json: $_" }
    } else {
        Log "  Khong co selftest-request.json — bo qua kiem tra phan vung OS"
        $result.os_partition_found = $true  # Khong yeu cau
    }

    # Kiem tra mang
    if ($reportUrl) {
        try {
            $body = @{ host=$env:COMPUTERNAME; phase="selftest"; status="ping" } | ConvertTo-Json
            Invoke-RestMethod -Uri $reportUrl -Method Post -ContentType "application/json" -Body $body -TimeoutSec 8 | Out-Null
            $result.network_ok = $true
            Log "  Mang: OK (gui duoc report)"
        } catch { Log "  Canh bao: Khong gui duoc report (mang?): $_" }
    } else {
        # Thu ping don gian
        try {
            $ping = Test-Connection -ComputerName "8.8.8.8" -Count 1 -Quiet -EA SilentlyContinue
            $result.network_ok = $ping
            Log "  Mang: $(if($ping){'Co mang'}else{'Khong co mang'})"
        } catch { Log "  Canh bao: Khong kiem tra duoc mang" }
    }

    # Ket qua cuoi
    $ok = $result.store_found -and $result.os_partition_found -and $result.disks_seen -gt 0
    $result.status = if ($ok) { "OK" } else { "THAT_BAI" }
    Log "  Ket qua selftest: $($result.status)"

    # Ghi selftest-ok.json
    if ($base) {
        $result | ConvertTo-Json | Set-Content -LiteralPath "$base\selftest-ok.json" -Encoding UTF8
        Log "  Da ghi selftest-ok.json"
        # Don dep request
        if ($reqFile -and (Test-Path $reqFile)) { Remove-Item $reqFile -Force -EA SilentlyContinue }
    }

    # Phuc hoi boot ve Windows roi reboot
    Restore-WindowsBoot
    Log "Selftest hoan tat. Reboot ve Windows sau 5 giay..."
    Start-Sleep 5
    wpeutil reboot
    exit 0
}

# ── Kiem tra selftest-ok.json (S14) ──────────────────────────────────────────

function Assert-SelftestValid {
    $sf = "$($script:base)\selftest-ok.json"
    if (-not (Test-Path $sf)) { Stop-Safe "Chua chay selftest — restore bi tu choi (S14)" }
    try {
        $st = Get-Content $sf -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($st.status -ne "OK") { Stop-Safe "Selftest that bai ($($st.status)) — restore bi tu choi (S14)" }
        # Kiem tra thoi han (7 ngay)
        $stTime = [datetime]$st.time
        if ((Get-Date) - $stTime -gt [TimeSpan]::FromDays(7)) {
            Stop-Safe "Selftest da qua 7 ngay — chay lai selftest truoc (S14)"
        }
        # Kiem tra model
        try {
            $cs    = Get-WmiObject Win32_ComputerSystem -EA SilentlyContinue
            $curM  = "$($cs.Manufacturer) $($cs.Model)".Trim()
            $bios  = Get-WmiObject Win32_BIOS -EA SilentlyContinue
            $curB  = $bios.SMBIOSBIOSVersion
            if ($st.model -and $st.model -ne $curM) {
                Stop-Safe "Model may thay doi ($($st.model) -> $curM) — S14"
            }
            if ($st.bios_version -and $st.bios_version -ne $curB) {
                Stop-Safe "BIOS thay doi ($($st.bios_version) -> $curB) — S14"
            }
        } catch { Log "Canh bao: Khong kiem tra duoc model/BIOS — cho qua (S14)" }
        Log "Selftest hop le: $($st.time) — $($st.model) (S14)"
    } catch {
        Stop-Safe "Khong doc duoc selftest-ok.json: $_ (S14)"
    }
}

# ── Kiem tra job (S13) ────────────────────────────────────────────────────────

function Assert-JobValid($job) {
    # job_id bat buoc
    if (-not $job.job_id) { Stop-Safe "Job thieu job_id (S13)" }
    # Kiem tra het han
    if ($job.expires_at) {
        try {
            $exp = [datetime]$job.expires_at
            if ((Get-Date) -gt $exp) { Stop-Safe "Job het han luc $($job.expires_at) (S13)" }
            Log "Job het han: $($job.expires_at) — con han (S13)"
        } catch { Log "Canh bao: Khong parse duoc expires_at — bo qua" }
    } else {
        Log "Canh bao: Job khong co expires_at — nen them (S13)"
    }
}

# Kiem tra token tren phan vung OS (S13 - chi dung TRUOC format)
function Assert-TokenOnPartition($osDriveLetter, $job) {
    if (-not $job.token) { Log "Canh bao: Job khong co token — bo qua kiem tra token (S13)"; return }
    $tokPath = "$osDriveLetter\ProgramData\LilbowRecovery\token.txt"
    if (-not (Test-Path $tokPath)) {
        Stop-Safe "Khong tim thay token.txt tren $osDriveLetter — S13"
    }
    $tok = (Get-Content $tokPath -Raw -EA SilentlyContinue).Trim()
    if ($tok -ne $job.token) {
        Stop-Safe "Token khong khop tren $osDriveLetter (S13)"
    }
    Log "Token xac nhan hop le tren $osDriveLetter (S13)"
}

# Kiem tra offset phan vung (S13)
function Assert-OffsetMatch($partition, $job) {
    if (-not $job.os_offset) { Log "Canh bao: Job khong co os_offset — bo qua (S13)"; return }
    if ([int64]$partition.Offset -ne [int64]$job.os_offset) {
        Stop-Safe "Offset phan vung khong khop: $([int64]$partition.Offset) != $([int64]$job.os_offset) (S13)"
    }
    Log "Offset phan vung khop: $([int64]$partition.Offset) (S13)"
}

# ── Kiem tra anh da xac minh (S18) ───────────────────────────────────────────

function Assert-ImageVerified($imagePath) {
    $metaPath = "$imagePath.meta.json"
    if (-not (Test-Path $metaPath)) {
        Stop-Safe "Anh '$imagePath' chua co meta.json — S18. Chay xac minh anh truoc."
    }
    try {
        $meta = Get-Content $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($meta.verified -ne $true) {
            Stop-Safe "Anh '$imagePath' chua duoc xac minh (verified=$($meta.verified)) — S18"
        }
        Log "Anh da xac minh: $($meta.source_host) / Build $($meta.windows_build) (S18)"
    } catch { Stop-Safe "Khong doc duoc meta.json: $_ (S18)" }
}

# Xac minh anh sau khi backup (mount thu, kiem tra file khoi dong)
function Verify-Image($imagePath) {
    Log "Xac minh anh sau backup (S18)..."
    $mnt = "X:\mnt_verify"
    New-Item -ItemType Directory -Force $mnt | Out-Null
    $verif = $false
    try {
        &dism.exe /Mount-Image /ImageFile:"$imagePath" /Index:1 /MountDir:"$mnt" /ReadOnly 2>&1 | ForEach-Object { Log "  [DISM-MNT] $_" }
        $ok1 = Test-Path "$mnt\Windows\System32\winload.efi"
        $ok2 = Test-Path "$mnt\Windows\System32\config\SYSTEM"
        Log "  winload.efi: $ok1  config\SYSTEM: $ok2"
        $verif = $ok1 -and $ok2
        # Doc so build Windows
        $build = ""
        try {
            $ini = Get-Content "$mnt\Windows\System32\winver.exe" -EA SilentlyContinue
            $ver = (Get-Item "$mnt\Windows\System32\ntoskrnl.exe" -EA SilentlyContinue).VersionInfo.ProductVersion
            $build = $ver
        } catch {}
        # Ghi meta.json
        $meta = @{
            sha256        = (Get-FileHash $imagePath -Algorithm SHA256).Hash
            created       = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
            source_host   = $env:COMPUTERNAME
            windows_build = $build
            verified      = $verif
        }
        $meta | ConvertTo-Json | Set-Content -LiteralPath "$imagePath.meta.json" -Encoding UTF8
        Log "  Ghi meta.json — verified=$verif"
    } catch {
        Log "Canh bao: Loi khi xac minh anh: $_"
    } finally {
        try { &dism.exe /Unmount-Image /MountDir:"$mnt" /Discard 2>&1 | Out-Null } catch {}
        Remove-Item $mnt -Force -EA SilentlyContinue
    }
    return $verif
}

# ── Nap driver theo model (M5a / Lop 5 muc 7.2) ──────────────────────────────

function Inject-Drivers($windowsLetter) {
    $model = ""
    try { $cs = Get-WmiObject Win32_ComputerSystem -EA SilentlyContinue; $model = $cs.Model.Trim() } catch {}
    if (-not $model) { Log "Canh bao: Khong doc duoc model may — bo qua inject driver"; return }
    $drvDir = "$($script:base)\drivers\$model"
    if (-not (Test-Path $drvDir)) {
        Log "Khong co driver cho model '$model' — bo qua (S5a)"
        return
    }
    Log "Nap driver cho model '$model' tu $drvDir..."
    try {
        &dism.exe /Image:"$windowsLetter\" /Add-Driver /Driver:"$drvDir" /Recurse 2>&1 | ForEach-Object { Log "  [DISM-DRV] $_" }
        Log "Nap driver hoan tat"
    } catch { Log "Canh bao: Loi nap driver: $_" }
}

# ── Kiem tra sau khi bung (M5a / Lop 5 muc 7.1) ──────────────────────────────

function Assert-PostRestore($windowsLetter) {
    Log "Kiem tra sau khi bung anh (M5a)..."
    $ok = $true
    if (-not (Test-Path "$windowsLetter\Windows\System32\winload.efi")) {
        Log "THAT BAI: Khong tim thay winload.efi tren $windowsLetter"; $ok = $false
    } else { Log "  winload.efi: OK" }
    if (-not (Test-Path "$windowsLetter\Windows\System32\config\SYSTEM")) {
        Log "THAT BAI: Khong tim thay config\SYSTEM tren $windowsLetter"; $ok = $false
    } else { Log "  config\SYSTEM: OK" }
    if (-not $ok) { Stop-Danger "Kiem tra sau khi bung THAT BAI — Windows co the khong boot duoc (M5a)" }
    Log "Kiem tra sau khi bung: OK"
}

# ── Tien ich ──────────────────────────────────────────────────────────────────

function Find-Partition-ByGuid($guid) {
    return Get-Partition | Where-Object { $_.Guid -ieq $guid } | Select-Object -First 1
}

function Assert-SerialMatch($disk, $job) {
    $norm = Norm $disk.SerialNumber
    $njob = Norm $job.disk_serial
    if ($norm -ne $njob) { return $false }
    return $true
}

# Tinh SHA256 cho file anh
function Compute-Sha256($path) {
    return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
}

# ─────────────────────────────────────────────────────────────────────────────
#  MAIN
# ─────────────────────────────────────────────────────────────────────────────

Log "=== LilbowRecovery engine v1.1 ==="
Log "  Thoi diem: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Log "  May: $env:COMPUTERNAME"

# ── Khoi tao BCD store ────────────────────────────────────────────────────────
Init-BcdStore

# ── Tim store ─────────────────────────────────────────────────────────────────
$script:base = Find-Store
if (-not $script:base) {
    Log "Khong tim thay thu muc LilbowRecovery voi job.json."
    # Neu WinPE khong co job/state — dat lai mac dinh ve Windows roi reboot
    Restore-WindowsBoot
    Log "Dat lai boot ve Windows. Reboot sau 10 giay..."
    Start-Sleep 10; wpeutil reboot; exit 0
}
Log "Store: $($script:base)"
New-Item -ItemType Directory -Force "$($script:base)\logs" | Out-Null

# ── Kiem tra selftest action ─────────────────────────────────────────────────
$selftestReq = "$($script:base)\selftest-request.json"
if (Test-Path $selftestReq) {
    Log "Phat hien selftest-request.json — chay selftest..."
    Run-Selftest
    # (Khong tra ve — Run-Selftest reboot may)
}

# ── Kiem tra state.json (resume sau mat dien) (S15) ──────────────────────────
$stateFile = "$($script:base)\state.json"
$isResume  = $false
if (Test-Path $stateFile) {
    try {
        $st = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($st.phase -in @("formatting","applying","boot-config","verifying")) {
            $script:attempts = [int]$st.attempts + 1
            Log "Phat hien state.json: phase=$($st.phase), lan thu=$($script:attempts) (S15)"
            if ($script:attempts -gt 3) {
                Set-State "failed"
                Log "Qua 3 lan thu — vao che do cuu ho (S19)"
                Enter-RescueMode
                exit 1
            }
            $isResume = $true
            Log "RESUME: lan thu $($script:attempts) — tiep tuc tu buoc format (S15)"
        } elseif ($st.phase -eq "done") {
            Log "State = done. Khoi dong chuan."
            $isResume = $false
        } elseif ($st.phase -eq "failed") {
            Log "State = failed — vao che do cuu ho (S19)"
            Enter-RescueMode; exit 1
        }
    } catch { Log "Canh bao: Khong doc duoc state.json: $_" }
}

# ── Doc job.json ──────────────────────────────────────────────────────────────
$jobPath = "$($script:base)\job.json"
if (-not (Test-Path $jobPath)) {
    Log "Khong co job.json."
    Restore-WindowsBoot
    Log "Reboot ve Windows sau 10 giay..."
    Start-Sleep 10; wpeutil reboot; exit 0
}

try {
    $script:job = Get-Content -LiteralPath $jobPath -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    Log "Khong doc duoc job.json: $_"
    Restore-WindowsBoot; Start-Sleep 10; wpeutil reboot; exit 1
}

Log "Doc job: action=$($script:job.action)  job_id=$($script:job.job_id)"

# ── Kiem tra job hop le (S13) ─────────────────────────────────────────────────
Set-State "checking"
Assert-JobValid $script:job

# ── Kiem tra nguon dien va dia (S20) ─────────────────────────────────────────
Assert-Power

# ── Tim phan vung luu anh ─────────────────────────────────────────────────────
$storePart = Find-Partition-ByGuid $script:job.store_partition_guid
if (-not $storePart) { Stop-Safe "Khong tim thay phan vung luu anh (GUID: $($script:job.store_partition_guid))" }
$storeL = Ensure-Letter $storePart
if (-not $storeL) { Stop-Safe "Khong gan duoc chu cai cho o luu anh" }

# ── BACKUP ────────────────────────────────────────────────────────────────────
if ($script:job.action -eq "backup") {
    Log "=== BACKUP ==="

    # Tim phan vung OS
    $osPart = Find-Partition-ByGuid $script:job.os_partition_guid
    if (-not $osPart) { Stop-Safe "Khong tim thay phan vung OS (GUID: $($script:job.os_partition_guid))" }
    $osDisk = Get-Disk -Number $osPart.DiskNumber
    if (-not (Assert-SerialMatch $osDisk $script:job)) { Stop-Safe "Serial dia OS khong khop" }
    $osL = Ensure-Letter $osPart
    if (-not $osL -or -not (Test-Path "$osL\Windows\System32")) { Stop-Safe "Phan vung OS khong co Windows" }

    # Kiem tra suc khoe dia
    Assert-DiskHealth $osPart.DiskNumber

    $imagePath = "$storeL\LilbowRecovery\$($script:job.image)"
    New-Item -ItemType Directory -Force (Split-Path $imagePath) | Out-Null

    Log "[1/4] Bat dau DISM /Capture-Image -> $imagePath"
    Set-State "applying"  # Dung applying cho ca backup de dong nhat
    $compress = if ($script:job.compress) { $script:job.compress } else { "fast" }
    &dism.exe /Capture-Image /ImageFile:"$imagePath" /CaptureDir:"$osL\" `
              /Name:"$($script:job.image_name)" /Description:"LilbowRecovery backup" `
              /Compress:$compress /Verify 2>&1 | ForEach-Object { Log "  [DISM] $_" }
    if ($LASTEXITCODE -ne 0) { Stop-Danger "DISM Capture-Image that bai (exitcode $LASTEXITCODE)" }

    Log "[2/4] Tinh SHA256..."
    $hash = Compute-Sha256 $imagePath
    Set-Content "$imagePath.sha256" $hash -Encoding UTF8
    Log "  SHA256: $hash"

    Log "[3/4] Xac minh anh (mount thu — S18)..."
    $verified = Verify-Image $imagePath

    Log "[4/4] Hoan tat backup."
    # Chuyen job vao logs (S8 — chi o trang thai done)
    Set-State "done"
    Move-Item -LiteralPath $jobPath -Destination "$($script:base)\logs\job-$(Get-Date -Format yyyyMMdd-HHmmss).json" -Force -EA SilentlyContinue
    Remove-Item $stateFile -Force -EA SilentlyContinue

    Finish "XONG" "Sao luu hoan tat: $($script:job.image) (verified=$verified)"
    Restore-WindowsBoot
    Log "Reboot ve Windows sau 10 giay..."
    Start-Sleep 10; wpeutil reboot; exit 0
}

# ── RESTORE ───────────────────────────────────────────────────────────────────
if ($script:job.action -eq "restore") {
    Log "=== RESTORE ==="

    # Kiem tra selftest (S14) — chi cho restore
    Assert-SelftestValid

    $imagePath = "$storeL\LilbowRecovery\$($script:job.image)"
    if (-not (Test-Path $imagePath)) { Stop-Safe "Khong tim thay file anh: $imagePath" }

    # Kiem tra anh da xac minh (S18)
    Assert-ImageVerified $imagePath

    # Tim phan vung OS dich
    $osPart = Find-Partition-ByGuid $script:job.os_partition_guid
    if (-not $osPart) { Stop-Safe "Khong tim thay phan vung dich (GUID: $($script:job.os_partition_guid))" }
    $osDisk = Get-Disk -Number $osPart.DiskNumber
    if (-not (Assert-SerialMatch $osDisk $script:job)) { Stop-Safe "Serial dia dich khong khop" }

    # Kiem tra offset (S13)
    Assert-OffsetMatch $osPart $script:job

    # Kiem tra suc khoe dia (S20)
    Assert-DiskHealth $osPart.DiskNumber

    # Gan chu cai cho phan vung OS (de kiem tra token)
    $osL = Ensure-Letter $osPart

    # Kiem tra token (S13) — CHI TRUOC FORMAT
    if (-not $isResume -and $osL) {
        Assert-TokenOnPartition $osL $script:job
    } else {
        Log "Resume mode — bo qua kiem tra token (S13), dung kiem tra muc 2"
        # Kiem tra muc 2: GUID, serial, offset, dung luong
        if ([int64]$osPart.Size -ne [int64]$script:job.os_size) {
            Stop-Safe "Dung luong phan vung khong khop khi resume: $([int64]$osPart.Size) != $([int64]$script:job.os_size)"
        }
    }

    # Chup snapshot phan vung (S17) — chi lan dau (khong phai resume)
    if (-not $isResume) { Save-PartitionSnapshot }

    # Tim EFI
    $efiPart = Get-Partition | Where-Object { $_.GptType -eq "{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}" } | Select-Object -First 1
    if (-not $efiPart) { Stop-Safe "Khong tim thay phan vung EFI" }
    $efiL = Ensure-Letter $efiPart

    # ==========================================================================
    #  DAT WINPE LAM MAC DINH BOOT TRUOC FORMAT (S16)
    # ==========================================================================
    Set-WinPE-AsDefault
    $script:pastPoint = $true   # Sau day la "vung nguy hiem"

    # ── Format phan vung dich ─────────────────────────────────────────────────
    Log "[1/5] Format phan vung dich (GUID: $($script:job.os_partition_guid))..."
    Set-State "formatting"
    try {
        Format-Volume -Partition $osPart -FileSystem NTFS -NewFileSystemLabel "WINDOWS" -Force -Confirm:$false
        Log "  Format hoan tat"
    } catch {
        Stop-Danger "Format that bai: $_"
    }

    # Gan lai chu cai sau format
    $osPart = Get-Partition -DiskNumber $osPart.DiskNumber -PartitionNumber $osPart.PartitionNumber
    $osL = Ensure-Letter $osPart
    if (-not $osL) { Stop-Danger "Khong gan duoc chu cai sau format" }

    # ── Bung anh ─────────────────────────────────────────────────────────────
    Log "[2/5] DISM /Apply-Image <- $imagePath"
    Set-State "applying"
    &dism.exe /Apply-Image /ImageFile:"$imagePath" /Index:$($script:job.image_index) /ApplyDir:"$osL\" /Verify 2>&1 |
        ForEach-Object { Log "  [DISM] $_" }
    if ($LASTEXITCODE -ne 0) { Stop-Danger "DISM Apply-Image that bai (exitcode $LASTEXITCODE)" }

    # ── Nap driver theo model (M5a) ───────────────────────────────────────────
    Log "[3/5] Nap driver theo model (M5a)..."
    Inject-Drivers $osL

    # ── Dung BCD (S16) ────────────────────────────────────────────────────────
    Log "[4/5] Dung boot voi bcdboot..."
    Set-State "boot-config"
    try {
        &bcdboot "$osL\Windows" /s "$efiL" /f UEFI /l vi-VN 2>&1 | ForEach-Object { Log "  [BCDBOOT] $_" }
        if ($LASTEXITCODE -ne 0) {
            # Thu lai voi en-US
            &bcdboot "$osL\Windows" /s "$efiL" /f UEFI /l en-US 2>&1 | ForEach-Object { Log "  [BCDBOOT-EN] $_" }
        }
    } catch { Stop-Danger "bcdboot that bai: $_" }

    # Xac nhan mac dinh da la Windows (S16)
    Assert-WindowsIsDefault

    # ── Kiem tra sau khi bung (M5a) ───────────────────────────────────────────
    Log "[5/5] Kiem tra sau khi bung..."
    Set-State "verifying"
    Assert-PostRestore $osL

    # Kiem tra phan vung ngoai nguyen ven (S17)
    Assert-OtherPartitionsIntact $script:job.os_partition_guid

    # ── Hoan tat ─────────────────────────────────────────────────────────────
    Set-State "done"
    # Chuyen job vao logs (S8)
    Move-Item -LiteralPath $jobPath -Destination "$($script:base)\logs\job-$(Get-Date -Format yyyyMMdd-HHmmss).json" -Force -EA SilentlyContinue
    Remove-Item $stateFile -Force -EA SilentlyContinue
    Finish "XONG" "Khoi phuc hoan tat: $($script:job.image)"
    Log "Reboot ve Windows sau 10 giay..."
    Start-Sleep 10; wpeutil reboot; exit 0
}

# ── Action khong ro ───────────────────────────────────────────────────────────
Log "Action khong xac dinh: '$($script:job.action)'"
Restore-WindowsBoot; Start-Sleep 10; wpeutil reboot; exit 1
