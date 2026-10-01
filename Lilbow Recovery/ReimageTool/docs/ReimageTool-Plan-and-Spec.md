# ReimageTool — Kế hoạch và Đặc tả kỹ thuật

> Phiên bản tài liệu: 0.1 — 30/09/2026
> Trạng thái: Đặc tả khởi đầu. Các script ở Phụ lục A **chưa được thử trên máy thật**.

Tài liệu gốc đầy đủ: xem file đặc tả được giao bởi người dùng (lưu ngoài repo hoặc trong thư mục riêng).

## Tóm tắt các quyết định kiến trúc

| Hạng mục | Quyết định |
|---|---|
| Ngôn ngữ UI/Core | C# WinForms, .NET Framework 4.8 |
| Ngôn ngữ Engine | PowerShell 5.1 (WinPE) |
| WinPE | Windows ADK + WinPE add-on |
| Định dạng ảnh | WIM (dism.exe) |
| Nhận diện phân vùng | GUID + Serial đĩa + Dung lượng + Nhãn (không dùng chữ cái ổ trong WinPE) |
| Đóng gói | Inno Setup |
| Lưu trữ ảnh | `D:\Reimage\images\*.wim` |
| Xác thực ảnh | SHA256 (.wim.sha256) |
| Giao tiếp Windows↔WinPE | job.json + result.json |

## Hợp đồng dữ liệu (tóm tắt)

### job.json

```json
{
  "action": "backup",
  "hostname": "PC-KETOAN-01",
  "os_partition_guid": "{b4c1e2a0-...}",
  "os_label": "WINDOWS",
  "os_size": 128849018880,
  "disk_serial": "S4EVNX0M123456",
  "store_partition_guid": "{aabbccdd-...}",
  "image": "images\\PC-KETOAN-01_20261101-0930.wim",
  "image_index": 1,
  "image_name": "Win PC-KETOAN-01 2026-11-01",
  "compress": "fast"
}
```

### result.json

```json
{
  "status": "XONG",
  "message": "Backup hoan tat: images\\...",
  "action": "backup",
  "time": "2026-11-01T09:30:00"
}
```

`status` có 3 giá trị: `XONG`, `DUNG` (dừng an toàn trước format), `LOI`.

## Cấu trúc thư mục trên ổ lưu ảnh

```
D:\Reimage\
  sources\boot.wim
  boot\boot.sdi
  images\*.wim
  images\*.wim.sha256
  images\_tmp\
  job.json          (chỉ tồn tại từ lúc bấm Process đến khi engine đọc)
  result.json
  logs\
  bootguid.txt
```

## Lịch trình milestone

Xem `README.md` hoặc tài liệu gốc đầy đủ.
