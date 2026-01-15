<#
    .SYNOPSIS
        Software Installer - A modern WPF GUI for Winget & MSStore.

    .DESCRIPTION
        Features:
        - Search & Install from Winget/MSStore repositories.
        - Backup & Restore installed packages (JSON).
        - Dark/Light mode support with system integration.
        - Async operations to prevent UI freezing.

    .NOTES
        Author:  Osman Onur Koç
        License: MIT License

    .LINK
        https://github.com/osmanonurkoc/WinGet_Installer
#>

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Add-Type -AssemblyName PresentationFramework, System.Windows.Forms, System.Drawing, WindowsBase

# --- NATIVE METHODS ---
$code = @"
using System;
using System.Runtime.InteropServices;

public class Win32 {
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("dwmapi.dll", PreserveSig = true)] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);

    public const int SW_HIDE = 0;
    public const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;

    public static void SetDarkMode(IntPtr hwnd, bool enabled) {
        int useDarkMode = enabled ? 1 : 0;
        DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, ref useDarkMode, sizeof(int));
    }
}
"@
if (-not ([System.Management.Automation.PSTypeName]'Win32').Type) { Add-Type -TypeDefinition $code -Language CSharp }

$hwnd = [Win32]::GetConsoleWindow()
if ($hwnd -ne [IntPtr]::Zero) { [Win32]::ShowWindow($hwnd, 0) }

# --- CONFIGURATION ---
$ScriptDir = $PSScriptRoot
$xmlPath = "$ScriptDir\config.xml"

if (-not (Test-Path "$ScriptDir\Programs")) {
    try {
        $parentProc = Get-CimInstance Win32_Process -Filter "ProcessId = $PID"
        $parentPath = (Get-Process -Id $parentProc.ParentProcessId -ErrorAction SilentlyContinue).Path
        $potentialDir = Split-Path $parentPath -Parent
        if (Test-Path "$potentialDir\config.xml") { $ScriptDir = $potentialDir; $xmlPath = "$potentialDir\config.xml" }
    } catch {}
}

$configLoaded = $false
if (Test-Path $xmlPath) { try { [xml]$config = Get-Content $xmlPath -Raw -ErrorAction Stop; $configLoaded = $true } catch {} }

# --- STATE VARIABLES ---
$script:selectionState = @{}
$script:RepoCache = @()
$script:isRepoFetched = $false
$script:activeProcess = $null
$script:activeOperation = ""

# --- TIMER (ASYNC HANDLER) ---
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(200)

