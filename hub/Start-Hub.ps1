<#
.SYNOPSIS
    The ADesk Cleaner hub: one window to find, read about, preview and run every
    script in this repository.

.DESCRIPTION
    Reads hub\catalog.json for the list of scripts, their groups, and the
    elevation and risk notes; reads each script's OWN comment-based help and
    parameter block through the PowerShell parser, so the form you fill in always
    matches the script and there is no second copy of the parameters to keep in
    sync; and starts the script you pick in a NEW console window, elevated when
    you tick the box.

    The launch is a -Command invocation rather than -File, which is what lets the
    hub do the two things the .cmd launchers cannot: turn a default-on [bool]
    off (-RemoveApps:$false) and pass a real list (-Scope 'Intel','ASUS'). The
    exact command line is shown before you run it and can be copied.

    Every script keeps its own console window open until you press Enter, so
    its output, its prompts and its exit code are all there to read.

    Light and dark themes: the toggle in the header switches live and the choice
    is remembered in %LOCALAPPDATA%\ADeskCleaner\hub-settings.json. On first run
    the hub follows the Windows app theme.

.PARAMETER SelfTest
    Load the catalogue, parse every script, build the window and every parameter
    form in both themes, and exit without showing anything. Exit 0 means healthy.

.EXAMPLE
    ..\Start-Hub.cmd
    Double-click from Explorer. Opens the hub with no console.

.EXAMPLE
    .\Start-Hub.ps1 -SelfTest
    Prints one line per script and exits.

.NOTES
    Windows PowerShell 5.1, WPF (PresentationFramework). No modules, no build.
#>
[CmdletBinding()]
param([switch]$SelfTest)

$ErrorActionPreference = 'Stop'

# WPF needs a single-threaded apartment. powershell.exe is STA by default; an
# -MTA host or a hosted runspace is not, so relaunch rather than fail.
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', ('"{0}"' -f $PSCommandPath))
    if ($SelfTest) { $argList += '-SelfTest' }
    $p = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $argList -Wait -PassThru
    exit $p.ExitCode
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

$script:HubRoot      = $PSScriptRoot
$script:RepoRoot     = Split-Path -Parent $PSScriptRoot
$script:PS51         = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script:SettingsPath = Join-Path $env:LOCALAPPDATA 'ADeskCleaner\hub-settings.json'

# =============================================================================
# Themes
# =============================================================================
# Every colour in the window is a DynamicResource brush keyed by one of these
# names, in XAML and in the elements built in code alike, so swapping the
# dictionary re-skins the whole window live.

$script:Themes = @{
    light = @{
        BgWindow = '#F3F4F6'; BgPanel = '#FFFFFF'; Border = '#E5E7EB'
        Text = '#111827'; TextBody = '#374151'; TextMuted = '#6B7280'
        Accent = '#2563EB'; AccentDark = '#1D4ED8'; Danger = '#DC2626'; DangerDark = '#B91C1C'
        FieldBg = '#FFFFFF'; FieldBorder = '#D1D5DB'; CodeBg = '#F9FAFB'
        CardBg = '#FFFFFF'; CardSelectedBg = '#EFF6FF'; CardHoverBorder = '#93C5FD'
        BtnBg = '#FFFFFF'; BtnFg = '#111827'; BtnBorder = '#D1D5DB'
        PopupBg = '#FFFFFF'; ItemHoverBg = '#EFF6FF'
        BadgeAmberBg = '#FEF3C7'; BadgeAmberFg = '#92400E'; BadgeRedBg = '#FEE2E2'; BadgeRedFg = '#991B1B'
        BadgeBlueBg = '#DBEAFE'; BadgeBlueFg = '#1E40AF'; BadgeGreenBg = '#DCFCE7'; BadgeGreenFg = '#166534'
        BadgeSolidBg = '#111827'; BadgeSolidFg = '#FFFFFF'
    }
    dark = @{
        BgWindow = '#0F172A'; BgPanel = '#1E293B'; Border = '#334155'
        Text = '#F1F5F9'; TextBody = '#CBD5E1'; TextMuted = '#94A3B8'
        Accent = '#3B82F6'; AccentDark = '#2563EB'; Danger = '#EF4444'; DangerDark = '#DC2626'
        FieldBg = '#0F172A'; FieldBorder = '#475569'; CodeBg = '#0B1220'
        CardBg = '#1E293B'; CardSelectedBg = '#1E3A5F'; CardHoverBorder = '#60A5FA'
        BtnBg = '#334155'; BtnFg = '#F1F5F9'; BtnBorder = '#475569'
        PopupBg = '#1E293B'; ItemHoverBg = '#1E3A5F'
        BadgeAmberBg = '#78350F'; BadgeAmberFg = '#FDE68A'; BadgeRedBg = '#7F1D1D'; BadgeRedFg = '#FECACA'
        BadgeBlueBg = '#1E3A8A'; BadgeBlueFg = '#BFDBFE'; BadgeGreenBg = '#14532D'; BadgeGreenFg = '#BBF7D0'
        BadgeSolidBg = '#F1F5F9'; BadgeSolidFg = '#0F172A'
    }
}

# The XAML brushes are mutated in place rather than replaced. Two reasons: a
# SolidColorBrush declared in XAML is not frozen, so changing its Color reaches
# every consumer at once; and an object assigned through the ResourceDictionary
# indexer from PowerShell arrives wrapped in a PSObject, which WPF cannot use as
# a Brush - it falls back to the string form and throws "'#FFF1F5F9' is not a
# valid value for property 'Foreground'". Only a key missing from the XAML is
# inserted, unwrapped, as a new brush.
function Set-Theme {
    param([string]$Name)
    if (-not $script:Themes.ContainsKey($Name)) { $Name = 'light' }
    $t = $script:Themes[$Name]
    foreach ($k in $t.Keys) {
        $color = [System.Windows.Media.ColorConverter]::ConvertFromString($t[$k])
        $existing = $script:Window.Resources[$k]
        if ($existing -is [System.Windows.Media.SolidColorBrush] -and -not $existing.IsFrozen) {
            $existing.Color = $color
        } else {
            $brush = New-Object System.Windows.Media.SolidColorBrush ($color)
            $script:Window.Resources[$k] = $brush.psobject.BaseObject
        }
    }
    $script:Theme = $Name
}

