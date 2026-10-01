# ReimageTool: Phương án giảm rủi ro khi cài lại Windows từ xa

> Tài liệu bổ sung (addendum v0.2) cho `ReimageTool-Plan-and-Spec.md`.
> Mục đích: giảm tối đa khả năng máy **không boot được** sau khi hệ thống khởi động lại vào WinPE, trong bối cảnh máy ở xa và chỉ điều khiển được qua UltraViewer/AnyDesk.
> Ngày: 30/09/2026. Trạng thái: đề xuất thiết kế. Các đoạn mã bên dưới là **mảnh minh họa chưa thử trên máy thật**, cần tích hợp vào `engine.ps1` và kiểm thử bằng fault injection (mục 11).

---

## 0. Quy tắc làm việc với Antigravity cho tài liệu này

1. Giao cho agent **từng lớp** (mục 3 đến mục 9) theo milestone ở mục 12, không giao cả tài liệu một lần.
2. Agent chỉ viết code, unit test cho logic thuần và checklist kiểm thử thủ công. **Việc ngắt nguồn VM, boot WinPE, format, bung ảnh do con người chạy trong VM Hyper-V.**
3. **Cấm agent chạy** `engine.ps1`, `Start-Job.ps1`, `Setup-Machine.bat`, `bcdedit`, `diskpart`, `Format-Volume`, `dism /Apply-Image`, `bcdboot` trên máy đang phát triển.
4. Mọi thông báo trong WinPE viết tiếng Việt **không dấu**.
5. Không được làm yếu các quy tắc an toàn S1-S12 ở đặc tả v0.1 và S13-S20 ở mục 10 của tài liệu này.

---

## 1. Mục tiêu và ba nguyên tắc

Không thể đưa rủi ro về 0 khi xóa và cài lại máy từ xa. Mục tiêu thực tế: làm cho tình huống "máy mất Windows và không cứu được từ xa" trở nên rất hiếm, bằng ba nguyên tắc:

1. **Chứng minh trước khi xóa.** Mọi thứ kiểm tra được thì kiểm tra lúc máy còn Windows.
2. **Cửa sổ nguy hiểm càng ngắn càng tốt, và tự hồi phục.** Nếu mất điện hoặc lỗi giữa lúc bung ảnh, máy tự làm lại thay vì nằm chết.
3. **Mọi trạng thái hỏng đều nhìn thấy và điều khiển được từ xa.** UltraViewer/AnyDesk không chạy được trong WinPE, nên cần kênh riêng.

---

## 2. Phân loại lỗi: lỗi nào thực sự nguy hiểm

| Giai đoạn | Nếu lỗi | Trạng thái máy | Mức nguy hiểm |
|---|---|---|---|
| Trong Windows, trước khi reboot | Script từ chối | Không đổi gì | An toàn |
| Reboot nhưng WinPE không lên | Máy vào lại Windows cũ | Windows cũ còn nguyên | An toàn |
| WinPE lên nhưng kiểm tra thất bại | Reboot về Windows cũ | Windows cũ còn nguyên | An toàn |
| WinPE treo, không mạng, không màn hình | Máy kẹt | Windows cũ còn, cần tắt/bật nguồn | Trung bình |
| Format, bung ảnh, dựng boot bị ngắt | Máy không có Windows | **Mất hệ điều hành** | **Nguy hiểm** |
| Windows mới bung xong nhưng không boot | Màn hình xanh hoặc không lên | **Mất hệ điều hành** | **Nguy hiểm** |

---

## 3. Lớp 1: Chạy thử vòng boot (selftest)

Thêm tác vụ `selftest` vô hại: máy khởi động vào WinPE, kiểm tra, rồi quay lại Windows, **không xóa gì**.

### 3.1 WinPE kiểm tra và ghi `selftest-ok.json`
- Thấy phân vùng lưu ảnh và phân vùng Windows (theo GUID).
- Thấy ổ NVMe/RAID, thấy mạng dây và gửi được một thông điệp "selftest OK" về kênh báo cáo.
- Ghi lại model máy, phiên bản BIOS, trạng thái Secure Boot, thời điểm.
- Đọc được ảnh trong `images` (đọc thử vài MB đầu file).