# --- XAML UI ---
[xml]$xaml = @"
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Software Installer @osmanonurkoc" Height="850" Width="1200"
    WindowStartupLocation="CenterScreen"
    Background="{DynamicResource BgBase}">

    <Window.Resources>
        <Style x:Key="ScrollThumbStyle" TargetType="{x:Type Thumb}">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type Thumb}">
                        <Border CornerRadius="4" Background="{TemplateBinding Background}" Margin="0" />
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="{x:Type ScrollBar}">
            <Setter Property="Stylus.IsFlicksEnabled" Value="false" />
            <Setter Property="Foreground" Value="{DynamicResource ScrollThumb}" />
            <Setter Property="Background" Value="Transparent" />
            <Setter Property="Width" Value="8" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type ScrollBar}">
                        <Grid x:Name="GridRoot" Width="8" Background="{TemplateBinding Background}">
                            <Track x:Name="PART_Track" IsDirectionReversed="true" Focusable="false">
                                <Track.Thumb>
                                    <Thumb x:Name="Thumb" Background="{TemplateBinding Foreground}" Style="{DynamicResource ScrollThumbStyle}"/>
                                </Track.Thumb>
                            </Track>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="GridViewColumnHeader">
            <Setter Property="Background" Value="{DynamicResource BgInput}" />
            <Setter Property="Foreground" Value="{DynamicResource TextPrimary}" />
            <Setter Property="Padding" Value="10,8" />
            <Setter Property="HorizontalContentAlignment" Value="Left" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="GridViewColumnHeader">
                        <Border Background="{TemplateBinding Background}" BorderThickness="0,0,1,1" BorderBrush="{DynamicResource BorderColor}">
                            <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center" SnapsToDevicePixels="True"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="ListViewItem">
            <Setter Property="HorizontalContentAlignment" Value="Stretch" />
            <Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ListViewItem">
                        <Border x:Name="Bd" Background="Transparent" BorderBrush="Transparent" BorderThickness="0,0,0,1" Padding="5">
                             <GridViewRowPresenter HorizontalAlignment="Stretch" VerticalAlignment="{TemplateBinding VerticalContentAlignment}" />
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="{DynamicResource BgHover}" />
                            </Trigger>
                            <Trigger Property="IsSelected" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="{DynamicResource AccentLow}" />
                                <Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource Accent}" />
                                <Setter TargetName="Bd" Property="BorderThickness" Value="4,0,0,1" />
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="Margin" Value="0,6"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="CheckBox">
                        <StackPanel Orientation="Horizontal">
                            <Border Name="box" Width="20" Height="20" CornerRadius="4" BorderThickness="1" BorderBrush="{DynamicResource BorderColor}" Background="{DynamicResource BgInput}">
                                <Path Name="check" Data="M 3,9 L 8,14 L 17,3" Stroke="{DynamicResource Accent}" StrokeThickness="2.5" Visibility="Collapsed" Margin="0"/>
                            </Border>
                            <ContentPresenter Margin="12,0,0,0" VerticalAlignment="Center"/>
                        </StackPanel>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="check" Property="Visibility" Value="Visible"/>
                                <Setter TargetName="box" Property="BorderBrush" Value="{DynamicResource Accent}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="Button" x:Key="FluentButton">
            <Setter Property="Background" Value="{DynamicResource BgCard}"/>
            <Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Padding" Value="15,10"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="BorderBrush" Value="{DynamicResource BorderColor}"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Name="brd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="brd" Property="Background" Value="{DynamicResource BgHover}"/>
                            </Trigger>
                             <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Opacity" Value="0.6"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="Button" x:Key="IconButton">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Name="brd" Background="{TemplateBinding Background}" CornerRadius="6">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="brd" Property="Background" Value="{DynamicResource BgHover}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="TabItem">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TabItem">
                        <Border Name="Border" Padding="15,12" Background="Transparent" CornerRadius="6" Margin="0,2">
                            <StackPanel Orientation="Horizontal">
                                <Rectangle Name="Indicator" Width="4" Height="18" Fill="{DynamicResource Accent}" Visibility="Hidden" Margin="0,0,12,0" RadiusX="2" RadiusY="2"/>
                                <ContentPresenter ContentSource="Header" TextElement.Foreground="{DynamicResource TextSecondary}" TextElement.FontSize="14" TextElement.FontWeight="Medium"/>
                            </StackPanel>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsSelected" Value="True">
                                <Setter TargetName="Border" Property="Background" Value="{DynamicResource BgCard}"/>
                                <Setter TargetName="Indicator" Property="Visibility" Value="Visible"/>
                                <Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Border" Property="Background" Value="{DynamicResource BgHover}"/>
                                <Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="TextBox">
            <Setter Property="Background" Value="{DynamicResource BgInput}"/>
            <Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource BorderColor}"/>
            <Setter Property="Padding" Value="10,8"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TextBox">
                        <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6">
                            <ScrollViewer x:Name="PART_ContentHost"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Viewbox x:Key="IconMoon"><Path Fill="{DynamicResource IconBrush}" Stretch="Uniform" Data="m 69.492851,31.587218 q 1.201475,0 2.170408,-0.581359 1.007692,-0.620117 1.589051,-1.58905 0.620117,-1.00769 0.620117,-2.209168 0,-1.240234 -0.620117,-2.209167 -0.581359,-1.00769 -1.589051,-1.589051 -0.968933,-0.620117 -2.170408,-0.620117 -1.201479,0 -2.209168,0.620117 -1.00769,0.581361 -1.589051,1.589051 -0.581361,0.968933 -0.581361,2.209167 0,1.201478 0.581361,2.209168 0.581361,0.968933 1.589051,1.58905 1.007689,0.581359 2.209168,0.581359 z M 33.409783,67.554014 q 1.201476,0 2.170409,-0.620117 1.007689,-0.581359 1.58905,-1.589048 0.620117,-0.968933 0.620117,-2.170411 0,-1.240235 -0.620117,-2.209168 -0.581361,-1.007689 -1.58905,-1.58905 -0.968933,-0.620118 -2.170409,-0.620118 -1.201478,0 -2.209168,0.620118 -1.007692,0.581361 -1.58905,1.58905 -0.581361,0.968933 -0.581361,2.209168 0,1.201478 0.581361,2.170411 0.581358,1.007689 1.58905,1.589048 1.00769,0.620117 2.209168,0.620117 z M 73.639885,42.28424 q 0,-0.736389 -0.387575,-1.356506 -0.387572,-0.658876 -1.00769,-1.007689 -0.620117,-0.387575 -1.395264,-0.387575 -0.736388,0 -1.395264,0.387575 -0.620117,0.348813 -1.00769,1.007689 -0.348816,0.620117 -0.348816,1.356506 0,0.775147 0.348816,1.43402 0.387573,0.620117 1.00769,1.007692 0.658876,0.348816 1.395264,0.348816 0.775147,0 1.395264,-0.348816 0.620118,-0.387575 1.00769,-1.007692 0.387575,-0.658873 0.387575,-1.43402 z M 56.896721,61.856688 q 2.325439,0 4.224546,-1.123963 1.899111,-1.123961 3.023074,-3.023071 1.162719,-1.937866 1.162719,-4.224546 0,-2.325442 -1.162719,-4.224549 -1.123963,-1.899108 -3.023074,-3.023071 -1.899107,-1.16272 -4.224546,-1.16272 -2.286683,0 -4.224549,1.16272 -1.899108,1.123963 -3.023071,3.023071 -1.123963,1.899107 -1.123963,4.224549 0,2.28668 1.123963,4.224546 1.123963,1.89911 3.023071,3.023071 1.937866,1.123963 4.224549,1.123963 z M 55.966544,9.1467283 v 0 q 0.891418,3.6431877 0.968933,7.5964357 0.07751,3.953248 -0.930174,8.139038 -1.47278,6.356202 -5.270998,11.627197 -3.798218,5.232238 -9.224243,8.759155 -5.426024,3.488159 -11.820982,4.650878 v 0 Q 24.418083,50.888365 19.53466,50.268248 14.651238,49.609375 10.310417,47.749023 7.7911898,46.62506 5.4657511,47.361451 3.1790695,48.097839 1.8225632,49.725646 0.46605668,51.27594 0.07848364,53.562623 q -0.34881608,2.28668 0.85266106,4.534606 v 0 q 3.7594592,6.93756 9.6505733,12.169799 5.929871,5.232238 13.410033,8.177794 7.480165,2.984315 15.851746,3.023074 h 0.658876 q 2.906797,0 5.813597,-0.387575 v 0 q 7.480165,-1.00769 14.030153,-4.379577 6.549988,-3.33313 11.665952,-8.565369 5.115968,-5.193482 8.371584,-11.782226 3.255616,-6.627503 4.147034,-14.107666 h 0.03876 Q 85.499626,33.990174 83.639275,26.432494 81.817679,18.874817 77.670645,12.557374 73.56237,6.2011718 67.710014,1.5890502 l -0.03876,-0.038757 v 0 Q 65.617118,0 63.330435,0 61.082511,0 59.183403,1.2014769 57.284293,2.402954 56.31536,4.4958494 55.346427,6.5499876 55.966544,9.1467283 Z" /></Viewbox>
        <Viewbox x:Key="IconSun"><Path Fill="{DynamicResource IconBrush}" Stretch="Uniform"><Path.Data><GeometryGroup><PathGeometry Figures="M167,12.7c4,5.3,9.1,8.9,15.4,11,6.3,2.1,12.7,2.1,19,.1,6.6-2.1,13-2.1,19.2,0s11.2,5.9,15.1,11.1c4,5.2,6,11.2,6,18.2s2.1,12.6,5.9,18c3.9,5.4,9,9.1,15.4,11.1,6.5,2.2,11.7,6.1,15.4,11.4,3.7,5.3,5.7,11.2,5.9,17.7.2,6.5-1.8,12.6-5.9,18.3-3.8,5.4-5.7,11.4-5.7,18s1.9,12.6,5.7,18c4.1,5.7,6.1,11.8,5.9,18.3s-2.1,12.5-5.9,17.9c-3.7,5.3-8.8,9-15.4,11.3-6.3,2.1-11.5,5.8-15.4,11.1-3.8,5.4-5.8,11.4-5.9,18,0,6.9-2,13-6,18.2-3.9,5.3-8.9,9-15.1,11.1-6.2,2.1-12.5,2.1-19.2,0-6.3-2-12.7-1.9-19,.1-6.2,2.1-11.4,5.7-15.4,11-4.1,5.7-9.3,9.4-15.5,11.3s-12.5,1.9-18.8,0-11.4-5.6-15.5-11.3c-3.9-5.3-9-8.9-15.4-11-6.3-2.1-12.6-2.1-18.9-.1-6.6,2.1-13,2.1-19.2,0s-11.2-5.9-15.2-11.1c-3.9-5.2-5.9-11.2-6-18.2,0-6.6-2-12.6-5.9-18s-9-9.1-15.2-11.1c-6.6-2.2-11.8-6-15.5-11.3-3.7-5.2-5.7-11.2-5.9-17.7,0-6.5,1.9-12.6,5.9-18.3,3.9-5.4,5.9-11.4,5.9-18s-2-12.6-5.9-18c-4-5.8-5.9-11.9-5.9-18.4.2-6.5,2.1-12.5,5.9-17.7,3.7-5.4,8.9-9.2,15.5-11.4,6.2-2.1,11.3-5.8,15.2-11.1,3.9-5.4,5.9-11.4,5.9-18s2.1-13,6-18.2c4-5.3,9.1-9,15.2-11.1,6.2-2.1,12.5-2.1,19.2,0,6.3,2,12.5,1.9,18.9-.1,6.3-2.1,11.5-5.7,15.4-11,4.1-5.7,9.3-9.4,15.5-11.3,6.3-1.9,12.5-1.9,18.8,0,6.3,1.9,11.4,5.6,15.5,11.3h0ZM86.9,243.4c13.2,7.6,27,12.3,41.5,13.9,14.5,1.8,28.6.8,42.3-2.9,13.9-3.6,26.6-9.8,38.2-18.5,11.6-8.8,21.2-19.8,28.9-33,7.6-13.2,12.3-27,14.1-41.5,1.8-14.5.8-28.6-2.9-42.3-3.7-13.9-9.9-26.6-18.6-38.2-8.7-11.6-19.7-21.2-33-28.9-13.2-7.6-27-12.3-41.5-13.9-14.4-1.8-28.5-.8-42.3,2.9-13.9,3.6-26.6,9.8-38.2,18.6-11.6,8.7-21.2,19.6-28.9,32.8s-12.3,27-14.1,41.5c-1.7,14.5-.6,28.6,3.1,42.5,3.7,13.8,9.9,26.5,18.6,38.1s19.6,21.2,32.8,28.9Z" /><EllipseGeometry Center="142.1,147.7" RadiusX="87.5" RadiusY="87.5" /></GeometryGroup></Path.Data></Path></Viewbox>
        <Viewbox x:Key="IconPackage"><Path Fill="{DynamicResource IconBrush}" Stretch="Uniform" Data="M21,16.5C21,16.88 20.79,17.21 20.47,17.38L12.57,21.82C12.41,21.94 12.21,22 12,22C11.79,22 11.59,21.94 11.43,21.82L3.53,17.38C3.21,17.21 3,16.88 3,16.5V7.5C3,7.12 3.21,6.79 3.53,6.62L11.43,2.18C11.59,2.06 11.79,2 12,2C12.21,2 12.41,2.06 12.57,2.18L20.47,6.62C20.79,6.79 21,7.12 21,7.5V16.5M12,4.15L6.04,7.5L12,10.85L17.96,7.5L12,4.15M5,15.91L11,19.29V12.58L5,9.21V15.91M19,15.91V9.21L13,12.58V19.29L19,15.91Z" /></Viewbox>
        <Viewbox x:Key="IconBackup"><Path Fill="{DynamicResource IconBrush}" Stretch="Uniform" Data="M12,3A9,9 0 0,0 3,12H0L4,16L8,12H5A7,7 0 0,1 12,5A7,7 0 0,1 19,12A7,7 0 0,1 12,19C10.5,19 9.09,18.5 7.94,17.7L6.5,19.14C8.04,20.3 9.94,21 12,21A9,9 0 0,0 21,12A9,9 0 0,0 12,3M14,12A2,2 0 0,0 12,10A2,2 0 0,0 10,12A2,2 0 0,0 12,14A2,2 0 0,0 14,12Z"/></Viewbox>
    </Window.Resources>

    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/> <RowDefinition Height="*"/> <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <Border Grid.Row="0" Background="{DynamicResource BgBase}" Padding="25,20">
            <Grid>
                <StackPanel Orientation="Horizontal">
                    <ContentControl Content="{StaticResource IconPackage}" Width="32" Height="32" Margin="0,0,12,0"/>
                    <TextBlock Text="Software Installer" FontSize="20" FontWeight="Bold" Foreground="{DynamicResource TextPrimary}" VerticalAlignment="Center"/>
                    <TextBlock Name="txtAuthorLink" Text=" | www.osmanonurkoc.com" FontSize="14" Foreground="{DynamicResource TextSecondary}" VerticalAlignment="Center" Margin="5,4,0,0" Cursor="Hand"/>
                </StackPanel>
                <Button Name="btnThemeToggle" HorizontalAlignment="Right" Width="42" Height="42" Style="{StaticResource IconButton}">
                    <ContentControl Name="iconThemeHolder" Width="32" Height="32"/>
                </Button>
            </Grid>
        </Border>

        <Grid Grid.Row="1">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="240"/> <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <Border Grid.Column="0" Background="{DynamicResource BgBase}" Padding="15,0">
                <StackPanel>
                    <TabControl Name="tabCategories" BorderThickness="0" Background="Transparent" TabStripPlacement="Left" />
                    <Border Height="1" Background="{DynamicResource BorderColor}" Margin="10,15,10,15"/>
                    <TabControl Name="tabFixedTools" BorderThickness="0" Background="Transparent" TabStripPlacement="Left">
                        <TabItem Name="tabSearch" Header="Search Repo"/>
                        <TabItem Name="tabBackup" Header="Backup &amp; Restore"/>
                    </TabControl>
                </StackPanel>
            </Border>

            <Border Grid.Column="1" Background="{DynamicResource BgCard}" CornerRadius="8" Margin="0,0,15,15" Padding="25">
                 <Grid>
                    <Grid Name="viewCategory" Visibility="Visible">
                         <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/> <RowDefinition Height="*"/> <RowDefinition Height="Auto"/>
                         </Grid.RowDefinitions>
                         <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/> <ColumnDefinition Width="300"/>
                         </Grid.ColumnDefinitions>

                         <StackPanel Grid.Row="0" Grid.Column="0" Margin="0,0,0,20">
                             <TextBlock Name="txtCategoryTitle" Text="Select Category" FontSize="24" FontWeight="Bold" Foreground="{DynamicResource TextPrimary}"/>
                             <TextBlock Text="Choose applications to install from config." FontSize="14" Foreground="{DynamicResource TextSecondary}" Margin="0,5,0,0"/>
                         </StackPanel>

                         <ScrollViewer Grid.Row="1" Grid.Column="0" VerticalScrollBarVisibility="Auto">
                             <StackPanel Name="pnlWingetContent" />
                         </ScrollViewer>

                         <Border Grid.Row="0" Grid.RowSpan="2" Grid.Column="1" Background="{DynamicResource BgLayer}" Margin="15,0,0,0" CornerRadius="8" Padding="20">
                             <Grid>
                                <Grid.RowDefinitions>
                                    <RowDefinition Height="Auto"/> <RowDefinition Height="*"/>
                                </Grid.RowDefinitions>
                                <StackPanel Grid.Row="0" Margin="0,0,0,20">
                                    <TextBlock Text="Local Apps" FontSize="18" FontWeight="Bold" Foreground="{DynamicResource TextPrimary}"/>
                                    <TextBlock Text="Install .exe / .msi" FontSize="13" Foreground="{DynamicResource TextSecondary}"/>
                                </StackPanel>
                                <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
                                    <StackPanel Name="pnlLocalApps" />
                                </ScrollViewer>
                            </Grid>
                        </Border>

                         <Button Name="btnInstall" Grid.Row="2" Grid.ColumnSpan="2" Content="INSTALL SELECTED (CONFIG)"
                            FontWeight="Bold" Background="{DynamicResource Accent}"
                            Foreground="{DynamicResource ButtonTextForeground}"
                            FontSize="14" Height="45" Cursor="Hand" Margin="0,15,0,0" HorizontalAlignment="Stretch">
                             <Button.Resources>
                                <Style TargetType="Border"><Setter Property="CornerRadius" Value="6"/></Style>
                            </Button.Resources>
                        </Button>
                    </Grid>

                    <Grid Name="viewSearch" Visibility="Collapsed">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/> <RowDefinition Height="*"/> <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>
                        <StackPanel Grid.Row="0" Margin="0,0,0,15">
                             <TextBlock Text="Search Repository" FontSize="24" FontWeight="Bold" Foreground="{DynamicResource TextPrimary}"/>
                             <TextBlock Text="Type to filter cache. Press ENTER to search Online (MSStore)." FontSize="14" Foreground="{DynamicResource TextSecondary}" Margin="0,5,0,15"/>
                             <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/> <ColumnDefinition Width="160"/>
                                </Grid.ColumnDefinitions>
                                <TextBox Name="txtSearch" Height="40" VerticalContentAlignment="Center" FontSize="14" />
                                <Button Name="btnUpdateRepo" Grid.Column="1" Content="Update Cache" Margin="10,0,0,0" Style="{StaticResource FluentButton}" />
                             </Grid>
                        </StackPanel>

                        <ListView Name="lvSearchResults" Grid.Row="1" Background="Transparent" BorderThickness="0" Foreground="{DynamicResource TextPrimary}">
                            <ListView.View>
                                <GridView>
                                    <GridViewColumn Header="Select" Width="50">
                                        <GridViewColumn.CellTemplate>
                                            <DataTemplate>
                                                <CheckBox IsChecked="{Binding IsSelected}" />
                                            </DataTemplate>
                                        </GridViewColumn.CellTemplate>
                                    </GridViewColumn>
                                    <GridViewColumn Header="Name" Width="300" DisplayMemberBinding="{Binding Name}"/>
                                    <GridViewColumn Header="ID" Width="250" DisplayMemberBinding="{Binding Id}"/>
                                    <GridViewColumn Header="Version" Width="100" DisplayMemberBinding="{Binding Version}"/>
                                    <GridViewColumn Header="Source" Width="100" DisplayMemberBinding="{Binding Source}"/>
                                </GridView>
                            </ListView.View>
                        </ListView>

                        <Button Name="btnInstallSearch" Grid.Row="2" Content="INSTALL CHECKED ITEMS"
                            FontWeight="Bold" Background="{DynamicResource Accent}"
                            Foreground="{DynamicResource ButtonTextForeground}"
                            FontSize="14" Height="45" Cursor="Hand" Margin="0,15,0,0">
                             <Button.Resources>
                                <Style TargetType="Border"><Setter Property="CornerRadius" Value="6"/></Style>
                            </Button.Resources>
                        </Button>
                    </Grid>

                    <Grid Name="viewBackup" Visibility="Collapsed">
                        <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
                             <ContentControl Content="{StaticResource IconBackup}" Width="80" Height="80" Margin="0,0,0,20"/>
                             <TextBlock Text="Backup &amp; Restore" FontSize="24" FontWeight="Bold" Foreground="{DynamicResource TextPrimary}" HorizontalAlignment="Center" Margin="0,0,0,30"/>
                             <Button Name="btnBackup" Content="EXPORT INSTALLED PACKAGES (JSON)" Width="350" Height="60" Margin="0,0,0,20" Style="{StaticResource FluentButton}" FontSize="16"/>
                             <Button Name="btnRestore" Content="IMPORT &amp; RESTORE FROM FILE" Width="350" Height="60" Style="{StaticResource FluentButton}" FontSize="16"/>
                             <TextBlock Name="txtBackupStatus" Text="Ready." Foreground="{DynamicResource TextSecondary}" HorizontalAlignment="Center" Margin="0,20,0,0"/>
                        </StackPanel>
                    </Grid>
                </Grid>
            </Border>
        </Grid>

        <Border Grid.Row="2" Background="{DynamicResource BgFooter}" Padding="20,15">
            <StackPanel VerticalAlignment="Center">
                <ProgressBar Name="pbInstall" Height="6" Background="{DynamicResource BgInput}" Foreground="{DynamicResource Accent}" BorderThickness="0" Value="0" Margin="0,0,0,5"/>
                <TextBlock Name="txtStatusFooter" Text="Waiting..." FontSize="12" Foreground="{DynamicResource TextSecondary}"/>
            </StackPanel>
        </Border>
    </Grid>
