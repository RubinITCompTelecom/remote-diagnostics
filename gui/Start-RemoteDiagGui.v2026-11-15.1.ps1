<#
  Start-RemoteDiagGui.v2026-11-15.1.ps1 - the Remote Diagnostics window (docs\gui-architecture.md).

  A front end, not an engine: each tool is a child powershell.exe running the same script its Run-*.bat
  launcher runs, with the same arguments, one at a time. This file only wires controls, one
  DispatcherTimer (250 ms) and a few dialogs to gui\Gui.Core.psm1. No event-log, dump, network, print,
  ESP or persistence logic lives here; no tool script is imported or dot-sourced into this process.
  Rules that never bend: an answer is sent to a tool only from the technician's own click or typing;
  closing a question box sends the script's own default (never yes); no tool is ever stopped on a timer;
  nothing opens on its own except what the technician clicks.

  Window parts COPIED FROM screenconnect-cleanup\gui\Start-CleanupGui.ps1 (2026-11-10) and kept in sync
  by hand: the DPI block, Set-GuiTheme / Get-Brush, the dialog primitive, Add-ConsoleLines, Show-Banner,
  the fit-to-screen / compact layout, the footer links, the unhandled-exception handler.

  Started by ..\Run-RemoteDiagGui.bat (elevated, -STA). Windows PowerShell 5.1, pure ASCII, no BOM.
  Test hooks (tests\gui only, honoured ONLY when this window is NOT elevated): -LoadOnly, -SelfTest,
  -ResultPath with -AutoTool/-TestValues/-TestSize/-RenderPng/-RenderScale. -AllowNotElevated lets a test run.
  -TestValues may also set a Password input (a PasswordBox).

  Phase 3: a tool of Kind ChangesPC first shows a confirmation box (Run it / Cancel; the X is Cancel). In a
  TEST window Show-Dialog returns $null, so a ChangesPC tool started with -AutoTool never runs - intended:
  tests can never change the PC. Prompt kinds (tools.json): YesNo, Text, FromInput (the value of a named
  input, no box) and Secret (the PasswordBox, sent with Send-GuiSecret, then cleared).
#>
param(
    [string]$ToolRoot = (Split-Path -Parent $PSScriptRoot),
    [switch]$AllowNotElevated,
    [switch]$LoadOnly,
    [switch]$SelfTest,
    [ValidateSet('System', 'Light', 'Dark')][string]$Theme = 'System',
    [string]$ResultPath = '',
    [string]$AutoTool = '',
    [string]$TestValues = '',
    [string]$TestSize = '',
    [int]$TestStopAfter = 0,
    [string]$RenderPng = '',
    [double]$RenderScale = 1.0
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$GuiVersion = '2026-11-15.1'

# WPF needs a single-threaded apartment. The launcher passes -STA; otherwise restart once with every parameter.
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $again = @('-NoLogo', '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        if ($kv.Value -is [System.Management.Automation.SwitchParameter]) { if ($kv.Value.IsPresent) { $again += ('-' + $kv.Key) } }
        else { $again += @(('-' + $kv.Key), [string]$kv.Value) }
    }
    & (Join-Path $PSHOME 'powershell.exe') @again
    exit $LASTEXITCODE
}

# ---- screen scaling: per-monitor v2 BEFORE WPF loads (docs\gui-architecture.md 7) -------------------
$script:DpiMode = 'system (WPF default)'
try {
    if (-not ('RdGuiDpi' -as [type])) {
        Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class RdGuiDpi { [DllImport("user32.dll", SetLastError = true)] public static extern bool SetProcessDpiAwarenessContext(IntPtr value); }'
    }
    [AppContext]::SetSwitch('Switch.System.Windows.DoNotScaleForDpiChanges', $false)
    if ([RdGuiDpi]::SetProcessDpiAwarenessContext([IntPtr](-4))) { $script:DpiMode = 'per-monitor v2' }
} catch { }

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Import-Module (Join-Path $PSScriptRoot 'Gui.Core.psm1') -Force

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $AllowNotElevated -and -not $LoadOnly) {
    [void][System.Windows.MessageBox]::Show("This window must run as administrator.`n`nClose it and start Run-RemoteDiagGui.bat, which asks for administrator rights once.", 'Remote Diagnostics', 'OK', 'Warning')
    exit 1
}
# Test hooks exist only in a window that is NOT elevated. Run-RemoteDiagGui.bat always elevates, so in a
# real run they do not exist (same rule as the ScreenConnect window, docs/14 12.6 item 1).
$script:TestHooks = (-not $isAdmin) -and [bool]$ResultPath
if (-not $script:TestHooks) { $AutoTool = ''; $TestValues = ''; $TestSize = ''; $TestStopAfter = 0; $RenderPng = ''; $RenderScale = 1.0 }

$xamlText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'MainWindow.xaml'))
$win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$xamlText)))
$ui = @{}
$controlNames = 'RootGrid', 'HeaderCard', 'TitleText', 'InfoText', 'BtnBack', 'StartPanel', 'ToolsGrid', 'RunPanel', 'StatusCard',
'KindText', 'StatusTitle', 'StatusDetail', 'Busy', 'Banner', 'BannerText', 'ToolNotice', 'InputsHost', 'BtnRun', 'BtnStopSave', 'BtnStop',
'ResultHost', 'RowConsole', 'BtnCopy', 'BtnOpenLog', 'ConsoleBox', 'LinkRubinIt', 'LinkPupontech'
$missing = @()
foreach ($n in $controlNames) { $c = $win.FindName($n); if ($null -eq $c) { $missing += $n } else { $ui[$n] = $c } }
if ($missing.Count -gt 0) { Write-Host ('Window is missing controls: ' + ($missing -join ', ')) -ForegroundColor Red; exit 1 }
if ($LoadOnly) { Write-Host ('LOAD_OK controls=' + $controlNames.Count); exit 0 }