### 3.2 Quy tắc dùng kết quả
- **Restore từ chối chạy** nếu không có `selftest-ok.json` hợp lệ: trong vòng **7 ngày**, cùng **model** và cùng **phiên bản BIOS** với hiện tại.
- Trên giao diện: nút "Kiểm tra khả năng khởi động" ở màn hình Restore; nút Restore bị khóa nếu chưa có kết quả đạt.
- Thời gian ước lượng: khoảng 3-5 phút.

### 3.3 Hợp đồng `selftest-ok.json`

| Trường | Ý nghĩa |
|---|---|
| `time` | Thời điểm ISO 8601 |
| `model` | Model máy (`Win32_ComputerSystem.Model`) |
| `bios_version` | Phiên bản BIOS |
| `secure_boot` | `true` hoặc `false` |
| `disks_seen` | Số đĩa WinPE thấy |
| `store_found` | `true` nếu thấy phân vùng lưu ảnh |
| `os_partition_found` | `true` nếu thấy phân vùng Windows theo GUID |
| `network_ok` | `true` nếu gửi được báo cáo |
| `status` | `OK` hoặc mô tả lỗi |

---

## 4. Lớp 2: Chống format nhầm phân vùng

Các kiểm tra hiện có (GUID, serial, dung lượng, nhãn, có `\Windows`) vẫn giữ. Thêm ba lớp **độc lập**:

1. **Token xác nhận.** Lúc tạo job, ghi mã ngẫu nhiên vào chính phân vùng Windows đã chọn. Engine chỉ format phân vùng chứa đúng mã đó.
2. **Vị trí (offset) và số thứ tự phân vùng** phải khớp job.
3. **Chụp ảnh bảng phân vùng trước và sau.** Sau khi bung, mọi phân vùng khác phải y hệt trước đó, và `D:\LilbowRecovery\sentinel.txt` phải còn nguyên.

Thêm **hạn dùng cho job** (`expires_at`, ví dụ 2 giờ) và `job_id` duy nhất.

```powershell
# Trong Windows, luc tao job
$token = [guid]::NewGuid().ToString()
New-Item -ItemType Directory -Force "C:\ProgramData\LilbowRecovery" | Out-Null
Set-Content "C:\ProgramData\LilbowRecovery\token.txt" $token
# Dua vao job.json: job_id, token, os_offset, expires_at

# Chup bang phan vung truoc khi chay
Get-Partition | Select-Object DiskNumber, PartitionNumber, Guid, Offset, Size, GptType |
    ConvertTo-Json | Set-Content "D:\LilbowRecovery\partitions-before.json" -Encoding UTF8
Set-Content "D:\LilbowRecovery\sentinel.txt" $token

# Trong WinPE, truoc khi format
$tokPath = "$W\ProgramData\LilbowRecovery\token.txt"
if (-not (Test-Path $tokPath) -or (Get-Content $tokPath -Raw).Trim() -ne $job.token) { Stop-Safe "Token khong khop" }
if ([int64]$tp.Offset -ne [int64]$job.os_offset) { Stop-Safe "Offset phan vung khong khop" }
if ((Get-Date) -gt [datetime]$job.expires_at) { Stop-Safe "Job het han" }

# Trong WinPE, sau khi bung xong
$before = Get-Content "$($script:base)\partitions-before.json" -Raw | ConvertFrom-Json
$after  = Get-Partition | Select-Object DiskNumber, PartitionNumber, Guid, Offset, Size
foreach ($b in $before) {
    if ($b.Guid -ieq $job.os_partition_guid) { continue }
    $a = $after | Where-Object { $_.Guid -ieq $b.Guid }
    if (-not $a -or [int64]$a.Offset -ne [int64]$b.Offset -or [int64]$a.Size -ne [int64]$b.Size) {
        throw "Phan vung khac bi thay doi: $($b.Guid)"
    }
}
if (-not (Test-Path "$($script:base)\sentinel.txt")) { throw "Mat sentinel tren o luu anh" }
```

---

