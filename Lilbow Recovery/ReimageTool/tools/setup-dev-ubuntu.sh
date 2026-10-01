#!/bin/bash
# ==============================================================================
#  setup-dev-ubuntu.sh
#  Cai dat moi truong phat trien ReimageTool tren Ubuntu
#
#  Chay:  chmod +x setup-dev-ubuntu.sh && ./setup-dev-ubuntu.sh
#
#  Cai dat:
#    - .NET 8 SDK (compile C# WinForms, dotnet test)
#    - PowerShell 7 (kiem tra cu phap engine.ps1, chay -WhatIf)
#    - VS Code + cac extension can thiet
#    - Git (neu chua co)
#    - wine (tuy chon, de thu chay .exe nhe khong can VM)
# ==============================================================================
set -e

RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[1;33m'; CYN='\033[0;36m'; RST='\033[0m'

log()  { echo -e "${CYN}[INFO]${RST} $*"; }
ok()   { echo -e "${GRN}[ OK ]${RST} $*"; }
warn() { echo -e "${YEL}[WARN]${RST} $*"; }
err()  { echo -e "${RED}[ERR ]${RST} $*"; }

echo ""
echo -e "${CYN}============================================================${RST}"
echo -e "${CYN}  Cai dat moi truong phat trien ReimageTool${RST}"
echo -e "${CYN}  Ubuntu + .NET 8 + PowerShell 7${RST}"
echo -e "${CYN}============================================================${RST}"
echo ""

# ── Kiem tra quyen ────────────────────────────────────────────────────────────
if [ "$EUID" -eq 0 ]; then
    err "Khong chay bang root. Chay bang user thuong (sudo se tu dong khi can)."
    exit 1
fi

# ── Cap nhat package list ──────────────────────────────────────────────────────
log "Cap nhat danh sach goi..."
sudo apt-get update -qq

# ── Cai Git ───────────────────────────────────────────────────────────────────
if command -v git &>/dev/null; then
    ok "Git da co: $(git --version)"
else
    log "Cai Git..."
    sudo apt-get install -y git
    ok "Git da cai: $(git --version)"
fi

# ── Cai .NET 8 SDK ────────────────────────────────────────────────────────────
if command -v dotnet &>/dev/null && dotnet --list-sdks | grep -q "^8\."; then
    ok ".NET 8 SDK da co: $(dotnet --version)"
else
    log "Cai .NET 8 SDK..."
    # Them Microsoft package repository
    wget -q https://packages.microsoft.com/config/ubuntu/$(lsb_release -rs)/packages-microsoft-prod.deb \
         -O /tmp/packages-microsoft-prod.deb
    sudo dpkg -i /tmp/packages-microsoft-prod.deb
    rm /tmp/packages-microsoft-prod.deb
    sudo apt-get update -qq
    sudo apt-get install -y dotnet-sdk-8.0
    ok ".NET 8 SDK da cai: $(dotnet --version)"
fi

# ── Cai PowerShell 7 ──────────────────────────────────────────────────────────
if command -v pwsh &>/dev/null; then
    ok "PowerShell da co: $(pwsh --version)"
else
    log "Cai PowerShell 7..."
    sudo apt-get install -y powershell
    ok "PowerShell da cai: $(pwsh --version)"
fi

# ── Cai VS Code ───────────────────────────────────────────────────────────────
if command -v code &>/dev/null; then
    ok "VS Code da co."
else
    log "Cai VS Code..."
    sudo apt-get install -y apt-transport-https
    wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > /tmp/microsoft.gpg
    sudo install -o root -g root -m 644 /tmp/microsoft.gpg /usr/share/keyrings/microsoft-archive-keyring.gpg
    rm /tmp/microsoft.gpg
    sudo sh -c 'echo "deb [arch=amd64,arm64,armhf signed-by=/usr/share/keyrings/microsoft-archive-keyring.gpg] https://packages.microsoft.com/repos/code stable main" > /etc/apt/sources.list.d/vscode.list'
    sudo apt-get update -qq
    sudo apt-get install -y code
    ok "VS Code da cai."
fi

# ── Cai extension VS Code ─────────────────────────────────────────────────────
log "Cai extension VS Code..."
EXTENSIONS=(
    "ms-dotnettools.csharp"               # C# (IntelliSense, debug)
    "ms-dotnettools.csdevkit"             # C# Dev Kit
    "ms-vscode.powershell"               # PowerShell
    "ms-vscode.vscode-json"              # JSON
    "streetsidesoftware.code-spell-checker"  # Kiem tra chinh ta
    "eamodio.gitlens"                    # Git lens
)
for EXT in "${EXTENSIONS[@]}"; do
    code --install-extension "$EXT" --force 2>/dev/null || warn "  Khong cai duoc: $EXT (co the can mo VS Code truoc)"
done
ok "Extension da cai."

# ── Kiem tra cuoi ─────────────────────────────────────────────────────────────
echo ""
echo -e "${GRN}============================================================${RST}"
echo -e "${GRN}  CAI DAT HOAN TAT!${RST}"
echo -e "${GRN}============================================================${RST}"
echo ""
echo "  OS       : $(lsb_release -ds)"
echo "  .NET SDK : $(dotnet --version 2>/dev/null || echo 'CHUA CO')"
echo "  PowerShell: $(pwsh --version 2>/dev/null || echo 'CHUA CO')"
echo "  Git      : $(git --version 2>/dev/null || echo 'CHUA CO')"
echo "  VS Code  : $(code --version 2>/dev/null | head -1 || echo 'CHUA CO')"
echo ""
echo -e "${YEL}  BUOC TIEP THEO:${RST}"
echo "  1. Mo thu muc du an trong VS Code:"
echo "     code '/home/$USER/Lilbow Recovery/ReimageTool'"
echo ""
echo "  2. Tao solution .NET (M6):"
echo "     cd 'ReimageTool/src'"
echo "     dotnet new solution -n ReimageTool"
echo "     dotnet new winforms -n ReimageTool.UI --framework net8.0-windows"
echo "     dotnet new classlib -n ReimageTool.Core --framework net8.0-windows"
echo "     dotnet new mstest -n ReimageTool.Tests --framework net8.0-windows"
echo ""
echo "  3. Build va test tren Ubuntu:"
echo "     dotnet build"
echo "     dotnet test"
echo ""
echo "  4. Tao file .exe cho Windows (tu Ubuntu):"
echo "     dotnet publish -r win-x64 --self-contained -c Release"
echo ""
echo "  5. Viec can may Windows lab:"
echo "     - Cai ADK, chay build-winpe.cmd"
echo "     - Chay Hyper-V, tao VM test"
echo "     - Chay Deploy-ReimageTool.bat tren may dich"
echo ""