</Window>
"@

# Load XAML
$reader = (New-Object System.Xml.XmlNodeReader $xaml)
try { $window = [Windows.Markup.XamlReader]::Load($reader) } catch { Write-Host $_; exit }

# --- CONTROLS MAPPING ---
$tabCategories = $window.FindName("tabCategories")
$tabFixedTools = $window.FindName("tabFixedTools")
$tabSearch = $window.FindName("tabSearch")
$tabBackup = $window.FindName("tabBackup")
$viewCategory = $window.FindName("viewCategory")
$viewSearch = $window.FindName("viewSearch")
$viewBackup = $window.FindName("viewBackup")
$pnlLocalApps = $window.FindName("pnlLocalApps")
$btnInstall = $window.FindName("btnInstall")
$pnlWingetContent = $window.FindName("pnlWingetContent")
$txtCategoryTitle = $window.FindName("txtCategoryTitle")
$txtSearch = $window.FindName("txtSearch")
$btnUpdateRepo = $window.FindName("btnUpdateRepo")
$lvSearchResults = $window.FindName("lvSearchResults")
$btnInstallSearch = $window.FindName("btnInstallSearch")
$btnBackup = $window.FindName("btnBackup")
$btnRestore = $window.FindName("btnRestore")
$txtBackupStatus = $window.FindName("txtBackupStatus")
$txtStatusFooter = $window.FindName("txtStatusFooter")
$pbInstall = $window.FindName("pbInstall")
$btnThemeToggle = $window.FindName("btnThemeToggle")
$iconThemeHolder = $window.FindName("iconThemeHolder")
$txtAuthorLink = $window.FindName("txtAuthorLink")

