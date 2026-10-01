#Requires -RunAsAdministrator
# ==============================================================================
#  LilbowRecovery.ps1 — Ung dung WPF GUI
#  Khong can cai them gi. PowerShell 5.1 + WPF co san trong Windows 10/11.
#  Double-click LilbowRecovery.bat de chay.
#  Phien ban: 1.0
# ==============================================================================
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$script:AppName     = "LilbowRecovery"
$script:ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:StoreLetter = "D"
$script:ReimageDir  = "LilbowRecovery"   # D:\LilbowRecovery\
$script:ImagesDir   = "images"

# ── Log ───────────────────────────────────────────────────────────────────────
$ld = "$env:ProgramData\$($script:AppName)\logs"
New-Item -ItemType Directory -Force $ld | Out-Null
$script:LogFile = Join-Path $ld "ui-$(Get-Date -Format yyyyMMdd-HHmmss).log"
function Log($m) { "$(Get-Date -Format s)  $m" | Add-Content -LiteralPath $script:LogFile -Encoding UTF8 }

# ── Tien ich ──────────────────────────────────────────────────────────────────
function Get-Base    { "$($script:StoreLetter):\$($script:ReimageDir)" }
function Get-ImgDir  { "$(Get-Base)\$($script:ImagesDir)" }
function Format-GB($b) { "$([math]::Round($b/1GB,1)) GB" }
function Get-BootGuid {
    $f = "$(Get-Base)\bootguid.txt"
    if (Test-Path $f) { return (Get-Content $f -Encoding UTF8).Trim() }; return $null
}
function Test-WinPEReady {
    $guid = Get-BootGuid
    if (-not $guid) { return $false }
    if (-not (Test-Path "$(Get-Base)\sources\boot.wim")) { return $false }
    return ([string](&bcdedit /enum all 2>$null) -match [regex]::Escape($guid))
}
function Get-AllPartitions {
    $r = @()
    foreach ($p in (Get-Partition | Where-Object { $_.Size -gt 50MB })) {
        try {
            $vol  = Get-Volume -Partition $p -EA SilentlyContinue
            $disk = Get-Disk -Number $p.DiskNumber -EA SilentlyContinue
            $let  = if ($p.DriveLetter) { "$($p.DriveLetter):" } else { "" }
            $r += [PSCustomObject]@{
                Partition  = $p; Letter=$let; Label=if($vol){$vol.FileSystemLabel}else{""}
                FileSystem = if($vol){$vol.FileSystem}else{"?"}
                SizeGB=[math]::Round($p.Size/1GB,1); FreeGB=if($vol){[math]::Round($vol.SizeRemaining/1GB,1)}else{0}
                HasWindows = ($let -and (Test-Path "$let\Windows\System32"))
                IsEFI=($p.GptType -eq "{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}")
                IsMSR=($p.GptType -eq "{e3c9e316-0b5c-4db8-817d-f92df00215ae}")
                IsRecovery=($p.GptType -eq "{de94bba4-06d1-4d40-a16a-bfd50179d6ac}")
                DiskNum=$p.DiskNumber; PartNum=$p.PartitionNumber; Guid=$p.Guid
                DiskModel=if($disk){$disk.FriendlyName}else{""}
            }
        } catch { continue }
    }; return $r
}
function Get-PartRows($mode) {
    $sg = (Get-Partition -DriveLetter $script:StoreLetter -EA SilentlyContinue).Guid
    return @(Get-AllPartitions | ForEach-Object {
        $locked=$false; $note=""
        if ($_.IsEFI)      { $locked=$true; $note="EFI — hệ thống" }
        elseif ($_.IsMSR)  { $locked=$true; $note="MSR" }
        elseif ($_.IsRecovery){$locked=$true;$note="Recovery"}
        elseif ($sg -and $_.Guid -ieq $sg){$locked=$true;$note="⛔ Ổ lưu ảnh — bị khóa"}
        elseif ($mode -eq "source" -and -not $_.HasWindows){$locked=$true;$note="Không có \Windows"}
        elseif ($mode -eq "target" -and -not $_.HasWindows){$locked=$true;$note="Không có \Windows"}
        if (-not $locked -and $_.HasWindows){$note="✅ Có Windows"}
        [PSCustomObject]@{
            Letter=$_.Letter; Label=$_.Label; FileSystem=$_.FileSystem
            SizeGB="$($_.SizeGB) GB"; FreeGB="$($_.FreeGB) GB"; DiskNum="Disk $($_.DiskNum)"
            Note=$note; Locked=$locked; OrigItem=$_
        }
    } | Where-Object { -not $_.Locked })
}
function Get-ImageRows {
    @(Get-ChildItem "$(Get-ImgDir)\*.wim" -EA SilentlyContinue | Sort-Object LastWriteTime -Descending |
      ForEach-Object {
          $hasSha = Test-Path "$($_.FullName).sha256"
          [PSCustomObject]@{Name=$_.Name; SizeStr=Format-GB $_.Length
              DateStr=$_.LastWriteTime.ToString("yyyy-MM-dd HH:mm")
              HashStatus=if($hasSha){"✔ OK"}else{"✘ Thiếu"}; FullPath=$_.FullName}
      })
}

# ==============================================================================
#  SECURITY CHECKS
# ==============================================================================
function Get-SecurityStatus {
    $items = @()

    # 1. BitLocker C:
    try {
        $bl = Get-BitLockerVolume -MountPoint "C:" -EA SilentlyContinue
        $status = if ($bl) { $bl.VolumeStatus } else { "FullyDecrypted" }
        $ok = ($status -eq "FullyDecrypted")
        $items += [PSCustomObject]@{
            Id="BL_C"; Name="BitLocker — Ổ C:"
            Status=if($ok){"✔ Tắt"}else{"✘ Đang bật ($status)"}
            OK=$ok; CanFix=$true
            Detail=if($ok){"An toàn"}else{"WinPE không thể truy cập C: nếu BitLocker bật"}
        }
    } catch { $items += [PSCustomObject]@{Id="BL_C";Name="BitLocker — Ổ C:";Status="? Không đọc được";OK=$false;CanFix=$false;Detail=""} }

    # 2. BitLocker ổ lưu ảnh
    try {
        $bl2 = Get-BitLockerVolume -MountPoint "$($script:StoreLetter):" -EA SilentlyContinue
        $s2  = if ($bl2) { $bl2.VolumeStatus } else { "FullyDecrypted" }
        $ok2 = ($s2 -eq "FullyDecrypted")
        $items += [PSCustomObject]@{
            Id="BL_STORE"; Name="BitLocker — Ổ $($script:StoreLetter):"
            Status=if($ok2){"✔ Tắt"}else{"✘ Đang bật ($s2)"}
            OK=$ok2; CanFix=$true
            Detail=if($ok2){"An toàn"}else{"WinPE không đọc được job.json nếu BitLocker bật"}
        }
    } catch { $items += [PSCustomObject]@{Id="BL_STORE";Name="BitLocker — Ổ $($script:StoreLetter):";Status="? Không đọc được";OK=$false;CanFix=$false;Detail=""} }

    # 3. Fast Startup (Hibernate)
    try {
        $hibFile = Test-Path "C:\hiberfil.sys"
        $hibReg  = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" -EA SilentlyContinue).HiberbootEnabled
        $fastOn  = ($hibFile -and $hibReg -eq 1)
        $items += [PSCustomObject]@{
            Id="FAST_STARTUP"; Name="Fast Startup (Khởi động nhanh)"
            Status=if(-not $fastOn){"✔ Tắt"}else{"✘ Đang bật — cần tắt"}
            OK=(-not $fastOn); CanFix=$true
            Detail=if(-not $fastOn){"An toàn"}else{"Fast Startup khiến NTFS bị lock — WinPE không thể truy cập"}
        }
    } catch { $items += [PSCustomObject]@{Id="FAST_STARTUP";Name="Fast Startup";Status="? Không đọc được";OK=$false;CanFix=$false;Detail=""} }

    # 4. PowerShell Execution Policy
    try {
        $policy = Get-ExecutionPolicy -Scope LocalMachine
        $policyOk = $policy -in @("RemoteSigned","Unrestricted","Bypass")
        $items += [PSCustomObject]@{
            Id="EXECPOLICY"; Name="PowerShell Execution Policy"
            Status=if($policyOk){"✔ $policy"}else{"✘ $policy — cần RemoteSigned"}
            OK=$policyOk; CanFix=$true
            Detail=if($policyOk){"Cho phép chạy script"}else{"Script sẽ bị chặn khi khởi động tự động"}
        }
    } catch { $items += [PSCustomObject]@{Id="EXECPOLICY";Name="Execution Policy";Status="? Không đọc được";OK=$false;CanFix=$false;Detail=""} }

    # 5. Windows Defender — Exclusion cho thư mục Reimage
    try {
        $prefs = Get-MpPreference -EA SilentlyContinue
        $excl  = $prefs.ExclusionPath
        $base  = Get-Base
        $hasExcl = ($excl | Where-Object { $_ -like "*$($script:ReimageDir)*" }) -ne $null
        $items += [PSCustomObject]@{
            Id="DEFENDER"; Name="Windows Defender — Exclusion"
            Status=if($hasExcl){"✔ Đã thêm exclusion"}else{"⚠ Chưa có exclusion"}
            OK=$hasExcl; CanFix=$true
            Detail=if($hasExcl){"Defender không chặn engine.ps1"}else{"Defender có thể chặn hoặc xóa engine.ps1 trong WinPE"}
        }
    } catch { $items += [PSCustomObject]@{Id="DEFENDER";Name="Windows Defender Exclusion";Status="? Không đọc được";OK=$false;CanFix=$false;Detail=""} }

    # 6. Smart App Control (Windows 11)
    try {
        $sac = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy" -EA SilentlyContinue).VerifiedAndReputablePolicyState
        # 0=Off, 1=Eval, 2=On
        $sacStr = switch($sac) { 0{"✔ Tắt"}; 1{"⚠ Chế độ đánh giá"}; 2{"⚠ Đang bật"}; default{"✔ Không áp dụng"} }
        $sacOk  = ($sac -eq $null -or $sac -eq 0)
        $items += [PSCustomObject]@{
            Id="SAC"; Name="Smart App Control (Win 11)"
            Status=$sacStr; OK=$sacOk; CanFix=$false
            Detail=if($sacOk){"Không ảnh hưởng"}else{"SAC có thể chặn script — tắt trong Settings > Privacy > Windows Security"}
        }
    } catch { $items += [PSCustomObject]@{Id="SAC";Name="Smart App Control";Status="✔ Không áp dụng";OK=$true;CanFix=$false;Detail=""} }

    # 7. Secure Boot
    try {
        $sb = Confirm-SecureBootUEFI -EA SilentlyContinue
        $sbOk = ($sb -eq $false -or $sb -eq $null)
        $items += [PSCustomObject]@{
            Id="SECUREBOOT"; Name="Secure Boot"
            Status=if($sbOk){"✔ Tắt hoặc không áp dụng"}else{"⚠ Đang bật"}
            OK=$sbOk; CanFix=$false
            Detail=if($sbOk){"An toàn"}else{"WinPE ADK thường được ký, nên thường không bị chặn. Nếu lỗi boot, tắt Secure Boot trong BIOS/UEFI."}
        }
    } catch { $items += [PSCustomObject]@{Id="SECUREBOOT";Name="Secure Boot";Status="✔ Không xác định";OK=$true;CanFix=$false;Detail=""} }

    return $items
}

