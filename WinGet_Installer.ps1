<#
    === WIN-GET INSTALLER (PRO) ===
    Author: Osman Onur Koc (Updated with Search & Backup)
    Repo: https://github.com/osmanonurkoc/WinGet_Installer
    License: MIT License

    New Features:
    1. Search Repository: Search and install apps from Winget/MSStore dynamically.
    2. Backup & Restore: Export installed packages to JSON and restore them.
    3. Console Hiding & Dark Mode support.
#>

# Set console output encoding to UTF-8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Required Assemblies
Add-Type -AssemblyName PresentationFramework, System.Windows.Forms, System.Drawing

# --- C# CODE: CONSOLE HIDE & DWM API ---
$code = @"
using System;
using System.Runtime.InteropServices;

public class Win32 {
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    public const int SW_HIDE = 0;
    public const int SW_SHOW = 5;

    [DllImport("dwmapi.dll", PreserveSig = true)]
    public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);

    public const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;

    public static void SetDarkMode(IntPtr hwnd, bool enabled) {
        int useDarkMode = enabled ? 1 : 0;
        DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, ref useDarkMode, sizeof(int));
    }
}
"@

if (-not ([System.Management.Automation.PSTypeName]'Win32').Type) {
    Add-Type -TypeDefinition $code -Language CSharp
}

# --- HIDE CONSOLE WINDOW ---
$hwnd = [Win32]::GetConsoleWindow()
if ($hwnd -ne [IntPtr]::Zero) { [Win32]::ShowWindow($hwnd, 0) }

# --- PATH DETECTION ---
$ScriptDir = $PSScriptRoot
$xmlPathOverride = $null

if (-not (Test-Path "$ScriptDir\Programs")) {
    try {
        $currentId = $PID
        $parentProcess = Get-CimInstance Win32_Process -Filter "ProcessId = $currentId"
        if ($parentProcess) {
            $parentId = $parentProcess.ParentProcessId
            $parentProcObj = Get-Process -Id $parentId -ErrorAction SilentlyContinue
            if ($parentProcObj) {
                $parentPath = $parentProcObj.Path
                $OriginalDir = Split-Path $parentPath -Parent
                if (Test-Path "$OriginalDir\config.xml") {
                     $ScriptDir = $OriginalDir
                     $xmlPathOverride = "$OriginalDir\config.xml"
                }
            }
        }
    } catch {}
}

# --- XML CHECK ---
if ($xmlPathOverride) { $xmlPath = $xmlPathOverride } else { $xmlPath = "$PSScriptRoot\config.xml" }