# --- THEME LOGIC ---
$isDark = $true
function Set-Theme {
    param([bool]$dark)
    $res = $window.Resources
    $c = New-Object System.Windows.Media.BrushConverter

    if ($dark) {
        $res["BgBase"] = $c.ConvertFromString("#202020"); $res["BgCard"] = $c.ConvertFromString("#2b2b2b"); $res["BgLayer"] = $c.ConvertFromString("#252525")
        $res["BgFooter"] = $c.ConvertFromString("#1c1c1c"); $res["BgInput"] = $c.ConvertFromString("#333333"); $res["BgHover"] = $c.ConvertFromString("#3e3e3e")
        $res["BorderColor"] = $c.ConvertFromString("#454545"); $res["TextPrimary"] = $c.ConvertFromString("#ffffff"); $res["TextSecondary"] = $c.ConvertFromString("#aaaaaa")
        $res["Accent"] = $c.ConvertFromString("#4cc2ff"); $res["AccentLow"] = $c.ConvertFromString("#334cc2ff"); $res["ScrollThumb"] = $c.ConvertFromString("#666666")
        $res["ButtonTextForeground"] = $c.ConvertFromString("#000000"); $res["IconBrush"] = $c.ConvertFromString("#ffffff")
        $iconThemeHolder.Content = $window.Resources["IconSun"]
        try { $hwnd = [System.Diagnostics.Process]::GetCurrentProcess().MainWindowHandle; if($hwnd -ne 0){[Win32]::SetDarkMode($hwnd, $true)} } catch {}
    } else {
        $res["BgBase"] = $c.ConvertFromString("#F0F0F0"); $res["BgCard"] = $c.ConvertFromString("#FFFFFF"); $res["BgLayer"] = $c.ConvertFromString("#FFFFFF")
        $res["BgFooter"] = $c.ConvertFromString("#D0D0D0"); $res["BgInput"] = $c.ConvertFromString("#FFFFFF"); $res["BgHover"] = $c.ConvertFromString("#F5F5F5")
        $res["BorderColor"] = $c.ConvertFromString("#D0D0D0"); $res["TextPrimary"] = $c.ConvertFromString("#000000"); $res["TextSecondary"] = $c.ConvertFromString("#505050")
        $res["Accent"] = $c.ConvertFromString("#0067c0"); $res["AccentLow"] = $c.ConvertFromString("#330067c0"); $res["ScrollThumb"] = $c.ConvertFromString("#909090")
        $res["ButtonTextForeground"] = $c.ConvertFromString("#ffffff"); $res["IconBrush"] = $c.ConvertFromString("#000000")
        $iconThemeHolder.Content = $window.Resources["IconMoon"]
        try { $hwnd = [System.Diagnostics.Process]::GetCurrentProcess().MainWindowHandle; if($hwnd -ne 0){[Win32]::SetDarkMode($hwnd, $false)} } catch {}
    }
}