function Fix-SecurityItem($id) {
    switch ($id) {
        "BL_C" {
            $bl = Get-BitLockerVolume -MountPoint "C:" -EA SilentlyContinue
            if ($bl -and $bl.VolumeStatus -ne "FullyDecrypted") {
                if ($bl.VolumeStatus -eq "FullyEncrypted") {
                    # Tam ngung BitLocker (phuc hoi sau reboot)
                    Suspend-BitLocker -MountPoint "C:" -RebootCount 1
                    Log "BitLocker C: tam ngung (1 reboot)"
                    return "✔ Đã tạm ngừng BitLocker C: (tự bật lại sau 1 lần reboot tiếp theo)"
                } else {
                    return "⚠ BitLocker đang ở trạng thái chuyển tiếp — chờ hoàn tất rồi thử lại"
                }
            }
            return "✔ BitLocker C: đã tắt"
        }
        "BL_STORE" {
            $bl2 = Get-BitLockerVolume -MountPoint "$($script:StoreLetter):" -EA SilentlyContinue
            if ($bl2 -and $bl2.VolumeStatus -ne "FullyDecrypted") {
                if ($bl2.VolumeStatus -eq "FullyEncrypted") {
                    Suspend-BitLocker -MountPoint "$($script:StoreLetter):" -RebootCount 1
                    Log "BitLocker $($script:StoreLetter): tam ngung"
                    return "✔ Đã tạm ngừng BitLocker $($script:StoreLetter):"
                } else {
                    return "⚠ Đang chuyển tiếp — chờ hoàn tất"
                }
            }
            return "✔ BitLocker $($script:StoreLetter): đã tắt"
        }
        "FAST_STARTUP" {
            &powercfg /h off 2>$null
            Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" -Name HiberbootEnabled -Value 0 -ErrorAction SilentlyContinue
            Log "Fast Startup tat"
            return "✔ Đã tắt Fast Startup"
        }
        "EXECPOLICY" {
            Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine -Force
            Log "ExecutionPolicy = RemoteSigned"
            return "✔ Đã đặt Execution Policy = RemoteSigned"
        }
        "DEFENDER" {
            $base = Get-Base
            Add-MpPreference -ExclusionPath $base -EA SilentlyContinue
            # Them ca thu muc ProgramData
            Add-MpPreference -ExclusionPath "$env:ProgramData\$($script:AppName)" -EA SilentlyContinue
            Log "Defender exclusion: $base"
            return "✔ Đã thêm exclusion cho $base"
        }
        default { return "Không hỗ trợ tự động" }
    }
}