# ---- state -----------------------------------------------------------------------------------------
$script:Catalog = Get-GuiCatalog
$script:Tool = $null
$script:Child = $null
$script:Inputs = @{}
$script:InDialog = $false
$script:LogPath = ''
$script:StopFile = ''
$script:StopRequested = $false
$script:StopAt = $null
$script:Result = $null
$script:WorkDir = Join-Path $env:TEMP 'RemoteDiagGui'
try { $null = New-Item -ItemType Directory -Path $script:WorkDir -Force } catch { }
$script:ConsoleSaved = Set-GuiConsoleEncoding

function Get-Brush { param([string]$Tone) return $win.FindResource('Brush.' + $Tone) }

function Set-GuiTheme {
    param([string]$Name)
    $useDark = ($Name -eq 'Dark')
    if ($Name -eq 'System') {
        try { $useDark = ([int](Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'AppsUseLightTheme' -ErrorAction Stop).AppsUseLightTheme -eq 0) } catch { $useDark = $false }
    }
    if ($useDark) { $dark = $win.Resources['Theme.Dark']; foreach ($k in @($dark.Keys)) { $win.Resources[$k] = $dark[$k] } }
    $script:ThemeName = $(if ($useDark) { 'Dark' } else { 'Light' })
}
Set-GuiTheme $Theme

function New-Text {
    param([string]$Text, [string]$Tone = 'Foreground', [double]$Size = 0, [switch]$Bold, [string]$Margin = '0,0,0,0')
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Text; $t.TextWrapping = 'Wrap'; $t.Foreground = Get-Brush $Tone; $t.Margin = $Margin
    if ($Size -gt 0) { $t.FontSize = $Size }
    if ($Bold) { $t.FontWeight = 'SemiBold' }
    return $t
}

function New-Button {
    param([string]$Text, [string]$Variant = 'Secondary', [scriptblock]$OnClick)
    $b = New-Object System.Windows.Controls.Button
    $b.Content = $Text; $b.Style = $win.FindResource('Button.' + $Variant); $b.Margin = '0,6,8,0'
    if ($OnClick) { $b.add_Click($OnClick) }
    return $b
}

function Write-GuiLogText {
    param([string]$Text)
    if (-not $script:LogPath) { return }
    try { [IO.File]::AppendAllText($script:LogPath, $Text + "`r`n", (New-Object System.Text.UTF8Encoding($false))) } catch { }
}

function Add-ConsoleLines {
    param([string[]]$Lines)
    if (@($Lines).Count -eq 0) { return }
    $ui.ConsoleBox.AppendText((@($Lines) -join "`r`n") + "`r`n")
    if ($ui.ConsoleBox.Text.Length -gt 400000) { $ui.ConsoleBox.Text = $ui.ConsoleBox.Text.Substring(200000) }
    $ui.ConsoleBox.ScrollToEnd()
    Write-GuiLogText (@($Lines) -join "`r`n")
}

function Add-ConsoleNote { param([string]$Text) Add-ConsoleLines @('[GUI] ' + $Text) }

function Show-Banner {
    param([string]$Text, [string]$Kind = 'info')
    $map = @{ info = @('SurfaceSunken', 'Border', 'Foreground'); ok = @('SuccessBg', 'SuccessBorder', 'SuccessFg'); warn = @('WarningBg', 'WarningBorder', 'WarningFg'); bad = @('DangerBg', 'DangerBorder', 'DangerFg') }
    $m = $map[$Kind]
    $ui.Banner.Background = Get-Brush $m[0]; $ui.Banner.BorderBrush = Get-Brush $m[1]
    $ui.BannerText.Foreground = Get-Brush $m[2]; $ui.BannerText.FontWeight = 'SemiBold'; $ui.BannerText.Text = $Text
    $ui.Banner.Visibility = 'Visible'
}

# ---- one dialog primitive (copied, trimmed: no typed-word gate - no tool here needs one) ---------------
function New-DialogWindow {
    param([string]$Title, [string]$Message, [string]$Detail = '', $Buttons, [switch]$TextInput)
    $w = New-Object System.Windows.Window
    $w.Title = $Title; $w.SizeToContent = 'WidthAndHeight'; $w.MaxWidth = 640; $w.ResizeMode = 'NoResize'
    $w.ShowInTaskbar = $false; $w.WindowStartupLocation = 'CenterOwner'
    if ($win.IsLoaded) { $w.Owner = $win }
    foreach ($k in @($win.Resources.Keys)) { $w.Resources[$k] = $win.Resources[$k] }
    $w.Background = Get-Brush 'Background'; $w.Foreground = Get-Brush 'Foreground'; $w.FontFamily = $win.FontFamily; $w.FontSize = $win.FontSize
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Margin = '22,18,22,18'
    [void]$sp.Children.Add((New-Text $Title -Size 15 -Bold -Margin '0,0,0,8'))
    $msg = New-Text $Message 'Muted'; $msg.MaxWidth = 590
    [void]$sp.Children.Add($msg)
    if ($Detail) {
        $d = New-Object System.Windows.Controls.TextBox
        $d.Text = $Detail; $d.IsReadOnly = $true; $d.TextWrapping = 'Wrap'; $d.FontFamily = 'Consolas'; $d.FontSize = 12; $d.MaxHeight = 200
        $d.VerticalScrollBarVisibility = 'Auto'; $d.Margin = '0,12,0,0'; $d.Padding = '8,6,8,6'
        $d.Background = Get-Brush 'SurfaceSunken'; $d.Foreground = Get-Brush 'Foreground'; $d.BorderBrush = Get-Brush 'Border'
        [void]$sp.Children.Add($d)
    }
    $tag = @{ Text = $null }
    if ($TextInput) {
        $box = New-Object System.Windows.Controls.TextBox
        $box.Margin = '0,12,0,0'; $box.FontFamily = 'Consolas'; $box.FontSize = 13; $box.Padding = '8,6,8,6'
        $box.Background = Get-Brush 'Surface'; $box.Foreground = Get-Brush 'Foreground'; $box.BorderBrush = Get-Brush 'BorderStrong'; $box.CaretBrush = Get-Brush 'Foreground'
        $tag.Text = $box
        [void]$sp.Children.Add($box)
    }
    $wp = New-Object System.Windows.Controls.WrapPanel
    $wp.Margin = '0,18,0,0'
    foreach ($b in $Buttons) {
        $btn = New-Object System.Windows.Controls.Button
        $btn.Content = $b.Text; $btn.Tag = $b.Value; $btn.Style = $win.FindResource('Button.Secondary')
        $btn.add_Click({
                param($s, $e)
                $dw = [System.Windows.Window]::GetWindow($s)
                $script:DlgValue = [string]$s.Tag
                if ($dw.Tag.Text) { $script:DlgText = [string]$dw.Tag.Text.Text }
                $dw.Close()
            })
        [void]$wp.Children.Add($btn)
    }
    [void]$sp.Children.Add($wp)
    $w.Tag = $tag; $w.Content = $sp
    return $w
}