## 5. Lớp 3: Tự hồi phục khi bung dở (quan trọng nhất)

### 5.1 Các trạng thái (`state.json`)

| `phase` | Ý nghĩa | Nếu bị ngắt rồi bật lại |
|---|---|---|
| `checking` | Đang kiểm tra | Về Windows cũ (chưa xóa gì) |
| `formatting` | Sắp/đang format | Resume từ bước format |
| `applying` | Đang bung ảnh | Resume từ bước format |
| `boot-config` | Đang dựng boot | Resume từ bước format |
| `verifying` | Kiểm tra sau bung | Resume từ bước kiểm tra |
| `done` | Hoàn tất | Về Windows mới |
| `failed` | Quá số lần thử | Chế độ cứu hộ (mục 8) |

### 5.2 Mã minh họa

```powershell
function Set-State($phase) {
    @{ job_id=$script:job.job_id; phase=$phase; attempts=$script:attempts; updated=(Get-Date -Format s) } |
        ConvertTo-Json | Set-Content "$($script:base)\state.json" -Encoding UTF8
}

# Truoc khi format: dat WinPE lam muc boot MAC DINH tren EFI
$S = Ensure-Letter $efi
$bcdStore = "$S\EFI\Microsoft\Boot\BCD"
$winpe = (Get-Content "$($script:base)\bootguid.txt").Trim()
bcdedit /store $bcdStore /default $winpe
bcdedit /store $bcdStore /timeout 3
Set-State "formatting"
```

Khi WinPE khởi động và thấy trạng thái dở:

```powershell
$stateFile = "$($script:base)\state.json"
if (Test-Path $stateFile) {
    $st = Get-Content $stateFile -Raw | ConvertFrom-Json
    if ($st.phase -in @("formatting","applying","boot-config","verifying")) {
        $script:attempts = [int]$st.attempts + 1
        if ($script:attempts -gt 3) { Set-State "failed"; Enter-RescueMode }
        # tiep tuc tu buoc format voi muc kiem tra thu hai
    }
}
```

### 5.3 Quy tắc kèm theo

| Điểm | Quy tắc |
|---|---|
| Khi resume | Dùng kiểm tra mức hai: GUID, serial, offset, dung lượng (không dùng token hay `\Windows`) |
| Giới hạn thử lại | Tối đa 3 lần. Quá thì vào chế độ cứu hộ, **không reboot lặp vô hạn** |
| Khi xong | Sau `bcdboot`, xác nhận mục mặc định **không còn là WinPE** trước khi ghi `done` |
| WinPE không có job/state | Đặt lại mặc định về Windows rồi reboot |
| Dọn job | Chuyển `job.json` vào `logs` chỉ khi `done` hoặc `DUNG` |

---

## 6. Lớp 4: Chỉ bung ảnh đã xác minh

```powershell
dism /Mount-Image /ImageFile:D:\LilbowRecovery\images\anh.wim /Index:1 /MountDir:X:\mnt /ReadOnly
# Kiem tra: \Windows\System32\winload.efi va \Windows\System32\config\SYSTEM
dism /Unmount-Image /MountDir:X:\mnt /Discard
```

Ghi `<ten-anh>.wim.meta.json`:

| Trường | Ý nghĩa |
|---|---|
| `sha256` | Hash của file ảnh |
| `created` | Thời điểm tạo |
| `source_host` | Tên máy nguồn |
| `windows_build` | Số build Windows trong ảnh |
| `verified` | `true` nếu đã mount thử và thấy các file khởi động |

**Restore chỉ nhận ảnh có `verified: true`.**

---

## 7. Lớp 5: Kiểm tra sau khi bung

### 7.1 Trước khi reboot khỏi WinPE
- `W:\Windows\System32\winload.efi` và `config\SYSTEM` tồn tại.
- `bcdboot` thành công và mục mặc định trỏ vào Windows mới.
- Bảng phân vùng và `sentinel.txt` giống trước.

### 7.2 Nạp driver theo model

```powershell
$model = (Get-CimInstance Win32_ComputerSystem).Model
$drv = "$($script:base)\drivers\$model"
if (Test-Path $drv) { & dism.exe /Image:"$W\" /Add-Driver /Driver:$drv /Recurse }
```