# ==============================================================================
#  XAML
# ==============================================================================
[xml]$XAML = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="LilbowRecovery — Sao lưu &amp; Khôi phục Windows"
    Height="640" Width="940"
    MinHeight="580" MinWidth="840"
    WindowStartupLocation="CenterScreen"
    Background="#0D1117" FontFamily="Segoe UI" ResizeMode="CanResize">
  <Window.Resources>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="#161B22"/>
      <Setter Property="CornerRadius" Value="10"/>
      <Setter Property="Padding" Value="16"/>
      <Setter Property="Margin" Value="6"/>
      <Setter Property="Effect">
        <Setter.Value><DropShadowEffect BlurRadius="12" ShadowDepth="2" Opacity="0.35" Color="#000000"/></Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="NavBtn" TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#8B949E"/>
      <Setter Property="FontSize" Value="13.5"/>
      <Setter Property="Height" Value="44"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="8" Margin="8,2">
              <ContentPresenter HorizontalAlignment="Left" VerticalAlignment="Center" Margin="16,0,0,0"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#21262D"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="ActionBtn" TargetType="Button">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Height" Value="50"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="10">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Opacity" Value="0.82"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="Bd" Property="Opacity" Value="0.65"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Bd" Property="Opacity" Value="0.3"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="SmBtn" TargetType="Button" BasedOn="{StaticResource ActionBtn}">
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Height" Value="32"/>
      <Setter Property="Padding" Value="14,0"/>
    </Style>
    <Style x:Key="DgHeader" TargetType="DataGridColumnHeader">
      <Setter Property="Background" Value="#161B22"/>
      <Setter Property="Foreground" Value="#8B949E"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Padding" Value="8,0"/>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="210"/>
      <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>

    <!-- SIDEBAR -->
    <Border Grid.Column="0" Background="#0D1117" BorderBrush="#21262D" BorderThickness="0,0,1,0">
      <DockPanel>
        <StackPanel DockPanel.Dock="Top" Margin="20,22,20,16">
          <TextBlock Text="🛡 LilbowRecovery" FontSize="17" FontWeight="Bold" Foreground="#E6EDF3"/>
          <TextBlock Text="Sao lưu &amp; Khôi phục Windows" FontSize="11" Foreground="#8B949E" Margin="0,4,0,0"/>
        </StackPanel>
        <StackPanel DockPanel.Dock="Top">
          <Button x:Name="NavDashboard" Style="{StaticResource NavBtn}" Content="📊  Dashboard"/>
          <Button x:Name="NavSecurity"  Style="{StaticResource NavBtn}" Content="🔐  Bảo mật"/>
          <Button x:Name="NavBackup"    Style="{StaticResource NavBtn}" Content="☁  Sao lưu (Backup)"/>
          <Button x:Name="NavRestore"   Style="{StaticResource NavBtn}" Content="🔄  Khôi phục (Restore)"/>
          <Button x:Name="NavImages"    Style="{StaticResource NavBtn}" Content="🗃  Quản lý ảnh"/>
          <Button x:Name="NavSettings"  Style="{StaticResource NavBtn}" Content="⚙  Cài đặt &amp; WinPE"/>
        </StackPanel>
        <TextBlock DockPanel.Dock="Bottom" Text="LilbowRecovery v1.0" Foreground="#484F58"
                   FontSize="10" HorizontalAlignment="Center" Margin="0,0,0,14"/>
      </DockPanel>
    </Border>

    <!-- MAIN -->
    <Grid Grid.Column="1">
      <Grid.RowDefinitions>
        <RowDefinition Height="*"/>
        <RowDefinition Height="34"/>
      </Grid.RowDefinitions>

      <ScrollViewer Grid.Row="0" VerticalScrollBarVisibility="Auto">
        <Grid>

          <!-- ═══════════ DASHBOARD ═══════════ -->
          <StackPanel x:Name="PageDashboard" Margin="22,18,22,18">
            <TextBlock Text="Dashboard" FontSize="21" FontWeight="Bold" Foreground="#E6EDF3"/>
            <TextBlock x:Name="TxtMachine" FontSize="12" Foreground="#8B949E" Margin="0,4,0,16"/>

            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition/></Grid.ColumnDefinitions>
              <Grid.RowDefinitions><RowDefinition/><RowDefinition/></Grid.RowDefinitions>

              <Border Grid.Row="0" Grid.Column="0" Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock x:Name="CWinPEIcon" Text="⬛" FontSize="26" Margin="0,0,0,6"/>
                  <TextBlock Text="WinPE" FontSize="13" FontWeight="SemiBold" Foreground="#E6EDF3"/>
                  <TextBlock x:Name="CWinPETxt" FontSize="12" Foreground="#8B949E" Margin="0,4,0,0"/>
                  <Button x:Name="BtnGoSetup" Content="Cài đặt ngay →"
                          Style="{StaticResource SmBtn}" Background="#1F6FEB" Margin="0,10,0,0"
                          Visibility="Collapsed" HorizontalAlignment="Left"/>
                </StackPanel>
              </Border>
              <Border Grid.Row="0" Grid.Column="1" Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock x:Name="CStoreIcon" Text="💾" FontSize="26" Margin="0,0,0,6"/>
                  <TextBlock Text="Ổ lưu ảnh" FontSize="13" FontWeight="SemiBold" Foreground="#E6EDF3"/>
                  <TextBlock x:Name="CStoreTxt" FontSize="12" Foreground="#8B949E" Margin="0,4,0,0"/>
                  <TextBlock x:Name="CStoreSub" FontSize="11" Foreground="#484F58" Margin="0,2,0,0"/>
                </StackPanel>
              </Border>
              <Border Grid.Row="1" Grid.Column="0" Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock x:Name="CSecIcon" Text="🔐" FontSize="26" Margin="0,0,0,6"/>
                  <TextBlock Text="Bảo mật" FontSize="13" FontWeight="SemiBold" Foreground="#E6EDF3"/>
                  <TextBlock x:Name="CSecTxt" FontSize="12" Foreground="#8B949E" Margin="0,4,0,0"/>
                  <Button x:Name="BtnGoSecurity" Content="Kiểm tra ngay →"
                          Style="{StaticResource SmBtn}" Background="#9B4DCA" Margin="0,10,0,0"
                          HorizontalAlignment="Left"/>
                </StackPanel>
              </Border>
              <Border Grid.Row="1" Grid.Column="1" Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock x:Name="CPowerIcon" Text="🔌" FontSize="26" Margin="0,0,0,6"/>
                  <TextBlock Text="Nguồn điện" FontSize="13" FontWeight="SemiBold" Foreground="#E6EDF3"/>
                  <TextBlock x:Name="CPowerTxt" FontSize="12" Foreground="#8B949E" Margin="0,4,0,0"/>
                </StackPanel>
              </Border>
            </Grid>

            <Border x:Name="CardResult" Style="{StaticResource Card}" Margin="6,10,6,0" Visibility="Collapsed">
              <StackPanel>
                <TextBlock Text="Kết quả lần chạy gần nhất" FontSize="12" FontWeight="SemiBold"
                           Foreground="#E6EDF3" Margin="0,0,0,6"/>
                <TextBlock x:Name="TxtLastResult" FontSize="12" Foreground="#8B949E" TextWrapping="Wrap"/>
              </StackPanel>
            </Border>

            <Grid Margin="6,18,6,0">
              <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="12"/><ColumnDefinition/></Grid.ColumnDefinitions>
              <Button x:Name="BtnBackup"  Grid.Column="0" Content="☁  SAO LƯU" Style="{StaticResource ActionBtn}" Background="#1F6FEB"/>
              <Button x:Name="BtnRestore" Grid.Column="2" Content="🔄  KHÔI PHỤC" Style="{StaticResource ActionBtn}" Background="#0D9373"/>
            </Grid>
          </StackPanel>

          <!-- ═══════════ BẢO MẬT ═══════════ -->
          <StackPanel x:Name="PageSecurity" Visibility="Collapsed" Margin="22,18,22,18">
            <DockPanel Margin="0,0,0,4">
              <TextBlock Text="🔐 Bảo mật" FontSize="21" FontWeight="Bold"
                         Foreground="#E6EDF3" DockPanel.Dock="Left"/>
              <Button x:Name="BtnFixAll" Content="✨ Tắt tất cả ngay"
                      Style="{StaticResource SmBtn}" Background="#9B4DCA"
                      HorizontalAlignment="Right" VerticalAlignment="Center"/>
            </DockPanel>
            <TextBlock Text="Kiểm tra và tắt các tính năng bảo mật có thể gây lỗi khi WinPE khởi động."
                       FontSize="12" Foreground="#8B949E" Margin="0,4,0,16" TextWrapping="Wrap"/>

            <!-- Security items list -->
            <ItemsControl x:Name="SecList">
              <ItemsControl.ItemTemplate>
                <DataTemplate>
                  <Border Style="{StaticResource Card}" Margin="0,4,0,0">
                    <Grid>
                      <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="32"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                      </Grid.ColumnDefinitions>
                      <TextBlock Grid.Column="0" Text="{Binding Icon}" FontSize="20" VerticalAlignment="Center"/>
                      <StackPanel Grid.Column="1" Margin="12,0,12,0" VerticalAlignment="Center">
                        <TextBlock Text="{Binding Name}" FontSize="13" FontWeight="SemiBold" Foreground="#E6EDF3"/>
                        <TextBlock Text="{Binding Status}" FontSize="12" Margin="0,2,0,0"
                                   Foreground="{Binding StatusColor}"/>
                        <TextBlock Text="{Binding Detail}" FontSize="11" Foreground="#484F58"
                                   Margin="0,2,0,0" TextWrapping="Wrap"/>
                      </StackPanel>
                      <Button Grid.Column="2" Content="{Binding BtnLabel}"
                              Style="{StaticResource SmBtn}" Background="{Binding BtnColor}"
                              IsEnabled="{Binding CanFix}" VerticalAlignment="Center"
                              Tag="{Binding Id}" x:Name="BtnFixOne"/>
                    </Grid>
                  </Border>
                </DataTemplate>
              </ItemsControl.ItemTemplate>
            </ItemsControl>

            <TextBlock Text="💡 Lưu ý: BitLocker sẽ được TẠM NGỪNG (suspend) cho 1 lần reboot tiếp theo,&#10;không phải giải mã hoàn toàn. Sau khi WinPE xong và về Windows, BitLocker tự bật lại."
                       FontSize="11" Foreground="#8B949E" Margin="6,14,6,0" TextWrapping="Wrap"/>
          </StackPanel>

          <!-- ═══════════ BACKUP ═══════════ -->
          <StackPanel x:Name="PageBackup" Visibility="Collapsed" Margin="22,18,22,18">
            <TextBlock Text="☁ Sao lưu (Backup)" FontSize="21" FontWeight="Bold" Foreground="#E6EDF3"/>
            <TextBlock Text="Chọn phân vùng nguồn cần sao lưu." FontSize="12" Foreground="#8B949E" Margin="0,4,0,16"/>
            <Border Style="{StaticResource Card}" Margin="0,0,0,10">
              <StackPanel>
                <TextBlock Text="Phân vùng nguồn" FontSize="13" FontWeight="SemiBold" Foreground="#E6EDF3" Margin="0,0,0,10"/>
                <DataGrid x:Name="GridBkParts" AutoGenerateColumns="False"
                          Background="Transparent" RowBackground="#0D1117" AlternatingRowBackground="#1C2128"
                          BorderBrush="#21262D" BorderThickness="1" RowHeight="36" HeadersVisibility="Column"
                          SelectionMode="Single" IsReadOnly="True" ColumnHeaderHeight="30"
                          GridLinesVisibility="Horizontal" HorizontalGridLinesBrush="#21262D"
                          Foreground="#E6EDF3" FontSize="12" ColumnHeaderStyle="{StaticResource DgHeader}">
                  <DataGrid.Columns>
                    <DataGridTextColumn Header="Ổ"          Binding="{Binding Letter}"     Width="55"/>
                    <DataGridTextColumn Header="Nhãn"        Binding="{Binding Label}"      Width="130"/>
                    <DataGridTextColumn Header="FS"          Binding="{Binding FileSystem}" Width="55"/>
                    <DataGridTextColumn Header="Kích thước"  Binding="{Binding SizeGB}"     Width="90"/>
                    <DataGridTextColumn Header="Trống"       Binding="{Binding FreeGB}"     Width="80"/>
                    <DataGridTextColumn Header="Disk"        Binding="{Binding DiskNum}"    Width="60"/>
                    <DataGridTextColumn Header="Ghi chú"     Binding="{Binding Note}"       Width="*"/>
                  </DataGrid.Columns>
                </DataGrid>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}" Margin="0,0,0,10">
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="16"/><ColumnDefinition/></Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0">
                  <TextBlock Text="Tên file ảnh" FontSize="12" Foreground="#8B949E" Margin="0,0,0,6"/>
                  <TextBox x:Name="TxtBkName" Background="#0D1117" Foreground="#E6EDF3"
                           BorderBrush="#30363D" BorderThickness="1" Padding="8,6" FontSize="13" CaretBrush="White"/>
                </StackPanel>
                <StackPanel Grid.Column="2">
                  <TextBlock Text="Mức nén" FontSize="12" Foreground="#8B949E" Margin="0,0,0,6"/>
                  <ComboBox x:Name="CmbCompress" Background="#0D1117" Foreground="#E6EDF3"
                            BorderBrush="#30363D" FontSize="13" Padding="8,6">
                    <ComboBoxItem Content="Nhanh — file lớn hơn, backup nhanh (khuyến nghị)" IsSelected="True" Tag="fast"/>
                    <ComboBoxItem Content="Tối đa (LZX) — file nhỏ hơn ~20%, backup chậm hơn" Tag="maximum"/>
                    <ComboBoxItem Content="Recovery (LZMS) — file nhỏ nhất ~35%, backup rất chậm" Tag="recovery"/>
                  </ComboBox>
                </StackPanel>
              </Grid>
            </Border>
            <Button x:Name="BtnStartBackup" Content="▶  BẮT ĐẦU SAO LƯU" Style="{StaticResource ActionBtn}" Background="#1F6FEB"/>
          </StackPanel>

          <!-- ═══════════ RESTORE ═══════════ -->
          <StackPanel x:Name="PageRestore" Visibility="Collapsed" Margin="22,18,22,18">
            <TextBlock Text="🔄 Khôi phục (Restore)" FontSize="21" FontWeight="Bold" Foreground="#E6EDF3"/>
            <TextBlock Text="Chọn ảnh và phân vùng đích để khôi phục." FontSize="12" Foreground="#8B949E" Margin="0,4,0,16"/>
            <Border Style="{StaticResource Card}" Margin="0,0,0,10">
              <StackPanel>
                <TextBlock Text="Chọn ảnh backup" FontSize="13" FontWeight="SemiBold" Foreground="#E6EDF3" Margin="0,0,0,10"/>
                <DataGrid x:Name="GridImgList" AutoGenerateColumns="False"
                          Background="Transparent" RowBackground="#0D1117" AlternatingRowBackground="#1C2128"
                          BorderBrush="#21262D" BorderThickness="1" RowHeight="36" HeadersVisibility="Column"
                          SelectionMode="Single" IsReadOnly="True" ColumnHeaderHeight="30"
                          GridLinesVisibility="Horizontal" HorizontalGridLinesBrush="#21262D"
                          Foreground="#E6EDF3" FontSize="12" ColumnHeaderStyle="{StaticResource DgHeader}">
                  <DataGrid.Columns>
                    <DataGridTextColumn Header="Tên file"     Binding="{Binding Name}"       Width="*"/>
                    <DataGridTextColumn Header="Kích thước"   Binding="{Binding SizeStr}"    Width="90"/>
                    <DataGridTextColumn Header="Ngày tạo"     Binding="{Binding DateStr}"    Width="130"/>
                    <DataGridTextColumn Header="Hash"         Binding="{Binding HashStatus}" Width="75"/>
                  </DataGrid.Columns>
                </DataGrid>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}" Margin="0,0,0,10">
              <StackPanel>
                <TextBlock Text="Phân vùng đích (sẽ bị FORMAT)" FontSize="13" FontWeight="SemiBold" Foreground="#FF6B6B" Margin="0,0,0,10"/>
                <DataGrid x:Name="GridRstParts" AutoGenerateColumns="False"
                          Background="Transparent" RowBackground="#0D1117" AlternatingRowBackground="#1C2128"
                          BorderBrush="#21262D" BorderThickness="1" RowHeight="36" HeadersVisibility="Column"
                          SelectionMode="Single" IsReadOnly="True" ColumnHeaderHeight="30"
                          GridLinesVisibility="Horizontal" HorizontalGridLinesBrush="#21262D"
                          Foreground="#E6EDF3" FontSize="12" ColumnHeaderStyle="{StaticResource DgHeader}">
                  <DataGrid.Columns>
                    <DataGridTextColumn Header="Ổ"          Binding="{Binding Letter}"  Width="55"/>
                    <DataGridTextColumn Header="Nhãn"        Binding="{Binding Label}"   Width="130"/>
                    <DataGridTextColumn Header="Kích thước"  Binding="{Binding SizeGB}"  Width="90"/>
                    <DataGridTextColumn Header="Disk"        Binding="{Binding DiskNum}" Width="60"/>
                    <DataGridTextColumn Header="Ghi chú"     Binding="{Binding Note}"    Width="*"/>
                  </DataGrid.Columns>
                </DataGrid>
              </StackPanel>
            </Border>
            <Button x:Name="BtnStartRestore" Content="🔄  BẮT ĐẦU KHÔI PHỤC" Style="{StaticResource ActionBtn}" Background="#0D9373"/>
          </StackPanel>

          <!-- ═══════════ IMAGES ═══════════ -->
          <StackPanel x:Name="PageImages" Visibility="Collapsed" Margin="22,18,22,18">
            <DockPanel Margin="0,0,0,14">
              <TextBlock Text="🗃 Quản lý ảnh" FontSize="21" FontWeight="Bold" Foreground="#E6EDF3"/>
              <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                <Button x:Name="BtnImport" Content="+ Nhập ảnh" Style="{StaticResource SmBtn}" Background="#1F6FEB" Margin="0,0,8,0"/>
                <Button x:Name="BtnDelete" Content="🗑 Xóa" Style="{StaticResource SmBtn}" Background="#B22222"/>
              </StackPanel>
            </DockPanel>
            <Border Style="{StaticResource Card}">
              <DataGrid x:Name="GridMgImg" AutoGenerateColumns="False"
                        Background="Transparent" RowBackground="#0D1117" AlternatingRowBackground="#1C2128"
                        BorderThickness="0" RowHeight="38" HeadersVisibility="Column"
                        SelectionMode="Single" IsReadOnly="True" ColumnHeaderHeight="30"
                        GridLinesVisibility="Horizontal" HorizontalGridLinesBrush="#21262D"
                        Foreground="#E6EDF3" FontSize="12" MinHeight="180"
                        ColumnHeaderStyle="{StaticResource DgHeader}">
                <DataGrid.Columns>
                  <DataGridTextColumn Header="Tên file"   Binding="{Binding Name}"       Width="*"/>
                  <DataGridTextColumn Header="Kích thước" Binding="{Binding SizeStr}"    Width="90"/>
                  <DataGridTextColumn Header="Ngày tạo"   Binding="{Binding DateStr}"    Width="130"/>
                  <DataGridTextColumn Header="Hash"       Binding="{Binding HashStatus}" Width="75"/>
                </DataGrid.Columns>
              </DataGrid>
            </Border>
          </StackPanel>

          <!-- ═══════════ SETTINGS ═══════════ -->
          <StackPanel x:Name="PageSettings" Visibility="Collapsed" Margin="22,18,22,18">
            <TextBlock Text="⚙ Cài đặt &amp; WinPE" FontSize="21" FontWeight="Bold" Foreground="#E6EDF3" Margin="0,0,0,16"/>
            <Border Style="{StaticResource Card}" Margin="0,0,0,10">
              <StackPanel>
                <TextBlock Text="Ổ lưu ảnh" FontSize="13" FontWeight="SemiBold" Foreground="#E6EDF3" Margin="0,0,0,10"/>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <ComboBox x:Name="CmbDrive" Background="#0D1117" Foreground="#E6EDF3"
                            BorderBrush="#30363D" FontSize="13" Padding="8,6"/>
                  <Button x:Name="BtnApplyDrive" Grid.Column="1" Content="Áp dụng"
                          Style="{StaticResource SmBtn}" Background="#1F6FEB" Margin="8,0,0,0"/>
                </Grid>
                <TextBlock Text="Chọn ổ chứa LilbowRecovery\ (NTFS, không phải ổ Windows)."
                           FontSize="11" Foreground="#8B949E" Margin="0,8,0,0"/>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}" Margin="0,0,0,10">
              <StackPanel>
                <TextBlock Text="WinPE" FontSize="13" FontWeight="SemiBold" Foreground="#E6EDF3" Margin="0,0,0,10"/>
                <StackPanel Orientation="Horizontal">
                  <Button x:Name="BtnInstWinPE" Content="🔧 Cài đặt / Cập nhật WinPE"
                          Style="{StaticResource SmBtn}" Background="#1F6FEB" Margin="0,0,8,0"/>
                  <Button x:Name="BtnUninstWinPE" Content="🗑 Gỡ WinPE"
                          Style="{StaticResource SmBtn}" Background="#484F58"/>
                </StackPanel>
                <TextBlock x:Name="TxtWinPESt" FontSize="12" Foreground="#8B949E" Margin="0,10,0,0"/>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Text="Thông tin hệ thống" FontSize="13" FontWeight="SemiBold" Foreground="#E6EDF3" Margin="0,0,0,8"/>
                <TextBlock x:Name="TxtSysInfo" FontSize="12" Foreground="#8B949E" TextWrapping="Wrap"/>
                <Button x:Name="BtnOpenLog" Content="📄 Mở thư mục log" Style="{StaticResource SmBtn}"
                        Background="#484F58" HorizontalAlignment="Left" Margin="0,12,0,0"/>
              </StackPanel>
            </Border>
          </StackPanel>

        </Grid>
      </ScrollViewer>

      <!-- STATUS BAR -->
      <Border Grid.Row="1" Background="#161B22" BorderBrush="#21262D" BorderThickness="0,1,0,0">
        <DockPanel Margin="16,0">
          <TextBlock x:Name="TxtStatus" VerticalAlignment="Center" Foreground="#8B949E" FontSize="11"/>
          <ProgressBar x:Name="PrgBar" DockPanel.Dock="Right" Width="110" Height="5"
                       VerticalAlignment="Center" Background="#21262D" Foreground="#9B4DCA"
                       Visibility="Collapsed" IsIndeterminate="True"/>
        </DockPanel>
      </Border>
    </Grid>
  </Grid>
