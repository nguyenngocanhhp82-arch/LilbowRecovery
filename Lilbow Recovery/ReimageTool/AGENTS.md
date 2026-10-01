# AGENTS.md — Quy tắc làm việc với AI Agent và Quy tắc an toàn

> **Đọc file này trước khi nhận bất kỳ nhiệm vụ nào liên quan đến dự án ReimageTool.**
> Phiên bản: 0.2 — 30/09/2026

## Môi trường phát triển

| Máy | OS | Vai trò |
|---|---|---|
| **Máy code** | Ubuntu | Viết C#/.NET 8, viết PS scripts, Git, docs |
| **Máy Windows lab** | Windows 10/11 | Chạy ADK, build WinPE, Hyper-V, test boot |

- **C# dùng .NET 8** (không phải .NET Framework 4.8) → compile được trên Ubuntu
- Publish Windows binary: `dotnet publish -r win-x64 --self-contained`
- **WinForms chỉ chạy trên Windows** — build trên Ubuntu, copy exe sang máy lab để test UI

---

## 0. Cách làm việc với AI Agent

1. **Làm từng milestone một** (xem mục 9 trong `docs/ReimageTool-Plan-and-Spec.md`).
   Mỗi lần giao đúng một milestone, kèm đường dẫn tới mục liên quan.

2. **Lập kế hoạch trước khi code.**
   Agent phải liệt kê kế hoạch và chờ người dùng duyệt trước khi viết code thực sự.

3. **Agent KHÔNG được tự kiểm thử phần boot.**
   Việc boot WinPE, bcdedit, format, bung ảnh **chỉ được chạy trong VM Hyper-V** do con người thực hiện.
   Agent chỉ viết code, unit test cho phần logic thuần, và soạn checklist kiểm thử thủ công.

4. **CẤM TUYỆT ĐỐI chạy các lệnh sau** trên máy đang dùng để phát triển:
   - `Start-Job.ps1`
   - `engine.ps1`
   - `Setup-Machine.bat`
   - `bcdedit`
   - `diskpart`
   - `Format-Volume`
   - `dism /Apply-Image`
   - `bcdboot`

   > Các lệnh này có thể làm máy phát triển **không khởi động được** hoặc **mất dữ liệu**.

5. **Commit Git sau mỗi milestone.**
   Tạo snapshot VM trước mỗi lần thử nghiệm phá hủy.

6. **Quy ước code:**
   - Tên biến, hàm, lớp: **tiếng Anh**
   - Giao diện người dùng (UI): **tiếng Việt có dấu**
   - Thông báo trong WinPE (engine): **tiếng Việt KHÔNG dấu** (console WinPE có thể không hiển thị dấu)

7. **Công cụ trên Ubuntu:**
   - `dotnet build / test / publish` — OK trên Ubuntu
   - `pwsh -File engine.ps1 -WhatIf` — kiểm tra cú pháp PS trên Ubuntu
   - Script `.bat`, `bcdedit`, `diskpart` — **chỉ chạy trên máy Windows lab**

---

## 3. Quy tắc an toàn bất biến (S1–S12)

> **Không được vi phạm. Mọi thay đổi code phải giữ các quy tắc này. Phải có test cho từng quy tắc.**

| Mã  | Quy tắc |
|-----|---------|
| S1  | **Không nhận diện ổ bằng chữ cái** (C:, D:) khi đã vào WinPE. Dùng GUID phân vùng, serial đĩa, dung lượng, nhãn. |
| S2  | Phân vùng bị format phải thỏa **tất cả**: GUID khớp job, serial đĩa khớp, dung lượng sai lệch không quá 100 MB, NTFS, nhãn khớp job, chứa thư mục `\Windows\System32`. Sai một điều thì dừng. |
| S3  | Phân vùng lưu ảnh (D:) và phân vùng EFI **không bao giờ** là đích của format. Nếu GUID đích trùng GUID nơi lưu ảnh thì dừng. |
| S4  | Không dùng `diskpart clean`, `Clear-Disk` hay bất kỳ lệnh nào xóa cả đĩa. Chỉ `Format-Volume` đúng một phân vùng. |
| S5  | Restore: kiểm tra SHA256, `Get-WimInfo` và phân vùng EFI tồn tại **trước khi** format. |
| S6  | Backup ghi ra `images\_tmp` rồi mới chuyển ra `images` khi chụp và kiểm tra thành công. Không bao giờ ghi đè ảnh đã có. |
| S7  | Trước điểm không quay lại (format), mọi lỗi phải dẫn tới **reboot về Windows cũ**. Sau điểm đó, ở lại WinPE và ghi lỗi. |
| S8  | `job.json` được chuyển vào `logs` ngay khi đọc xong, để không chạy lại ngoài ý muốn. |
| S9  | BitLocker phải tắt hẳn trên C: và ổ lưu ảnh trước khi đặt boot. Phần mềm tự kiểm tra và từ chối. |
| S10 | Restore yêu cầu người dùng gõ chữ `XOA`. Màn hình xác nhận phải hiển thị: Disk, Partition, dung lượng, nhãn của phân vùng sẽ bị xóa, và ghi rõ ổ lưu ảnh không bị động tới. |
| S11 | Máy xách tay phải cắm điện (kiểm tra pin/AC) trước khi bắt đầu. |
| S12 | Ổ chỉ cho chọn làm đích nếu chứa `\Windows`. Các phân vùng khác bị khóa trên giao diện, hiển thị lý do. |

---

## Lưu ý kỹ thuật cần kiểm chứng khi test

- Serial đĩa NVMe trong WinPE có thể khác định dạng với Windows → đã chuẩn hóa bằng hàm `Norm`.
- `Get-Partition.Type` dùng giá trị `Basic` cho phân vùng dữ liệu.
- `dism` có thể không chấp nhận phần mở rộng lạ → file tạm vẫn dùng đuôi `.wim` (đặt trong `_tmp`).
- `bcdboot` trên EFI có sẵn cần xác nhận Windows vẫn là mục boot mặc định sau restore.