# Create dummy config if not exists (to allow Search/Backup mode to work without config)
$configLoaded = $false
if (Test-Path $xmlPath) {
    try {
        [xml]$config = Get-Content $xmlPath -Raw -ErrorAction Stop
        $configLoaded = $true
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Error reading config.xml:`n$($_.Exception.Message)", "XML Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    }
}

# --- GLOBAL SELECTION STATE ---
$script:selectionState = @{}

# --- XAML UI ---
[xml]$xaml = @"
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Windows Package Manager UI @osmanonurkoc" Height="850" Width="1200"
    WindowStartupLocation="CenterScreen"
    Background="{DynamicResource BgBase}">

    <Window.Resources>
        <Style x:Key="ModernScrollBar" TargetType="{x:Type ScrollBar}">
            <Setter Property="Stylus.IsFlicksEnabled" Value="false" />
            <Setter Property="Foreground" Value="{DynamicResource ScrollThumb}" />
            <Setter Property="Background" Value="Transparent" />
            <Setter Property="Width" Value="10" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type ScrollBar}">
                        <Grid x:Name="GridRoot" Width="10" Background="{TemplateBinding Background}">
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
        <Style x:Key="ScrollThumbStyle" TargetType="{x:Type Thumb}">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type Thumb}">
                        <Border CornerRadius="5" Background="{TemplateBinding Background}" Margin="2" />
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="{x:Type ScrollViewer}">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type ScrollViewer}">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <ScrollContentPresenter Grid.Column="0"/>
                            <ScrollBar x:Name="PART_VerticalScrollBar" Grid.Column="1" Value="{TemplateBinding VerticalOffset}" Maximum="{TemplateBinding ScrollableHeight}" ViewportSize="{TemplateBinding ViewportHeight}" Style="{StaticResource ModernScrollBar}" Visibility="{TemplateBinding ComputedVerticalScrollBarVisibility}"/>
                        </Grid>
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

        <Viewbox x:Key="IconMoon">
            <Path Fill="{DynamicResource IconBrush}" Stretch="Uniform" Data="m 69.492851,31.587218 q 1.201475,0 2.170408,-0.581359 1.007692,-0.620117 1.589051,-1.58905 0.620117,-1.00769 0.620117,-2.209168 0,-1.240234 -0.620117,-2.209167 -0.581359,-1.00769 -1.589051,-1.589051 -0.968933,-0.620117 -2.170408,-0.620117 -1.201479,0 -2.209168,0.620117 -1.00769,0.581361 -1.589051,1.589051 -0.581361,0.968933 -0.581361,2.209167 0,1.201478 0.581361,2.209168 0.581361,0.968933 1.589051,1.58905 1.007689,0.581359 2.209168,0.581359 z M 33.409783,67.554014 q 1.201476,0 2.170409,-0.620117 1.007689,-0.581359 1.58905,-1.589048 0.620117,-0.968933 0.620117,-2.170411 0,-1.240235 -0.620117,-2.209168 -0.581361,-1.007689 -1.58905,-1.58905 -0.968933,-0.620118 -2.170409,-0.620118 -1.201478,0 -2.209168,0.620118 -1.007692,0.581361 -1.58905,1.58905 -0.581361,0.968933 -0.581361,2.209168 0,1.201478 0.581361,2.170411 0.581358,1.007689 1.58905,1.589048 1.00769,0.620117 2.209168,0.620117 z M 73.639885,42.28424 q 0,-0.736389 -0.387575,-1.356506 -0.387572,-0.658876 -1.00769,-1.007689 -0.620117,-0.387575 -1.395264,-0.387575 -0.736388,0 -1.395264,0.387575 -0.620117,0.348813 -1.00769,1.007689 -0.348816,0.620117 -0.348816,1.356506 0,0.775147 0.348816,1.43402 0.387573,0.620117 1.00769,1.007692 0.658876,0.348816 1.395264,0.348816 0.775147,0 1.395264,-0.348816 0.620118,-0.387575 1.00769,-1.007692 0.387575,-0.658873 0.387575,-1.43402 z M 56.896721,61.856688 q 2.325439,0 4.224546,-1.123963 1.899111,-1.123961 3.023074,-3.023071 1.162719,-1.937866 1.162719,-4.224546 0,-2.325442 -1.162719,-4.224549 -1.123963,-1.899108 -3.023074,-3.023071 -1.899107,-1.16272 -4.224546,-1.16272 -2.286683,0 -4.224549,1.16272 -1.899108,1.123963 -3.023071,3.023071 -1.123963,1.899107 -1.123963,4.224549 0,2.28668 1.123963,4.224546 1.123963,1.89911 3.023071,3.023071 1.937866,1.123963 4.224549,1.123963 z M 55.966544,9.1467283 v 0 q 0.891418,3.6431877 0.968933,7.5964357 0.07751,3.953248 -0.930174,8.139038 -1.47278,6.356202 -5.270998,11.627197 -3.798218,5.232238 -9.224243,8.759155 -5.426024,3.488159 -11.820982,4.650878 v 0 Q 24.418083,50.888365 19.53466,50.268248 14.651238,49.609375 10.310417,47.749023 7.7911898,46.62506 5.4657511,47.361451 3.1790695,48.097839 1.8225632,49.725646 0.46605668,51.27594 0.07848364,53.562623 q -0.34881608,2.28668 0.85266106,4.534606 v 0 q 3.7594592,6.93756 9.6505733,12.169799 5.929871,5.232238 13.410033,8.177794 7.480165,2.984315 15.851746,3.023074 h 0.658876 q 2.906797,0 5.813597,-0.387575 v 0 q 7.480165,-1.00769 14.030153,-4.379577 6.549988,-3.33313 11.665952,-8.565369 5.115968,-5.193482 8.371584,-11.782226 3.255616,-6.627503 4.147034,-14.107666 h 0.03876 Q 85.499626,33.990174 83.639275,26.432494 81.817679,18.874817 77.670645,12.557374 73.56237,6.2011718 67.710014,1.5890502 l -0.03876,-0.038757 v 0 Q 65.617118,0 63.330435,0 61.082511,0 59.183403,1.2014769 57.284293,2.402954 56.31536,4.4958494 55.346427,6.5499876 55.966544,9.1467283 Z M 30.658013,55.422974 q 7.518919,-1.356508 13.836364,-5.464783 6.356199,-4.108278 10.774535,-10.231935 4.418335,-6.123657 6.201171,-13.565063 0.891419,-3.836974 1.007692,-7.518921 0.155028,-3.681944 -0.348816,-7.208861 -0.03876,-0.07752 -0.07752,-0.193787 0,-0.116273 0,-0.193786 -0.15503,-0.930176 -0.31006,-1.7828378 l -0.03876,-0.077514 q -0.15503,-0.7363892 -0.31006,-1.3565063 -0.271301,-1.2402344 0.775148,-1.8991091 1.085204,-0.6976319 2.092896,0.038758 0.620117,0.503845 1.085204,0.8914183 v 0 q 0.736389,0.6201172 1.511536,1.3565063 0.31006,0.2713014 0.426331,0.4263305 6.317443,6.0849001 9.573059,14.6502691 3.294372,8.565369 2.131652,18.293455 -0.775147,6.549988 -3.643188,12.324829 -2.829285,5.774843 -7.325135,10.348206 -4.495847,4.534606 -10.231932,7.441406 -5.697328,2.945559 -12.208557,3.836977 Q 37.750594,76.584472 30.619245,74.72412 23.526655,72.902527 17.6743,68.755493 11.8607,64.647218 7.9074546,58.794862 7.7911808,58.639832 7.5586386,58.291016 7.0160364,57.477113 6.4734341,56.546936 l -0.038759,-0.03876 Q 6.0858683,55.926818 5.853326,55.46173 5.2332088,54.299011 6.0471121,53.330078 q 0.8526595,-1.00769 2.0153815,-0.465088 0.6976295,0.271302 1.4727766,0.581359 v 0 q 0.8139038,0.31006 1.6278088,0.581361 0.116272,0.03876 0.193787,0.07751 0.116271,0.03876 0.193786,0.07752 4.418335,1.43402 9.224242,1.821593 4.844667,0.348816 9.883119,-0.581359 z" />
        </Viewbox>
        <Viewbox x:Key="IconPackage">
            <Path Fill="{DynamicResource IconBrush}" Stretch="Uniform" Data="m 32.129822,66.546324 q 0,-1.007689 -0.852662,-1.58905 l -7.828978,-4.689637 q -0.387575,-0.232542 -0.813906,0 -0.387573,0.193789 -0.387573,0.658876 v 5.464784 q 0,1.007689 0.852663,1.58905 l 7.828978,4.689634 q 0.387572,0.232545 0.775147,0 0.426331,-0.193786 0.426331,-0.658873 z M 38.796081,0.81390383 Q 37.478332,0 35.928038,0 34.416502,0 33.098755,0.77514661 L 2.5579837,19.378662 Q 1.3565055,20.076294 0.65887335,21.316529 0,22.518004 0,23.835754 v 34.765321 q 0,1.976622 0.96893326,3.720703 1.00768944,1.744077 2.71301364,2.790526 L 33.137512,83.018187 q 2.790526,1.705324 5.581054,0 L 68.174131,65.112304 q 1.74408,-1.046449 2.674257,-2.790526 0.968934,-1.782837 0.968934,-3.720703 V 23.835754 q 0,-2.945556 -2.480469,-4.495851 L 38.834837,0.81390383 Z M 35.928038,5.5810546 45.7724,11.58844 18.409729,28.215333 8.6041255,22.207947 Z M 54.957884,17.169495 63.639525,22.440489 35.966796,38.912352 27.595213,33.796387 Z M 5.5810546,58.601075 V 26.897583 l 9.7280884,5.929871 v 6.084898 q 0,0.46509 0.387573,0.736391 l 7.480165,4.534606 q 0.426328,0.232545 0.852659,0 0.465087,-0.232544 0.465087,-0.736388 v -4.999696 l 8.642885,5.270997 V 76.468199 L 6.588744,60.345152 Q 5.5810546,59.725035 5.5810546,58.601075 Z M 65.267334,60.345152 38.718566,76.429443 V 43.757018 L 66.236267,27.362671 v 31.238404 q 0,1.12396 -0.968933,1.705321 z" />
        </Viewbox>
        <Viewbox x:Key="IconSun">
             <Path Fill="{DynamicResource IconBrush}" Stretch="Uniform">
                <Path.Data>
                    <GeometryGroup>
                         <PathGeometry Figures="M167,12.7c4,5.3,9.1,8.9,15.4,11,6.3,2.1,12.7,2.1,19,.1,6.6-2.1,13-2.1,19.2,0s11.2,5.9,15.1,11.1c4,5.2,6,11.2,6,18.2s2.1,12.6,5.9,18c3.9,5.4,9,9.1,15.4,11.1,6.5,2.2,11.7,6.1,15.4,11.4,3.7,5.3,5.7,11.2,5.9,17.7.2,6.5-1.8,12.6-5.9,18.3-3.8,5.4-5.7,11.4-5.7,18s1.9,12.6,5.7,18c4.1,5.7,6.1,11.8,5.9,18.3s-2.1,12.5-5.9,17.9c-3.7,5.3-8.8,9-15.4,11.3-6.3,2.1-11.5,5.8-15.4,11.1-3.8,5.4-5.8,11.4-5.9,18,0,6.9-2,13-6,18.2-3.9,5.3-8.9,9-15.1,11.1-6.2,2.1-12.5,2.1-19.2,0-6.3-2-12.7-1.9-19,.1-6.2,2.1-11.4,5.7-15.4,11-4.1,5.7-9.3,9.4-15.5,11.3s-12.5,1.9-18.8,0-11.4-5.6-15.5-11.3c-3.9-5.3-9-8.9-15.4-11-6.3-2.1-12.6-2.1-18.9-.1-6.6,2.1-13,2.1-19.2,0s-11.2-5.9-15.2-11.1c-3.9-5.2-5.9-11.2-6-18.2,0-6.6-2-12.6-5.9-18s-9-9.1-15.2-11.1c-6.6-2.2-11.8-6-15.5-11.3-3.7-5.2-5.7-11.2-5.9-17.7,0-6.5,1.9-12.6,5.9-18.3,3.9-5.4,5.9-11.4,5.9-18s-2-12.6-5.9-18c-4-5.8-5.9-11.9-5.9-18.4.2-6.5,2.1-12.5,5.9-17.7,3.7-5.4,8.9-9.2,15.5-11.4,6.2-2.1,11.3-5.8,15.2-11.1,3.9-5.4,5.9-11.4,5.9-18s2.1-13,6-18.2c4-5.3,9.1-9,15.2-11.1,6.2-2.1,12.5-2.1,19.2,0,6.3,2,12.5,1.9,18.9-.1,6.3-2.1,11.5-5.7,15.4-11,4.1-5.7,9.3-9.4,15.5-11.3,6.3-1.9,12.5-1.9,18.8,0,6.3,1.9,11.4,5.6,15.5,11.3h0ZM86.9,243.4c13.2,7.6,27,12.3,41.5,13.9,14.5,1.8,28.6.8,42.3-2.9,13.9-3.6,26.6-9.8,38.2-18.5,11.6-8.8,21.2-19.8,28.9-33,7.6-13.2,12.3-27,14.1-41.5,1.8-14.5.8-28.6-2.9-42.3-3.7-13.9-9.9-26.6-18.6-38.2-8.7-11.6-19.7-21.2-33-28.9-13.2-7.6-27-12.3-41.5-13.9-14.4-1.8-28.5-.8-42.3,2.9-13.9,3.6-26.6,9.8-38.2,18.6-11.6,8.7-21.2,19.6-28.9,32.8s-12.3,27-14.1,41.5c-1.7,14.5-.6,28.6,3.1,42.5,3.7,13.8,9.9,26.5,18.6,38.1s19.6,21.2,32.8,28.9Z" />
                         <EllipseGeometry Center="142.1,147.7" RadiusX="87.5" RadiusY="87.5" />
                    </GeometryGroup>
                </Path.Data>
            </Path>
        </Viewbox>
    </Window.Resources>

    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/> <RowDefinition Height="*"/> <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <Border Grid.Row="0" Background="{DynamicResource BgBase}" Padding="25,20">
            <Grid>
                <StackPanel Orientation="Horizontal">
                    <ContentControl Content="{StaticResource IconPackage}" Width="32" Height="32" Margin="0,0,12,0"/>
                    <TextBlock Text="Package Manager Pro" FontSize="20" FontWeight="Bold" Foreground="{DynamicResource TextPrimary}" VerticalAlignment="Center"/>
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
                    <TabControl Name="tabCategories" BorderThickness="0" Background="Transparent" TabStripPlacement="Left">
                        </TabControl>
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
                             <TextBlock Text="Search and install from Winget &amp; MSStore." FontSize="14" Foreground="{DynamicResource TextSecondary}" Margin="0,5,0,15"/>
                             <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/> <ColumnDefinition Width="120"/>
                                </Grid.ColumnDefinitions>
                                <TextBox Name="txtSearch" Height="40" VerticalContentAlignment="Center" FontSize="14" />
                                <Button Name="btnSearch" Grid.Column="1" Content="Search" Margin="10,0,0,0" Style="{StaticResource FluentButton}" />
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

# --- CONTROLS REFERENCES ---
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
$btnSearch = $window.FindName("btnSearch")
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

# --- THEME MANAGEMENT ---
$isDark = $true
function Set-Theme {
    param([bool]$dark)
    $res = $window.Resources
    $c = New-Object System.Windows.Media.BrushConverter

    if ($dark) {
        $res["BgBase"]      = $c.ConvertFromString("#202020")
        $res["BgCard"]      = $c.ConvertFromString("#2b2b2b")
        $res["BgLayer"]     = $c.ConvertFromString("#252525")
        $res["BgFooter"]    = $c.ConvertFromString("#1c1c1c")
        $res["BgInput"]     = $c.ConvertFromString("#333333")
        $res["BgHover"]     = $c.ConvertFromString("#3e3e3e")
        $res["BorderColor"] = $c.ConvertFromString("#454545")
        $res["TextPrimary"] = $c.ConvertFromString("#ffffff")
        $res["TextSecondary"] = $c.ConvertFromString("#aaaaaa")
        $res["Accent"]      = $c.ConvertFromString("#4cc2ff")
        $res["ScrollThumb"] = $c.ConvertFromString("#555555")
        $res["ButtonTextForeground"] = $c.ConvertFromString("#000000")
        $res["IconBrush"]   = $c.ConvertFromString("#ffffff")
        $iconThemeHolder.Content = $window.Resources["IconSun"]
        try { $hwnd = [System.Diagnostics.Process]::GetCurrentProcess().MainWindowHandle; if($hwnd -ne 0){[Win32]::SetDarkMode($hwnd, $true)} } catch {}
    } else {
        $res["BgBase"]      = $c.ConvertFromString("#F0F0F0")
        $res["BgCard"]      = $c.ConvertFromString("#FFFFFF")
        $res["BgLayer"]     = $c.ConvertFromString("#FFFFFF")
        $res["BgFooter"]    = $c.ConvertFromString("#D0D0D0")
        $res["BgInput"]     = $c.ConvertFromString("#FFFFFF")
        $res["BgHover"]     = $c.ConvertFromString("#F5F5F5")
        $res["BorderColor"] = $c.ConvertFromString("#D0D0D0")
        $res["TextPrimary"] = $c.ConvertFromString("#000000")
        $res["TextSecondary"] = $c.ConvertFromString("#505050")
        $res["Accent"]      = $c.ConvertFromString("#0067c0")
        $res["ScrollThumb"] = $c.ConvertFromString("#909090")
        $res["ButtonTextForeground"] = $c.ConvertFromString("#ffffff")
        $res["IconBrush"]   = $c.ConvertFromString("#000000")
        $iconThemeHolder.Content = $window.Resources["IconMoon"]
        try { $hwnd = [System.Diagnostics.Process]::GetCurrentProcess().MainWindowHandle; if($hwnd -ne 0){[Win32]::SetDarkMode($hwnd, $false)} } catch {}
    }
}

# --- VIEW SWITCHING LOGIC ---
function Switch-View($viewName) {
    $viewCategory.Visibility = "Collapsed"
    $viewSearch.Visibility = "Collapsed"
    $viewBackup.Visibility = "Collapsed"

    switch ($viewName) {
        "Category" { $viewCategory.Visibility = "Visible" }
        "Search"   { $viewSearch.Visibility = "Visible" }
        "Backup"   { $viewBackup.Visibility = "Visible" }
    }
}

# --- POPULATE CONFIG CATEGORIES ---
if ($configLoaded -and $config.InstallerConfig.WingetApps.Category) {
    foreach ($category in $config.InstallerConfig.WingetApps.Category) {
        $tabItem = New-Object System.Windows.Controls.TabItem
        $tabItem.Header = $category.Name
        $tabItem.Tag = $category
        $tabCategories.Items.Add($tabItem) | Out-Null
    }
}

# --- TAB EVENTS ---
$tabCategories.Add_SelectionChanged({
    if ($tabCategories.SelectedItem -eq $null) { return }
    # Unselect Fixed Tabs
    $tabFixedTools.SelectedIndex = -1
    Switch-View "Category"

    $selectedTab = $tabCategories.SelectedItem
    $categoryData = $selectedTab.Tag
    $catName = $categoryData.Name
    $txtCategoryTitle.Text = $catName

    $pnlWingetContent.Children.Clear()

    $chkSelectAll = New-Object System.Windows.Controls.CheckBox
    $chkSelectAll.Content = "Select All ($catName)"
    $chkSelectAll.FontWeight = "Bold"
    $chkSelectAll.Margin = "0,0,0,15"
    $pnlWingetContent.Children.Add($chkSelectAll) | Out-Null

    $sep = New-Object System.Windows.Controls.Border
    $sep.Height = 1; $sep.Margin = "0,0,0,10"; $sep.SnapsToDevicePixels = $true
    $sep.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, "BorderColor")
    $pnlWingetContent.Children.Add($sep) | Out-Null

    if ($categoryData.App) {
        foreach ($app in $categoryData.App) {
            $chk = New-Object System.Windows.Controls.CheckBox
            $chk.Content = $app.Name
            $chk.Tag = $app.Id
            if ($script:selectionState.ContainsKey($app.Id) -and $script:selectionState[$app.Id] -eq $true) {
                $chk.IsChecked = $true
            }
            $chk.Add_Checked({ $script:selectionState[$this.Tag] = $true })
            $chk.Add_Unchecked({ $script:selectionState[$this.Tag] = $false })
            $pnlWingetContent.Children.Add($chk) | Out-Null
        }
    }

    $chkSelectAll.Add_Click({
        $currentState = $this.IsChecked
        foreach ($element in $pnlWingetContent.Children) {
            if ($element -is [System.Windows.Controls.CheckBox] -and $element -ne $this) {
                $element.IsChecked = $currentState
                $script:selectionState[$element.Tag] = $currentState
            }
        }
    })
})

$tabFixedTools.Add_SelectionChanged({
    if ($tabFixedTools.SelectedItem -eq $null) { return }
    # Unselect Categories
    $tabCategories.SelectedIndex = -1

    if ($tabFixedTools.SelectedItem -eq $tabSearch) {
        Switch-View "Search"
    } elseif ($tabFixedTools.SelectedItem -eq $tabBackup) {
        Switch-View "Backup"
    }
})

# --- LOCAL APPS POPULATION ---
if ($configLoaded -and $config.InstallerConfig.LocalApps.App) {
    foreach ($localApp in $config.InstallerConfig.LocalApps.App) {
        $btn = New-Object System.Windows.Controls.Button
        $btn.Content = $localApp.Name
        $btn.Tag = @{ Path = $localApp.Path; Args = $localApp.Args }
        $btn.Style = $window.Resources["FluentButton"]
        $btn.HorizontalContentAlignment = "Left"
        $btn.Margin = "0,0,0,8"

        $btn.Add_Click({
            $props = $this.Tag
            $fullPath = Join-Path $script:ScriptDir $props.Path
            $workDir = Split-Path -Parent $fullPath

            if (Test-Path $fullPath) {
                $txtStatusFooter.Text = "Running: $($this.Content)"
                if ($fullPath.ToLower().EndsWith(".msi")) {
                    $msiArgs = "/i `"$fullPath`" /qn"
                    if ($props.Args) { $msiArgs = "/i `"$fullPath`" $($props.Args)" }
                    Start-Process "msiexec.exe" $msiArgs -WorkingDirectory $workDir
                }
                else {
                    if ($props.Args) { Start-Process -FilePath $fullPath -ArgumentList $props.Args -WorkingDirectory $workDir }
                    else { Start-Process -FilePath $fullPath -WorkingDirectory $workDir }
                }
            } else { $txtStatusFooter.Text = "Error: File not found ($fullPath)" }
        })
        [void]$pnlLocalApps.Children.Add($btn)
    }
}

# --- SEARCH FEATURE LOGIC ---
$btnSearch.Add_Click({
    $query = $txtSearch.Text
    if ([string]::IsNullOrWhiteSpace($query)) { return }

    $btnSearch.IsEnabled = $false
    $txtStatusFooter.Text = "Searching repositories... This may take a moment."
    $lvSearchResults.ItemsSource = $null
    [System.Windows.Forms.Application]::DoEvents()

    try {
        # Run winget search
        # Using specific arguments to get cleaner output if possible, but parsing is key
        $proc = Start-Process "winget" -ArgumentList "search --accept-source-agreements `"$query`"" -NoNewWindow -Wait -PassThru -RedirectStandardOutput "$env:TEMP\winget_search.tmp"

        $lines = Get-Content "$env:TEMP\winget_search.tmp" -Encoding UTF8
        $results = @()

        # Simple parsing strategy: Skip header, look for lines with ID
        # Winget table usually: Name, Id, Version, Match, Source
        foreach ($line in $lines) {
            if ($line -match "^\s*Name\s+Id" -or $line -match "^-+" -or [string]::IsNullOrWhiteSpace($line)) { continue }

            # Split by 2 or more spaces to separate columns roughly
            $parts = $line -split "\s{2,}"
            if ($parts.Count -ge 3) {
                $obj = New-Object PSObject
                $obj | Add-Member -MemberType NoteProperty -Name "IsSelected" -Value $false
                $obj | Add-Member -MemberType NoteProperty -Name "Name" -Value $parts[0].Trim()
                $obj | Add-Member -MemberType NoteProperty -Name "Id" -Value $parts[1].Trim()
                $obj | Add-Member -MemberType NoteProperty -Name "Version" -Value $parts[2].Trim()

                # Source is usually the last one, sometimes there is a 'Match' column in between
                if ($parts.Count -ge 4) { $obj | Add-Member -MemberType NoteProperty -Name "Source" -Value $parts[$parts.Count -1].Trim() }
                else { $obj | Add-Member -MemberType NoteProperty -Name "Source" -Value "Unknown" }

                $results += $obj
            }
        }
        $lvSearchResults.ItemsSource = $results
        $txtStatusFooter.Text = "Found $($results.Count) applications."
    } catch {
        $txtStatusFooter.Text = "Search failed."
    }
    $btnSearch.IsEnabled = $true
})