</Window>
'@

# ── Load Window ───────────────────────────────────────────────────────────────
$reader = New-Object System.Xml.XmlNodeReader $XAML
$Win    = [Windows.Markup.XamlReader]::Load($reader)
function C($n) { $Win.FindName($n) }

# Nav
$NavDashboard = C "NavDashboard"; $NavSecurity = C "NavSecurity"
$NavBackup    = C "NavBackup";    $NavRestore  = C "NavRestore"
$NavImages    = C "NavImages";    $NavSettings = C "NavSettings"

# Pages
$PgDash = C "PageDashboard"; $PgSec  = C "PageSecurity"
$PgBk   = C "PageBackup";   $PgRst  = C "PageRestore"
$PgImg  = C "PageImages";   $PgSet  = C "PageSettings"

# Dashboard controls
$CWinPEIcon = C "CWinPEIcon"; $CWinPETxt = C "CWinPETxt"; $BtnGoSetup = C "BtnGoSetup"
$CStoreIcon = C "CStoreIcon"; $CStoreTxt = C "CStoreTxt"; $CStoreSub  = C "CStoreSub"
$CSecIcon   = C "CSecIcon";   $CSecTxt   = C "CSecTxt";   $BtnGoSecurity = C "BtnGoSecurity"
$CPowerIcon = C "CPowerIcon"; $CPowerTxt = C "CPowerTxt"
$CardResult = C "CardResult"; $TxtLastResult = C "TxtLastResult"
$BtnBackup  = C "BtnBackup";  $BtnRestore = C "BtnRestore"

