#!/bin/bash
# ==============================================================================
#  create-solution.sh
#  Tao solution .NET 8 cho ReimageTool (chay tren Ubuntu)
#
#  Chay tu thu muc goc du an:
#    cd ~/Lilbow\ Recovery/ReimageTool
#    bash tools/create-solution.sh
#
#  Tao ra:
#    src/ReimageTool.sln
#    src/ReimageTool.Core/   (class library, net8.0-windows)
#    src/ReimageTool.UI/     (WinForms, net8.0-windows)
#    src/ReimageTool.Tests/  (MSTest, net8.0-windows)
# ==============================================================================
set -e

RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[1;33m'; CYN='\033[0;36m'; RST='\033[0m'
log()  { echo -e "${CYN}[INFO]${RST} $*"; }
ok()   { echo -e "${GRN}[ OK ]${RST} $*"; }

# ── Kiem tra dang o dung thu muc ─────────────────────────────────────────────
if [ ! -f "AGENTS.md" ]; then
    echo -e "${RED}[ERR]${RST} Phai chay tu thu muc goc du an ReimageTool (chua co AGENTS.md)."
    exit 1
fi

if ! command -v dotnet &>/dev/null; then
    echo -e "${RED}[ERR]${RST} .NET SDK chua cai. Chay tools/setup-dev-ubuntu.sh truoc."
    exit 1
fi

SRC="src"
cd "$SRC"

# ── Tao solution ──────────────────────────────────────────────────────────────
log "Tao solution ReimageTool.sln..."
dotnet new sln -n ReimageTool --force
ok "Solution da tao."

# ── ReimageTool.Core ──────────────────────────────────────────────────────────
log "Tao ReimageTool.Core (class library)..."
if [ ! -d "ReimageTool.Core" ]; then
    dotnet new classlib -n ReimageTool.Core --framework net8.0-windows -o ReimageTool.Core --force
    # Xoa Class1.cs mac dinh
    rm -f ReimageTool.Core/Class1.cs
fi
dotnet sln add ReimageTool.Core/ReimageTool.Core.csproj
ok "ReimageTool.Core da tao."

# ── ReimageTool.UI ────────────────────────────────────────────────────────────
log "Tao ReimageTool.UI (WinForms)..."
if [ ! -d "ReimageTool.UI" ]; then
    dotnet new winforms -n ReimageTool.UI --framework net8.0-windows -o ReimageTool.UI --force
fi
dotnet sln add ReimageTool.UI/ReimageTool.UI.csproj
ok "ReimageTool.UI da tao."

# ── ReimageTool.Tests ─────────────────────────────────────────────────────────
log "Tao ReimageTool.Tests (MSTest)..."
if [ ! -d "ReimageTool.Tests" ]; then
    dotnet new mstest -n ReimageTool.Tests --framework net8.0-windows -o ReimageTool.Tests --force
fi
dotnet sln add ReimageTool.Tests/ReimageTool.Tests.csproj
ok "ReimageTool.Tests da tao."

# ── Them tham chieu giua cac project ─────────────────────────────────────────
log "Them project references..."
dotnet add ReimageTool.UI/ReimageTool.UI.csproj     reference ReimageTool.Core/ReimageTool.Core.csproj
dotnet add ReimageTool.Tests/ReimageTool.Tests.csproj reference ReimageTool.Core/ReimageTool.Core.csproj
ok "References da them."

# ── Them Newtonsoft.Json cho Core (de xu ly JSON) ─────────────────────────────
log "Them Newtonsoft.Json cho ReimageTool.Core..."
dotnet add ReimageTool.Core/ReimageTool.Core.csproj package Newtonsoft.Json
ok "Newtonsoft.Json da them."

# ── Build thu ─────────────────────────────────────────────────────────────────
log "Build solution thu nghiem..."
dotnet build ReimageTool.sln -c Debug --nologo 2>&1 | tail -5
ok "Build thanh cong."

cd ..

echo ""
echo -e "${GRN}============================================================${RST}"
echo -e "${GRN}  Solution da tao xong!${RST}"
echo -e "${GRN}============================================================${RST}"
echo ""
echo "  src/"
echo "  ├── ReimageTool.sln"
echo "  ├── ReimageTool.Core/     (logic nghiep vu, khong UI)"
echo "  ├── ReimageTool.UI/       (WinForms, 5 man hinh)"
echo "  └── ReimageTool.Tests/    (unit test)"
echo ""
echo -e "${YEL}  Lenh thuong dung:${RST}"
echo "    dotnet build src/ReimageTool.sln"
echo "    dotnet test  src/ReimageTool.sln"
echo ""
echo "  Publish ra .exe cho Windows (tu Ubuntu):"
echo "    cd src/ReimageTool.UI"
echo "    dotnet publish -r win-x64 --self-contained -c Release -o ../../dist"
echo ""
echo "  Copy dist/*.exe sang may Windows de chay."