function Show-Dialog {
    # Returns $null when closed with the window X (the caller then sends the script's default, never yes).
    # In a test window there is nobody to click: every dialog counts as closed with the X.
    param([string]$Title, [string]$Message, [string]$Detail = '', $Buttons, [switch]$TextInput)
    if ($script:TestHooks) { return $null }
    $script:DlgValue = $null; $script:DlgText = $null
    $w = New-DialogWindow -Title $Title -Message $Message -Detail $Detail -Buttons $Buttons -TextInput:$TextInput
    $script:InDialog = $true
    try { [void]$w.ShowDialog() } finally { $script:InDialog = $false }
    if ($null -eq $script:DlgValue) { return $null }
    return [pscustomobject]@{ Value = $script:DlgValue; Text = $script:DlgText }
}

function Resolve-Prompt {
    # Shows a box that names the question, then sends the technician's own answer.
    param($Pending)
    $c = $script:Child
    if ($Pending.Kind -eq 'Unknown') {
        $r = Show-Dialog -Title 'The tool is waiting for an answer' -Message ('The tool is waiting for an answer:' + "`r`n`r`n" + 'Type an answer and Send, or close this box to send an empty line (the tool''s own default). Choose "This is not a question" only if the tool is still working; this box comes back after a minute if it is still waiting.') -Detail $Pending.Text -TextInput -Buttons (@(
            @{ Text = 'Send'; Value = 'send' }, @{ Text = 'This is not a question'; Value = 'skip' }) + $(if ($script:Tool.Kind -ne 'ChangesPC') { @(@{ Text = 'Stop the tool'; Value = 'stop' }) } else { @() }))
        if ($r -and $r.Value -eq 'stop') { Stop-RunningTool -NoConfirm; return }
        if ($r -and $r.Value -eq 'skip') { Set-GuiPromptDismissed -Child $c -Text $Pending.Text; Add-ConsoleNote 'Marked as not a question; the tool keeps running.' }
        elseif ($r -and $r.Value -eq 'send') { Send-GuiAnswer -Child $c -Text $r.Text }
        else { Send-GuiAnswer -Child $c -Text ''; Add-ConsoleNote 'Box closed: sent an empty line, the tool''s own default.' }
        return
    }
    $p = $Pending.Prompt
    switch ([string](Get-GuiProp $p 'Kind' 'YesNo')) {
        'FromInput' {
            # The answer is what the technician already typed in the named input: no box.
            $src = $script:Inputs[[string]$p.Input]
            $v = ''
            if ($src -and -not ($src -is [System.Windows.Controls.PasswordBox])) { $v = ([string]$src.Text).Trim() }
            Send-GuiAnswer -Child $c -Text $v
            return
        }
        'Secret' {
            # The password goes to the child's input only, then the box is cleared. Never logged or shown.
            $src = $script:Inputs[[string]$p.Input]
            if ($src -is [System.Windows.Controls.PasswordBox]) {
                try { Send-GuiSecret -Child $c -Text $src.Password } finally { $src.Clear() }
            } else { Send-GuiSecret -Child $c -Text '' }
            return
        }
        'Text' {
            # A question with a typed answer: a box with a text field; the window X sends an empty line (the default).
            $r = Show-Dialog -Title ([string]$p.Title) -Message ([string]$p.Message) -Detail $Pending.Text -TextInput -Buttons @(@{ Text = 'Send'; Value = 'send' })
            Send-GuiAnswer -Child $c -Text $(if ($r -and $r.Value -eq 'send') { [string]$r.Text } else { '' })
            return
        }
    }
    # A y/N question from tools.json: Yes sends Accept, No or the window X send the script's default.
    $r = Show-Dialog -Title ([string]$p.Title) -Message ([string]$p.Message) -Detail $Pending.Text -Buttons @(
        @{ Text = [string]$p.AcceptText; Value = 'yes' }, @{ Text = [string]$p.RefuseText; Value = 'no' })
    Send-GuiAnswer -Child $c -Text $(if ($r -and $r.Value -eq 'yes') { [string]$p.Accept } else { [string]$p.Default })
}

# ---- start panel: one card per tool --------------------------------------------------------------------
function Get-KindWords {
    param($Tool)
    if ($Tool.Kind -eq 'ChangesPC') { return @('CHANGES THIS PC', 'WarningFg') }
    return @('READ-ONLY', 'SuccessFg')
}

function Initialize-ToolCards {
    $ui.ToolsGrid.Children.Clear()
    foreach ($t in @($script:Catalog.Tools)) {
        $b = New-Object System.Windows.Controls.Button
        $b.Style = $win.FindResource('ToolCard'); $b.Tag = [string]$t.Id
        $sp = New-Object System.Windows.Controls.StackPanel
        $kind = Get-KindWords $t
        $badge = New-Text $kind[0] $kind[1] 11 -Bold
        if ([bool](Get-GuiProp $t 'LongRunning' $false)) { $badge.Text += '  -  RUNS UNTIL STOPPED' }
        [void]$sp.Children.Add($badge)
        [void]$sp.Children.Add((New-Text ([string]$t.Title) -Size 14 -Bold -Margin '0,2,0,0'))
        [void]$sp.Children.Add((New-Text ([string]$t.Summary) 'Muted' -Margin '0,3,0,0'))
        if (-not $t.Enabled) {
            [void]$sp.Children.Add((New-Text ('Not in this window yet. ' + [string]$t.DisabledWhy) 'Muted' 12 -Margin '0,6,0,0'))
            $b.IsEnabled = $false
        }
        $b.Content = $sp
        $b.add_Click({ param($s, $e) Open-Tool ([string]$s.Tag) })
        [void]$ui.ToolsGrid.Children.Add($b)
    }
}