# Security
$SecList  = C "SecList"; $BtnFixAll = C "BtnFixAll"

# Backup / Restore
$GridBkParts  = C "GridBkParts";  $TxtBkName = C "TxtBkName"; $CmbCompress = C "CmbCompress"
$BtnStartBk   = C "BtnStartBackup"
$GridImgList  = C "GridImgList";  $GridRstParts = C "GridRstParts"
$BtnStartRst  = C "BtnStartRestore"

# Images
$GridMgImg = C "GridMgImg"; $BtnImport = C "BtnImport"; $BtnDelete = C "BtnDelete"

# Settings
$CmbDrive = C "CmbDrive"; $BtnApplyDrive = C "BtnApplyDrive"
$BtnInstWinPE = C "BtnInstWinPE"; $BtnUninstWinPE = C "BtnUninstWinPE"
$TxtWinPESt = C "TxtWinPESt"; $TxtSysInfo = C "TxtSysInfo"; $BtnOpenLog = C "BtnOpenLog"
$TxtStatus = C "TxtStatus"; $PrgBar = C "PrgBar"

# ── Helpers UI ────────────────────────────────────────────────────────────────
function Set-Status($m, $spin=$false) {
    $TxtStatus.Text = $m; $PrgBar.Visibility = if($spin){"Visible"}else{"Collapsed"}
    $Win.Dispatcher.Invoke([Action]{},"Render")
}
function Show-Page($pg) {
    foreach ($p in @($PgDash,$PgSec,$PgBk,$PgRst,$PgImg,$PgSet)) { $p.Visibility="Collapsed" }
    $pg.Visibility="Visible"
}
function Hl-Nav($b) {
    foreach ($n in @($NavDashboard,$NavSecurity,$NavBackup,$NavRestore,$NavImages,$NavSettings)) {
        $n.Foreground="#8B949E"; $n.Background="Transparent"
    }
    $b.Foreground="#E6EDF3"; $b.Background="#21262D"
}

# ── Dashboard refresh ─────────────────────────────────────────────────────────
function Update-Dashboard {
    Set-Status "Đang kiểm tra hệ thống..." $true
    $TxtMachine.Text = Ctrl-text "Máy: $env:COMPUTERNAME  •  $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

    # WinPE
    $rdy = Test-WinPEReady
    $CWinPEIcon.Text=$if($rdy){"✅"}{"❌"}
    $CWinPETxt.Text= if($rdy){"Đã cài đặt"}{"Chưa cài đặt"}
    $CWinPETxt.Foreground=if($rdy){"#3FB950"}{"#FF6B6B"}
    $BtnGoSetup.Visibility=if($rdy){"Collapsed"}{"Visible"}

    # Storage
    try {
        $v = Get-Volume -DriveLetter $script:StoreLetter -EA SilentlyContinue
        if ($v) {
            $CStoreTxt.Text="$($script:StoreLetter): — $(Format-GB $v.SizeRemaining) trống"
            $CStoreTxt.Foreground=if($v.SizeRemaining -lt 20GB){"#F0883E"}else{"#3FB950"}
            $CStoreSub.Text="Tổng: $(Format-GB $v.Size) • $((Get-ChildItem (Get-ImgDir) -Filter *.wim -EA SilentlyContinue).Count) ảnh"
        } else { $CStoreTxt.Text="Không tìm thấy ổ $($script:StoreLetter):"; $CStoreTxt.Foreground="#FF6B6B" }
    } catch { $CStoreTxt.Text="Lỗi đọc ổ"; $CStoreTxt.Foreground="#FF6B6B" }

    # Security quick check
    try {
        $blC  = (Get-BitLockerVolume -MountPoint "C:" -EA SilentlyContinue).VolumeStatus
        $blS  = (Get-BitLockerVolume -MountPoint "$($script:StoreLetter):" -EA SilentlyContinue).VolumeStatus
        $hib  = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" -EA SilentlyContinue).HiberbootEnabled
        $blOk = ($blC -in @("FullyDecrypted",$null)) -and ($blS -in @("FullyDecrypted",$null))
        $hibOk= ($hib -ne 1)
        $allOk= $blOk -and $hibOk
        $CSecIcon.Text=if($allOk){"🛡"}else{"⚠"}
        $CSecTxt.Text=if($allOk){"Tất cả ổn"}else{
            $issues = @(); if(-not $blOk){"BitLocker bật"} | ForEach-Object { $issues+=$_ }
            if(-not $hibOk){$issues+="Fast Startup bật"}
            $issues -join " • "
        }
        $CSecTxt.Foreground=if($allOk){"#3FB950"}else{"#F0883E"}
    } catch { $CSecTxt.Text="Chưa kiểm tra"; $CSecTxt.Foreground="#8B949E" }

    # Power
    try {
        $bat=$Win.Dispatcher.Invoke([Func[object]]{ Get-WmiObject Win32_Battery -EA SilentlyContinue })
        if ($bat) {
            $CPowerIcon.Text=if($bat.BatteryStatus -eq 1){"🔋"}else{"🔌"}
            $CPowerTxt.Text=if($bat.BatteryStatus -eq 1){"Pin: $($bat.EstimatedChargeRemaining)%"}else{"Cắm điện (AC)"}
            $CPowerTxt.Foreground=if($bat.BatteryStatus -eq 1 -and $bat.EstimatedChargeRemaining -lt 30){"#FF6B6B"}else{"#3FB950"}
        } else { $CPowerIcon.Text="🖥"; $CPowerTxt.Text="Máy để bàn"; $CPowerTxt.Foreground="#3FB950" }
    } catch { $CPowerTxt.Text="Không xác định" }

    # Last result
    $rf = "$(Get-Base)\result.json"
    if (Test-Path $rf) {
        try {
            $r = Get-Content $rf -Raw -Encoding UTF8 | ConvertFrom-Json
            $em = @{XONG="✅";DUNG="⚠️";LOI="❌"}[$r.status]
            $TxtLastResult.Text = "$em $($r.action.ToUpper()) — $($r.status): $($r.message)`n$($r.time)"
            $TxtLastResult.Foreground = @{XONG="#3FB950";DUNG="#F0883E";LOI="#FF6B6B"}[$r.status]
            $CardResult.Visibility="Visible"
        } catch {}
    }

    $BtnBackup.IsEnabled  = $rdy
    $BtnRestore.IsEnabled = $rdy
    Set-Status "Sẵn sàng  •  Ổ lưu ảnh: $($script:StoreLetter):  •  $((Get-ChildItem (Get-ImgDir) -Filter *.wim -EA SilentlyContinue).Count) ảnh"
}
function Ctrl-text($t) { $t }