# --- ASYNC PROCESS LOGIC (DispatcherTimer) ---
$timer.Add_Tick({
    if ($script:activeProcess -ne $null) {
        if ($script:activeProcess.HasExited) {
            $timer.Stop()
            $pbInstall.IsIndeterminate = $false

            # PROCESS FETCH
            if ($script:activeOperation -eq "Fetch") {
                $tempFile = "$env:TEMP\winget_all_cache.tmp"
                if (Test-Path $tempFile) {
                    $lines = Get-Content $tempFile -Encoding UTF8
                    $newCache = @()
                    foreach ($line in $lines) {
                        if ($line -match "^\s*Name\s+Id" -or $line -match "^-+" -or [string]::IsNullOrWhiteSpace($line)) { continue }
                        $parts = $line -split "\s{2,}"
                        if ($parts.Count -ge 2) {
                            $obj = New-Object PSObject; $obj | Add-Member -MemberType NoteProperty -Name "IsSelected" -Value $false
                            $obj | Add-Member -MemberType NoteProperty -Name "Name" -Value $parts[0].Trim(); $obj | Add-Member -MemberType NoteProperty -Name "Id" -Value $parts[1].Trim()
                            $ver = ""; if ($parts.Count -ge 3) { $ver = $parts[2].Trim() }; $src = "Unknown"; if ($parts.Count -ge 4) { $src = $parts[$parts.Count -1].Trim() }
                            $obj | Add-Member -MemberType NoteProperty -Name "Version" -Value $ver; $obj | Add-Member -MemberType NoteProperty -Name "Source" -Value $src
                            $newCache += $obj
                        }
                    }
                    $script:RepoCache = $newCache
                    $script:isRepoFetched = $true
                    Filter-Repo $txtSearch.Text
                    $txtStatusFooter.Text = "Cache updated. $($newCache.Count) packages found."
                }
                $btnUpdateRepo.IsEnabled = $true; $txtSearch.IsEnabled = $true
            }
            # PROCESS ONLINE SEARCH
            elseif ($script:activeOperation -eq "OnlineSearch") {
                $tempFile = "$env:TEMP\winget_online_search.tmp"
                if (Test-Path $tempFile) {
                    $lines = Get-Content $tempFile -Encoding UTF8
                    $newResults = @()
                    foreach ($line in $lines) {
                        if ($line -match "^\s*Name\s+Id" -or $line -match "^-+" -or [string]::IsNullOrWhiteSpace($line)) { continue }
                        $parts = $line -split "\s{2,}"
                        if ($parts.Count -ge 2) {
                            $obj = New-Object PSObject; $obj | Add-Member -MemberType NoteProperty -Name "IsSelected" -Value $false
                            $obj | Add-Member -MemberType NoteProperty -Name "Name" -Value $parts[0].Trim(); $obj | Add-Member -MemberType NoteProperty -Name "Id" -Value $parts[1].Trim()
                            $ver = ""; if ($parts.Count -ge 3) { $ver = $parts[2].Trim() }; $src = "Unknown"; if ($parts.Count -ge 4) { $src = $parts[$parts.Count -1].Trim() }
                            $obj | Add-Member -MemberType NoteProperty -Name "Version" -Value $ver; $obj | Add-Member -MemberType NoteProperty -Name "Source" -Value $src
                            $newResults += $obj
                        }
                    }
                    $lvSearchResults.ItemsSource = $newResults
                    $txtStatusFooter.Text = "Online Search: $($newResults.Count) results."
                }
            }
            $script:activeProcess = $null
        }
    }
})