Xuất driver từ máy mẫu:

```powershell
dism /Online /Export-Driver /Destination:C:\Drivers\export
```

---

## 8. Lớp 6: Nhìn thấy và điều khiển WinPE từ xa

### 8.1 Heartbeat (mỗi 30 giây)

| Trường | Ý nghĩa |
|---|---|
| `host` | Tên máy |
| `job_id` | Mã job |
| `phase` | Giai đoạn hiện tại |
| `percent` | Phần trăm bung/chụp (phân tích đầu ra DISM) |
| `last_log` | Vài dòng log cuối |
| `time` | Thời điểm |

### 8.2 Danh sách lệnh cho phép

| Lệnh | Tác dụng |
|---|---|
| `retry` | Chạy lại từ bước format |
| `reboot` | Khởi động lại |
| `reboot-windows` | Đặt mặc định về Windows rồi reboot |
| `abort` | Dừng và ở lại WinPE chờ lệnh |

### 8.3 Triển khai
- **Bot Telegram:** gọi `sendMessage` để báo trạng thái và `getUpdates` để nhận lệnh qua HTTPS.
- Hoặc **webhook FastAPI** nhận trạng thái và trả lệnh.
- Lỗi mạng chỉ bỏ qua, **không làm hỏng job**.

### 8.4 Chế độ cứu hộ
Khi quá 3 lần thử hoặc `failed`: engine **ở lại WinPE**, tiếp tục heartbeat và chờ lệnh.

### 8.5 Yêu cầu mạng
Cần **mạng dây (Ethernet)** trong WinPE. Wi-Fi trong WinPE gần như không dùng được.

---

## 9. Lớp 7: Phần cứng và quy trình

1. **Kiểm tra đĩa:**
```powershell
Get-PhysicalDisk | Select-Object FriendlyName, HealthStatus, OperationalStatus
```
Khác `Healthy` → từ chối, yêu cầu có người tại chỗ.

2. **Điện:** máy xách tay phải cắm điện, pin trên 50%.
3. **Tắt/bật nguồn từ xa:** BIOS "AC Power Recovery = Power On" + ổ cắm thông minh, hoặc Intel AMT/vPro.
4. **USB WinPE cứu hộ** ở mỗi chi nhánh.
5. **Quy trình:** chạy canary cho mỗi model trước, chọn giờ hành chính, có người liên hệ tại chi nhánh.

---

## 10. Quy tắc an toàn mới (S13–S20)

| Mã | Quy tắc |
|---|---|
| S8 (sửa) | `job.json` chỉ chuyển vào `logs` khi `done`, `failed` hoặc `DUNG` |
| S13 | Job có `job_id`, `token`, `os_offset`, `expires_at`. Engine từ chối job thiếu/hết hạn. Trước format phải khớp token và offset |
| S14 | Restore chỉ chạy khi có `selftest-ok.json` hợp lệ (7 ngày, cùng model, cùng BIOS) |
| S15 | Ghi `state.json` trước mỗi bước nguy hiểm. Resume dùng kiểm tra mức hai |
| S16 | Trước format phải đặt WinPE làm boot mặc định. Sau `bcdboot` phải xác nhận mặc định trỏ vào Windows mới |
| S17 | Chụp bảng phân vùng trước và sau; mọi phân vùng khác phải nguyên vẹn; `sentinel.txt` phải còn |
| S18 | Restore chỉ nhận ảnh có `verified: true` |
| S19 | Tối đa 3 lần thử lại, sau đó vào chế độ cứu hộ, không reboot lặp vô hạn |
| S20 | Từ chối khi đĩa không `Healthy`, hoặc máy xách tay không cắm điện/pin dưới 50% |

### Trường mới trong `job.json`

| Trường | Kiểu | Ý nghĩa |
|---|---|---|
| `job_id` | string | Mã duy nhất của job |
| `token` | string | Mã ngẫu nhiên ghi trên phân vùng Windows đã chọn |
| `os_offset` | number | Vị trí (byte) của phân vùng Windows |
| `expires_at` | string | Hạn dùng job, ISO 8601 |