# ── Security page refresh ─────────────────────────────────────────────────────
function Update-Security {
    Set-Status "Đang kiểm tra bảo mật..." $true
    $items = Get-SecurityStatus | ForEach-Object {
        [PSCustomObject]@{
            Id          = $_.Id
            Name        = $_.Name
            Status      = $_.Status
            StatusColor = if($_.OK){"#3FB950"}elseif($_.Status -like "*⚠*"){"#F0883E"}else{"#FF6B6B"}
            Detail      = $_.Detail
            BtnLabel    = if($_.CanFix){"Tắt / Sửa"}else{"Thủ công"}
            BtnColor    = if($_.CanFix){"#9B4DCA"}else{"#484F58"}
            CanFix      = $_.CanFix
            Icon        = if($_.OK){"✅"}elseif($_.Status -like "*⚠*"){"⚠️"}else{"❌"}
        }
    }
    $SecList.ItemsSource = $items
    $okCount = ($items | Where-Object { $_.StatusColor -eq "#3FB950" }).Count
    Set-Status "Bảo mật: $okCount/$($items.Count) mục ổn"
}

# Wire up per-item fix button via event bubbling
$SecList.Add_MouseUp({
    param($s,$e)
    $btn = $e.OriginalSource
    # Tim Button cha
    $el = $e.OriginalSource
    while ($el -ne $null -and $el -isnot [System.Windows.Controls.Button]) {
        $el = [System.Windows.Media.VisualTreeHelper]::GetParent($el)
    }
    if ($el -ne $null -and $el.Tag) {
        $id = $el.Tag
        Set-Status "Đang xử lý $id..." $true
        try {
            $msg = Fix-SecurityItem $id
            [Windows.MessageBox]::Show($msg,"Kết quả","OK","Information") | Out-Null
        } catch {
            [Windows.MessageBox]::Show("Lỗi: $_","Lỗi","OK","Error") | Out-Null
        }
        Update-Security
    }
})

# ── NAV ───────────────────────────────────────────────────────────────────────
$NavDashboard.Add_Click({ Hl-Nav $NavDashboard; Show-Page $PgDash; Update-Dashboard })

$NavSecurity.Add_Click({
    Hl-Nav $NavSecurity; Show-Page $PgSec; Update-Security
})

$NavBackup.Add_Click({
    Hl-Nav $NavBackup; Show-Page $PgBk
    $GridBkParts.ItemsSource = Get-PartRows "source"
    $TxtBkName.Text = "$($env:COMPUTERNAME)_$(Get-Date -Format yyyyMMdd-HHmm)"
    Set-Status "Chọn phân vùng nguồn cần sao lưu"
})
$NavRestore.Add_Click({
    Hl-Nav $NavRestore; Show-Page $PgRst
    $GridImgList.ItemsSource  = Get-ImageRows
    $GridRstParts.ItemsSource = Get-PartRows "target"
    Set-Status "Chọn ảnh và phân vùng đích"
})
$NavImages.Add_Click({
    Hl-Nav $NavImages; Show-Page $PgImg
    $GridMgImg.ItemsSource = Get-ImageRows
    Set-Status "$((Get-ChildItem (Get-ImgDir) -Filter *.wim -EA SilentlyContinue).Count) ảnh trong kho"
})
$NavSettings.Add_Click({
    Hl-Nav $NavSettings; Show-Page $PgSet
    $drives = @(Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Name -ne "C" -and (Test-Path "$($_.Name):\") } | ForEach-Object { $_.Name })
    $CmbDrive.ItemsSource = $drives; $CmbDrive.SelectedItem = $script:StoreLetter
    $TxtWinPESt.Text = if (Test-WinPEReady) { "✅ Đã cài — GUID: $(Get-BootGuid)" } else { "❌ Chưa cài" }
    $TxtSysInfo.Text = "Máy: $env:COMPUTERNAME`nOS: $([Environment]::OSVersion.VersionString)`nPowerShell: $($PSVersionTable.PSVersion)`nThư mục: $(Get-Base)`nLog: $script:LogFile"
    Set-Status "Cài đặt"
})

# Dashboard -> shortcut
$BtnBackup.Add_Click({ $NavBackup.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent)) })
$BtnRestore.Add_Click({ $NavRestore.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent)) })
$BtnGoSetup.Add_Click({ $NavSettings.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent)) })
$BtnGoSecurity.Add_Click({ $NavSecurity.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent)) })

# Fix All
$BtnFixAll.Add_Click({
    $res = [Windows.MessageBox]::Show(
        "Tự động xử lý tất cả mục có thể sửa:`n`n• Tạm ngừng BitLocker C: và $($script:StoreLetter): (1 reboot)`n• Tắt Fast Startup`n• Đặt ExecutionPolicy = RemoteSigned`n• Thêm Defender exclusion cho $(Get-Base)`n`nTiếp tục?",
        "Tắt tất cả bảo mật","YesNo","Question")
    if ($res -ne "Yes") { return }
    Set-Status "Đang xử lý..." $true
    $log = @()
    foreach ($id in @("BL_C","BL_STORE","FAST_STARTUP","EXECPOLICY","DEFENDER")) {
        try { $log += Fix-SecurityItem $id } catch { $log += "Lỗi $id : $_" }
    }
    Update-Security
    [Windows.MessageBox]::Show(($log -join "`n"),"Kết quả","OK","Information") | Out-Null
    Log ("Fix-All: " + ($log -join " | "))
})