function Start-AsyncProcess {
    param($argsList, $opName, $outputFile)
    $script:activeOperation = $opName
    $pbInstall.IsIndeterminate = $true

    if ($outputFile) {
        $script:activeProcess = Start-Process "winget" -ArgumentList $argsList -NoNewWindow -PassThru -RedirectStandardOutput $outputFile
    } else {
        $script:activeProcess = Start-Process "winget" -ArgumentList $argsList -NoNewWindow -PassThru
    }
    $timer.Start()
}

function Filter-Repo {
    param($query)
    if ($script:RepoCache.Count -gt 0) {
        if ([string]::IsNullOrWhiteSpace($query)) {
            $lvSearchResults.ItemsSource = $script:RepoCache
            $txtStatusFooter.Text = "Displaying cached packages."
        } else {
            $filtered = $script:RepoCache.Where({ ($_.Name -match "$query") -or ($_.Id -match "$query") })
            $lvSearchResults.ItemsSource = $filtered
            $txtStatusFooter.Text = "Cached Matches: $($filtered.Count)"
        }
    }
}

function Search-Online {
    param($query)
    if ([string]::IsNullOrWhiteSpace($query)) { return }
    $txtStatusFooter.Text = "Searching Online Repositories..."
    Start-AsyncProcess "search `"$query`" --accept-source-agreements" "OnlineSearch" "$env:TEMP\winget_online_search.tmp"
}

function Fetch-Repo {
    if ($script:activeProcess) { return }
    $btnUpdateRepo.IsEnabled = $false; $txtSearch.IsEnabled = $false
    $txtStatusFooter.Text = "Updating Cache..."
    Start-AsyncProcess "search `"`" --accept-source-agreements" "Fetch" "$env:TEMP\winget_all_cache.tmp"
}