### File và thư mục mới trên ổ lưu ảnh

```
D:\LilbowRecovery\
  state.json                 trạng thái máy (mục 5)
  selftest-ok.json           kết quả selftest (mục 3)
  sentinel.txt               mã kiểm tra ổ lưu ảnh còn nguyên
  partitions-before.json     bảng phân vùng trước khi chạy
  drivers\<model>\           driver nạp vào Windows mới (mục 7.2)
  images\*.wim.meta.json     thông tin xác minh ảnh (mục 6)
```

---

## 11. Kiểm thử lỗi cố ý (fault injection) trên VM

```powershell
Stop-VM -Name ReimageTest -TurnOff -Force
Start-VM -Name ReimageTest
```

| Ngắt nguồn tại | Kỳ vọng sau khi bật lại |
|---|---|
| Trước format (`checking`) | Về Windows cũ, ghi `DUNG` |
| Ngay lúc format | Vào WinPE, resume, hoàn tất |
| Bung ảnh ở 10%, 50%, 90% | Vào WinPE, resume, hoàn tất |
| Giữa lúc `bcdboot` | Vào WinPE, resume, hoàn tất |
| Ngay sau `bcdboot` | Vào Windows mới hoặc resume đúng cách |
| Ngắt nguồn 4 lần liên tiếp | Vào chế độ cứu hộ, không reboot lặp |

**Test an toàn:**
1. Xóa `selftest-ok.json` → restore bị từ chối.
2. Sửa `token` trong job → dừng và về Windows cũ.
3. Sửa `expires_at` thành quá khứ → dừng.
4. Đổi `os_offset` → dừng.
5. Sau restore, đối chiếu `partitions-before.json` → phân vùng khác không đổi.
6. Ảnh `verified: false` → bị từ chối.
7. Mất mạng trong WinPE → job vẫn chạy được.

---

## 12. Milestone bổ sung

| Mốc | Nội dung | Ưu tiên | Công sức |
|---|---|---|---|
| **M4a** | Tác vụ `selftest` (engine + nút giao diện) | Bắt buộc v1.0 | Thấp |
| **M4b** | Token, offset, expiry, snapshot phân vùng (S13, S17) | Bắt buộc v1.0 | Thấp |
| **M4c** | Máy trạng thái, resume, mặc định WinPE (S15, S16) | Bắt buộc v1.0 | Trung bình |
| **M4d** | Ảnh đã xác minh `meta.json` (S18) | Nên có v1.0 | Thấp |
| **M5a** | Kiểm tra sau bung + nạp driver theo model | Bắt buộc v1.0 | Trung bình |
| **M8a** | Heartbeat, nhận lệnh, cứu hộ qua Telegram/webhook | Nên có v1.0 | Trung bình |
| **M9a** | Bộ kiểm thử fault injection hoàn chỉnh | Nên có | Trung bình |
| **M9b** | Kiểm tra đĩa, pin/AC (S20) | Nên có | Thấp |

---

## 13. Rủi ro còn lại

Dù làm hết các lớp trên, vẫn cần người tại chỗ khi:
- Đĩa hoặc firmware hỏng thật giữa lúc bung.
- WinPE không có driver mạng và tự hồi phục thất bại.
- Phân vùng EFI bị hỏng.
- Windows mới thiếu driver ổ đĩa của dòng máy chưa từng thử.
- Máy chỉ có Wi-Fi, không có kênh theo dõi từ xa trong WinPE.

> Giai đoạn đầu nên thí điểm ở chi nhánh có người hỗ trợ, rồi mới mở rộng.

---

## 14. Câu hỏi mở

1. Máy ở chi nhánh dùng **mạng dây hay chỉ Wi-Fi**?
2. Có máy chủ nội bộ để chạy webhook, hay dùng **Telegram Bot**?
3. Có **ổ cắm thông minh** hoặc máy có **Intel AMT/vPro** để tắt/bật nguồn từ xa không?
4. Có chấp nhận thêm dung lượng một bản Windows cho phương án **A/B** (sau v1.0) không?