# ── BACKUP LOGIC ──────────────────────────────────────────────────────────────
$BtnStartBk.Add_Click({
    $row = $GridBkParts.SelectedItem
    if (-not $row) { [Windows.MessageBox]::Show("Chọn phân vùng nguồn trước.","","OK","Warning")|Out-Null; return }
    $imgName = $TxtBkName.Text.Trim()
    if (-not $imgName) { $imgName = "$($env:COMPUTERNAME)_$(Get-Date -Format yyyyMMdd-HHmm)" }
    if (-not $imgName.EndsWith(".wim")) { $imgName += ".wim" }
    if (Test-Path "$(Get-ImgDir)\$imgName") {
        [Windows.MessageBox]::Show("Tên '$imgName' đã tồn tại.","Trùng tên","OK","Warning")|Out-Null; return
    }
    $item = $row.OrigItem
    $compress = switch ($CmbCompress.SelectedIndex) { 1 { "maximum" }; 2 { "recovery" }; default { "fast" } }
    $osPart  = $item.Partition; $osVol = Get-Volume -DriveLetter $item.Letter.TrimEnd(":") -EA SilentlyContinue
    $disk    = Get-Disk -Number $osPart.DiskNumber; $stPart = Get-Partition -DriveLetter $script:StoreLetter
    $msg = "XÁC NHẬN SAO LƯU:`n`n  Phân vùng : $($item.Letter) — '$($item.Label)' ($($item.SizeGB))`n  Lưu tại   : $($script:StoreLetter):\$($script:ReimageDir)\images\$imgName`n  Mức nén   : $compress`n`nMáy sẽ khởi động lại vào WinPE (~10-40 phút)."
    if ([Windows.MessageBox]::Show($msg,"Xác nhận","OKCancel","Question") -ne "OK") { return }
    try {
        # Tao job_id va token (S13)
        $jobId  = [guid]::NewGuid().ToString()
        $token  = [guid]::NewGuid().ToString()
        $expiry = (Get-Date).AddHours(2).ToString("yyyy-MM-ddTHH:mm:ss")
        # Ghi token vao phan vung OS de engine xac nhan (S13)
        $tokDir = "$($item.Letter)ProgramData\LilbowRecovery"
        New-Item -ItemType Directory -Force $tokDir | Out-Null
        Set-Content "$tokDir\token.txt" $token -Encoding UTF8
        # Chup bang phan vung + ghi sentinel (S17)
        $base = Get-Base
        Get-Partition | Select-Object DiskNumber,PartitionNumber,Guid,Offset,Size,GptType |
            ConvertTo-Json | Set-Content "$base\partitions-before.json" -Encoding UTF8
        Set-Content "$base\sentinel.txt" $token -Encoding UTF8
        $job = @{
            action            = "backup"
            job_id            = $jobId
            token             = $token
            expires_at        = $expiry
            hostname          = $env:COMPUTERNAME
            os_partition_guid = $osPart.Guid
            os_offset         = $osPart.Offset
            os_label          = if($osVol){$osVol.FileSystemLabel}else{""}
            os_size           = $osPart.Size
            disk_serial       = "$($disk.SerialNumber)".Trim()
            store_partition_guid = $stPart.Guid
            image             = "$($script:ImagesDir)\$imgName"
            image_index       = 1
            image_name        = "$($script:AppName) $env:COMPUTERNAME $(Get-Date -Format 'yyyy-MM-dd') $($item.Label)"
            compress          = $compress
        }
        $job | ConvertTo-Json | Set-Content "$base\job.json" -Encoding UTF8
        &bcdedit /bootsequence (Get-BootGuid) | Out-Null
        Log "Backup: $imgName <- $($item.Letter) GUID=$($osPart.Guid) job_id=$jobId"
        [Windows.MessageBox]::Show("Job ghi xong!`nMáy khởi động lại sau 5 giây.","OK","OK","Information")|Out-Null
        Start-Sleep 5; Restart-Computer -Force
    } catch { [Windows.MessageBox]::Show("Lỗi: $_","Lỗi","OK","Error")|Out-Null; Set-Status "Lỗi: $_" }
})

# ── SELFTEST trigger ──────────────────────────────────────────────────────────
function Start-Selftest {
    $stPt = Get-Partition -DriveLetter $script:StoreLetter -EA SilentlyContinue
    if (-not $stPt) { [Windows.MessageBox]::Show("Không tìm thấy ổ lưu ảnh $($script:StoreLetter):","Lỗi","OK","Error")|Out-Null; return }
    $osPart = Get-Partition | Where-Object { (Test-Path "$($_.DriveLetter):\Windows\System32") } | Select-Object -First 1
    if (-not $osPart) { [Windows.MessageBox]::Show("Không tìm thấy phân vùng Windows.","Lỗi","OK","Error")|Out-Null; return }
    $base = Get-Base
    # Ghi selftest-request.json
    @{ os_partition_guid=$osPart.Guid; hostname=$env:COMPUTERNAME
       requested_at=(Get-Date -Format "yyyy-MM-ddTHH:mm:ss") } |
        ConvertTo-Json | Set-Content "$base\selftest-request.json" -Encoding UTF8
    &bcdedit /bootsequence (Get-BootGuid) | Out-Null
    Log "Selftest: yeu cau gui, reboot sau 5 giay"
    [Windows.MessageBox]::Show("Máy sẽ khởi động vào WinPE để kiểm tra (~3-5 phút), rồi tự về Windows.`nKết quả xem trong Dashboard sau khi về Windows.","Selftest","OK","Information")|Out-Null
    Start-Sleep 5; Restart-Computer -Force
}

# Kiem tra selftest-ok.json co hop le khong (S14) — dung trong UI
function Test-SelftestValid {
    $sf = "$(Get-Base)\selftest-ok.json"
    if (-not (Test-Path $sf)) { return $false }
    try {
        $st = Get-Content $sf -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($st.status -ne "OK") { return $false }
        if ((Get-Date) - [datetime]$st.time -gt [TimeSpan]::FromDays(7)) { return $false }
        return $true
    } catch { return $false }
}

# ── RESTORE LOGIC ─────────────────────────────────────────────────────────────
$BtnStartRst.Add_Click({
    $selImg = $GridImgList.SelectedItem; $selPt = $GridRstParts.SelectedItem
    if (-not $selImg) { [Windows.MessageBox]::Show("Chọn ảnh backup trước.","","OK","Warning")|Out-Null; return }
    if (-not $selPt)  { [Windows.MessageBox]::Show("Chọn phân vùng đích trước.","","OK","Warning")|Out-Null; return }

    # Kiem tra meta.json (S18)
    $metaPath = "$($selImg.FullPath).meta.json"
    if (Test-Path $metaPath) {
        $meta = Get-Content $metaPath -Raw | ConvertFrom-Json -EA SilentlyContinue
        if ($meta -and $meta.verified -eq $false) {
            [Windows.MessageBox]::Show("Ảnh '$($selImg.Name)' chưa được xác minh (verified=false).`nKhông thể dùng để restore — S18.","Ảnh chưa xác minh","OK","Error")|Out-Null
            return
        }
    }

    # Kiem tra SHA256
    if (-not (Test-Path "$($selImg.FullPath).sha256")) {
        [Windows.MessageBox]::Show("Thiếu file .sha256.","Thiếu hash","OK","Error")|Out-Null; return
    }
    Set-Status "Đang kiểm tra SHA256..." $true
    $exp = ((Get-Content "$($selImg.FullPath).sha256" -Raw).Trim() -split "\s+")[0]
    $act = (Get-FileHash $selImg.FullPath -Algorithm SHA256).Hash
    if ($act -ne $exp) {
        [Windows.MessageBox]::Show("File ảnh bị hỏng! SHA256 không khớp.","Ảnh hỏng","OK","Error")|Out-Null
        Set-Status "SHA256 lỗi"; return
    }

    # Kiem tra selftest (S14)
    if (-not (Test-SelftestValid)) {
        $ans = [Windows.MessageBox]::Show(
            "⚠ Chưa có kết quả selftest hợp lệ (S14).`n`nRestore có thể thất bại nếu WinPE không boot được máy này.`n`nBạn có muốn chạy Selftest trước không?",
            "Cần Selftest","YesNo","Warning")
        if ($ans -eq "Yes") { Start-Selftest; return }
        # Cho phep bỏ qua nhưng cảnh báo rõ
        if ([Windows.MessageBox]::Show("Tiếp tục mà KHÔNG có selftest? Rủi ro cao nếu máy ở xa.","Xác nhận bỏ qua","OKCancel","Warning") -ne "OK") { return }
    }

    $item=$selPt.OrigItem; $dstPt=$item.Partition; $dstDsk=Get-Disk -Number $dstPt.DiskNumber
    $dstVol=Get-Volume -DriveLetter $item.Letter.TrimEnd(":") -EA SilentlyContinue
    $stPt=Get-Partition -DriveLetter $script:StoreLetter
    $warn="⚠ CẢNH BÁO — THAO TÁC KHÔNG THỂ HOÀN TÁC!`n`nSẼ FORMAT:`n  Ổ: $($item.Letter)  Nhãn: $($item.Label)  Disk$($item.DiskNum)  $($item.SizeGB)`n`nẢnh: $($selImg.Name)`nỔ $($script:StoreLetter): KHÔNG bị ảnh hưởng.`n`nNhấn OK để xác nhận."
    if ([Windows.MessageBox]::Show($warn,"⚠ XÁC NHẬN","OKCancel","Warning") -ne "OK") { return }
    try {
        # Tao job_id + token + expiry (S13)
        $jobId  = [guid]::NewGuid().ToString()
        $token  = [guid]::NewGuid().ToString()
        $expiry = (Get-Date).AddHours(2).ToString("yyyy-MM-ddTHH:mm:ss")
        # Ghi token vao phan vung dich (S13)
        $dstLetter = $item.Letter
        $tokDir = "${dstLetter}ProgramData\LilbowRecovery"
        New-Item -ItemType Directory -Force $tokDir -EA SilentlyContinue | Out-Null
        Set-Content "$tokDir\token.txt" $token -Encoding UTF8
        # Chup bang phan vung + ghi sentinel (S17)
        $base = Get-Base
        Get-Partition | Select-Object DiskNumber,PartitionNumber,Guid,Offset,Size,GptType |
            ConvertTo-Json | Set-Content "$base\partitions-before.json" -Encoding UTF8
        Set-Content "$base\sentinel.txt" $token -Encoding UTF8
        $job = @{
            action            = "restore"
            job_id            = $jobId
            token             = $token
            expires_at        = $expiry
            hostname          = $env:COMPUTERNAME
            os_partition_guid = $dstPt.Guid
            os_offset         = $dstPt.Offset
            os_label          = if($dstVol){$dstVol.FileSystemLabel}else{""}
            os_size           = $dstPt.Size
            disk_serial       = "$($dstDsk.SerialNumber)".Trim()
            store_partition_guid = $stPt.Guid
            image             = "$($script:ImagesDir)\$($selImg.Name)"
            image_index       = 1; image_name=""; compress="fast"
        }
        $job | ConvertTo-Json | Set-Content "$base\job.json" -Encoding UTF8
        &bcdedit /bootsequence (Get-BootGuid) | Out-Null
        Log "Restore: $($selImg.Name) -> $($item.Letter) GUID=$($dstPt.Guid) job_id=$jobId"
        [Windows.MessageBox]::Show("Job ghi xong!`nMáy khởi động lại sau 5 giây.","OK","OK","Information")|Out-Null
        Start-Sleep 5; Restart-Computer -Force
    } catch { [Windows.MessageBox]::Show("Lỗi: $_","Lỗi","OK","Error")|Out-Null; Set-Status "Lỗi: $_" }
})