function Get-Settings {
    $s = [pscustomobject]@{ theme = '' }
    try {
        if (Test-Path -LiteralPath $script:SettingsPath) {
            $j = Get-Content -LiteralPath $script:SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.theme) { $s.theme = "$($j.theme)" }
        }
    } catch { }
    $s
}

function Save-Settings {
    param($Settings)
    try {
        $dir = Split-Path -Parent $script:SettingsPath
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $Settings | ConvertTo-Json | Set-Content -LiteralPath $script:SettingsPath -Encoding UTF8
    } catch { }
}

# Windows' own "choose your default app mode" setting, for the first run.
function Get-SystemTheme {
    try {
        $v = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop
        if ($v.AppsUseLightTheme -eq 0) { return 'dark' }
    } catch { }
    'light'
}

# =============================================================================
# Catalogue and script metadata
# =============================================================================

function Get-Catalog {
    $path = Join-Path $script:HubRoot 'catalog.json'
    if (-not (Test-Path -LiteralPath $path)) { throw "catalog.json not found beside the hub: $path" }
    $cat = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($s in $cat.scripts) {
        $full = Join-Path $script:RepoRoot ($s.file -replace '/', '\')
        Add-Member -InputObject $s -NotePropertyName FullPath -NotePropertyValue $full
        Add-Member -InputObject $s -NotePropertyName Exists   -NotePropertyValue (Test-Path -LiteralPath $full -PathType Leaf)
        Add-Member -InputObject $s -NotePropertyName Info     -NotePropertyValue $null
    }
    $cat
}

# Comment-based help arrives with the source indentation; strip the common
# indent and the surrounding blank lines but keep the line structure, because
# several descriptions carry aligned tables.
function Format-HelpText {
    param([string]$Text, [switch]$Flow)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $lines = $Text -replace "`r", '' -split "`n"
    $indent = ($lines | Where-Object { $_.Trim() } | ForEach-Object { ($_ -replace '^(\s*).*$', '$1').Length } | Measure-Object -Minimum).Minimum
    if (-not $indent) { $indent = 0 }
    $out = $lines | ForEach-Object { if ($_.Length -ge $indent) { $_.Substring($indent).TrimEnd() } else { $_.TrimEnd() } }
    $joined = (($out -join "`n").Trim("`n", ' '))
    if ($Flow) {
        # Parameter help is prose hard-wrapped at 80 columns: re-flow each
        # paragraph so the window wraps it, keeping only the blank-line breaks.
        $joined = (($joined -split "`n`n+") | ForEach-Object { ($_ -split "`n" | ForEach-Object { $_.Trim() }) -join ' ' }) -join "`n`n"
    }
    $joined
}

function Get-ScriptInfo {
    param([string]$Path)
    $tokens = $null; $errors = $null
    $ast  = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    $help = $ast.GetHelpContent()
    $lines = [IO.File]::ReadAllLines($Path)
    $params = @()
    if ($ast.ParamBlock) {
        foreach ($p in $ast.ParamBlock.Parameters) {
            $name    = $p.Name.VariablePath.UserPath
            $typeAst = $p.Attributes | Where-Object { $_ -is [System.Management.Automation.Language.TypeConstraintAst] } | Select-Object -First 1
            $type    = if ($typeAst) { $typeAst.TypeName.FullName } else { 'object' }
            $vset = @(); $aliases = @()
            foreach ($a in $p.Attributes) {
                if ($a -isnot [System.Management.Automation.Language.AttributeAst]) { continue }
                if ($a.TypeName.Name -eq 'ValidateSet') { $vset    = @($a.PositionalArguments | ForEach-Object { "$($_.Value)" }) }
                if ($a.TypeName.Name -eq 'Alias')       { $aliases = @($a.PositionalArguments | ForEach-Object { "$($_.Value)" }) }
            }
            $default = if ($p.DefaultValue) { $p.DefaultValue.Extent.Text } else { '' }
            $doc = ''
            if ($help -and $help.Parameters) {
                foreach ($k in $help.Parameters.Keys) { if ($k -ieq $name) { $doc = $help.Parameters[$k]; break } }
            }
            if (-not $doc) {
                # No .PARAMETER block: fall back to a trailing comment on the param line.
                $src = $lines[$p.Extent.StartLineNumber - 1]
                if ($src -match '#\s*(.+)$') { $doc = $Matches[1] }
            }
            $params += [pscustomobject]@{
                Name = $name; Type = $type
                IsSwitch = ($type -eq 'switch'); IsBool = ($type -eq 'bool'); IsArray = $type.EndsWith('[]'); IsInt = ($type -in 'int','long')
                Default = $default; ValidateSet = $vset; Aliases = $aliases; Help = (Format-HelpText $doc -Flow)
            }
        }
    }
    [pscustomobject]@{
        Synopsis    = Format-HelpText $(if ($help) { $help.Synopsis } else { '' }) -Flow
        Description = Format-HelpText $(if ($help) { $help.Description } else { '' })
        Examples    = @($(if ($help) { @($help.Examples) } else { @() }) | ForEach-Object { Format-HelpText $_ } | Where-Object { $_ })
        Notes       = Format-HelpText $(if ($help) { $help.Notes } else { '' })
        Parameters  = $params
        ParseErrors = @($errors).Count
    }
}

function Get-InfoFor {
    param($Script)
    if (-not $Script.Info -and $Script.Exists) { $Script.Info = Get-ScriptInfo -Path $Script.FullPath }
    $Script.Info
}

# =============================================================================
# Command line construction
# =============================================================================

# Single quotes only: the whole command travels inside -Command "...", so a
# double quote in a value would end the argument early. Paths cannot carry one;
# a typed value that does is stripped of it.
function ConvertTo-PsLiteral {
    param([string]$Value)
    "'" + (($Value -replace '"', '') -replace "'", "''") + "'"
}

function Get-ArgumentTokens {
    param($Script, [bool]$Preview)
    $tokens = New-Object 'System.Collections.Generic.List[string]'
    $info = Get-InfoFor $Script
    foreach ($p in @($info.Parameters)) {
        if (-not $script:ParamControls.ContainsKey($p.Name)) { continue }
        $ctl = $script:ParamControls[$p.Name]
        if ($p.IsSwitch) {
            if ($ctl.IsChecked) { $tokens.Add("-$($p.Name)") }
            continue
        }
        if ($p.IsBool) {
            $defaultOn = ($p.Default -match '^\$true$')
            $on = [bool]$ctl.IsChecked
            if ($on -ne $defaultOn) { $tokens.Add(('-{0}:${1}' -f $p.Name, $on.ToString().ToLower())) }
            continue
        }
        if ($ctl -is [System.Windows.Controls.ComboBox]) {
            $v = "$($ctl.SelectedItem)"
            $d = $p.Default.Trim("'", '"')
            if ($v -and $v -ne $d) { $tokens.Add("-$($p.Name) " + (ConvertTo-PsLiteral $v)) }
            continue
        }
        $text = "$($ctl.Text)".Trim()
        if (-not $text) { continue }
        if ($p.IsArray) {
            $items = @($text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            $tokens.Add("-$($p.Name) " + (($items | ForEach-Object { ConvertTo-PsLiteral $_ }) -join ','))
        } elseif ($p.IsInt) {
            $n = 0
            if (-not [int]::TryParse($text, [ref]$n)) { throw "-$($p.Name) must be a whole number (got '$text')." }
            $tokens.Add("-$($p.Name) $n")
        } else {
            $tokens.Add("-$($p.Name) " + (ConvertTo-PsLiteral $text))
        }
    }
    if ($Preview) {
        foreach ($a in @($Script.preview)) { if ($a -and -not $tokens.Contains($a)) { $tokens.Add($a) } }
    }
    , $tokens
}

# The console stays open until Enter so the output, the prompts and the exit
# code can be read. Built from single-quoted pieces: '' is one quote.
function Get-CommandText {
    param($Script, $Tokens)
    $inner = '& ' + (ConvertTo-PsLiteral $Script.FullPath)
    if ($Tokens.Count) { $inner += ' ' + ($Tokens -join ' ') }
    '& { $Host.UI.RawUI.WindowTitle = ' + (ConvertTo-PsLiteral $Script.name) + '; ' + $inner +
    '; $rc = $LASTEXITCODE; if ($null -eq $rc) { $rc = 0 }; Write-Host ''''; ' +
    'Write-Host (''Finished with exit code {0}.'' -f $rc) -ForegroundColor Cyan; ' +
    'Write-Host ''Press Enter to close this window.''; [void](Read-Host); exit $rc }'
}

function Get-LaunchLine {
    param($Script, $Tokens)
    '"{0}" -NoProfile -ExecutionPolicy Bypass -Command "{1}"' -f $script:PS51, (Get-CommandText $Script $Tokens)
}

function Start-CatalogScript {
    param($Script, [bool]$Preview, [bool]$Elevated)
    $tokens  = Get-ArgumentTokens -Script $Script -Preview $Preview
    $argLine = '-NoProfile -ExecutionPolicy Bypass -Command "' + (Get-CommandText $Script $tokens) + '"'
    $sp = @{
        FilePath         = $script:PS51
        ArgumentList     = $argLine
        WorkingDirectory = (Split-Path -Parent $Script.FullPath)
    }
    if ($Elevated) { $sp['Verb'] = 'RunAs' }
    Start-Process @sp | Out-Null
    (Get-LaunchLine $Script $tokens)
}

# =============================================================================
# Window
# =============================================================================

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="ADesk Cleaner" Width="1260" Height="820" MinWidth="1000" MinHeight="620"
        WindowStartupLocation="CenterScreen" Background="{DynamicResource BgWindow}"
        FontFamily="Segoe UI" FontSize="13" TextOptions.TextFormattingMode="Display" UseLayoutRounding="True">
  <Window.Resources>
    <!-- theme brushes: light values here, replaced live by Set-Theme -->
    <SolidColorBrush x:Key="BgWindow" Color="#F3F4F6"/>
    <SolidColorBrush x:Key="BgPanel" Color="#FFFFFF"/>
    <SolidColorBrush x:Key="Border" Color="#E5E7EB"/>
    <SolidColorBrush x:Key="Text" Color="#111827"/>
    <SolidColorBrush x:Key="TextBody" Color="#374151"/>
    <SolidColorBrush x:Key="TextMuted" Color="#6B7280"/>
    <SolidColorBrush x:Key="Accent" Color="#2563EB"/>
    <SolidColorBrush x:Key="AccentDark" Color="#1D4ED8"/>
    <SolidColorBrush x:Key="Danger" Color="#DC2626"/>
    <SolidColorBrush x:Key="DangerDark" Color="#B91C1C"/>
    <SolidColorBrush x:Key="FieldBg" Color="#FFFFFF"/>
    <SolidColorBrush x:Key="FieldBorder" Color="#D1D5DB"/>
    <SolidColorBrush x:Key="CodeBg" Color="#F9FAFB"/>
    <SolidColorBrush x:Key="CardBg" Color="#FFFFFF"/>
    <SolidColorBrush x:Key="CardSelectedBg" Color="#EFF6FF"/>
    <SolidColorBrush x:Key="CardHoverBorder" Color="#93C5FD"/>
    <SolidColorBrush x:Key="BtnBg" Color="#FFFFFF"/>
    <SolidColorBrush x:Key="BtnFg" Color="#111827"/>
    <SolidColorBrush x:Key="BtnBorder" Color="#D1D5DB"/>
    <SolidColorBrush x:Key="PopupBg" Color="#FFFFFF"/>
    <SolidColorBrush x:Key="ItemHoverBg" Color="#EFF6FF"/>
    <SolidColorBrush x:Key="BadgeAmberBg" Color="#FEF3C7"/>
    <SolidColorBrush x:Key="BadgeAmberFg" Color="#92400E"/>
    <SolidColorBrush x:Key="BadgeRedBg" Color="#FEE2E2"/>
    <SolidColorBrush x:Key="BadgeRedFg" Color="#991B1B"/>
    <SolidColorBrush x:Key="BadgeBlueBg" Color="#DBEAFE"/>
    <SolidColorBrush x:Key="BadgeBlueFg" Color="#1E40AF"/>
    <SolidColorBrush x:Key="BadgeGreenBg" Color="#DCFCE7"/>
    <SolidColorBrush x:Key="BadgeGreenFg" Color="#166534"/>
    <SolidColorBrush x:Key="BadgeSolidBg" Color="#111827"/>
    <SolidColorBrush x:Key="BadgeSolidFg" Color="#FFFFFF"/>

    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="Background" Value="{DynamicResource BtnBg}"/>
      <Setter Property="Foreground" Value="{DynamicResource BtnFg}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource BtnBorder}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Opacity" Value="0.85"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="B" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="BtnPrimary" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="{DynamicResource Accent}"/>
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="BorderBrush" Value="{DynamicResource AccentDark}"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="BtnDanger" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="{DynamicResource Danger}"/>
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="BorderBrush" Value="{DynamicResource DangerDark}"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="Card" TargetType="ListBoxItem">
      <Setter Property="Margin" Value="0,0,0,6"/>
      <Setter Property="Padding" Value="12,9"/>
      <Setter Property="Background" Value="{DynamicResource CardBg}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource Border}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Border x:Name="B" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="BorderBrush" Value="{DynamicResource CardHoverBorder}"/></Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="B" Property="BorderBrush" Value="{DynamicResource Accent}"/>
                <Setter TargetName="B" Property="Background" Value="{DynamicResource CardSelectedBg}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Panel" TargetType="Border">
      <Setter Property="Background" Value="{DynamicResource BgPanel}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource Border}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="10"/>
      <Setter Property="Padding" Value="14"/>
    </Style>
    <Style x:Key="Field" TargetType="TextBox">
      <Setter Property="Padding" Value="8,6"/>
      <Setter Property="Background" Value="{DynamicResource FieldBg}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource FieldBorder}"/>
      <Setter Property="Foreground" Value="{DynamicResource Text}"/>
      <Setter Property="CaretBrush" Value="{DynamicResource Text}"/>
    </Style>
    <Style x:Key="Combo" TargetType="ComboBox">
      <Setter Property="Foreground" Value="{DynamicResource Text}"/>
      <Setter Property="Padding" Value="8,5"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <ToggleButton x:Name="Toggle" Focusable="False" ClickMode="Press"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border Background="{DynamicResource FieldBg}" BorderBrush="{DynamicResource FieldBorder}" BorderThickness="1" CornerRadius="4">
                      <Path HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,10,0" Data="M 0 0 L 4 4 L 8 0 Z" Fill="{DynamicResource TextMuted}"/>
                    </Border>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <ContentPresenter Content="{TemplateBinding SelectionBoxItem}" ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                                Margin="{TemplateBinding Padding}" VerticalAlignment="Center" HorizontalAlignment="Left" IsHitTestVisible="False"/>
              <Popup x:Name="PART_Popup" IsOpen="{TemplateBinding IsDropDownOpen}" Placement="Bottom" AllowsTransparency="True" Focusable="False" PopupAnimation="Fade">
                <Border Background="{DynamicResource PopupBg}" BorderBrush="{DynamicResource Border}" BorderThickness="1" CornerRadius="4"
                        MinWidth="{TemplateBinding ActualWidth}" MaxHeight="{TemplateBinding MaxDropDownHeight}" Margin="0,2,0,0">
                  <ScrollViewer VerticalScrollBarVisibility="Auto"><ItemsPresenter/></ScrollViewer>
                </Border>
              </Popup>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="ComboItem" TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="{DynamicResource Text}"/>
      <Setter Property="Padding" Value="8,5"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="B" Background="Transparent" Padding="{TemplateBinding Padding}"><ContentPresenter/></Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="B" Property="Background" Value="{DynamicResource ItemHoverBg}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="H1" TargetType="TextBlock">
      <Setter Property="FontSize" Value="22"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="{DynamicResource Text}"/>
    </Style>
    <Style x:Key="H2" TargetType="TextBlock">
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="{DynamicResource TextMuted}"/>
      <Setter Property="Margin" Value="0,14,0,6"/>
    </Style>
    <Style x:Key="Muted" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{DynamicResource TextMuted}"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <Style x:Key="Body" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{DynamicResource TextBody}"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <Style x:Key="Check" TargetType="CheckBox">
      <Setter Property="Foreground" Value="{DynamicResource TextBody}"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
  </Window.Resources>

  <Grid Margin="18,14,18,12">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="240"/>
      <ColumnDefinition Width="350"/>
      <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>

    <!-- header -->
    <DockPanel Grid.Row="0" Grid.ColumnSpan="3" Margin="0,0,0,12" LastChildFill="True">
      <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
        <CheckBox x:Name="ChkDark" Style="{StaticResource Check}" Content="Dark mode" Margin="0,0,18,0"/>
        <Button x:Name="BtnReadme" Style="{StaticResource Btn}" Content="Open README"/>
        <Button x:Name="BtnLogs"   Style="{StaticResource Btn}" Content="Open log folder" Margin="0"/>
      </StackPanel>
      <StackPanel>
        <TextBlock x:Name="TxtTitle" Style="{StaticResource H1}" Text="ADesk Cleaner"/>
        <TextBlock x:Name="TxtTagline" Style="{StaticResource Muted}" Margin="0,2,0,0"/>
      </StackPanel>
    </DockPanel>

    <!-- groups -->
    <Border Grid.Row="1" Grid.Column="0" Style="{StaticResource Panel}" Margin="0,0,12,0">
      <DockPanel LastChildFill="True">
        <TextBox x:Name="TxtSearch" DockPanel.Dock="Top" Style="{StaticResource Field}" Margin="0,0,0,10" ToolTip="Filter by name, file or summary"/>
        <TextBlock DockPanel.Dock="Top" Style="{StaticResource H2}" Text="GROUPS" Margin="0,0,0,6"/>
        <ListBox x:Name="LstGroups" BorderThickness="0" Background="Transparent" ItemContainerStyle="{StaticResource Card}"
                 ScrollViewer.HorizontalScrollBarVisibility="Disabled"/>
      </DockPanel>
    </Border>

    <!-- scripts -->
    <Border Grid.Row="1" Grid.Column="1" Style="{StaticResource Panel}" Margin="0,0,12,0">
      <DockPanel LastChildFill="True">
        <TextBlock x:Name="TxtListHeading" DockPanel.Dock="Top" Style="{StaticResource H2}" Text="SCRIPTS" Margin="0,0,0,6"/>
        <ListBox x:Name="LstScripts" BorderThickness="0" Background="Transparent" ItemContainerStyle="{StaticResource Card}"
                 ScrollViewer.HorizontalScrollBarVisibility="Disabled"/>
      </DockPanel>
    </Border>

    <!-- details -->
    <Border Grid.Row="1" Grid.Column="2" Style="{StaticResource Panel}">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <StackPanel Grid.Row="0" x:Name="PnlHeader">
          <TextBlock x:Name="TxtName" Style="{StaticResource H1}" FontSize="20" Text="Pick a script"/>
          <TextBlock x:Name="TxtFile" Style="{StaticResource Muted}" FontFamily="Consolas" FontSize="12" Margin="0,2,0,6"/>
          <WrapPanel x:Name="PnlBadges"/>
        </StackPanel>

        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" Margin="0,6,0,6" Padding="0,0,8,0">
          <StackPanel x:Name="PnlBody">
            <TextBlock x:Name="TxtSynopsis" Style="{StaticResource Body}" Foreground="{DynamicResource Text}" FontSize="14" Margin="0,4,0,0"/>
            <Expander x:Name="ExpDescription" Header="What it does" IsExpanded="False" Margin="0,10,0,0" Foreground="{DynamicResource TextBody}">
              <TextBlock x:Name="TxtDescription" Style="{StaticResource Body}" Margin="0,8,0,0"/>
            </Expander>
            <TextBlock Style="{StaticResource H2}" Text="PARAMETERS"/>
            <StackPanel x:Name="PnlParams"/>
            <TextBlock Style="{StaticResource H2}" Text="RECENT LOGS (double-click to open)"/>
            <ListBox x:Name="LstLogs" BorderThickness="0" Background="Transparent" ItemContainerStyle="{StaticResource Card}" MaxHeight="170"/>
            <TextBlock x:Name="TxtNoLogs" Style="{StaticResource Muted}"/>
          </StackPanel>
        </ScrollViewer>

        <StackPanel Grid.Row="2">
          <Separator Margin="0,0,0,10" Background="{DynamicResource Border}"/>
          <DockPanel LastChildFill="True" Margin="0,0,0,8">
            <CheckBox x:Name="ChkElevated" Style="{StaticResource Check}" DockPanel.Dock="Left" Content="Run elevated (UAC prompt)" Margin="0,0,16,0"/>
            <TextBlock x:Name="TxtElevationNote" Style="{StaticResource Muted}" VerticalAlignment="Center"/>
          </DockPanel>
          <TextBox x:Name="TxtCommand" Style="{StaticResource Field}" IsReadOnly="True" FontFamily="Consolas" FontSize="11"
                   TextWrapping="Wrap" MaxHeight="72" VerticalScrollBarVisibility="Auto" Background="{DynamicResource CodeBg}" Foreground="{DynamicResource TextBody}"/>
          <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
            <Button x:Name="BtnPreview" Style="{StaticResource BtnPrimary}" Content="Preview (changes nothing)"/>
            <Button x:Name="BtnRun"     Style="{StaticResource BtnDanger}"  Content="Run"/>
            <Button x:Name="BtnFolder"  Style="{StaticResource Btn}" Content="Open script folder"/>
            <Button x:Name="BtnCopy"    Style="{StaticResource Btn}" Content="Copy command" Margin="0"/>
          </StackPanel>
        </StackPanel>
      </Grid>
    </Border>

    <!-- status -->
    <TextBlock Grid.Row="2" Grid.ColumnSpan="3" x:Name="TxtStatus" Style="{StaticResource Muted}" Margin="0,10,0,0"/>
  </Grid>
</Window>
'@

# Elements built in code take their colours by resource KEY, never by value, so
# the theme toggle reaches them too.
function New-TextBlock {
    param([string]$Text, [string]$Key = 'Text', [double]$Size = 13, [string]$Weight = 'Normal', [bool]$Wrap = $true, [string]$Font = '')
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Text
    $t.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $Key)
    $t.FontSize = $Size
    $t.FontWeight = [System.Windows.FontWeight]::FromOpenTypeWeight($(switch ($Weight) { 'SemiBold' { 600 } 'Bold' { 700 } default { 400 } }))
    if ($Wrap) { $t.TextWrapping = 'Wrap' }
    if ($Font) { $t.FontFamily = New-Object System.Windows.Media.FontFamily($Font) }
    $t
}

function New-Badge {
    param([string]$Text, [string]$Kind)
    $b = New-Object System.Windows.Controls.Border
    $b.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, "Badge${Kind}Bg")
    $b.CornerRadius = New-Object System.Windows.CornerRadius(10)
    $b.Padding      = New-Object System.Windows.Thickness(8, 2, 8, 2)
    $b.Margin       = New-Object System.Windows.Thickness(0, 0, 6, 4)
    $b.Child = New-TextBlock -Text $Text -Key "Badge${Kind}Fg" -Size 11 -Weight 'SemiBold' -Wrap $false
    $b
}

function Get-ElevationBadge {
    param([string]$Elevation)
    switch ($Elevation) {
        'self'     { New-Badge 'Elevates itself'  'Amber' }
        'required' { New-Badge 'Needs admin'      'Red' }
        'optional' { New-Badge 'Admin optional'   'Blue' }
        default    { New-Badge 'No admin needed'  'Green' }
    }
}

function Get-RiskBadge {
    param([string]$Risk)
    switch ($Risk) {
        'high'   { New-Badge 'Uninstalls software' 'Red' }
        'medium' { New-Badge 'Changes settings'    'Amber' }
        default  { New-Badge 'Low risk'            'Green' }
    }
}

function New-ScriptCard {
    param($Script)
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Children.Add((New-TextBlock -Text $Script.name -Weight 'SemiBold' -Size 14)) | Out-Null
    $sp.Children.Add((New-TextBlock -Text $Script.summary -Key 'TextMuted' -Size 12)) | Out-Null
    $wp = New-Object System.Windows.Controls.WrapPanel
    $wp.Margin = New-Object System.Windows.Thickness(0, 6, 0, 0)
    $wp.Children.Add((Get-ElevationBadge $Script.elevation)) | Out-Null
    $wp.Children.Add((Get-RiskBadge $Script.risk)) | Out-Null
    if (-not $Script.Exists) { $wp.Children.Add((New-Badge 'FILE MISSING' 'Solid')) | Out-Null }
    $sp.Children.Add($wp) | Out-Null
    $sp
}

# One row per parameter: label, control, help. Controls are kept by name so the
# command builder can read them back.
function Add-ParameterRow {
    param($Panel, $P)
    $row = New-Object System.Windows.Controls.Grid
    $row.Margin = New-Object System.Windows.Thickness(0, 0, 0, 10)
    $c0 = New-Object System.Windows.Controls.ColumnDefinition; $c0.Width = New-Object System.Windows.GridLength(230)
    $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = New-Object System.Windows.GridLength(1, 'Star')
    $row.ColumnDefinitions.Add($c0); $row.ColumnDefinitions.Add($c1)
    $r0 = New-Object System.Windows.Controls.RowDefinition; $r0.Height = 'Auto'
    $r1 = New-Object System.Windows.Controls.RowDefinition; $r1.Height = 'Auto'
    $row.RowDefinitions.Add($r0); $row.RowDefinitions.Add($r1)

    $label = New-TextBlock -Text ("-{0}" -f $P.Name) -Weight 'SemiBold' -Font 'Consolas' -Wrap $false
    $label.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($label, 0); [System.Windows.Controls.Grid]::SetRow($label, 0)
    $row.Children.Add($label) | Out-Null

    $defaultShown = ''
    if ($P.IsSwitch) {
        $ctl = New-Object System.Windows.Controls.CheckBox
        $ctl.Style = $script:Window.FindResource('Check')
        $ctl.Content = 'on'
    } elseif ($P.IsBool) {
        $ctl = New-Object System.Windows.Controls.CheckBox
        $ctl.Style = $script:Window.FindResource('Check')
        $ctl.IsChecked = ($P.Default -match '^\$true$')
        $ctl.Content = $(if ($ctl.IsChecked) { 'on (default on; untick to pass -{0}:$false)' -f $P.Name } else { 'off (default off)' })
    } elseif ($P.ValidateSet.Count -gt 0) {
        $ctl = New-Object System.Windows.Controls.ComboBox
        $ctl.Style = $script:Window.FindResource('Combo')
        $ctl.ItemContainerStyle = $script:Window.FindResource('ComboItem')
        foreach ($v in $P.ValidateSet) { $ctl.Items.Add($v) | Out-Null }
        $d = $P.Default.Trim("'", '"')
        if ($d -and $ctl.Items.Contains($d)) { $ctl.SelectedItem = $d } elseif ($ctl.Items.Count) { $ctl.SelectedIndex = 0 }
        $ctl.Width = 220; $ctl.HorizontalAlignment = 'Left'
    } else {
        $ctl = New-Object System.Windows.Controls.TextBox
        $ctl.Style = $script:Window.FindResource('Field')
        $ctl.MinWidth = 260; $ctl.HorizontalAlignment = 'Stretch'
        if ($P.Default) { $defaultShown = 'Default: ' + $P.Default + '. Leave empty to keep it.' }
        if ($P.IsArray) { $ctl.ToolTip = 'Comma-separated list' }
    }
    $ctl.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($ctl, 1); [System.Windows.Controls.Grid]::SetRow($ctl, 0)
    $row.Children.Add($ctl) | Out-Null
    $script:ParamControls[$P.Name] = $ctl

    $helpText = @()
    $meta = $P.Type
    if ($P.IsArray) { $meta += ', comma-separated' }
    if ($P.Aliases.Count) { $meta += ', alias -' + ($P.Aliases -join ', -') }
    $helpText += "[$meta]"
    if ($P.Help) { $helpText += $P.Help }
    if ($defaultShown) { $helpText += $defaultShown }
    $help = New-TextBlock -Text ($helpText -join '  ') -Key 'TextMuted' -Size 11
    $help.Margin = New-Object System.Windows.Thickness(0, 3, 0, 0)
    [System.Windows.Controls.Grid]::SetColumn($help, 1); [System.Windows.Controls.Grid]::SetRow($help, 1)
    $row.Children.Add($help) | Out-Null

    $Panel.Children.Add($row) | Out-Null
}

function Set-Status { param([string]$Text) $script:Ui.TxtStatus.Text = $Text }

function Update-CommandPreview {
    if (-not $script:Current) { $script:Ui.TxtCommand.Text = ''; return }
    try {
        $tokens = Get-ArgumentTokens -Script $script:Current -Preview $false
        $script:Ui.TxtCommand.Text = Get-LaunchLine $script:Current $tokens
    } catch {
        $script:Ui.TxtCommand.Text = $_.Exception.Message
    }
}

function Show-Logs {
    param($Script)
    $lst = $script:Ui.LstLogs
    $lst.Items.Clear()
    if (-not $Script.logPattern) {
        $script:Ui.TxtNoLogs.Text = 'This script prints to its console and writes no log file.'
        $lst.Visibility = 'Collapsed'; return
    }
    $logs = @(Get-ChildItem -Path $env:TEMP -Filter $Script.logPattern -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 8)
    if (-not $logs) {
        $script:Ui.TxtNoLogs.Text = ('No logs yet - they land in %TEMP% as {0}.' -f $Script.logPattern)
        $lst.Visibility = 'Collapsed'; return
    }
    $script:Ui.TxtNoLogs.Text = ''
    $lst.Visibility = 'Visible'
    foreach ($l in $logs) {
        $item = New-Object System.Windows.Controls.ListBoxItem
        $item.Style = $script:Window.FindResource('Card')
        $item.Padding = New-Object System.Windows.Thickness(10, 5, 10, 5)
        $item.Content = New-TextBlock -Text ('{0}   {1:yyyy-MM-dd HH:mm}   {2:N0} KB' -f $l.Name, $l.LastWriteTime, ($l.Length / 1KB)) -Key 'TextBody' -Font 'Consolas' -Size 11 -Wrap $false
        $item.Tag = $l.FullName
        $lst.Items.Add($item) | Out-Null
    }
}

function Show-Script {
    param($Script)
    $script:Current = $Script
    $script:ParamControls = @{}
    $ui = $script:Ui
    $ui.TxtName.Text = $Script.name
    $ui.TxtFile.Text = $Script.file
    $ui.PnlBadges.Children.Clear()
    $ui.PnlBadges.Children.Add((Get-ElevationBadge $Script.elevation)) | Out-Null
    $ui.PnlBadges.Children.Add((Get-RiskBadge $Script.risk)) | Out-Null
    $ui.PnlParams.Children.Clear()

    if (-not $Script.Exists) {
        $ui.TxtSynopsis.Text = 'The script file is missing: ' + $Script.FullPath
        $ui.TxtDescription.Text = ''
        $ui.TxtCommand.Text = ''
        $ui.BtnPreview.IsEnabled = $false; $ui.BtnRun.IsEnabled = $false
        return
    }
    $info = Get-InfoFor $Script
    $ui.TxtSynopsis.Text    = $(if ($info.Synopsis) { $info.Synopsis } else { $Script.summary })
    $ui.TxtDescription.Text = $(if ($info.Description) { $info.Description } else { '(no description in the script header)' })
    $ui.ExpDescription.IsExpanded = $false
    foreach ($p in @($info.Parameters)) { Add-ParameterRow -Panel $ui.PnlParams -P $p }
    if (-not @($info.Parameters).Count) { $ui.PnlParams.Children.Add((New-TextBlock -Text 'No parameters.' -Key 'TextMuted')) | Out-Null }

    $elevate = $Script.elevation -in 'self', 'required'
    $ui.ChkElevated.IsChecked = $elevate
    $ui.TxtElevationNote.Text = switch ($Script.elevation) {
        'self'     { 'Self-elevating script: starting it elevated avoids the second window and keeps the exit code.' }
        'required' { 'Needs an elevated window.' }
        'optional' { 'Per-user work needs no elevation; machine-wide items do.' }
        default    { 'Runs as you.' }
    }
    $ui.BtnPreview.IsEnabled = ($Script.preview -and @($Script.preview).Count -gt 0)
    $ui.BtnPreview.Content = $(if ($ui.BtnPreview.IsEnabled) { 'Preview  ' + (@($Script.preview) -join ' ') } else { 'No preview mode' })
    $ui.BtnRun.IsEnabled = $true

    # Any edit to the form refreshes the command line.
    foreach ($ctl in $script:ParamControls.Values) {
        if ($ctl -is [System.Windows.Controls.CheckBox]) {
            $ctl.Add_Checked({ Update-CommandPreview }); $ctl.Add_Unchecked({ Update-CommandPreview })
        } elseif ($ctl -is [System.Windows.Controls.ComboBox]) {
            $ctl.Add_SelectionChanged({ Update-CommandPreview })
        } else {
            $ctl.Add_TextChanged({ Update-CommandPreview })
        }
    }
    Update-CommandPreview
    Show-Logs $Script
    Set-Status ('{0} - {1} parameter(s) read from the script.' -f $Script.file, @($info.Parameters).Count)
}

function Update-ScriptList {
    $lst = $script:Ui.LstScripts
    $lst.Items.Clear()
    $groupId = $null
    if ($script:Ui.LstGroups.SelectedItem) { $groupId = $script:Ui.LstGroups.SelectedItem.Tag }
    $q = "$($script:Ui.TxtSearch.Text)".Trim()
    $shown = 0
    foreach ($s in $script:Catalog.scripts) {
        if ($groupId -and $s.group -ne $groupId) { continue }
        if ($q -and -not ("$($s.name) $($s.file) $($s.summary)" -imatch [regex]::Escape($q))) { continue }
        $item = New-Object System.Windows.Controls.ListBoxItem
        $item.Style = $script:Window.FindResource('Card')
        $item.Content = New-ScriptCard $s
        $item.Tag = $s
        $lst.Items.Add($item) | Out-Null
        $shown++
    }
    $script:Ui.TxtListHeading.Text = ('SCRIPTS ({0})' -f $shown)
    if ($shown -gt 0) { $lst.SelectedIndex = 0 }
}

function Initialize-Window {
    $reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
    $script:Window = [System.Windows.Markup.XamlReader]::Load($reader)
    $script:Ui = @{}
    foreach ($n in 'TxtTitle','TxtTagline','ChkDark','BtnReadme','BtnLogs','TxtSearch','LstGroups','TxtListHeading','LstScripts',
                   'TxtName','TxtFile','PnlBadges','TxtSynopsis','ExpDescription','TxtDescription','PnlParams','LstLogs','TxtNoLogs',
                   'ChkElevated','TxtElevationNote','TxtCommand','BtnPreview','BtnRun','BtnFolder','BtnCopy','TxtStatus') {
        $el = $script:Window.FindName($n)
        if (-not $el) { throw "XAML element missing: $n" }
        $script:Ui[$n] = $el
    }
    $ui = $script:Ui
    $ui.TxtTitle.Text   = $script:Catalog.title
    $ui.TxtTagline.Text = $script:Catalog.tagline
    $script:Window.Title = $script:Catalog.title

    # Theme: remembered choice, else the Windows app mode.
    $script:Settings = Get-Settings
    $initial = $(if ($script:Settings.theme) { $script:Settings.theme } else { Get-SystemTheme })
    Set-Theme $initial
    $ui.ChkDark.IsChecked = ($script:Theme -eq 'dark')
    $applyTheme = {
        $name = $(if ($script:Ui.ChkDark.IsChecked) { 'dark' } else { 'light' })
        Set-Theme $name
        $script:Settings.theme = $name
        Save-Settings $script:Settings
        Set-Status ('{0} theme. Remembered in {1}.' -f $(if ($name -eq 'dark') { 'Dark' } else { 'Light' }), $script:SettingsPath)
    }
    $ui.ChkDark.Add_Checked($applyTheme); $ui.ChkDark.Add_Unchecked($applyTheme)

    # Groups: "All" first, then the catalogue order.
    $all = New-Object System.Windows.Controls.ListBoxItem
    $all.Style = $script:Window.FindResource('Card')
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Children.Add((New-TextBlock -Text 'All scripts' -Weight 'SemiBold')) | Out-Null
    $sp.Children.Add((New-TextBlock -Text ('{0} scripts' -f @($script:Catalog.scripts).Count) -Key 'TextMuted' -Size 11)) | Out-Null
    $all.Content = $sp; $all.Tag = $null
    $ui.LstGroups.Items.Add($all) | Out-Null
    foreach ($g in $script:Catalog.groups) {
        $item = New-Object System.Windows.Controls.ListBoxItem
        $item.Style = $script:Window.FindResource('Card')
        $sp = New-Object System.Windows.Controls.StackPanel
        $sp.Children.Add((New-TextBlock -Text $g.name -Weight 'SemiBold')) | Out-Null
        $sp.Children.Add((New-TextBlock -Text $g.blurb -Key 'TextMuted' -Size 11)) | Out-Null
        $item.Content = $sp; $item.Tag = $g.id
        $ui.LstGroups.Items.Add($item) | Out-Null
    }

    $ui.LstGroups.Add_SelectionChanged({ Update-ScriptList })
    $ui.TxtSearch.Add_TextChanged({ Update-ScriptList })
    $ui.LstScripts.Add_SelectionChanged({
        $sel = $script:Ui.LstScripts.SelectedItem
        if ($sel -and $sel.Tag) { Show-Script $sel.Tag }
    })
    $ui.LstLogs.Add_MouseDoubleClick({
        $sel = $script:Ui.LstLogs.SelectedItem
        if ($sel -and $sel.Tag) { Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f $sel.Tag) }
    })
    $ui.ChkElevated.Add_Checked({ Update-CommandPreview }); $ui.ChkElevated.Add_Unchecked({ Update-CommandPreview })
    $ui.BtnReadme.Add_Click({ Start-Process -FilePath (Join-Path $script:RepoRoot 'README.md') })
    $ui.BtnLogs.Add_Click({ Start-Process -FilePath 'explorer.exe' -ArgumentList $env:TEMP })
    $ui.BtnFolder.Add_Click({
        if ($script:Current) { Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"{0}"' -f $script:Current.FullPath) }
    })
    $ui.BtnCopy.Add_Click({
        if ($script:Ui.TxtCommand.Text) { [System.Windows.Clipboard]::SetText($script:Ui.TxtCommand.Text); Set-Status 'Command line copied to the clipboard.' }
    })
    $launch = {
        param([bool]$Preview)
        if (-not $script:Current) { return }
        try {
            Start-CatalogScript -Script $script:Current -Preview $Preview -Elevated ([bool]$script:Ui.ChkElevated.IsChecked) | Out-Null
            Set-Status ('{0} {1} in a new window{2}. Its output stays there until you press Enter.' -f
                $(if ($Preview) { 'Previewing' } else { 'Started' }), $script:Current.name,
                $(if ($script:Ui.ChkElevated.IsChecked) { ' (elevated)' } else { '' }))
            Show-Logs $script:Current
        } catch {
            Set-Status ('Not started: ' + $_.Exception.Message)
        }
    }
    $ui.BtnPreview.Add_Click({ & $launch $true })
    $ui.BtnRun.Add_Click({
        $s = $script:Current
        if (-not $s) { return }
        if ($s.risk -eq 'high') {
            $msg = ('{0} will make real changes on this machine.{1}Run it now? Use Preview first if you have not.' -f $s.name, [Environment]::NewLine)
            $r = [System.Windows.MessageBox]::Show($script:Window, $msg, 'ADesk Cleaner', 'YesNo', 'Warning')
            if ($r -ne 'Yes') { Set-Status 'Cancelled.'; return }
        }
        & $launch $false
    })

    $ui.LstGroups.SelectedIndex = 0
}

# =============================================================================
# Main
# =============================================================================

$script:Catalog       = Get-Catalog
$script:Current       = $null
$script:ParamControls = @{}
$script:Window        = $null
$script:Ui            = $null
$script:Theme         = 'light'
$script:Settings      = $null

Initialize-Window

if ($SelfTest) {
    $bad = 0
    foreach ($theme in 'dark', 'light') {
        Set-Theme $theme
        foreach ($s in $script:Catalog.scripts) {
            if (-not $s.Exists) { Write-Output ('MISSING  {0}' -f $s.file); $bad++; continue }
            $info = Get-InfoFor $s
            Show-Script $s
            $tokens = Get-ArgumentTokens -Script $s -Preview $true
            $line = Get-LaunchLine $s $tokens
            $ok = ($info.ParseErrors -eq 0) -and ($line -like "*$($s.FullPath)*")
            if (-not $ok) { $bad++ }
            if ($theme -eq 'light') {
                Write-Output ('{0}  {1,-48} params={2,-2} parse-errors={3} synopsis={4} preview={5}' -f
                    $(if ($ok) { 'OK     ' } else { 'FAIL   ' }), $s.file, @($info.Parameters).Count, $info.ParseErrors,
                    $(if ($info.Synopsis) { 'yes' } else { 'NO ' }), (@($s.preview) -join ' '))
            }
        }
    }
    $missingBrush = @($script:Themes.light.Keys | Where-Object { -not $script:Themes.dark.ContainsKey($_) })
    if ($missingBrush.Count) { Write-Output ('FAIL     dark theme lacks: ' + ($missingBrush -join ', ')); $bad++ }
    Write-Output ('SELFTEST {0}: {1} scripts x 2 themes, {2} problem(s)' -f $(if ($bad) { 'FAILED' } else { 'PASSED' }), @($script:Catalog.scripts).Count, $bad)
    exit $(if ($bad) { 1 } else { 0 })
}

[void]$script:Window.ShowDialog()