function Show-Panel {
    param([string]$Which)
    $ui.StartPanel.Visibility = $(if ($Which -eq 'Start') { 'Visible' } else { 'Collapsed' })
    $ui.RunPanel.Visibility = $(if ($Which -eq 'Run') { 'Visible' } else { 'Collapsed' })
    $ui.BtnBack.Visibility = $(if ($Which -eq 'Run') { 'Visible' } else { 'Collapsed' })
}

# ---- run panel -------------------------------------------------------------------------------------------
function Open-Tool {
    param([string]$Id)
    $t = Get-GuiTool -Id $Id -Catalog $script:Catalog
    if (-not $t.Enabled) { return }
    $script:Tool = $t; $script:Result = $null
    $kind = Get-KindWords $t
    $ui.StatusTitle.Text = [string]$t.Title
    $ui.KindText.Text = $kind[0]; $ui.KindText.Foreground = Get-Brush $kind[1]
    $ui.StatusDetail.Text = [string]$t.Summary
    $ui.Busy.IsIndeterminate = $false; $ui.Busy.Value = 0
    $ui.ToolNotice.Text = [string](Get-GuiProp $t 'Notice' '')
    $ui.ToolNotice.Visibility = $(if ($ui.ToolNotice.Text) { 'Visible' } else { 'Collapsed' })
    $ui.Banner.Visibility = 'Collapsed'
    $ui.ResultHost.Children.Clear()
    $ui.InputsHost.Children.Clear()
    $script:Inputs = @{}
    foreach ($i in @($t.Inputs)) {
        if ($i.Type -eq 'Bool') {
            $cb = New-Object System.Windows.Controls.CheckBox
            $cb.IsChecked = [bool]$i.Default; $cb.Foreground = Get-Brush 'Foreground'; $cb.Margin = '0,6,0,2'
            $label = [string]$i.Label
            if ((Get-GuiProp $i 'Info' '') -eq 'MemoryDump') {
                $md = Get-GuiMemoryDumpInfo
                $label += $(if ($md.Exists) { '  (found on this PC: ' + $md.SizeGB + ' GB)' } else { '  (none on this PC)' })
            }
            $cb.Content = $label
            [void]$ui.InputsHost.Children.Add($cb)
            $script:Inputs[[string]$i.Id] = $cb
        } elseif ($i.Type -eq 'Password') {
            [void]$ui.InputsHost.Children.Add((New-Text ([string]$i.Label) 'Muted' 12 -Margin '0,8,0,2'))
            $pb = New-Object System.Windows.Controls.PasswordBox
            $pb.MaxWidth = 520; $pb.MinWidth = 360; $pb.HorizontalAlignment = 'Left'; $pb.Padding = '6,4,6,4'
            $pb.Background = Get-Brush 'Surface'; $pb.Foreground = Get-Brush 'Foreground'; $pb.BorderBrush = Get-Brush 'BorderStrong'; $pb.CaretBrush = Get-Brush 'Foreground'
            [void]$ui.InputsHost.Children.Add($pb)
            $script:Inputs[[string]$i.Id] = $pb
        } elseif ($i.Type -eq 'Printer') {
            [void]$ui.InputsHost.Children.Add((New-Text ([string]$i.Label) 'Muted' 12 -Margin '0,8,0,2'))
            $cmb = New-Object System.Windows.Controls.ComboBox
            $cmb.IsEditable = $true; $cmb.MaxWidth = 520; $cmb.MinWidth = 360; $cmb.HorizontalAlignment = 'Left'; $cmb.Padding = '6,4,6,4'
            $cmb.Background = Get-Brush 'Surface'; $cmb.Foreground = Get-Brush 'Foreground'; $cmb.BorderBrush = Get-Brush 'BorderStrong'
            # Display only: the names of the queues on this PC (an empty list is fine; the name can be typed).
            try { foreach ($pn in @(Get-Printer -ErrorAction Stop | Sort-Object -Property Name | ForEach-Object { [string]$_.Name })) { [void]$cmb.Items.Add($pn) } } catch { }
            $cmb.Text = [string]$i.Default
            [void]$ui.InputsHost.Children.Add($cmb)
            $script:Inputs[[string]$i.Id] = $cmb
        } else {
            [void]$ui.InputsHost.Children.Add((New-Text ([string]$i.Label) 'Muted' 12 -Margin '0,8,0,2'))
            $tb = New-Object System.Windows.Controls.TextBox
            $tb.Text = [string]$i.Default; $tb.MaxWidth = 520; $tb.HorizontalAlignment = 'Left'; $tb.Padding = '6,4,6,4'
            $tb.MinWidth = $(if ($i.Type -eq 'Int') { 90 } else { 360 })
            $tb.Background = Get-Brush 'Surface'; $tb.Foreground = Get-Brush 'Foreground'; $tb.BorderBrush = Get-Brush 'BorderStrong'; $tb.CaretBrush = Get-Brush 'Foreground'
            [void]$ui.InputsHost.Children.Add($tb)
            $script:Inputs[[string]$i.Id] = $tb
        }
    }
    if (@($t.Inputs).Count -eq 0) { [void]$ui.InputsHost.Children.Add((New-Text 'This tool has no options.' 'Muted' 12)) }
    $script:ScriptPath = Resolve-GuiScript -ToolRoot $ToolRoot -Name ([string]$t.Script)
    $ui.BtnRun.IsEnabled = [bool]$script:ScriptPath
    $ui.BtnRun.Content = 'Run'
    $ui.BtnStopSave.Visibility = 'Collapsed'
    if (-not $script:ScriptPath) { Show-Banner ($t.Script + '.v*.ps1 was not found in ' + $ToolRoot + '. Copy the whole remote-diagnostics folder.') 'bad' }
    else { Add-ConsoleNote ($t.Title + ': ' + (Split-Path -Leaf $script:ScriptPath)) }
    Show-Panel 'Run'
}