# --- VIEW SWITCHING ---
function Switch-View($viewName) {
    $viewCategory.Visibility = "Collapsed"; $viewSearch.Visibility = "Collapsed"; $viewBackup.Visibility = "Collapsed"
    switch ($viewName) {
        "Category" { $viewCategory.Visibility = "Visible" }
        "Search"   { $viewSearch.Visibility = "Visible" }
        "Backup"   { $viewBackup.Visibility = "Visible" }
    }
}

# --- POPULATE CONFIG ---
if ($configLoaded -and $config.InstallerConfig.WingetApps.Category) {
    foreach ($cat in $config.InstallerConfig.WingetApps.Category) {
        $t = New-Object System.Windows.Controls.TabItem; $t.Header = $cat.Name; $t.Tag = $cat; $tabCategories.Items.Add($t) | Out-Null
    }
}

$tabCategories.Add_SelectionChanged({
    if ($tabCategories.SelectedItem -eq $null) { return }
    $tabFixedTools.SelectedIndex = -1; Switch-View "Category"
    $sel = $tabCategories.SelectedItem; $catData = $sel.Tag; $txtCategoryTitle.Text = $catData.Name
    $pnlWingetContent.Children.Clear()
    $chkAll = New-Object System.Windows.Controls.CheckBox; $chkAll.Content = "Select All"; $chkAll.FontWeight = "Bold"; $chkAll.Margin = "0,0,0,15"; $pnlWingetContent.Children.Add($chkAll) | Out-Null

    if ($catData.App) {
        foreach ($app in $catData.App) {
            $chk = New-Object System.Windows.Controls.CheckBox; $chk.Content = $app.Name; $chk.Tag = $app.Id
            if ($script:selectionState[$app.Id]) { $chk.IsChecked = $true }
            $chk.Add_Checked({ $script:selectionState[$this.Tag] = $true }); $chk.Add_Unchecked({ $script:selectionState[$this.Tag] = $false })
            $pnlWingetContent.Children.Add($chk) | Out-Null
        }
    }
    $chkAll.Add_Click({ $val = $this.IsChecked; foreach ($e in $pnlWingetContent.Children) { if ($e -is [System.Windows.Controls.CheckBox] -and $e -ne $this) { $e.IsChecked = $val; $script:selectionState[$e.Tag] = $val } } })
})

