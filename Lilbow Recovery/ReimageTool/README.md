# ReimageTool

> Phần mềm backup/restore Windows tự động cho máy UEFI/GPT, kiểu OneKey Ghost, chạy qua WinPE.

---

## Mô tả

ReimageTool cho phép nhân viên IT **backup và restore phân vùng Windows hoàn toàn tự động** sau khi bấm nút, không cần có mặt tại máy. Máy tự khởi động vào WinPE, thực hiện backup/restore, rồi tự quay về Windows và hiển thị kết quả.

### Tính năng chính (v1.0)

- ✅ Backup phân vùng Windows thành file WIM, lưu tại `D:\Reimage\images`
- ✅ Restore từ file WIM (chỉ format phân vùng Windows, không động tới ổ D:)
- ✅ Giao diện 5 bước (Windows Forms, tiếng Việt)
- ✅ Kiểm tra an toàn 12 quy tắc (S1–S12) — không bao giờ format nhầm ổ dữ liệu
- ✅ Ghi nhật ký và hiển thị kết quả sau khi Windows lên lại
- ✅ Bộ cài đặt một file `.exe` cho mỗi máy

### Yêu cầu hệ thống

- Windows 10/11 x64
- UEFI/GPT (không hỗ trợ MBR/BIOS legacy)
- Ổ dữ liệu D: (hoặc phân vùng khác) tách biệt với ổ Windows C:
- BitLocker phải tắt trên C: và ổ lưu ảnh
- Quyền Administrator

---

## Cấu trúc repo

```
ReimageTool/
  AGENTS.md                      Quy tắc cho AI agent (mục 0 và mục 3 của spec)
  README.md                      File này
  docs/
    ReimageTool-Plan-and-Spec.md Đặc tả kỹ thuật đầy đủ
    test-checklists/             Checklist kiểm thử thủ công theo milestone
    hardware-matrix.md           Ma trận kiểm thử phần cứng (M9)
  src/
    ReimageTool.Core/            C# class library — logic nghiệp vụ, không UI
    ReimageTool.UI/              C# WinForms — giao diện 5 màn hình
    ReimageTool.Tests/           C# MSTest/NUnit — unit test logic thuần
  winpe/
    engine.ps1                   Script chạy trong WinPE
    build-winpe.cmd              Dựng boot.wim tùy biến (cần ADK)
    drivers/                     Driver NVMe, Intel RST/VMD, mạng (không commit file lớn)
    dist/                        boot.wim, boot.sdi sau khi build (gitignore)
  setup/
    Setup-Machine.bat            Cài đặt một lần mỗi máy
    Uninstall-Machine.bat        Gỡ cài đặt (xóa mục BCD)
    installer.iss                Script Inno Setup
  scripts/
    Start-Job.ps1                CLI dùng trong giai đoạn đầu (M5)
  tools/
    test-vm/                     Hướng dẫn dựng VM Hyper-V để kiểm thử
```

---

## Quy trình làm việc an toàn

> ⚠️ Xem `AGENTS.md` để biết danh sách lệnh **TUYỆT ĐỐI KHÔNG CHẠY** trên máy phát triển.

```
[Windows]  Chọn tác vụ → ghi job.json → bcdedit /bootsequence → reboot
     ↓
[WinPE]    engine.ps1 → kiểm tra S1-S12 → backup/restore → ghi result.json → reboot
     ↓
[Windows]  Đọc result.json → hiển thị kết quả (Hoàn tất / Lỗi)
```

---

## Lịch trình milestone

| Mốc | Tuần       | Nội dung                      |
|-----|------------|-------------------------------|
| M0  | 05-11/10   | Môi trường, repo, VM          |
| M1  | 12-18/10   | Dựng WinPE                    |
| M2  | 19-25/10   | Setup và boot một lần         |
| M3  | 26/10-1/11 | Engine: backup                |
| M4  | 02-08/11   | Engine: restore + test sai    |
| M5  | 09-15/11   | CLI end-to-end + máy lab      |
| M6  | 16-22/11   | Core (C#)                     |
| M7  | 23/11-6/12 | Giao diện WinForms            |
| M8  | 07-13/12   | Cài đặt, kết quả, webhook     |
| M9  | 14-20/12   | Nhiều dòng máy, driver        |
| M10 | 21-27/12   | Thí điểm, phát hành v1.0      |

---

## Công nghệ

- **UI/Core:** C# WinForms, .NET Framework 4.8
- **Engine:** PowerShell 5.1 (WinPE)
- **WinPE:** Windows ADK + WinPE add-on
- **Đóng gói:** Inno Setup
- **Không phụ thuộc phần mềm trả phí**

---

## Giấy phép

Dùng nội bộ. Xem Phụ lục C trong spec về điều khoản WinPE của Microsoft khi phát hành ra ngoài.