function Get-InputValues {
    $v = Get-GuiDefaultValues $script:Tool
    foreach ($k in @($script:Inputs.Keys)) {
        $c = $script:Inputs[$k]
        if ($c -is [System.Windows.Controls.PasswordBox]) { continue }   # read only at send time, never in the values
        if ($c -is [System.Windows.Controls.CheckBox]) { $v[$k] = [bool]$c.IsChecked } else { $v[$k] = [string]$c.Text }
    }
    return $v
}

function Set-Running {
    param([bool]$On)
    foreach ($c in $script:Inputs.Values) { $c.IsEnabled = -not $On }
    $ui.BtnRun.IsEnabled = (-not $On) -and [bool]$script:ScriptPath
    $ui.BtnBack.IsEnabled = -not $On
    $ui.Busy.IsIndeterminate = $On
    $ui.BtnStopSave.Visibility = $(if ($On -and $script:StopFile) { 'Visible' } else { 'Collapsed' })
    $ui.BtnStopSave.IsEnabled = $On
    # Stop is offered for tools that only read this PC. A tool that changes it is never cut off half way
    # (its Yes/No boxes and the "Run it / Cancel" box are the way out).
    $ui.BtnStop.Visibility = $(if ($On -and $script:Tool.Kind -ne 'ChangesPC') { 'Visible' } else { 'Collapsed' })
    $ui.BtnStop.IsEnabled = $On
    if (-not $On) { $script:StopAt = $null }
}

function Stop-RunningTool {
    # Ends the running read-only tool and everything it started. Asks first (the print watch would skip its save).
    param([switch]$NoConfirm)
    if (-not $script:Child -or $script:Child.Finished -or $script:Tool.Kind -eq 'ChangesPC') { return }
    if (-not $NoConfirm) {
        $q = 'Stop "' + $script:Tool.Title + '" now? It only reads this PC, so nothing is changed, but its output will be incomplete.'
        if ($script:StopFile) { $q += "`n`nTo end the print watch AND save its events and crash reports, choose No and press 'Stop and save' instead." }
        $prev = $script:InDialog; $script:InDialog = $true
        try { $ans = [System.Windows.MessageBox]::Show($q, 'Remote Diagnostics', 'YesNo', 'Question') } finally { $script:InDialog = $prev }
        if ($ans -ne 'Yes') { return }
        if (-not $script:Child -or $script:Child.Finished) { return }
    }
    $script:StopRequested = $true
    $ui.BtnStop.IsEnabled = $false; $ui.BtnStopSave.IsEnabled = $false
    $ui.StatusDetail.Text = 'Stopping...'
    Add-ConsoleNote 'Stop requested by you: ending the tool and everything it started.'
    Stop-GuiChild $script:Child
}