# ── IMAGES LOGIC ──────────────────────────────────────────────────────────────
$BtnImport.Add_Click({
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter="WIM files (*.wim)|*.wim"; $dlg.Title="Chọn file ảnh WIM"
    if ($dlg.ShowDialog() -ne $true) { return }
    $src=$dlg.FileName; $dest=Join-Path (Get-ImgDir) (Split-Path $src -Leaf)
    if (Test-Path $dest) { [Windows.MessageBox]::Show("Tên đã tồn tại.","","OK","Warning")|Out-Null; return }
    New-Item -ItemType Directory -Force (Get-ImgDir)|Out-Null
    Set-Status "Đang sao chép..." $true; Copy-Item $src $dest -Force
    Set-Status "Đang tính SHA256..." $true
    $hash=(Get-FileHash $dest -Algorithm SHA256).Hash; $hash|Set-Content "$dest.sha256" -Encoding UTF8
    $GridMgImg.ItemsSource=Get-ImageRows; Log "Import: $dest"
    Set-Status "Đã nhập: $(Split-Path $src -Leaf)"
    [Windows.MessageBox]::Show("Nhập thành công!`nSHA256: $hash","OK","OK","Information")|Out-Null
})
$BtnDelete.Add_Click({
    $sel=$GridMgImg.SelectedItem
    if (-not $sel) { [Windows.MessageBox]::Show("Chọn ảnh cần xóa.","","OK","Warning")|Out-Null; return }
    if ([Windows.MessageBox]::Show("Xóa '$($sel.Name)'?","Xác nhận","YesNo","Warning") -ne "Yes") { return }
    Remove-Item $sel.FullPath -Force; Remove-Item "$($sel.FullPath).sha256" -Force -EA SilentlyContinue
    $GridMgImg.ItemsSource=Get-ImageRows; Log "Delete: $($sel.Name)"; Set-Status "Đã xóa: $($sel.Name)"
})

# ── SETTINGS LOGIC ────────────────────────────────────────────────────────────
$BtnApplyDrive.Add_Click({
    $nl=$CmbDrive.SelectedItem; if($nl){$script:StoreLetter=$nl; Update-Dashboard; Set-Status "Đổi ổ lưu ảnh: $nl:"}
})
$BtnInstWinPE.Add_Click({
    $wimSrc=$null
    foreach ($loc in @("$script:ScriptDir\boot.wim","$script:ScriptDir\dist\boot.wim")) { if(Test-Path $loc){$wimSrc=$loc;break} }
    if (-not $wimSrc) { [Windows.MessageBox]::Show("Không tìm thấy boot.wim cạnh LilbowRecovery.bat.","Thiếu file","OK","Error")|Out-Null; return }
    $sdiSrc=$wimSrc-replace"boot\.wim$","boot.sdi"
    Set-Status "Đang cài đặt WinPE..." $true
    try {
        $base=Get-Base
        foreach ($s in @("sources","boot","$($script:ImagesDir)\_tmp","logs")) { New-Item -ItemType Directory -Force "$base\$s"|Out-Null }
        Copy-Item $wimSrc "$base\sources\boot.wim" -Force; Copy-Item $sdiSrc "$base\boot\boot.sdi" -Force
        &bcdedit /create "{ramdiskoptions}" /d "LilbowRecovery Ramdisk"|Out-Null
        &bcdedit /set "{ramdiskoptions}" ramdisksdidevice "partition=$($script:StoreLetter):"|Out-Null
        &bcdedit /set "{ramdiskoptions}" ramdisksdipath "\$($script:ReimageDir)\boot\boot.sdi"|Out-Null
        $bcdOut=&bcdedit /create /d "LilbowRecovery WinPE" /application osloader
        $gm=($bcdOut|Out-String)|Select-String "\{[0-9a-f\-]+\}"
        if (-not $gm) { throw "Tạo BCD thất bại" }
        $guid=$gm.Matches[0].Value
        &bcdedit /set $guid device    "ramdisk=[$($script:StoreLetter):]\$($script:ReimageDir)\sources\boot.wim,{ramdiskoptions}"|Out-Null
        &bcdedit /set $guid osdevice  "ramdisk=[$($script:StoreLetter):]\$($script:ReimageDir)\sources\boot.wim,{ramdiskoptions}"|Out-Null
        &bcdedit /set $guid path      "\windows\system32\boot\winload.efi"|Out-Null
        &bcdedit /set $guid systemroot "\windows"|Out-Null
        &bcdedit /set $guid winpe     "yes"|Out-Null
        &bcdedit /set $guid detecthal "yes"|Out-Null
        &bcdedit /displayorder $guid /addlast|Out-Null
        $guid|Set-Content "$base\bootguid.txt" -Encoding UTF8
        attrib +h $base|Out-Null
        &icacls $base /inheritance:r /grant:r "Administrators:(OI)(CI)F" "SYSTEM:(OI)(CI)F"|Out-Null
        Log "WinPE: $guid"; $TxtWinPESt.Text="✅ Đã cài — GUID: $guid"
        Set-Status "Cài đặt WinPE hoàn tất!"; Update-Dashboard
        [Windows.MessageBox]::Show("Cài đặt WinPE hoàn tất!","OK","OK","Information")|Out-Null
    } catch { [Windows.MessageBox]::Show("Lỗi: $_","Lỗi","OK","Error")|Out-Null; Set-Status "Lỗi: $_" }
})
$BtnUninstWinPE.Add_Click({
    if ([Windows.MessageBox]::Show("Gỡ WinPE?","Xác nhận","YesNo","Warning") -ne "Yes") { return }
    $g=Get-BootGuid; if($g){ &bcdedit /displayorder $g /remove|Out-Null; &bcdedit /delete $g /f|Out-Null; Remove-Item "$(Get-Base)\bootguid.txt" -Force -EA SilentlyContinue }
    $TxtWinPESt.Text="❌ Đã gỡ"; Update-Dashboard; Set-Status "Đã gỡ WinPE"
})
$BtnOpenLog.Add_Click({ $ld="$env:ProgramData\$($script:AppName)\logs"; if(Test-Path $ld){Start-Process explorer $ld} })

# ── STARTUP ───────────────────────────────────────────────────────────────────
$Win.Add_Loaded({ Hl-Nav $NavDashboard; Update-Dashboard })
[void]$Win.ShowDialog()