$tabFixedTools.Add_SelectionChanged({
    if ($tabFixedTools.SelectedItem -eq $null) { return }
    $tabCategories.SelectedIndex = -1
    if ($tabFixedTools.SelectedItem -eq $tabSearch) { Switch-View "Search"; if (-not $script:isRepoFetched) { Fetch-Repo } }
    elseif ($tabFixedTools.SelectedItem -eq $tabBackup) { Switch-View "Backup" }
})

# --- LOCAL APPS (FIXED) ---
if ($configLoaded -and $config.InstallerConfig.LocalApps.App) {
    # Ensure it's an array to handle single items correctly
    $localApps = @($config.InstallerConfig.LocalApps.App)
    foreach ($localApp in $localApps) {
        $btn = New-Object System.Windows.Controls.Button; $btn.Content = $localApp.Name; $btn.Tag = @{ Path = $localApp.Path; Args = $localApp.Args }
        $btn.Style = $window.Resources["FluentButton"]; $btn.HorizontalContentAlignment = "Left"; $btn.Margin = "0,0,0,8"
        $btn.Add_Click({
            $props = $this.Tag; $fullPath = Join-Path $script:ScriptDir $props.Path; $workDir = Split-Path -Parent $fullPath
            if (Test-Path $fullPath) {
                $txtStatusFooter.Text = "Running: $($this.Content)"; if ($fullPath.ToLower().EndsWith(".msi")) { $msiArgs = "/i `"$fullPath`" /qn"; if ($props.Args) { $msiArgs = "/i `"$fullPath`" $($props.Args)" }; Start-Process "msiexec.exe" $msiArgs -WorkingDirectory $workDir } else { if ($props.Args) { Start-Process -FilePath $fullPath -ArgumentList $props.Args -WorkingDirectory $workDir } else { Start-Process -FilePath $fullPath -WorkingDirectory $workDir } }
            } else { $txtStatusFooter.Text = "Error: File not found" }
        })
        [void]$pnlLocalApps.Children.Add($btn)
    }
}

# --- EVENT HANDLERS ---
$txtSearch.Add_TextChanged({ Filter-Repo $txtSearch.Text })
$txtSearch.Add_KeyDown({ if ($_.Key -eq "Enter") { Search-Online $txtSearch.Text } })
$btnUpdateRepo.Add_Click({ Fetch-Repo })

$btnInstall.Add_Click({
    if (-not $configLoaded) { return }
    $apps = @(); $config.InstallerConfig.WingetApps.Category | ForEach-Object { $_.App | ForEach-Object { if ($script:selectionState[$_.Id]) { $apps += $_ } } }
    Install-Apps $apps
})

$btnInstallSearch.Add_Click({
    if ($lvSearchResults.ItemsSource) {
        $sel = @(); foreach ($i in $lvSearchResults.ItemsSource) { if ($i.IsSelected) { $sel += $i } }
        Install-Apps $sel
    }
})

function Install-Apps($list) {
    if ($list.Count -eq 0) { return }
    $pbInstall.IsIndeterminate = $false; $pbInstall.Maximum = $list.Count; $pbInstall.Value = 0
    foreach ($app in $list) {
        $txtStatusFooter.Text = "Installing: $($app.Name)..."; [System.Windows.Forms.Application]::DoEvents()
        $src = "--source winget"; if ($app.Source -match "msstore") { $src = "--source msstore" }
        Start-Process "winget" "install --id $($app.Id) -e --silent --accept-package-agreements --accept-source-agreements $src" -NoNewWindow -Wait
        $pbInstall.Value++
    }
    $txtStatusFooter.Text = "Ready."
}

$btnBackup.Add_Click({
    $sfd = New-Object System.Windows.Forms.SaveFileDialog; $sfd.Filter = "JSON|*.json"; $sfd.FileName = "backup.json"
    if ($sfd.ShowDialog() -eq "OK") {
        $txtBackupStatus.Text = "Exporting..."; $pbInstall.IsIndeterminate = $true; [System.Windows.Forms.Application]::DoEvents()
        Start-Process "winget" "export -o `"$($sfd.FileName)`"" -NoNewWindow -Wait
        $txtBackupStatus.Text = "Saved."; $pbInstall.IsIndeterminate = $false
    }
})

$btnRestore.Add_Click({
    $ofd = New-Object System.Windows.Forms.OpenFileDialog; $ofd.Filter = "JSON|*.json"
    if ($ofd.ShowDialog() -eq "OK") {
        $txtBackupStatus.Text = "Restoring..."; $pbInstall.IsIndeterminate = $true; [System.Windows.Forms.Application]::DoEvents()
        Start-Process "winget" "import -i `"$($ofd.FileName)`" --accept-package-agreements" -NoNewWindow -Wait
        $txtBackupStatus.Text = "Done."; $pbInstall.IsIndeterminate = $false
    }
})

$btnThemeToggle.Add_Click({ $script:isDark = -not $script:isDark; Set-Theme $script:isDark })
$txtAuthorLink.Add_MouseLeftButtonDown({ Start-Process "https://www.osmanonurkoc.com" })

# --- STARTUP ---
$window.Add_Loaded({
    if ($tabCategories.Items.Count -gt 0) { $tabCategories.SelectedIndex = 0 } else { $tabFixedTools.SelectedIndex = 0 }
    Set-Theme $true
    Fetch-Repo
})

$window.ShowDialog() | Out-Null