function Start-Tool {
    if ($script:Child) { return }
    $t = $script:Tool
    $values = Get-InputValues
    $errors = @(Test-GuiToolValues -Tool $t -Values $values)
    if ($errors.Count -gt 0) { Show-Banner ('Check the options: ' + ($errors -join ' ')) 'warn'; return }
    # What goes to the tool over its input (user name, password) must survive the console code page, or it
    # would arrive changed and fail with a wrong-password error. Nothing is started and the text is never shown.
    foreach ($i in @($t.Inputs)) {
        if (-not [bool](Get-GuiProp $i 'Stdin' $false)) { continue }
        $src = $script:Inputs[[string]$i.Id]
        if (-not $src) { continue }
        $txt = $(if ($src -is [System.Windows.Controls.PasswordBox]) { [string]$src.Password } else { [string]$src.Text })
        if (-not (Test-GuiTextEncodable $txt)) {
            Show-Banner ('"' + [string]$i.Id + '" has a character that this PC''s console code page (' + [Console]::InputEncoding.CodePage + ') cannot pass to the tool, so it would arrive changed. Nothing was started. Use the matching Run-*.bat and type it in its console, or use an account whose name and password use only letters and digits.') 'warn'
            return
        }
    }
    if ([string]$t.Kind -eq 'ChangesPC') {
        # A tool that changes this PC never starts without a click on "Run it". The X and Cancel both mean no.
        $msg = [string](Get-GuiProp $t 'Confirm' (Get-GuiProp $t 'Notice' ''))
        if (-not $msg) { $msg = 'This tool changes this PC. Run it?' }
        $ans = Show-Dialog -Title ('Run "' + [string]$t.Title + '"?') -Message $msg -Buttons @(@{ Text = 'Run it'; Value = 'run' }, @{ Text = 'Cancel'; Value = 'cancel' })
        if (-not $ans -or $ans.Value -ne 'run') {
            Add-ConsoleNote 'Not run: the confirmation was not given.'
            Show-Banner 'Not run: the confirmation was cancelled. Nothing was changed.' 'info'
            return
        }
    }
    $stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    $script:StopFile = ''
    if ([bool](Get-GuiProp $t 'StopFile' $false)) { $script:StopFile = Join-Path $script:WorkDir ('stop-' + [guid]::NewGuid().ToString('N') + '.flag') }
    $call = Get-GuiToolCall -Tool $t -ToolRoot $ToolRoot -Values $values -StopFile $script:StopFile
    if (-not $call.ScriptPath) { Show-Banner 'The script was not found.' 'bad'; return }
    $script:LogPath = Join-Path $script:WorkDir ($t.Id + '_' + $stamp + '.log')
    $ui.BtnOpenLog.IsEnabled = $true
    $ui.Banner.Visibility = 'Collapsed'; $ui.ResultHost.Children.Clear()
    Add-ConsoleLines @('', ('=== ' + $t.Title + ' - ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' ==='), ('> ' + (Split-Path -Leaf $call.ScriptPath) + ' ' + (ConvertTo-GuiArgString $call.Args)))
    try {
        $script:Child = Start-GuiChild -ScriptPath $call.ScriptPath -ArgumentList $call.Args -WorkingDirectory $ToolRoot
    } catch {
        Show-Banner ('Could not start the tool: ' + $_.Exception.Message) 'bad'
        return
    }
    $ui.StatusDetail.Text = 'Starting...'
    Set-Running $true
}

function Complete-Tool {
    param([int]$ExitCode)
    $c = $script:Child
    $script:Child = $null
    Set-Running $false
    $ui.Busy.Value = 1
    if ($script:StopFile) { try { Remove-Item -LiteralPath $script:StopFile -Force -ErrorAction SilentlyContinue } catch { }; $script:StopFile = '' }
    $script:Result = Get-GuiRunResult -Tool $script:Tool -Lines @($c.AllLines.ToArray()) -ExitCode $ExitCode
    Add-ConsoleNote ('The tool ended with exit code ' + $ExitCode + '.')
    $elapsed = (Get-Date).ToUniversalTime() - $c.StartedUtc
    $ui.StatusDetail.Text = 'Finished after ' + ('{0:00}:{1:00}' -f [int][Math]::Floor($elapsed.TotalMinutes), $elapsed.Seconds) + '.'
    if ($script:StopRequested) {
        $script:StopRequested = $false
        Show-Banner 'Stopped at your request. The tool only reads this PC, so nothing was changed, but its output is incomplete.' 'warn'
    }
    elseif ($script:Result.Failed) { Show-Banner ('The tool reported an error (exit code ' + $ExitCode + '). Read the console output below and the log.') 'bad' }
    elseif ($script:Result.Cancelled) { Show-Banner 'Cancelled at your answer. The tool stopped and changed nothing.' 'info' }
    elseif (@($script:Result.Warnings).Count -gt 0) {
        $wt = [string](Get-GuiProp $script:Tool 'WarningText' 'The tool finished, but one or more steps failed, so the output is incomplete. Read the console output below.')
        Show-Banner ($wt + ' First one: "' + [string]$script:Result.Warnings[0] + '" (' + @($script:Result.Warnings).Count + ' in all).') 'warn'
    }
    elseif (@($script:Result.Items).Count -eq 0 -and -not [bool](Get-GuiProp $script:Tool 'NoOutputFiles' $false)) { Show-Banner 'Finished. The tool did not print where it saved its output; see the console output below.' 'warn' }
    else { Show-Banner 'Finished.' 'ok' }
    $ui.BtnRun.Content = 'Run again'
    Show-Result
    if ($ResultPath) { Write-ResultFile; if ($RenderPng) { Save-WindowPng }; if ($AutoTool) { $win.Close() } }
}

function Show-Result {
    $h = $ui.ResultHost
    $h.Children.Clear()
    $res = $script:Result
    if (@($res.Items).Count -eq 0 -and [bool](Get-GuiProp $script:Tool 'NoOutputFiles' $false)) { return }
    [void]$h.Children.Add((New-Text 'Output' -Size 15 -Bold -Margin '0,0,0,4'))
    $words = @{ Folder = 'Output folder'; Zip = 'Zip'; Log = 'Run log'; File = 'File' }
    foreach ($it in @($res.Items)) {
        [void]$h.Children.Add((New-Text ($words[$it.Kind] + $(if ($it.Exists) { '' } else { ' (not found on disk)' })) $(if ($it.Exists) { 'Muted' } else { 'WarningFg' }) 12 -Bold -Margin '0,6,0,0'))
        $box = New-Object System.Windows.Controls.TextBox
        $box.Text = $it.Path; $box.IsReadOnly = $true; $box.BorderThickness = 0; $box.Background = [System.Windows.Media.Brushes]::Transparent; $box.Foreground = Get-Brush 'Foreground'; $box.TextWrapping = 'Wrap'
        [void]$h.Children.Add($box)
        if ($it.Exists) {
            $p = $it.Path
            if ($it.Kind -eq 'Folder') { [void]$h.Children.Add((New-Button 'Open folder' -OnClick { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $p + '"') }.GetNewClosure())) }
            else { [void]$h.Children.Add((New-Button ('Open ' + $words[$it.Kind].ToLower() + ' location') -OnClick { Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"' + $p + '"') }.GetNewClosure())) }
        }
    }
    if (@($res.Items).Count -eq 0) { [void]$h.Children.Add((New-Text 'not available - the tool did not print an output location.' 'Muted' 12)) }
    $files = @(Get-GuiProp $script:Tool 'ReviewFiles' @())
    if ($files.Count -gt 0) {
        [void]$h.Children.Add((New-Text 'REVIEW lists the script wrote (inventory, not a verdict)' -Size 14 -Bold -Margin '0,14,0,0'))
        foreach ($f in $files) {
            $rl = Get-GuiReviewList -Folder $res.Folder -FileName $f
            [void]$h.Children.Add((New-Text $f 'Muted' 12 -Bold -Margin '0,8,0,2'))
            $tb = New-Object System.Windows.Controls.TextBox
            $tb.Text = $rl.Text; $tb.IsReadOnly = $true; $tb.FontFamily = 'Consolas'; $tb.FontSize = 12; $tb.TextWrapping = 'Wrap'; $tb.Padding = '8,6,8,6'
            $tb.Background = Get-Brush 'SurfaceSunken'; $tb.Foreground = Get-Brush $(if ($rl.Available) { 'Foreground' } else { 'Muted' }); $tb.BorderBrush = Get-Brush 'Border'
            [void]$h.Children.Add($tb)
        }
    }
}

function Invoke-Tick {
    if ($script:InDialog -or -not $script:Child) { return }
    $u = Update-GuiChild -Child $script:Child
    if (@($u.Lines).Count -gt 0) { Add-ConsoleLines $u.Lines }
    if ($u.Exited) { Complete-Tool ([int]$u.ExitCode); return }
    $elapsed = (Get-Date).ToUniversalTime() - $script:Child.StartedUtc
    $quiet = (Get-Date).ToUniversalTime() - $script:Child.LastOutputUtc
    $text = 'Running for ' + ('{0:00}:{1:00}' -f [int][Math]::Floor($elapsed.TotalMinutes), $elapsed.Seconds)
    if ($quiet.TotalMinutes -ge 2) { $text += ' - no output for ' + [int][Math]::Floor($quiet.TotalMinutes) + ' minutes (information only; the tool is never stopped automatically)' }
    $ui.StatusDetail.Text = $text
    # Test hook (non-elevated only): press Stop without the confirmation, N seconds after the tool started.
    if ($TestStopAfter -gt 0 -and $elapsed.TotalSeconds -ge $TestStopAfter -and -not $script:StopRequested) { Stop-RunningTool -NoConfirm; return }
    $pp = Get-GuiPendingPrompt -Child $script:Child -Tool $script:Tool
    if ($pp) { Resolve-Prompt $pp }
}

function Write-ResultFile {
    # Test hook only (-ResultPath, non-elevated): the window state, for tests\gui\Test-GuiWindow.ps1.
    try {
        $doc = [ordered]@{
            Tool = $(if ($script:Tool) { $script:Tool.Id } else { '' }); Banner = $ui.BannerText.Text; BannerVisible = ($ui.Banner.Visibility -eq 'Visible')
            ResultFolder = $(if ($script:Result) { $script:Result.Folder } else { '' }); Failed = $(if ($script:Result) { [bool]$script:Result.Failed } else { $false })
            ResultTexts = @($ui.ResultHost.Children | ForEach-Object { if ($_ -is [System.Windows.Controls.TextBlock] -or $_ -is [System.Windows.Controls.TextBox]) { [string]$_.Text } })
            ConsoleText = $ui.ConsoleBox.Text; Cards = $ui.ToolsGrid.Children.Count; Columns = $ui.ToolsGrid.Columns
            EnabledCards = @($ui.ToolsGrid.Children | Where-Object { $_.IsEnabled }).Count
            DpiMode = $script:DpiMode; TextMode = [string][System.Windows.Media.TextOptions]::GetTextFormattingMode($win); Theme = $script:ThemeName
            WindowWidth = $win.ActualWidth; WindowHeight = $win.ActualHeight; ConsoleHeight = $ui.RowConsole.ActualHeight
            CompactWidth = [bool]$script:Compact.Width; CompactHeight = [bool]$script:Compact.Height
            StartPanelVisible = ($ui.StartPanel.Visibility -eq 'Visible'); RunPanelVisible = ($ui.RunPanel.Visibility -eq 'Visible')
            Links = @($ui.LinkRubinIt.NavigateUri.AbsoluteUri, $ui.LinkPupontech.NavigateUri.AbsoluteUri); Info = $ui.InfoText.Text
        }
        ($doc | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $ResultPath -Encoding UTF8
    } catch { }
}

# ---- self-test: tokens and the dialog builder (no window is shown, nothing runs) ------------------------
if ($SelfTest) {
    $fails = @()
    $light = @($win.Resources.Keys | Where-Object { ([string]$_).StartsWith('Brush.') } | ForEach-Object { [string]$_ } | Sort-Object)
    $dark = @($win.Resources['Theme.Dark'].Keys | Where-Object { $_ -is [string] -and $_.StartsWith('Brush.') } | Sort-Object)
    if (($light -join ',') -ne ($dark -join ',')) { $fails += 'light and dark palettes define different tokens' }
    $src = [IO.File]::ReadAllText($PSCommandPath)
    foreach ($m in [regex]::Matches($src, "(?:Get-Brush |New-Text \S+ )'(\w+)'")) { if ($light -notcontains ('Brush.' + $m.Groups[1].Value)) { $fails += ('unknown token: ' + $m.Groups[1].Value) } }
    if ($src -match "'#[0-9A-Fa-f]{6}") { $fails += 'a literal colour in the script (use a Brush.* token)' }
    $d = New-DialogWindow -Title 'T' -Message 'M' -Detail 'D' -TextInput -Buttons @(@{ Text = 'Send'; Value = 'send' })
    if (-not $d.Tag.Text) { $fails += 'dialog text input missing' }
    if ($fails.Count -eq 0) { Write-Host ('SELFTEST_OK tokens=' + $light.Count + ' theme=' + $script:ThemeName + ' dpi=' + $script:DpiMode); exit 0 }
    $fails | ForEach-Object { Write-Host ('SELFTEST_FAIL ' + $_) }
    exit 1
}

# ---- wiring -------------------------------------------------------------------------------------------------
$ui.TitleText.Text = 'Remote Diagnostics  v' + $GuiVersion
$ui.InfoText.Text = 'PC: ' + $env:COMPUTERNAME + '     Elevated: ' + $(if ($isAdmin) { 'yes' } else { 'NO - test window' }) + '     Scripts: ' + $ToolRoot
Initialize-ToolCards
Show-Panel 'Start'

$ui.BtnBack.add_Click({ if (-not $script:Child) { $script:Tool = $null; Show-Panel 'Start' } })
$ui.BtnRun.add_Click({ Start-Tool })
$ui.BtnStopSave.add_Click({
        if ($script:StopFile) {
            try { [IO.File]::WriteAllText($script:StopFile, 'stop') ; Add-ConsoleNote 'Stop requested: the tool saves its events and crash reports, then ends.' } catch { Add-ConsoleNote ('Could not write the stop file: ' + $_.Exception.Message) }
            $ui.BtnStopSave.IsEnabled = $false
        }
    })
$ui.BtnStop.add_Click({ Stop-RunningTool })
$ui.BtnOpenLog.add_Click({ if ($script:LogPath -and (Test-Path -LiteralPath $script:LogPath)) { Start-Process -FilePath 'notepad.exe' -ArgumentList ('"' + $script:LogPath + '"') } })
$ui.BtnCopy.add_Click({ try { [System.Windows.Clipboard]::SetText($ui.ConsoleBox.Text) } catch { } })

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(250)
$timer.add_Tick({
        try { Invoke-Tick }
        catch {
            try { Add-ConsoleNote ('GUI error: ' + $_.Exception.Message) } catch { }
            try { [IO.File]::AppendAllText((Join-Path $script:WorkDir 'gui-error.log'), (Get-Date -Format 's') + ' ' + $_.ToString() + "`r`n") } catch { }
        }
    })

$win.add_Closing({
        param($s, $e)
        if (-not $script:Child -or $script:Child.Finished) { return }
        # The timer must not answer a question behind this box (InDialog pauses it while a box is open).
        $script:InDialog = $true
        try {
            if ($script:Tool.Kind -eq 'ChangesPC') {
                [void][System.Windows.MessageBox]::Show(('"' + $script:Tool.Title + '" is changing this PC. Closing now could leave it half done. Wait for it to finish.'), 'Remote Diagnostics', 'OK', 'Warning')
                $e.Cancel = $true; return
            }
            if (-not $AutoTool) {
                $q = 'A tool is still running. Stop it and close? It only reads this PC, so stopping it changes nothing, but its output may be incomplete.'
                if ($script:StopFile) { $q += "`n`nFor the print watch, press 'Stop and save' first: closing now skips its save step." }
                if ([System.Windows.MessageBox]::Show($q, 'Remote Diagnostics', 'YesNo', 'Question') -ne 'Yes') { $e.Cancel = $true; return }
            }
            Stop-GuiChild $script:Child
        } finally { $script:InDialog = $false }
    })

[System.Windows.Threading.Dispatcher]::CurrentDispatcher.add_UnhandledException({
        param($s, $e)
        try {
            [IO.File]::AppendAllText((Join-Path $script:WorkDir 'gui-error.log'), (Get-Date -Format 's') + ' ' + $e.Exception.ToString() + "`r`n")
            [void][System.Windows.MessageBox]::Show(('The window hit an error and leaves a running tool alone:' + "`n`n" + $e.Exception.Message), 'Remote Diagnostics', 'OK', 'Warning')
        } catch { }
        $e.Handled = $true
    })

# ---- fit the screen (1366x768 at 150% = about 910x480 DIP of work area) ------------------------------------
$script:Compact = @{ Width = $null; Height = $null }
function Set-WindowFitToScreen {
    $wa = [System.Windows.SystemParameters]::WorkArea
    $w = [Math]::Min(1120, $wa.Width - 16); $h = [Math]::Min(760, $wa.Height - 16)
    if ($TestSize -match '^(\d+)x(\d+)$') { $w = [double]$Matches[1]; $h = [double]$Matches[2] }
    $win.MinWidth = [Math]::Min(760, $w); $win.MinHeight = [Math]::Min(460, $h)
    $win.Width = $w; $win.Height = $h
}
function Update-CompactLayout {
    $narrow = ($win.ActualWidth -gt 0 -and $win.ActualWidth -lt 1000)
    $short = ($win.ActualHeight -gt 0 -and $win.ActualHeight -lt 660)
    if ($script:Compact.Width -ne $narrow) { $ui.ToolsGrid.Columns = $(if ($narrow) { 1 } else { 2 }); $script:Compact.Width = $narrow }
    if ($script:Compact.Height -ne $short) {
        $ui.RowConsole.Height = New-Object System.Windows.GridLength $(if ($short) { 88 } else { 170 })
        $ui.RootGrid.Margin = $(if ($short) { '10,8,10,4' } else { '16,16,16,8' })
        $ui.HeaderCard.Padding = $(if ($short) { '14,6,14,6' } else { '18,12,18,12' })
        $ui.HeaderCard.Margin = $(if ($short) { '0,0,0,8' } else { '0,0,0,12' })
        $ui.TitleText.FontSize = $(if ($short) { 16 } else { 19 })
        $ui.StatusCard.Padding = $(if ($short) { '14,6,14,8' } else { '16,12,16,12' })
        $script:Compact.Height = $short
    }
}
function Update-TextMode {
    $scale = 1.0
    try { $scale = [System.Windows.Media.VisualTreeHelper]::GetDpi($win).DpiScaleX } catch { }
    [System.Windows.Media.TextOptions]::SetTextFormattingMode($win, $(if ($scale -gt 1.01) { 'Ideal' } else { 'Display' }))
}
Set-WindowFitToScreen
$win.add_SizeChanged({ Update-CompactLayout })
$win.add_DpiChanged({ Update-TextMode })

# Footer links open in the normal browser (handed to Explorer, so it does not inherit admin rights), on click only.
foreach ($link in $ui.LinkRubinIt, $ui.LinkPupontech) {
    $link.add_RequestNavigate({ param($s, $e) try { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $e.Uri.AbsoluteUri + '"') } catch { }; $e.Handled = $true })
}

function Save-WindowPng {
    # Test hook: render this window's own visual tree (never a screen capture).
    try {
        $win.UpdateLayout()
        $rs = [Math]::Max(1.0, $RenderScale)
        $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap ([int]($win.ActualWidth * $rs)), ([int]($win.ActualHeight * $rs)), (96 * $rs), (96 * $rs), ([System.Windows.Media.PixelFormats]::Pbgra32)
        $rtb.Render($win)
        $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
        $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
        $fs = [IO.File]::Create($RenderPng); $enc.Save($fs); $fs.Close()
    } catch { }
}

$win.add_Loaded({
        Update-TextMode
        Update-CompactLayout
        $timer.Start()
        if ($AutoTool) {
            Open-Tool $AutoTool
            if ($TestValues) { $tv = $TestValues | ConvertFrom-Json; foreach ($p in $tv.PSObject.Properties) { $c = $script:Inputs[$p.Name]; if ($c -is [System.Windows.Controls.CheckBox]) { $c.IsChecked = [bool]$p.Value } elseif ($c -is [System.Windows.Controls.PasswordBox]) { $c.Password = [string]$p.Value } elseif ($c) { $c.Text = [string]$p.Value } } }
            Start-Tool
            # Test hook: when nothing was started (values refused, confirmation not given) there is no run to wait for.
            if (-not $script:Child) { Write-ResultFile; $win.Close() }
        } elseif ($ResultPath) {
            [void]$win.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::ContextIdle, [Action]{ Write-ResultFile; if ($RenderPng) { Save-WindowPng }; $win.Close() })
        }
    })

try {
    [void]$win.ShowDialog()
} finally {
    $timer.Stop()
    if ($script:Child -and -not $script:Child.Finished) { Stop-GuiChild $script:Child }
    Restore-GuiConsoleEncoding $script:ConsoleSaved
}
exit 0