# --- INSTALL LOGIC (SHARED) ---
function Install-AppList($appList) {
    if ($appList.Count -eq 0) {
        $txtStatusFooter.Text = "No applications selected."
        return
    }

    $pbInstall.Maximum = $appList.Count
    $pbInstall.Value = 0
    $failedList = @()
    $isRepairDone = $false

    foreach ($app in $appList) {
        $appName = $app.Name
        $appId = $app.Id
        $txtStatusFooter.Text = "Installing: $appName..."
        [System.Windows.Forms.Application]::DoEvents()

        $sourceParam = "--source winget"
        if ($app.Source -match "msstore" -or ($appId -notmatch "\." -and $appId -match "^[a-zA-Z0-9]+$")) {
            $sourceParam = "--source msstore"
        }

        $baseArgs = "install --id $appId -e --silent --disable-interactivity --accept-package-agreements --accept-source-agreements --ignore-security-hash"
        $finalArgs = "$baseArgs $sourceParam"

        function Run-Winget($argsStr) {
            return Start-Process "winget" $argsStr -NoNewWindow -Wait -PassThru
        }

        try {
            $proc = Run-Winget $finalArgs

            # --- ERROR HANDLING & REPAIR LOGIC ---
            $isCertificateError = $proc.ExitCode -eq -1978335138
            $isSourceError = ($proc.ExitCode -eq -2145844844) -or ($proc.ExitCode -eq -1978335212)

            if (($isCertificateError -or $isSourceError) -and -not $isRepairDone) {
                $txtStatusFooter.Text = "Source Error detected. Attempting repair..."
                [System.Windows.Forms.Application]::DoEvents()
                Run-Winget "source reset --force"
                Run-Winget "source update"
                $isRepairDone = $true
                $txtStatusFooter.Text = "Retrying $appName..."
                [System.Windows.Forms.Application]::DoEvents()
                $proc = Run-Winget $finalArgs
            }

            if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne -1978335189) {
                $failedList += "$appName (Code: $($proc.ExitCode))"
            }
        } catch {
             $failedList += "$appName (Script Error)"
        }
        $pbInstall.Value += 1
    }

    if ($failedList.Count -gt 0) {
        $txtStatusFooter.Text = "Completed with errors."
        [System.Windows.Forms.MessageBox]::Show("Failed:`n" + ($failedList -join "`n"), "Warning", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
    } else {
        $txtStatusFooter.Text = "All operations completed successfully."
        [System.Windows.Forms.MessageBox]::Show("Installation Successful!", "Success", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
    }
}

# --- INSTALL BUTTONS ---
$btnInstall.Add_Click({
    if (-not $configLoaded) { return }
    $appsToInstall = @()
    if ($config.InstallerConfig.WingetApps.Category) {
        foreach ($cat in $config.InstallerConfig.WingetApps.Category) {
            foreach ($app in $cat.App) {
                if ($script:selectionState.ContainsKey($app.Id) -and $script:selectionState[$app.Id] -eq $true) {
                    $appsToInstall += $app
                }
            }
        }
    }
    $btnInstall.IsEnabled = $false
    Install-AppList $appsToInstall
    $btnInstall.IsEnabled = $true
})

$btnInstallSearch.Add_Click({
    if ($lvSearchResults.ItemsSource -eq $null) { return }
    $selected = @()
    foreach ($item in $lvSearchResults.ItemsSource) {
        if ($item.IsSelected) { $selected += $item }
    }
    $btnInstallSearch.IsEnabled = $false
    Install-AppList $selected
    $btnInstallSearch.IsEnabled = $true
})

# --- BACKUP & RESTORE LOGIC ---
$btnBackup.Add_Click({
    $sfd = New-Object System.Windows.Forms.SaveFileDialog
    $sfd.Filter = "JSON Files (*.json)|*.json"
    $sfd.FileName = "winget-backup-$(Get-Date -Format 'yyyyMMdd').json"

    if ($sfd.ShowDialog() -eq "OK") {
        $txtBackupStatus.Text = "Exporting list... Please wait."
        [System.Windows.Forms.Application]::DoEvents()
        try {
            Start-Process "winget" -ArgumentList "export -o `"$($sfd.FileName)`" --include-versions" -NoNewWindow -Wait
            $txtBackupStatus.Text = "Export saved to: $($sfd.FileName)"
            [System.Windows.Forms.MessageBox]::Show("Backup completed successfully!", "Backup", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        } catch {
            $txtBackupStatus.Text = "Export failed."
        }
    }
})

$btnRestore.Add_Click({
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Filter = "JSON Files (*.json)|*.json"

    if ($ofd.ShowDialog() -eq "OK") {
        $txtBackupStatus.Text = "Restoring from file... Check console if needed."
        [System.Windows.Forms.Application]::DoEvents()
        try {
            Start-Process "winget" -ArgumentList "import -i `"$($ofd.FileName)`" --accept-package-agreements --accept-source-agreements" -NoNewWindow -Wait
            $txtBackupStatus.Text = "Restore completed."
            [System.Windows.Forms.MessageBox]::Show("Packages have been processed. Some might require manual intervention if unavailable.", "Restore", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        } catch {
            $txtBackupStatus.Text = "Restore failed."
        }
    }
})

# --- THEME BUTTON ---
$btnThemeToggle.Add_Click({ $script:isDark = -not $script:isDark; Set-Theme $script:isDark })

# --- AUTHOR LINK ---
$txtAuthorLink.Add_MouseLeftButtonDown({ try { Start-Process "https://www.osmanonurkoc.com" } catch {} })

# On Load
$window.Add_Loaded({
    if ($tabCategories.Items.Count -gt 0) { $tabCategories.SelectedIndex = 0 }
    else { $tabFixedTools.SelectedIndex = 0 } # Fallback if no config

    try { $hwnd = [System.Windows.Interop.WindowInteropHelper]::new($window).Handle; [Win32]::SetDarkMode($hwnd, $true) } catch {}
    Set-Theme $true
})

$window.ShowDialog() | Out-Null
