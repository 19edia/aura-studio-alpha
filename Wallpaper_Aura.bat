@echo off
setlocal DisableDelayedExpansion
title AURA Wallpaper Studio
set "AURA_SCRIPT=%~f0"
if not exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" goto missing_powershell
start "" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -STA -WindowStyle Hidden -Command "try{$lines=[IO.File]::ReadAllLines($env:AURA_SCRIPT,[Text.Encoding]::UTF8);$i=[Array]::IndexOf($lines,'#==AURA_POWERSHELL==');if($i -lt 0){throw 'Arquivo AURA incompleto.'};& ([ScriptBlock]::Create(($lines[($i+1)..($lines.Length-1)] -join [Environment]::NewLine)))}catch{Add-Type -AssemblyName PresentationFramework;[void][System.Windows.MessageBox]::Show($_.Exception.Message,'AURA - Nao foi possivel abrir')}"
exit /b
:missing_powershell
echo Nao foi possivel encontrar o Windows PowerShell neste computador.
pause
exit /b 1
#==AURA_POWERSHELL==
param(
    [string]$RenderPreviewPath,
    [string]$PreviewImagePath,
    [ValidateSet('Original','FullHD','4K','8K')][string]$PreviewResolution = 'Original'
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Drawing

# Build-time placeholders are replaced when the single BAT is assembled.
$script:EngineSource = {
function Invoke-AuraWallpaper {
    <#
    .SYNOPSIS
        Prepares a photo and applies it as the current user's desktop wallpaper.
    .DESCRIPTION
        Compatible with a clean Windows PowerShell 5.1 runspace. Load this function
        into the worker runspace; it has no UI or dependencies on the UI runspace.
        Returns one object and throws on failure. RenderOnly requires an explicit
        OutputDirectory and never accesses the registry or desktop wallpaper API.
        SystemParametersInfoW documentation:
        https://learn.microsoft.com/windows/win32/api/winuser/nf-winuser-systemparametersinfow
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $ImagePath,

        [ValidateSet('Original', 'FullHD', '4K', '8K')]
        [string] $Resolution = 'Original',

        [switch] $RenderOnly,

        [string] $OutputDirectory
    )

    $ErrorActionPreference = 'Stop'
    $sourceImage = $null
    $sourceStream = $null
    $bitmap = $null
    $graphics = $null
    $imageAttributes = $null
    $outputStream = $null
    $desktopKey = $null
    $newWallpaper = $null
    $partialWallpaper = $null
    $keepOutput = $false
    $applied = $false
    $styleChanged = $false
    $oldSettings = @{}

    try {
        if ($RenderOnly -and [string]::IsNullOrWhiteSpace($OutputDirectory)) {
            throw 'A verificacao interna exige uma pasta de saida explicita.'
        }
        if (-not $RenderOnly -and -not [string]::IsNullOrWhiteSpace($OutputDirectory)) {
            throw 'Uma pasta personalizada so pode ser usada na verificacao interna.'
        }

        $selectedPath = [IO.Path]::GetFullPath($ImagePath)
        if (-not [IO.File]::Exists($selectedPath)) {
            throw 'A foto nao foi encontrada. Escolha um arquivo salvo neste computador.'
        }
        if ([IO.Path]::GetExtension($selectedPath).ToLowerInvariant() -notin @('.jpg', '.jpeg', '.png', '.bmp')) {
            throw 'Escolha uma imagem JPG, JPEG, PNG ou BMP.'
        }

        [void](Add-Type -AssemblyName System.Drawing -ErrorAction Stop)
        $sourceStream = [IO.File]::Open($selectedPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $sourceImage = [System.Drawing.Image]::FromStream($sourceStream, $true, $true)

        # Correct phone/camera orientation before measuring or cropping. The
        # rendered BMP contains the corrected pixels, not stale EXIF metadata.
        if ($sourceImage.PropertyIdList -contains 274) {
            $orientationBytes = $sourceImage.GetPropertyItem(274).Value
            if ($null -ne $orientationBytes -and $orientationBytes.Length -ge 2) {
                $orientation = [int][BitConverter]::ToUInt16($orientationBytes, 0)
                $transforms = @{
                    2 = [System.Drawing.RotateFlipType]::RotateNoneFlipX
                    3 = [System.Drawing.RotateFlipType]::Rotate180FlipNone
                    4 = [System.Drawing.RotateFlipType]::Rotate180FlipX
                    5 = [System.Drawing.RotateFlipType]::Rotate90FlipX
                    6 = [System.Drawing.RotateFlipType]::Rotate90FlipNone
                    7 = [System.Drawing.RotateFlipType]::Rotate270FlipX
                    8 = [System.Drawing.RotateFlipType]::Rotate270FlipNone
                }
                if ($transforms.ContainsKey($orientation)) {
                    $sourceImage.RotateFlip($transforms[$orientation])
                }
            }
        }

        $targetWidth = $sourceImage.Width
        $targetHeight = $sourceImage.Height
        switch ($Resolution) {
            'FullHD' { $targetWidth = 1920; $targetHeight = 1080 }
            '4K'     { $targetWidth = 3840; $targetHeight = 2160 }
            '8K'     { $targetWidth = 7680; $targetHeight = 4320 }
        }

        $bitmap = New-Object System.Drawing.Bitmap($targetWidth, $targetHeight, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        # Desktop BMPs are opaque: flatten transparency onto the studio's dark
        # background. Preserve aspect ratio; preset sizes use a centered crop.
        $graphics.Clear([System.Drawing.Color]::FromArgb(10, 13, 24))
        $graphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceOver
        $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
        if ($Resolution -eq 'Original') {
            $graphics.DrawImageUnscaled($sourceImage, 0, 0)
        } else {
            $scale = [Math]::Max($targetWidth / [double]$sourceImage.Width, $targetHeight / [double]$sourceImage.Height)
            $cropWidth = $targetWidth / $scale
            $cropHeight = $targetHeight / $scale
            $cropX = ($sourceImage.Width - $cropWidth) / 2.0
            $cropY = ($sourceImage.Height - $cropHeight) / 2.0
            $destination = New-Object System.Drawing.Rectangle(0, 0, $targetWidth, $targetHeight)
            $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $imageAttributes = New-Object System.Drawing.Imaging.ImageAttributes
            $imageAttributes.SetWrapMode([System.Drawing.Drawing2D.WrapMode]::TileFlipXY)
            $graphics.DrawImage($sourceImage, $destination, [single]$cropX, [single]$cropY, [single]$cropWidth, [single]$cropHeight, [System.Drawing.GraphicsUnit]::Pixel, $imageAttributes)
        }

        $cacheFolder = if ($RenderOnly) {
            [IO.Path]::GetFullPath($OutputDirectory)
        } else {
            [IO.Path]::GetFullPath([IO.Path]::Combine([Environment]::GetFolderPath('LocalApplicationData'), 'AuraWallpaper'))
        }
        [void][IO.Directory]::CreateDirectory($cacheFolder)
        $newWallpaper = [IO.Path]::Combine($cacheFolder, ('aura-' + [Guid]::NewGuid().ToString('N') + '.bmp'))
        $partialWallpaper = $newWallpaper + '.part'
        $outputStream = [IO.File]::Open($partialWallpaper, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $bitmap.Save($outputStream, [System.Drawing.Imaging.ImageFormat]::Bmp)
        $outputStream.Flush($true)
        $outputStream.Dispose(); $outputStream = $null
        [IO.File]::Move($partialWallpaper, $newWallpaper)
        $partialWallpaper = $null

        # Free image buffers and file handles before touching desktop settings.
        if ($null -ne $imageAttributes) { $imageAttributes.Dispose(); $imageAttributes = $null }
        $graphics.Dispose(); $graphics = $null
        $bitmap.Dispose(); $bitmap = $null
        $sourceImage.Dispose(); $sourceImage = $null
        $sourceStream.Dispose(); $sourceStream = $null

        # Hard boundary for QA: everything involving registry or native desktop
        # APIs is below this early return and cannot execute with RenderOnly.
        if ($RenderOnly) {
            $keepOutput = $true
            return [pscustomobject]@{
                Width = [int]$targetWidth
                Height = [int]$targetHeight
                Resolution = $Resolution
                OutputPath = $newWallpaper
            }
        }

        if ($null -eq ('AuraWallpaperNativeV2' -as [type])) {
            [void](Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class AuraWallpaperNativeV2 {
    [DllImport("user32.dll", EntryPoint = "SystemParametersInfoW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetWallpaper(uint action, uint parameter, string path, uint flags);

    [DllImport("user32.dll", EntryPoint = "SystemParametersInfoW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetWallpaper(uint action, uint parameter, StringBuilder path, uint flags);
}
'@ -ErrorAction Stop)
        }

        # SPI_GETDESKWALLPAPER. Failure only disables cleanup of the old file.
        $previousBuffer = New-Object System.Text.StringBuilder 32768
        $hasPrevious = [AuraWallpaperNativeV2]::GetWallpaper(0x0073, [uint32]$previousBuffer.Capacity, $previousBuffer, 0)
        $previousWallpaper = if ($hasPrevious) { $previousBuffer.ToString() } else { $null }

        $desktopKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Control Panel\Desktop', $true)
        if ($null -eq $desktopKey) {
            throw 'Nao foi possivel abrir as configuracoes do desktop.'
        }
        foreach ($name in @('WallpaperStyle', 'TileWallpaper')) {
            $exists = $desktopKey.GetValueNames() -contains $name
            $oldSettings[$name] = @{
                Exists = $exists
                Value = $desktopKey.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                Kind = if ($exists) { $desktopKey.GetValueKind($name) } else { $null }
            }
        }
        $styleChanged = $true
        $desktopKey.SetValue('WallpaperStyle', '10', [Microsoft.Win32.RegistryValueKind]::String)
        $desktopKey.SetValue('TileWallpaper', '0', [Microsoft.Win32.RegistryValueKind]::String)

        # SPI_SETDESKWALLPAPER (0x0014), SPIF_UPDATEINIFILE | SPIF_SENDCHANGE
        # (0x0003): persist the path and notify the desktop of the change.
        $applied = [AuraWallpaperNativeV2]::SetWallpaper(0x0014, 0, $newWallpaper, 0x0003)
        if (-not $applied) {
            $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw ('O Windows recusou a troca do papel de parede. Codigo: ' + $errorCode + '.')
        }
        $keepOutput = $true

        # Delete only the previously active file, with the exact generated name,
        # inside this application's cache directory. Never enumerate or recurse.
        # Never delete the selected original or follow a reparse-point file.
        if (-not [string]::IsNullOrWhiteSpace($previousWallpaper)) {
            try {
                $previousFull = [IO.Path]::GetFullPath($previousWallpaper)
                $previousDirectory = [IO.Path]::GetDirectoryName($previousFull)
                $sameDirectory = [string]::Equals($previousDirectory.TrimEnd('\'), $cacheFolder.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)
                $ownName = [IO.Path]::GetFileName($previousFull) -cmatch '^aura-[a-f0-9]{32}\.bmp$'
                $differentFromSource = -not [string]::Equals($previousFull, $selectedPath, [StringComparison]::OrdinalIgnoreCase)
                $differentFromNew = -not [string]::Equals($previousFull, $newWallpaper, [StringComparison]::OrdinalIgnoreCase)
                if ($sameDirectory -and $ownName -and $differentFromSource -and $differentFromNew -and [IO.File]::Exists($previousFull)) {
                    $oldAttributes = [IO.File]::GetAttributes($previousFull)
                    $cacheAttributes = [IO.File]::GetAttributes($cacheFolder)
                    if (($oldAttributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 -and
                        ($cacheAttributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
                        [IO.File]::Delete($previousFull)
                    }
                }
            } catch { } # A locked old cache must not turn successful apply into failure.
        }

        return [pscustomobject]@{
            Width = [int]$targetWidth
            Height = [int]$targetHeight
            Resolution = $Resolution
            OutputPath = $newWallpaper
        }
    } catch {
        $failure = $_
        if ($styleChanged -and -not $applied -and $null -ne $desktopKey) {
            $rollbackFailures = New-Object 'System.Collections.Generic.List[string]'
            foreach ($name in $oldSettings.Keys) {
                try {
                    $old = $oldSettings[$name]
                    if ($old.Exists) { $desktopKey.SetValue($name, $old.Value, $old.Kind) }
                    else { $desktopKey.DeleteValue($name, $false) }
                } catch { $rollbackFailures.Add($name) }
            }
            if ($rollbackFailures.Count -gt 0) {
                throw (New-Object System.InvalidOperationException(($failure.Exception.Message + ' Tambem nao foi possivel restaurar o enquadramento anterior.'), $failure.Exception))
            }
        }
        throw $failure
    } finally {
        if ($null -ne $outputStream) { $outputStream.Dispose() }
        if ($null -ne $imageAttributes) { $imageAttributes.Dispose() }
        if ($null -ne $graphics) { $graphics.Dispose() }
        if ($null -ne $bitmap) { $bitmap.Dispose() }
        if ($null -ne $sourceImage) { $sourceImage.Dispose() }
        if ($null -ne $sourceStream) { $sourceStream.Dispose() }
        if ($null -ne $desktopKey) { $desktopKey.Dispose() }
        if ($partialWallpaper -and [IO.File]::Exists($partialWallpaper)) {
            try { [IO.File]::Delete($partialWallpaper) } catch { }
        }
        if (-not $keepOutput -and $newWallpaper -and [IO.File]::Exists($newWallpaper)) {
            try { [IO.File]::Delete($newWallpaper) } catch { }
        }
    }
}

}.ToString()
$xamlSource = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="AURA — Wallpaper Studio" Width="1120" Height="760" MinWidth="560" MinHeight="380"
        WindowStartupLocation="CenterScreen" WindowStyle="None" ResizeMode="CanResizeWithGrip"
        AllowsTransparency="True" Background="Transparent" FontFamily="Segoe UI"
        Foreground="#F5F4FC" UseLayoutRounding="True" SnapsToDevicePixels="True">
  <Window.Icon>
    <DrawingImage><DrawingImage.Drawing><DrawingGroup>
      <GeometryDrawing Brush="#191729" Geometry="M 8,0 L 56,0 Q 64,0 64,8 L 64,56 Q 64,64 56,64 L 8,64 Q 0,64 0,56 L 0,8 Q 0,0 8,0 Z"/>
      <GeometryDrawing Geometry="M 13,47 L 31,16 L 49,47 M 21,35 L 41,35"><GeometryDrawing.Pen><Pen Brush="#C9AEFA" Thickness="3"/></GeometryDrawing.Pen></GeometryDrawing>
      <GeometryDrawing Brush="#8BDDE6"><GeometryDrawing.Geometry><EllipseGeometry Center="48,14" RadiusX="4" RadiusY="4"/></GeometryDrawing.Geometry></GeometryDrawing>
    </DrawingGroup></DrawingImage.Drawing></DrawingImage>
  </Window.Icon>
  <Window.Resources>
    <SolidColorBrush x:Key="MutedText" Color="#9699B1"/>
    <Style TargetType="ToolTip">
      <Setter Property="Background" Value="#252238"/><Setter Property="Foreground" Value="#E0D8F2"/>
      <Setter Property="BorderBrush" Value="#65547F"/><Setter Property="Padding" Value="10,7"/>
      <Setter Property="FontFamily" Value="Segoe UI"/><Setter Property="FontSize" Value="11"/>
      <Setter Property="HasDropShadow" Value="False"/>
    </Style>
    <Style x:Key="WindowButton" TargetType="Button">
      <Setter Property="Width" Value="34"/><Setter Property="Height" Value="30"/>
      <Setter Property="Foreground" Value="#9296B1"/><Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
        <Border x:Name="Chrome" Background="{TemplateBinding Background}" CornerRadius="9">
          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Chrome" Property="Background" Value="#25273B"/><Setter Property="Foreground" Value="#FFFFFF"/></Trigger>
          <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Chrome" Property="Background" Value="#353049"/></Trigger>
          <Trigger Property="IsPressed" Value="True"><Setter TargetName="Chrome" Property="Opacity" Value="0.65"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="ChooseStyle" TargetType="Button">
      <Setter Property="Height" Value="72"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Foreground" Value="#EEEAFE"/><Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Background" Value="#1D1C35"/><Setter Property="BorderBrush" Value="#514274"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
        <Border x:Name="Chrome" BorderThickness="1" BorderBrush="{TemplateBinding BorderBrush}" Background="{TemplateBinding Background}" CornerRadius="14" Padding="16,0">
          <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Chrome" Property="Background" Value="#29213F"/><Setter TargetName="Chrome" Property="BorderBrush" Value="#A68CF0"/></Trigger>
          <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Chrome" Property="BorderBrush" Value="#C9B8FF"/></Trigger>
          <Trigger Property="IsPressed" Value="True"><Setter TargetName="Chrome" Property="Background" Value="#352C50"/></Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Chrome" Property="Opacity" Value="0.4"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="ResolutionTile" TargetType="RadioButton">
      <Setter Property="Foreground" Value="#EEEFFA"/><Setter Property="Background" Value="#131625"/>
      <Setter Property="BorderBrush" Value="#2A2D42"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Height" Value="66"/><Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="RadioButton">
        <Border x:Name="Tile" CornerRadius="12" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" Background="{TemplateBinding Background}" Padding="13,9">
          <Grid>
            <ContentPresenter HorizontalAlignment="Left" VerticalAlignment="Center"/>
            <Border x:Name="DotRing" Width="12" Height="12" CornerRadius="6" BorderBrush="#41465F" BorderThickness="1" HorizontalAlignment="Right" VerticalAlignment="Top">
              <Ellipse x:Name="SelectedDot" Fill="#CAB9FF" Margin="3" Opacity="0"/>
            </Border>
          </Grid>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Tile" Property="Background" Value="#202239"/><Setter TargetName="Tile" Property="BorderBrush" Value="#62617F"/></Trigger>
          <Trigger Property="IsChecked" Value="True"><Setter TargetName="Tile" Property="Background" Value="#27213F"/><Setter TargetName="Tile" Property="BorderBrush" Value="#9774DE"/><Setter TargetName="DotRing" Property="BorderBrush" Value="#B59CEB"/><Setter TargetName="SelectedDot" Property="Opacity" Value="1"/></Trigger>
          <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Tile" Property="BorderBrush" Value="#E4D9FF"/><Setter TargetName="Tile" Property="BorderThickness" Value="2"/></Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Tile" Property="Opacity" Value="0.45"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="ApplyStyle" TargetType="Button">
      <Setter Property="Foreground" Value="#FFFFFF"/><Setter Property="Height" Value="52"/>
      <Setter Property="FontSize" Value="14"/><Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
        <Border x:Name="Chrome" CornerRadius="13" BorderThickness="1" BorderBrush="#A58BE7">
          <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#8461D3" Offset="0"/><GradientStop Color="#6753BB" Offset="0.62"/><GradientStop Color="#426D98" Offset="1"/></LinearGradientBrush></Border.Background>
          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Chrome" Property="BorderBrush" Value="#E3CEFF"/><Setter TargetName="Chrome" Property="Opacity" Value="0.9"/></Trigger>
          <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Chrome" Property="BorderThickness" Value="2"/><Setter TargetName="Chrome" Property="BorderBrush" Value="#FFFFFF"/></Trigger>
          <Trigger Property="IsPressed" Value="True"><Setter TargetName="Chrome" Property="Opacity" Value="0.72"/></Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Chrome" Property="Opacity" Value="0.38"/><Setter Property="Foreground" Value="#B5ABCB"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
  </Window.Resources>
  <Window.Triggers>
    <EventTrigger RoutedEvent="Window.Loaded"><BeginStoryboard><Storyboard>
      <DoubleAnimation Storyboard.TargetName="RootSurface" Storyboard.TargetProperty="Opacity" From="0" To="1" Duration="0:0:0.3"/>
    </Storyboard></BeginStoryboard></EventTrigger>
  </Window.Triggers>
  <Viewbox Stretch="Uniform">
    <Border x:Name="RootSurface" Width="1120" Height="760" CornerRadius="22" BorderThickness="1" BorderBrush="#292A40" AllowDrop="True">
      <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#111322" Offset="0"/><GradientStop Color="#0C0E18" Offset="0.53"/><GradientStop Color="#141225" Offset="1"/></LinearGradientBrush></Border.Background>
      <Grid Margin="32,15,32,18">
        <Grid.RowDefinitions><RowDefinition Height="35"/><RowDefinition Height="74"/><RowDefinition Height="*"/><RowDefinition Height="32"/></Grid.RowDefinitions>
        <Grid x:Name="DragBar" Background="Transparent" Grid.Row="0">
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
            <Ellipse Width="5" Height="5" Fill="#8B6EC7" Margin="0,0,8,0"/>
            <TextBlock Text="UM NOVO OLHAR PARA O SEU DESKTOP" FontSize="9" Foreground="#73768F" VerticalAlignment="Center"/>
          </StackPanel>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
            <Button x:Name="MinimizeButton" Style="{StaticResource WindowButton}" ToolTip="Minimizar" AutomationProperties.Name="Minimizar janela"><Path Data="M 0,5 L 11,5" Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}" StrokeThickness="1.3"/></Button>
            <Button x:Name="CloseButton" Style="{StaticResource WindowButton}" Margin="3,0,0,0" ToolTip="Fechar" AutomationProperties.Name="Fechar janela"><Path Data="M 1,1 L 10,10 M 10,1 L 1,10" Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}" StrokeThickness="1.3"/></Button>
          </StackPanel>
        </Grid>
        <Grid Grid.Row="1" Margin="0,5,0,20">
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
            <Border Width="41" Height="41" CornerRadius="13" BorderBrush="#5B447D" BorderThickness="1" Margin="0,0,13,0">
              <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#3F2C5F"/><GradientStop Color="#1C2339" Offset="1"/></LinearGradientBrush></Border.Background>
              <Grid><Path Data="M 9,28 L 20,10 L 31,28 M 14,22 L 26,22" Stroke="#D2BDFC" StrokeThickness="1.8" StrokeLineJoin="Round"/><Ellipse Width="5" Height="5" Fill="#8BDBE8" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,7,7,0"/></Grid>
            </Border>
            <StackPanel><TextBlock Text="A U R A" FontSize="23" FontWeight="SemiBold" Foreground="#F9F5FF"/><TextBlock Text="W A L L P A P E R   S T U D I O" FontSize="8" Foreground="#9291AA" Margin="1,1,0,0"/></StackPanel>
          </StackPanel>
          <Border HorizontalAlignment="Right" VerticalAlignment="Center" CornerRadius="13" BorderBrush="#292D3F" BorderThickness="1" Background="#111725" Padding="11,6">
            <StackPanel Orientation="Horizontal"><Ellipse Width="5" Height="5" Fill="#88CFB4" VerticalAlignment="Center" Margin="0,0,7,0"/><TextBlock Text="100% LOCAL" FontSize="9" Foreground="#A8B7B6"/><TextBlock Text="  /  OFFLINE" FontSize="9" Foreground="#696F87"/></StackPanel>
          </Border>
        </Grid>
        <Grid Grid.Row="2" Margin="0,0,0,10">
          <Grid.ColumnDefinitions><ColumnDefinition Width="680"/><ColumnDefinition Width="28"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
          <Grid Grid.Column="0">
            <Grid.RowDefinitions><RowDefinition Height="127"/><RowDefinition Height="383"/><RowDefinition Height="*"/></Grid.RowDefinitions>
            <StackPanel Grid.Row="0">
              <TextBlock FontSize="40" FontWeight="SemiBold" LineHeight="45" LineStackingStrategy="BlockLineHeight"><Run Text="Seu desktop."/><LineBreak/><Run Text="Outra dimensão." Foreground="#C5B1F2"/></TextBlock>
              <TextBlock Text="Transforme uma imagem no seu lugar favorito." Foreground="#9699B1" FontSize="12" Margin="1,14,0,0"/>
            </StackPanel>
            <Border Grid.Row="1" CornerRadius="18" BorderBrush="#38374E" BorderThickness="1" Background="#111827">
              <Grid>
                <Grid.Clip><RectangleGeometry Rect="0,0,678,381" RadiusX="17" RadiusY="17"/></Grid.Clip>
                <Grid x:Name="DemoArtwork">
                  <Grid.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#0C1424" Offset="0"/><GradientStop Color="#151730" Offset="0.38"/><GradientStop Color="#302548" Offset="0.72"/><GradientStop Color="#081522" Offset="1"/></LinearGradientBrush></Grid.Background>
                  <Canvas Width="678" Height="381">
                    <Ellipse Width="560" Height="410" Canvas.Left="240" Canvas.Top="-160" Opacity="0.6"><Ellipse.Fill><RadialGradientBrush><GradientStop Color="#7860AE" Offset="0"/><GradientStop Color="#00645192" Offset="1"/></RadialGradientBrush></Ellipse.Fill></Ellipse>
                    <Ellipse Width="420" Height="360" Canvas.Left="-170" Canvas.Top="125" Opacity="0.35"><Ellipse.Fill><RadialGradientBrush><GradientStop Color="#318F9A" Offset="0"/><GradientStop Color="#00163641" Offset="1"/></RadialGradientBrush></Ellipse.Fill></Ellipse>
                    <Path Data="M -100,355 C 94,374 81,120 268,112 C 445,103 383,360 562,278 C 661,233 620,90 797,40 L 800,410 L -100,410 Z" Opacity="0.85">
                      <Path.Fill><LinearGradientBrush StartPoint="0.05,0.25" EndPoint="0.92,0.72"><GradientStop Color="#174958" Offset="0"/><GradientStop Color="#455B8B" Offset="0.3"/><GradientStop Color="#9771BC" Offset="0.51"/><GradientStop Color="#5E4389" Offset="0.7"/><GradientStop Color="#16394C" Offset="1"/></LinearGradientBrush></Path.Fill>
                    </Path>
                    <Path Data="M -80,336 C 116,394 102,131 268,129 C 439,127 391,372 567,291 C 674,241 650,126 772,95" StrokeThickness="2" Opacity="0.8"><Path.Stroke><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#295C77"/><GradientStop Color="#E3BDFA" Offset="0.49"/><GradientStop Color="#656BA7" Offset="1"/></LinearGradientBrush></Path.Stroke></Path>
                    <Path Data="M -115,454 C 104,317 126,68 294,153 C 427,221 369,464 594,352 C 710,294 683,165 819,160 L 820,500 L -115,500 Z">
                      <Path.Fill><LinearGradientBrush StartPoint="0.12,0.08" EndPoint="0.85,0.95"><GradientStop Color="#759FAF" Offset="0"/><GradientStop Color="#3A5C7C" Offset="0.16"/><GradientStop Color="#403957" Offset="0.39"/><GradientStop Color="#0C1628" Offset="0.69"/><GradientStop Color="#101B30" Offset="1"/></LinearGradientBrush></Path.Fill>
                    </Path>
                    <Path Data="M -70,419 C 80,333 147,82 295,159 C 426,229 381,458 594,354 C 710,297 710,192 770,181" StrokeThickness="1.1" Opacity="0.75"><Path.Stroke><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#8DDFE7"/><GradientStop Color="#BBA7D4" Offset="0.4"/><GradientStop Color="#234361" Offset="1"/></LinearGradientBrush></Path.Stroke></Path>
                    <Path Data="M -80,416 C 104,408 145,236 302,274 C 447,310 419,429 689,315 L 760,440 Z" Fill="#0D1425" Opacity="0.76"/>
                    <Path Data="M -80,411 C 104,403 145,234 302,273 C 447,309 419,425 689,312" Stroke="#6C7798" StrokeThickness="0.6" Opacity="0.38"/>
                  </Canvas>
                </Grid>
                <Image x:Name="PreviewImage" Visibility="Collapsed" Stretch="UniformToFill" HorizontalAlignment="Stretch" VerticalAlignment="Stretch" RenderOptions.BitmapScalingMode="HighQuality"/>
                <Border VerticalAlignment="Top" Height="93"><Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#68080B14"/><GradientStop Color="#00080B14" Offset="1"/></LinearGradientBrush></Border.Background></Border>
                <Border HorizontalAlignment="Left" VerticalAlignment="Top" Margin="18" CornerRadius="8" Background="#70131623" BorderBrush="#405B607B" BorderThickness="1" Padding="9,5"><StackPanel Orientation="Horizontal"><Ellipse Width="4" Height="4" Fill="#BAAAE6" Margin="0,0,6,0" VerticalAlignment="Center"/><TextBlock Text="PRÉVIA EM 16:9" FontSize="9" Foreground="#E1DDEE"/></StackPanel></Border>
                <TextBlock x:Name="DemoLabel" Text="DEMONSTRAÇÃO" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,26,21,0" FontSize="8" Foreground="#A7A5BE"/>
                <StackPanel x:Name="DemoCaption" HorizontalAlignment="Left" VerticalAlignment="Bottom" Margin="26,0,0,61" IsHitTestVisible="False"><TextBlock Text="MAKE ROOM" FontSize="9" Foreground="#AFC0D7"/><TextBlock Text="for inspiration." FontSize="23" Foreground="#F0EDF8" FontWeight="Light" Margin="0,3,0,0"/></StackPanel>
                <Border HorizontalAlignment="Center" VerticalAlignment="Bottom" Margin="0,0,0,15" CornerRadius="13" Background="#D21A2033" BorderBrush="#52657089" BorderThickness="1" Padding="10,7" IsHitTestVisible="False">
                  <StackPanel Orientation="Horizontal">
                    <Grid Width="19" Height="19" Margin="3,0,11,0"><Grid.RowDefinitions><RowDefinition/><RowDefinition/></Grid.RowDefinitions><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition/></Grid.ColumnDefinitions><Rectangle Margin="0,0,1,1" Fill="#92BBDC" RadiusX="1" RadiusY="1"/><Rectangle Grid.Column="1" Margin="1,0,0,1" Fill="#92BBDC" RadiusX="1" RadiusY="1"/><Rectangle Grid.Row="1" Margin="0,1,1,0" Fill="#92BBDC" RadiusX="1" RadiusY="1"/><Rectangle Grid.Row="1" Grid.Column="1" Margin="1,1,0,0" Fill="#92BBDC" RadiusX="1" RadiusY="1"/></Grid>
                    <Border Width="1" Height="18" Background="#49536B" Margin="0,0,11,0"/>
                    <Border Width="20" Height="19" Background="#BFAA78" CornerRadius="4" Margin="0,0,10,0"><Rectangle Fill="#E2CB91" Height="12" RadiusX="3" RadiusY="3" VerticalAlignment="Bottom"/></Border>
                    <Ellipse Width="19" Height="19" Margin="0,0,10,0"><Ellipse.Fill><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#8EA8D7"/><GradientStop Color="#61BDBB" Offset="1"/></LinearGradientBrush></Ellipse.Fill></Ellipse>
                    <Border Width="19" Height="19" CornerRadius="5" Background="#9C83C5" Margin="0,0,10,0"><Path Data="M 5,13 L 9,5 L 13,13 M 7,10 L 11,10" Stroke="#F8EEFF" StrokeThickness="1.2"/></Border>
                    <Border Width="19" Height="19" CornerRadius="5" Background="#66728F"><Ellipse Width="9" Height="9" Stroke="#BFC5D5" StrokeThickness="1.6"/></Border>
                  </StackPanel>
                </Border>
              </Grid>
            </Border>
            <Grid Grid.Row="2" Margin="1,16,1,0" VerticalAlignment="Top">
              <StackPanel Orientation="Horizontal"><Path Data="M 1,4 L 1,1 L 5,1 M 1,10 L 1,13 L 5,13 M 13,4 L 13,1 L 9,1 M 13,10 L 13,13 L 9,13" Stroke="#737A94" StrokeThickness="1" Margin="0,0,8,0"/><TextBlock Text="Prévia ilustrativa • preenchimento com recorte central" FontSize="10" Foreground="#787E96" VerticalAlignment="Center"/></StackPanel>
              <TextBlock Text="SEU ESPAÇO, SUA IDENTIDADE" FontSize="8" Foreground="#666980" HorizontalAlignment="Right" VerticalAlignment="Center"/>
            </Grid>
          </Grid>
          <Border Grid.Column="2" VerticalAlignment="Top" CornerRadius="19" BorderThickness="1" BorderBrush="#2D2D43" Padding="21,20,21,14">
            <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0.9,1"><GradientStop Color="#1A1A2D"/><GradientStop Color="#121522" Offset="1"/></LinearGradientBrush></Border.Background>
            <StackPanel>
              <TextBlock Text="Crie sua atmosfera" FontSize="19" FontWeight="SemiBold"/>
              <TextBlock Text="Uma imagem. Um novo começo." FontSize="10.5" Foreground="#9899B3" Margin="0,7,0,16"/>
              <Button x:Name="ChooseButton" Style="{StaticResource ChooseStyle}" ToolTip="Escolher uma foto do computador" AutomationProperties.Name="Escolher foto">
                <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="40"/><ColumnDefinition Width="*"/><ColumnDefinition Width="15"/></Grid.ColumnDefinitions>
                  <Border Width="30" Height="30" Background="#342946" CornerRadius="9" HorizontalAlignment="Left"><Grid><Rectangle Width="16" Height="13" RadiusX="2" RadiusY="2" Stroke="#C5ACEA" StrokeThickness="1.2"/><Path Data="M 8,19 L 12,14 L 16,18 L 19,15 L 23,20" Stroke="#C5ACEA" StrokeThickness="1.1"/><Ellipse Width="3" Height="3" Fill="#C5ACEA" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="10,10,0,0"/></Grid></Border>
                  <StackPanel Grid.Column="1" VerticalAlignment="Center"><TextBlock Text="Escolher foto" FontSize="13" FontWeight="SemiBold"/><TextBlock Text="ou arraste a imagem para cá" FontSize="9" Foreground="#A499BA" Margin="0,4,0,0"/></StackPanel>
                  <Path Grid.Column="2" Data="M 1,6 L 10,6 M 6,2 L 10,6 L 6,10" Stroke="#BBA5DA" StrokeThickness="1.2" VerticalAlignment="Center"/>
                </Grid>
              </Button>
              <TextBlock x:Name="FileName" Text="Nenhuma imagem selecionada" FontSize="10.5" Foreground="#C0BED2" Margin="2,10,0,0" TextTrimming="CharacterEllipsis"/>
              <TextBlock x:Name="ImageInfo" Text="JPG, PNG ou BMP • do seu computador" FontSize="9" Foreground="#757C95" Margin="2,5,0,0" TextTrimming="CharacterEllipsis"/>
              <Grid Margin="1,19,0,10"><TextBlock Text="RESOLUÇÃO DE SAÍDA" FontSize="9" FontWeight="SemiBold" Foreground="#A6A3BA"/><TextBlock Text="ATÉ 8K" FontSize="8" Foreground="#9986BD" HorizontalAlignment="Right"/></Grid>
              <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="9"/><ColumnDefinition/></Grid.ColumnDefinitions><Grid.RowDefinitions><RowDefinition/><RowDefinition Height="9"/><RowDefinition/></Grid.RowDefinitions>
                <RadioButton x:Name="OriginalRadio" GroupName="Resolution" IsChecked="True" Style="{StaticResource ResolutionTile}" ToolTip="Manter a resolução da foto" AutomationProperties.Name="Resolução original"><StackPanel><TextBlock Text="Original" FontSize="12" FontWeight="SemiBold"/><TextBlock Text="Da sua imagem" FontSize="9" Foreground="#959AB0" Margin="0,5,0,0"/></StackPanel></RadioButton>
                <RadioButton x:Name="FullHDRadio" Grid.Column="2" GroupName="Resolution" Style="{StaticResource ResolutionTile}" ToolTip="1920 por 1080 pixels" AutomationProperties.Name="Full HD, 1920 por 1080"><StackPanel><TextBlock Text="Full HD" FontSize="12" FontWeight="SemiBold"/><TextBlock Text="1920 × 1080" FontSize="9" Foreground="#959AB0" Margin="0,5,0,0"/></StackPanel></RadioButton>
                <RadioButton x:Name="FourKRadio" Grid.Row="2" GroupName="Resolution" Style="{StaticResource ResolutionTile}" ToolTip="3840 por 2160 pixels" AutomationProperties.Name="4K, 3840 por 2160"><StackPanel><TextBlock Text="4K UHD" FontSize="12" FontWeight="SemiBold"/><TextBlock Text="3840 × 2160" FontSize="9" Foreground="#959AB0" Margin="0,5,0,0"/></StackPanel></RadioButton>
                <RadioButton x:Name="EightKRadio" Grid.Row="2" Grid.Column="2" GroupName="Resolution" Style="{StaticResource ResolutionTile}" ToolTip="7680 por 4320 pixels" AutomationProperties.Name="8K, 7680 por 4320"><StackPanel><TextBlock Text="8K Ultra" FontSize="12" FontWeight="SemiBold"/><TextBlock Text="7680 × 4320" FontSize="9" Foreground="#959AB0" Margin="0,5,0,0"/></StackPanel></RadioButton>
              </Grid>
              <TextBlock x:Name="OutputInfo" Text="Resolução original • sem ampliação" FontSize="9.5" Foreground="#B3A5CE" Margin="1,12,0,0" Height="14" TextTrimming="CharacterEllipsis"/>
              <TextBlock x:Name="ResizeNote" Text="Ampliar não recupera detalhes. O recorte central pode cortar bordas." FontSize="9" LineHeight="14" Foreground="#7C829B" Margin="1,7,0,12" Height="28" TextWrapping="Wrap"/>
              <Button x:Name="ApplyButton" Style="{StaticResource ApplyStyle}" IsEnabled="False" ToolTip="Aplicar a foto como papel de parede do Windows" AutomationProperties.Name="Aplicar wallpaper"><StackPanel Orientation="Horizontal"><TextBlock x:Name="ApplyLabel" Text="Aplicar wallpaper"/><Path Data="M 1,6 L 12,6 M 8,2 L 12,6 L 8,10" Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}" StrokeThickness="1.4" Margin="13,0,0,0" VerticalAlignment="Center"/></StackPanel></Button>
              <Grid Height="9"><ProgressBar x:Name="BusyProgress" Height="3" IsIndeterminate="True" Visibility="Collapsed" Foreground="#AF93E3" Background="#272338" BorderThickness="0" Margin="3,6,3,0"/></Grid>
              <TextBlock x:Name="StatusText" Text="Escolha uma foto para começar." FontSize="9" Foreground="#9398B0" TextWrapping="Wrap" LineHeight="14" Margin="2,6,2,0" Height="28"/>
            </StackPanel>
          </Border>
        </Grid>
        <Grid Grid.Row="3" VerticalAlignment="Bottom" Margin="0,0,0,2">
          <Border Height="1" Background="#252638" VerticalAlignment="Top" Margin="0,-12,0,0"/>
          <TextBlock Text="Feito para o seu espaço." Foreground="#757B92" FontSize="10"/>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right"><TextBlock Text="AURA STUDIO" Foreground="#9286B0" FontSize="8"/><TextBlock Text="  /  WALLPAPER, COM PERSONALIDADE" Foreground="#62687F" FontSize="8"/></StackPanel>
        </Grid>
      </Grid>
    </Border>
  </Viewbox>
</Window>

'@

function New-AuraBrush([string]$Color) {
    return (New-Object System.Windows.Media.BrushConverter).ConvertFromString($Color)
}

function Read-AuraPreview([string]$Path) {
    $source = $null; $thumb = $null; $drawing = $null; $stream = $null
    try {
        $source = [Drawing.Image]::FromFile($Path)
        if ($source.PropertyIdList -contains 274) {
            $orientation = [BitConverter]::ToUInt16($source.GetPropertyItem(274).Value, 0)
            $transform = @{ 2=4; 3=2; 4=6; 5=5; 6=1; 7=7; 8=3 }
            if ($transform.ContainsKey([int]$orientation)) { $source.RotateFlip([Drawing.RotateFlipType]$transform[[int]$orientation]) }
        }
        $originalWidth = $source.Width; $originalHeight = $source.Height
        $ratio = [Math]::Min(1.0, 1440.0 / [Math]::Max($source.Width, $source.Height))
        $width = [Math]::Max(1, [int][Math]::Round($source.Width * $ratio))
        $height = [Math]::Max(1, [int][Math]::Round($source.Height * $ratio))
        $thumb = New-Object Drawing.Bitmap($width, $height, [Drawing.Imaging.PixelFormat]::Format24bppRgb)
        $drawing = [Drawing.Graphics]::FromImage($thumb)
        $drawing.Clear([Drawing.Color]::FromArgb(10, 13, 24))
        $drawing.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $drawing.DrawImage($source, 0, 0, $width, $height)
        $stream = New-Object IO.MemoryStream
        $thumb.Save($stream, [Drawing.Imaging.ImageFormat]::Png)
        $stream.Position = 0
        $image = New-Object Windows.Media.Imaging.BitmapImage
        $image.BeginInit()
        $image.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $image.StreamSource = $stream
        $image.EndInit()
        $image.Freeze()
        return [pscustomobject]@{ Image=$image; Width=$originalWidth; Height=$originalHeight }
    } finally {
        if ($drawing) { $drawing.Dispose() }
        if ($thumb) { $thumb.Dispose() }
        if ($source) { $source.Dispose() }
        if ($stream) { $stream.Dispose() }
    }
}

function Set-AuraStatus([string]$Text, [string]$Color = '#9399B7') {
    $script:UI.StatusText.Text = $Text
    $script:UI.StatusText.Foreground = New-AuraBrush $Color
}

function Update-AuraResolution {
    $script:Resolution = 'Original'
    if ($script:UI.FullHDRadio.IsChecked) { $script:Resolution = 'FullHD' }
    if ($script:UI.FourKRadio.IsChecked) { $script:Resolution = '4K' }
    if ($script:UI.EightKRadio.IsChecked) { $script:Resolution = '8K' }
    $dimensions = switch ($script:Resolution) {
        'FullHD' { '1920 × 1080 pixels' }
        '4K' { '3840 × 2160 pixels' }
        '8K' { '7680 × 4320 pixels' }
        default {
            if ($script:SelectedImage) { '{0} × {1} pixels' -f $script:SelectedImage.Width, $script:SelectedImage.Height }
            else { 'Preserva a resolução da foto' }
        }
    }
    $script:UI.OutputInfo.Text = $dimensions
    if ($script:SelectedPath -and -not $script:Busy) {
        $script:UI.ApplyLabel.Text = 'Aplicar wallpaper'
        Set-AuraStatus 'Tudo pronto. Dê vida ao seu desktop.' '#A7AED0'
    }
}

function Select-AuraImage([string]$Path) {
    if ($script:Busy) { return }
    try {
        if (-not [IO.File]::Exists($Path)) { throw 'Não foi possível encontrar essa imagem.' }
        if ([IO.Path]::GetExtension($Path).ToLowerInvariant() -notin @('.jpg','.jpeg','.png','.bmp')) {
            throw 'Escolha uma foto JPG, PNG ou BMP.'
        }
        $preview = Read-AuraPreview $Path
        $script:SelectedPath = [IO.Path]::GetFullPath($Path)
        $script:SelectedImage = $preview
        $script:UI.PreviewImage.Source = $preview.Image
        $script:UI.PreviewImage.Visibility = 'Visible'
        $script:UI.DemoArtwork.Visibility = 'Collapsed'
        $script:UI.DemoLabel.Visibility = 'Collapsed'
        $script:UI.DemoCaption.Visibility = 'Collapsed'
        $script:UI.FileName.Text = [IO.Path]::GetFileName($Path)
        $script:UI.FileName.ToolTip = $script:SelectedPath
        $script:UI.ImageInfo.Text = '{0} × {1} px  ·  {2}' -f $preview.Width, $preview.Height, [IO.Path]::GetExtension($Path).TrimStart('.').ToUpperInvariant()
        $script:UI.ApplyButton.IsEnabled = $true
        Update-AuraResolution
    } catch {
        Set-AuraStatus 'Não consegui abrir a foto. Tente outra imagem.' '#FFB2BC'
        [void][Windows.MessageBox]::Show($script:Window, $_.Exception.Message, 'AURA · Escolher imagem', 'OK', 'Warning')
    }
}

function Set-AuraBusy([bool]$Value) {
    $script:Busy = $Value
    $script:UI.ChooseButton.IsEnabled = -not $Value
    foreach ($name in @('OriginalRadio','FullHDRadio','FourKRadio','EightKRadio')) {
        $script:UI[$name].IsEnabled = -not $Value
    }
    $script:UI.ApplyButton.IsEnabled = (-not $Value) -and [bool]$script:SelectedPath
    $script:UI.BusyProgress.Visibility = if ($Value) { 'Visible' } else { 'Collapsed' }
    $script:UI.ApplyLabel.Text = if ($Value) { 'Preparando sua atmosfera…' } else { 'Aplicar wallpaper' }
}

function Start-AuraApply {
    if ($script:Busy -or -not $script:SelectedPath) { return }
    try {
        Set-AuraBusy $true
        Set-AuraStatus 'Processando a imagem. Só mais um instante…' '#C1ADFF'
        $script:Worker = [PowerShell]::Create()
        [void]$script:Worker.AddScript($script:EngineSource)
        [void]$script:Worker.AddStatement().AddCommand('Invoke-AuraWallpaper').AddParameter('ImagePath', $script:SelectedPath).AddParameter('Resolution', $script:Resolution)
        $script:WorkHandle = $script:Worker.BeginInvoke()
        $script:PollTimer.Start()
    } catch {
        if ($script:Worker) { $script:Worker.Dispose(); $script:Worker = $null }
        $script:WorkHandle = $null
        Set-AuraBusy $false
        Set-AuraStatus 'Não foi possível iniciar. Tente novamente.' '#FFB2BC'
        [void][Windows.MessageBox]::Show($script:Window, $_.Exception.Message, 'AURA · Aplicar wallpaper', 'OK', 'Warning')
    }
}

$script:Window = [Windows.Markup.XamlReader]::Parse($xamlSource)
$script:UI = @{}
foreach ($name in @('DragBar','MinimizeButton','CloseButton','RootSurface','ChooseButton','FileName','ImageInfo','OriginalRadio','FullHDRadio','FourKRadio','EightKRadio','OutputInfo','ResizeNote','ApplyButton','ApplyLabel','BusyProgress','StatusText','DemoArtwork','DemoLabel','DemoCaption','PreviewImage')) {
    $script:UI[$name] = $script:Window.FindName($name)
    if ($null -eq $script:UI[$name]) { throw ('Controle ausente: ' + $name) }
}
$script:SelectedPath = $null
$script:SelectedImage = $null
$script:Resolution = 'Original'
$script:Busy = $false
$script:Worker = $null
$script:WorkHandle = $null
$script:PollTimer = New-Object Windows.Threading.DispatcherTimer
$script:PollTimer.Interval = [TimeSpan]::FromMilliseconds(160)

$script:PollTimer.Add_Tick({
    if ($script:WorkHandle -and $script:WorkHandle.IsCompleted) {
        $script:PollTimer.Stop()
        try {
            $results = @($script:Worker.EndInvoke($script:WorkHandle))
            if ($script:Worker.HadErrors) { throw $script:Worker.Streams.Error[0].ToString() }
            $result = $results | Where-Object { $_.PSObject.Properties.Name -contains 'OutputPath' } | Select-Object -Last 1
            if (-not $result) { throw 'O Windows não confirmou a alteração.' }
            Set-AuraBusy $false
            $script:UI.ApplyLabel.Text = 'Wallpaper aplicado  ✓'
            Set-AuraStatus ('Seu novo visual está pronto. {0} × {1} px.' -f $result.Width, $result.Height) '#7EE2C0'
        } catch {
            Set-AuraBusy $false
            Set-AuraStatus 'O Windows não concluiu a troca. Tente novamente.' '#FFB2BC'
            [void][Windows.MessageBox]::Show($script:Window, ($_.Exception.Message + "`n`nRestrições do Windows ou da organização podem impedir a troca."), 'AURA · Não foi possível aplicar', 'OK', 'Warning')
        } finally {
            if ($script:Worker) { $script:Worker.Dispose(); $script:Worker = $null }
            $script:WorkHandle = $null
        }
    }
})

$script:UI.ChooseButton.Add_Click({
    if ($script:Busy) { return }
    $picker = New-Object Microsoft.Win32.OpenFileDialog
    $picker.Title = 'AURA · Escolha sua próxima atmosfera'
    $picker.Filter = 'Imagens JPG, PNG e BMP|*.jpg;*.jpeg;*.png;*.bmp'
    $picker.CheckFileExists = $true
    $picker.Multiselect = $false
    $picker.InitialDirectory = [Environment]::GetFolderPath('MyPictures')
    if ($picker.ShowDialog($script:Window)) { Select-AuraImage $picker.FileName }
})
$script:UI.ApplyButton.Add_Click({ Start-AuraApply })
foreach ($name in @('OriginalRadio','FullHDRadio','FourKRadio','EightKRadio')) {
    $script:UI[$name].Add_Checked({ Update-AuraResolution })
}
$script:UI.CloseButton.Add_Click({ $script:Window.Close() })
$script:UI.MinimizeButton.Add_Click({ $script:Window.WindowState = 'Minimized' })
$script:UI.DragBar.Add_MouseLeftButtonDown({
    param($sender, $eventArgs)
    if ($eventArgs.ChangedButton -eq [Windows.Input.MouseButton]::Left) {
        try { $script:Window.DragMove() } catch { }
    }
})
$script:Window.Add_PreviewKeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.Key -eq 'Escape' -and -not $script:Busy) { $script:Window.Close(); $eventArgs.Handled = $true }
})
$script:UI.RootSurface.Add_DragOver({
    param($sender, $eventArgs)
    $eventArgs.Effects = [Windows.DragDropEffects]::None
    if (-not $script:Busy -and $eventArgs.Data.GetDataPresent([Windows.DataFormats]::FileDrop)) {
        $files = @($eventArgs.Data.GetData([Windows.DataFormats]::FileDrop))
        if ($files.Count -eq 1 -and [IO.Path]::GetExtension($files[0]).ToLowerInvariant() -in @('.jpg','.jpeg','.png','.bmp')) {
            $eventArgs.Effects = [Windows.DragDropEffects]::Copy
        }
    }
    $eventArgs.Handled = $true
})
$script:UI.RootSurface.Add_Drop({
    param($sender, $eventArgs)
    if (-not $script:Busy -and $eventArgs.Data.GetDataPresent([Windows.DataFormats]::FileDrop)) {
        $files = @($eventArgs.Data.GetData([Windows.DataFormats]::FileDrop))
        if ($files.Count -eq 1) { Select-AuraImage $files[0] }
    }
    $eventArgs.Handled = $true
})
$script:Window.Add_Closing({
    param($sender, $eventArgs)
    if ($script:Busy) {
        $eventArgs.Cancel = $true
        Set-AuraStatus 'Aguarde a aplicação terminar para fechar.' '#C1ADFF'
    } else {
        $script:PollTimer.Stop()
    }
})

Update-AuraResolution
if ($RenderPreviewPath) {
    if ($PreviewImagePath) { Select-AuraImage $PreviewImagePath }
    $radioName = @{ Original='OriginalRadio'; FullHD='FullHDRadio'; '4K'='FourKRadio'; '8K'='EightKRadio' }[$PreviewResolution]
    $script:UI[$radioName].IsChecked = $true
    $surface = $script:Window.Content
    $surface.Measure((New-Object Windows.Size(1120, 760)))
    $surface.Arrange((New-Object Windows.Rect(0, 0, 1120, 760)))
    $surface.UpdateLayout()
    $render = New-Object Windows.Media.Imaging.RenderTargetBitmap(1120, 760, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
    $render.Render($surface)
    $encoder = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($render))
    $outputStream = [IO.File]::Create($RenderPreviewPath)
    try { $encoder.Save($outputStream) } finally { $outputStream.Dispose() }
    $script:Window.Close()
    return
}

$workArea = [Windows.SystemParameters]::WorkArea
$scale = [Math]::Min(1.0, [Math]::Min(($workArea.Width - 32) / 1120, ($workArea.Height - 32) / 760))
$script:Window.Width = 1120 * $scale
$script:Window.Height = 760 * $scale
[void]$script:Window.ShowDialog()
