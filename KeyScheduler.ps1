Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Win11 DWM interop so the title bar follows the app's light/dark theme (Fluent).
if (-not ("Native.Dwm" -as [type])) {
    Add-Type -Namespace Native -Name Dwm -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("dwmapi.dll")]
public static extern int DwmSetWindowAttribute(System.IntPtr hwnd, int attr, ref int val, int size);
'@
}

$ErrorActionPreference = "Stop"

$AppName = "Key Scheduler"
$StoreDir = Join-Path $env:LOCALAPPDATA "KeyScheduler"
$StorePath = Join-Path $StoreDir "schedules.json"
$LogPath = Join-Path $StoreDir "runs.json"

$KeyOptions = [ordered]@{
    "Enter" = "{ENTER}"
    "Escape" = "{ESC}"
    "Tab" = "{TAB}"
    "Space" = " "
    "Arrow Up" = "{UP}"
    "Arrow Down" = "{DOWN}"
    "Arrow Left" = "{LEFT}"
    "Arrow Right" = "{RIGHT}"
    "F1" = "{F1}"
    "F2" = "{F2}"
    "F3" = "{F3}"
    "F4" = "{F4}"
    "F5" = "{F5}"
    "F6" = "{F6}"
    "F7" = "{F7}"
    "F8" = "{F8}"
    "F9" = "{F9}"
    "F10" = "{F10}"
    "F11" = "{F11}"
    "F12" = "{F12}"
    "Ctrl+S" = "^s"
    "Ctrl+C" = "^c"
    "Ctrl+V" = "^v"
    "Ctrl+Z" = "^z"
}

$RepeatOptions = @("One-time", "Daily", "Weekly")
$script:Schedules = New-Object System.Collections.Generic.List[object]
$script:RunLog = New-Object System.Collections.Generic.List[object]
$script:SelectedScheduleId = $null

function Ensure-Store {
    if (-not (Test-Path $StoreDir)) {
        New-Item -ItemType Directory -Path $StoreDir | Out-Null
    }
}

function New-ScheduleId {
    return [guid]::NewGuid().ToString("N")
}

function ConvertTo-DateTimeOrNull {
    param([object]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }

    $text = [string]$Value
    if ($text -match '^/Date\((-?\d+)\)/$') {
        return [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$matches[1]).LocalDateTime
    }

    return [datetime]::Parse($text, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
}

function ConvertTo-StorageDate {
    param([object]$Value)

    if ($null -eq $Value) { return $null }
    return ([datetime]$Value).ToString("o", [Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-StorageSchedule {
    param([object]$Schedule)

    return [pscustomobject]@{
        Id = $Schedule.Id
        KeyName = $Schedule.KeyName
        SendKeysValue = $Schedule.SendKeysValue
        Repeat = $Schedule.Repeat
        NextRunAt = ConvertTo-StorageDate $Schedule.NextRunAt
        Enabled = $Schedule.Enabled
        Status = $Schedule.Status
        LastRunAt = ConvertTo-StorageDate $Schedule.LastRunAt
    }
}

function ConvertTo-StorageLogEntry {
    param([object]$Entry)

    return [pscustomobject]@{
        Time = ConvertTo-StorageDate $Entry.Time
        KeyName = $Entry.KeyName
        Status = $Entry.Status
        Details = $Entry.Details
    }
}

function Load-Data {
    Ensure-Store

    if (Test-Path $StorePath) {
        $items = Get-Content -Raw -Path $StorePath | ConvertFrom-Json
        foreach ($item in @($items)) {
            if ($null -eq $item) { continue }
            $script:Schedules.Add([pscustomobject]@{
                Id = [string]$item.Id
                KeyName = [string]$item.KeyName
                SendKeysValue = [string]$item.SendKeysValue
                Repeat = [string]$item.Repeat
                NextRunAt = ConvertTo-DateTimeOrNull $item.NextRunAt
                Enabled = [bool]$item.Enabled
                Status = [string]$item.Status
                LastRunAt = ConvertTo-DateTimeOrNull $item.LastRunAt
            })
        }
    }

    if (Test-Path $LogPath) {
        $items = Get-Content -Raw -Path $LogPath | ConvertFrom-Json
        foreach ($item in @($items)) {
            if ($null -eq $item) { continue }
            $script:RunLog.Add([pscustomobject]@{
                Time = ConvertTo-DateTimeOrNull $item.Time
                KeyName = [string]$item.KeyName
                Status = [string]$item.Status
                Details = [string]$item.Details
            })
        }
    }
}

function Save-Data {
    Ensure-Store

    $scheduleItems = @($script:Schedules | ForEach-Object { ConvertTo-StorageSchedule $_ })
    $logItems = @($script:RunLog | Select-Object -Last 100 | ForEach-Object { ConvertTo-StorageLogEntry $_ })

    ConvertTo-Json -InputObject $scheduleItems -Depth 5 |
        Set-Content -Path $StorePath -Encoding UTF8

    ConvertTo-Json -InputObject $logItems -Depth 5 |
        Set-Content -Path $LogPath -Encoding UTF8
}

function Show-AppError {
    param(
        [string]$Context,
        [object]$ErrorRecord
    )

    $message = "$Context`r`n`r`n$($ErrorRecord.Exception.Message)"
    [System.Windows.Forms.MessageBox]::Show($message, $AppName, "OK", "Error") | Out-Null
}

function Add-RunLog {
    param(
        [object]$Schedule,
        [string]$Status,
        [string]$Details
    )

    $script:RunLog.Add([pscustomobject]@{
        Time = Get-Date
        KeyName = $Schedule.KeyName
        Status = $Status
        Details = $Details
    })

    while ($script:RunLog.Count -gt 100) {
        $script:RunLog.RemoveAt(0)
    }
}

function Get-NextRun {
    param(
        [datetime]$CurrentRun,
        [string]$Repeat
    )

    switch ($Repeat) {
        "Daily" { return $CurrentRun.AddDays(1) }
        "Weekly" { return $CurrentRun.AddDays(7) }
        default { return $null }
    }
}

function Format-DateTime {
    param([object]$Value)
    if ($null -eq $Value) { return "" }
    return ([datetime]$Value).ToString("yyyy-MM-dd HH:mm:ss")
}

function Invoke-Schedule {
    param([object]$Schedule)

    $now = Get-Date
    $lateBy = ($now - $Schedule.NextRunAt).TotalSeconds

    if ($lateBy -gt 60) {
        $Schedule.Status = "Missed"
        $Schedule.LastRunAt = $now
        Add-RunLog $Schedule "Missed" "Scheduled time was missed by more than 60 seconds."
    }
    else {
        try {
            [System.Windows.Forms.SendKeys]::SendWait($Schedule.SendKeysValue)
            $Schedule.Status = "Succeeded"
            $Schedule.LastRunAt = $now
            Add-RunLog $Schedule "Succeeded" "Sent to active window."
        }
        catch {
            $Schedule.Status = "Failed"
            $Schedule.LastRunAt = $now
            Add-RunLog $Schedule "Failed" $_.Exception.Message
        }
    }

    $nextRun = Get-NextRun $Schedule.NextRunAt $Schedule.Repeat
    if ($null -eq $nextRun) {
        [void]$script:Schedules.Remove($Schedule)
    }
    else {
        while ($nextRun -le (Get-Date)) {
            $nextRun = Get-NextRun $nextRun $Schedule.Repeat
        }
        $Schedule.NextRunAt = $nextRun
        $Schedule.Enabled = $true
    }
}

function Refresh-ScheduleList {
    $scheduleGrid.Rows.Clear()

    foreach ($schedule in $script:Schedules) {
        $index = $scheduleGrid.Rows.Add(
            $schedule.KeyName,
            $schedule.Repeat,
            (Format-DateTime $schedule.NextRunAt),
            $schedule.Status
        )
        $scheduleGrid.Rows[$index].Tag = $schedule.Id
    }
}

function Refresh-RunLog {
    $logGrid.Rows.Clear()

    foreach ($entry in ($script:RunLog | Select-Object -Last 20)) {
        [void]$logGrid.Rows.Add(
            (Format-DateTime $entry.Time),
            $entry.KeyName,
            $entry.Status,
            $entry.Details
        )
    }
}

function Refresh-All {
    Refresh-ScheduleList
    Refresh-RunLog
}

function Get-SelectedSchedule {
    if ($scheduleGrid.SelectedRows.Count -eq 0) {
        return $null
    }

    $id = [string]$scheduleGrid.SelectedRows[0].Tag
    foreach ($schedule in $script:Schedules) {
        if ($schedule.Id -eq $id) {
            return $schedule
        }
    }

    return $null
}

function Set-FormFromSchedule {
    param([object]$Schedule)

    if ($null -eq $Schedule) { return }

    $keyCombo.SelectedItem = $Schedule.KeyName
    $repeatCombo.SelectedItem = $Schedule.Repeat
    if ($null -ne $Schedule.NextRunAt) {
        $datePicker.Value = $Schedule.NextRunAt.Date
        $timePicker.Value = $Schedule.NextRunAt
    }
    $script:SelectedScheduleId = $Schedule.Id
}

function Get-RequestedRunTime {
    $date = $datePicker.Value.Date
    $time = $timePicker.Value
    return $date.AddHours($time.Hour).AddMinutes($time.Minute).AddSeconds($time.Second)
}

function Upsert-ScheduleFromForm {
    $keyName = [string]$keyCombo.SelectedItem
    $repeat = [string]$repeatCombo.SelectedItem
    $runAt = Get-RequestedRunTime

    if ([string]::IsNullOrWhiteSpace($keyName)) {
        [System.Windows.Forms.MessageBox]::Show("Choose a key.", $AppName) | Out-Null
        return
    }

    if ($repeat -eq "One-time" -and $runAt -le (Get-Date)) {
        [System.Windows.Forms.MessageBox]::Show("Choose a future time for a one-time schedule.", $AppName) | Out-Null
        return
    }

    if ($runAt -le (Get-Date)) {
        while ($runAt -le (Get-Date)) {
            $runAt = Get-NextRun $runAt $repeat
        }
    }

    $existing = $null
    foreach ($schedule in $script:Schedules) {
        if ($schedule.Id -eq $script:SelectedScheduleId) {
            $existing = $schedule
            break
        }
    }

    if ($null -eq $existing) {
        $script:Schedules.Add([pscustomobject]@{
            Id = New-ScheduleId
            KeyName = $keyName
            SendKeysValue = $KeyOptions[$keyName]
            Repeat = $repeat
            NextRunAt = $runAt
            Enabled = $true
            Status = "Pending"
            LastRunAt = $null
        })
    }
    else {
        $existing.KeyName = $keyName
        $existing.SendKeysValue = $KeyOptions[$keyName]
        $existing.Repeat = $repeat
        $existing.NextRunAt = $runAt
        $existing.Enabled = $true
        $existing.Status = "Pending"
    }

    Save-Data
    Refresh-All
}

function Clear-FormSelection {
    $script:SelectedScheduleId = $null
    $keyCombo.SelectedIndex = 0
    $repeatCombo.SelectedIndex = 0
    $datePicker.Value = (Get-Date).Date
    $timePicker.Value = (Get-Date).AddMinutes(1)
}

# =====================================================================
#  Fluent Design theme (color, typography, elevation, geometry, motion)
#  https://learn.microsoft.com/windows/apps/design/guidelines-overview
# =====================================================================

function Blend-Color {
    param([System.Drawing.Color]$From, [System.Drawing.Color]$To, [double]$T)
    $r = [int][math]::Round($From.R + ($To.R - $From.R) * $T)
    $g = [int][math]::Round($From.G + ($To.G - $From.G) * $T)
    $b = [int][math]::Round($From.B + ($To.B - $From.B) * $T)
    $clamp = { param($v) [math]::Max(0, [math]::Min(255, $v)) }
    return [System.Drawing.Color]::FromArgb((& $clamp $r), (& $clamp $g), (& $clamp $b))
}

function C { param($r, $g, $b) [System.Drawing.Color]::FromArgb($r, $g, $b) }

# Honor the user's system accent color, the heart of a Fluent app's identity.
function Get-AccentColor {
    try {
        $v = [int64](Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\DWM' -Name AccentColor -ErrorAction Stop).AccentColor
        return (C ($v -band 0xFF) (($v -shr 8) -band 0xFF) (($v -shr 16) -band 0xFF))
    }
    catch {
        return (C 0 95 184)   # Fallback: Windows default accent (#005FB8)
    }
}

# Follow the system light/dark app theme.
$script:IsDark = $false
try {
    $lightPref = (Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop).AppsUseLightTheme
    $script:IsDark = ($lightPref -eq 0)
}
catch { }

$accent = Get-AccentColor
if ($script:IsDark) { $accent = Blend-Color $accent ([System.Drawing.Color]::White) 0.10 }

# Text-on-accent legibility (accent buttons flip to dark text on light accents).
$accentLum = 0.299 * $accent.R + 0.587 * $accent.G + 0.114 * $accent.B
$onAccent = if ($accentLum -gt 150) { C 20 20 20 } else { [System.Drawing.Color]::White }

if ($script:IsDark) {
    $script:Palette = @{
        WinBg          = (C 32 32 32)
        CardBg         = (C 43 43 43)
        CardBorder     = (C 56 56 56)
        TextPrimary    = (C 255 255 255)
        TextSecondary  = (C 176 176 176)
        ControlBg      = (C 59 59 59)
        ControlHover   = (C 68 68 68)
        ControlPressed = (C 52 52 52)
        ControlBorder  = (C 80 80 80)
        Accent         = $accent
        AccentHover    = (Blend-Color $accent ([System.Drawing.Color]::White) 0.12)
        AccentPressed  = (Blend-Color $accent ([System.Drawing.Color]::Black) 0.12)
        OnAccent       = $onAccent
        GridSelBg      = (Blend-Color (C 43 43 43) $accent 0.30)
        GridSelFg      = (C 255 255 255)
    }
}
else {
    $script:Palette = @{
        WinBg          = (C 243 243 243)
        CardBg         = (C 255 255 255)
        CardBorder     = (C 229 229 229)
        TextPrimary    = (C 26 26 26)
        TextSecondary  = (C 94 94 94)
        ControlBg      = (C 251 251 251)
        ControlHover   = (C 244 244 244)
        ControlPressed = (C 237 237 237)
        ControlBorder  = (C 214 214 214)
        Accent         = $accent
        AccentHover    = (Blend-Color $accent ([System.Drawing.Color]::Black) 0.10)
        AccentPressed  = (Blend-Color $accent ([System.Drawing.Color]::Black) 0.20)
        OnAccent       = $onAccent
        GridSelBg      = (Blend-Color (C 255 255 255) $accent 0.14)
        GridSelFg      = (C 26 26 26)
    }
}

# Typography: the Segoe UI type ramp (Body / Body Strong / Title / Caption).
$installedFonts = (New-Object System.Drawing.Text.InstalledFontCollection).Families | ForEach-Object { $_.Name }
$baseFamily = @('Segoe UI Variable Text', 'Segoe UI') | Where-Object { $installedFonts -contains $_ } | Select-Object -First 1
if (-not $baseFamily) { $baseFamily = 'Segoe UI' }
$semiFamily = if ($installedFonts -contains 'Segoe UI Semibold') { 'Segoe UI Semibold' } else { $baseFamily }

$script:FontBody = New-Object System.Drawing.Font $baseFamily, 10, ([System.Drawing.FontStyle]::Regular)
$script:FontCaption = New-Object System.Drawing.Font $baseFamily, 8.5, ([System.Drawing.FontStyle]::Regular)
if ($semiFamily -ne $baseFamily) {
    $script:FontStrong = New-Object System.Drawing.Font $semiFamily, 10, ([System.Drawing.FontStyle]::Regular)
    $script:FontTitle = New-Object System.Drawing.Font $semiFamily, 16, ([System.Drawing.FontStyle]::Regular)
}
else {
    $script:FontStrong = New-Object System.Drawing.Font $baseFamily, 10, ([System.Drawing.FontStyle]::Bold)
    $script:FontTitle = New-Object System.Drawing.Font $baseFamily, 16, ([System.Drawing.FontStyle]::Bold)
}

function Enable-DoubleBuffer {
    param([System.Windows.Forms.Control]$Control)
    $prop = [System.Windows.Forms.Control].GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::NonPublic)
    $prop.SetValue($Control, $true, $null)
}

function New-RoundedPath {
    param([System.Drawing.Rectangle]$Rect, [int]$Radius)
    $d = $Radius * 2
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $p.AddArc($Rect.X, $Rect.Y, $d, $d, 180, 90)
    $p.AddArc($Rect.Right - $d, $Rect.Y, $d, $d, 270, 90)
    $p.AddArc($Rect.Right - $d, $Rect.Bottom - $d, $d, $d, 0, 90)
    $p.AddArc($Rect.X, $Rect.Bottom - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

# Elevation: a rounded, bordered surface (Fluent "card"), 8px corner radius.
function New-Card {
    param([string]$Title)
    $card = New-Object System.Windows.Forms.Panel
    Enable-DoubleBuffer $card
    $card.Dock = 'Fill'
    $card.BackColor = $script:Palette.WinBg
    $card.Margin = New-Object System.Windows.Forms.Padding 0, 0, 0, 14
    $card.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $rect = New-Object System.Drawing.Rectangle 0, 0, ($s.Width - 1), ($s.Height - 1)
        $path = New-RoundedPath $rect 8
        $brush = New-Object System.Drawing.SolidBrush $script:Palette.CardBg
        $pen = New-Object System.Drawing.Pen $script:Palette.CardBorder
        $g.FillPath($brush, $path)
        $g.DrawPath($pen, $path)
        $brush.Dispose(); $pen.Dispose(); $path.Dispose()
    })

    $header = New-Object System.Windows.Forms.Label
    $header.Text = $Title
    $header.AutoSize = $true
    $header.Location = New-Object System.Drawing.Point 18, 13
    $header.Font = $script:FontStrong
    $header.ForeColor = $script:Palette.TextPrimary
    $header.BackColor = $script:Palette.CardBg
    $card.Controls.Add($header)
    return $card
}

# Commanding: owner-drawn accent / subtle buttons with hover + pressed motion.
function New-FluentButton {
    param([string]$Text, [int]$Width, [switch]$Primary, [System.Drawing.Color]$Container)
    if (-not $Container) { $Container = $script:Palette.CardBg }
    $b = New-Object System.Windows.Forms.Panel
    Enable-DoubleBuffer $b
    $b.Width = $Width
    $b.Height = 32
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $b.BackColor = $Container
    Add-Member -InputObject $b -NotePropertyName Caption -NotePropertyValue $Text
    Add-Member -InputObject $b -NotePropertyName IsPrimary -NotePropertyValue ([bool]$Primary)
    Add-Member -InputObject $b -NotePropertyName Hover -NotePropertyValue $false
    Add-Member -InputObject $b -NotePropertyName Pressed -NotePropertyValue $false
    $b.Add_MouseEnter({ $this.Hover = $true; $this.Invalidate() })
    $b.Add_MouseLeave({ $this.Hover = $false; $this.Pressed = $false; $this.Invalidate() })
    $b.Add_MouseDown({ $this.Pressed = $true; $this.Invalidate() })
    $b.Add_MouseUp({ $this.Pressed = $false; $this.Invalidate() })
    $b.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear($s.BackColor)
        $rect = New-Object System.Drawing.Rectangle 0, 0, ($s.Width - 1), ($s.Height - 1)
        $path = New-RoundedPath $rect 4
        if ($s.IsPrimary) {
            $fill = if ($s.Pressed) { $script:Palette.AccentPressed } elseif ($s.Hover) { $script:Palette.AccentHover } else { $script:Palette.Accent }
            $fg = $script:Palette.OnAccent
        }
        else {
            $fill = if ($s.Pressed) { $script:Palette.ControlPressed } elseif ($s.Hover) { $script:Palette.ControlHover } else { $script:Palette.ControlBg }
            $fg = $script:Palette.TextPrimary
        }
        $brush = New-Object System.Drawing.SolidBrush $fill
        $g.FillPath($brush, $path)
        $brush.Dispose()
        if (-not $s.IsPrimary) {
            $pen = New-Object System.Drawing.Pen $script:Palette.ControlBorder
            $g.DrawPath($pen, $path)
            $pen.Dispose()
        }
        $path.Dispose()
        $flags = [System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter
        [System.Windows.Forms.TextRenderer]::DrawText($g, $s.Caption, $script:FontStrong, $s.ClientRectangle, $fg, $flags)
    })
    return $b
}

function New-FieldLabel {
    param([string]$Text, [int]$X, [int]$Y)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.AutoSize = $true
    $l.Location = New-Object System.Drawing.Point $X, $Y
    $l.Font = $script:FontCaption
    $l.ForeColor = $script:Palette.TextSecondary
    $l.BackColor = $script:Palette.CardBg
    return $l
}

function Style-Input {
    param([System.Windows.Forms.Control]$Control)
    $Control.Font = $script:FontBody
    $Control.BackColor = $script:Palette.ControlBg
    $Control.ForeColor = $script:Palette.TextPrimary
    if ($Control -is [System.Windows.Forms.ComboBox]) {
        $Control.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    }
}

# Layout: a flat, borderless list surface consistent with Fluent data tables.
function Style-FluentGrid {
    param([System.Windows.Forms.DataGridView]$Grid)
    $Grid.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $Grid.BackgroundColor = $script:Palette.CardBg
    $Grid.GridColor = $script:Palette.CardBorder
    $Grid.EnableHeadersVisualStyles = $false
    $Grid.CellBorderStyle = [System.Windows.Forms.DataGridViewCellBorderStyle]::SingleHorizontal
    $Grid.ColumnHeadersBorderStyle = [System.Windows.Forms.DataGridViewHeaderBorderStyle]::None
    $Grid.RowHeadersVisible = $false
    $Grid.AllowUserToResizeRows = $false
    $Grid.Font = $script:FontBody
    $Grid.RowTemplate.Height = 34
    $Grid.ColumnHeadersHeight = 36
    $Grid.ColumnHeadersHeightSizeMode = [System.Windows.Forms.DataGridViewColumnHeadersHeightSizeMode]::DisableResizing

    $pad = New-Object System.Windows.Forms.Padding 8, 0, 8, 0

    $h = $Grid.ColumnHeadersDefaultCellStyle
    $h.BackColor = $script:Palette.CardBg
    $h.ForeColor = $script:Palette.TextSecondary
    $h.SelectionBackColor = $script:Palette.CardBg
    $h.SelectionForeColor = $script:Palette.TextSecondary
    $h.Font = $script:FontStrong
    $h.Padding = $pad

    $c = $Grid.DefaultCellStyle
    $c.BackColor = $script:Palette.CardBg
    $c.ForeColor = $script:Palette.TextPrimary
    $c.SelectionBackColor = $script:Palette.GridSelBg
    $c.SelectionForeColor = $script:Palette.GridSelFg
    $c.Padding = $pad
}

Load-Data

$form = New-Object System.Windows.Forms.Form
$form.Text = $AppName
$form.Size = New-Object System.Drawing.Size 920, 660
$form.MinimumSize = New-Object System.Drawing.Size 800, 560
$form.StartPosition = "CenterScreen"
$form.BackColor = $script:Palette.WinBg
$form.ForeColor = $script:Palette.TextPrimary
$form.Font = $script:FontBody

$mainLayout = New-Object System.Windows.Forms.TableLayoutPanel
$mainLayout.Dock = "Fill"
$mainLayout.BackColor = $script:Palette.WinBg
$mainLayout.Padding = New-Object System.Windows.Forms.Padding 24, 18, 24, 12
$mainLayout.ColumnCount = 1
$mainLayout.RowCount = 5
$mainLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 60))) | Out-Null
$mainLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 176))) | Out-Null
$mainLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 56))) | Out-Null
$mainLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 44))) | Out-Null
$mainLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 30))) | Out-Null
$form.Controls.Add($mainLayout)

# --- Header (app title + subtitle) ---
$headerPanel = New-Object System.Windows.Forms.Panel
$headerPanel.Dock = "Fill"
$headerPanel.BackColor = $script:Palette.WinBg

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = $AppName
$titleLabel.AutoSize = $true
$titleLabel.Location = New-Object System.Drawing.Point 0, 2
$titleLabel.Font = $script:FontTitle
$titleLabel.ForeColor = $script:Palette.TextPrimary
$titleLabel.BackColor = $script:Palette.WinBg
$headerPanel.Controls.Add($titleLabel)

$subtitleLabel = New-Object System.Windows.Forms.Label
$subtitleLabel.Text = "Schedule a keystroke to whichever app is active when it fires."
$subtitleLabel.AutoSize = $true
$subtitleLabel.Location = New-Object System.Drawing.Point 2, 36
$subtitleLabel.Font = $script:FontCaption
$subtitleLabel.ForeColor = $script:Palette.TextSecondary
$subtitleLabel.BackColor = $script:Palette.WinBg
$headerPanel.Controls.Add($subtitleLabel)

$mainLayout.Controls.Add($headerPanel, 0, 0)

# --- Input card ---
$inputCard = New-Card "New schedule"

$inputCard.Controls.Add((New-FieldLabel "Key" 18 46))
$keyCombo = New-Object System.Windows.Forms.ComboBox
$keyCombo.DropDownStyle = "DropDownList"
$keyCombo.Location = New-Object System.Drawing.Point 18, 68
$keyCombo.Width = 150
$KeyOptions.Keys | ForEach-Object { [void]$keyCombo.Items.Add($_) }
$keyCombo.SelectedIndex = 0
Style-Input $keyCombo
$inputCard.Controls.Add($keyCombo)

$inputCard.Controls.Add((New-FieldLabel "Repeat" 188 46))
$repeatCombo = New-Object System.Windows.Forms.ComboBox
$repeatCombo.DropDownStyle = "DropDownList"
$repeatCombo.Location = New-Object System.Drawing.Point 188, 68
$repeatCombo.Width = 140
$RepeatOptions | ForEach-Object { [void]$repeatCombo.Items.Add($_) }
$repeatCombo.SelectedIndex = 0
Style-Input $repeatCombo
$inputCard.Controls.Add($repeatCombo)

$inputCard.Controls.Add((New-FieldLabel "Date" 348 46))
$datePicker = New-Object System.Windows.Forms.DateTimePicker
$datePicker.Format = "Short"
$datePicker.Location = New-Object System.Drawing.Point 348, 68
$datePicker.Width = 140
Style-Input $datePicker
$inputCard.Controls.Add($datePicker)

$inputCard.Controls.Add((New-FieldLabel "Time" 508 46))
$timePicker = New-Object System.Windows.Forms.DateTimePicker
$timePicker.Format = "Time"
$timePicker.ShowUpDown = $true
$timePicker.Location = New-Object System.Drawing.Point 508, 68
$timePicker.Width = 118
Style-Input $timePicker
$inputCard.Controls.Add($timePicker)

$saveButton = New-FluentButton -Text "Add to queue" -Width 132 -Primary
$saveButton.Location = New-Object System.Drawing.Point 18, 112
$saveButton.Add_Click({
    try {
        Upsert-ScheduleFromForm
    }
    catch {
        Show-AppError "Could not save the schedule." $_
    }
})
$inputCard.Controls.Add($saveButton)

$deleteButton = New-FluentButton -Text "Delete" -Width 104
$deleteButton.Location = New-Object System.Drawing.Point 162, 112
$deleteButton.Add_Click({
    try {
        $selected = Get-SelectedSchedule
        if ($null -eq $selected) { return }
        [void]$script:Schedules.Remove($selected)
        Clear-FormSelection
        Save-Data
        Refresh-All
    }
    catch {
        Show-AppError "Could not delete the schedule." $_
    }
})
$inputCard.Controls.Add($deleteButton)

$noteLabel = New-Object System.Windows.Forms.Label
$noteLabel.Text = "Select a row above to edit it, or delete it from the queue."
$noteLabel.AutoSize = $true
$noteLabel.Location = New-Object System.Drawing.Point 288, 120
$noteLabel.Font = $script:FontCaption
$noteLabel.ForeColor = $script:Palette.TextSecondary
$noteLabel.BackColor = $script:Palette.CardBg
$inputCard.Controls.Add($noteLabel)

$mainLayout.Controls.Add($inputCard, 0, 1)

# --- Queue card ---
$scheduleGrid = New-Object System.Windows.Forms.DataGridView
$scheduleGrid.AllowUserToAddRows = $false
$scheduleGrid.AllowUserToDeleteRows = $false
$scheduleGrid.ReadOnly = $true
$scheduleGrid.SelectionMode = "FullRowSelect"
$scheduleGrid.MultiSelect = $false
$scheduleGrid.AutoSizeColumnsMode = "Fill"
$scheduleGrid.Columns.Add("KeyName", "Key") | Out-Null
$scheduleGrid.Columns.Add("Repeat", "Repeat") | Out-Null
$scheduleGrid.Columns.Add("NextRunAt", "Next run") | Out-Null
$scheduleGrid.Columns.Add("Status", "Status") | Out-Null
Style-FluentGrid $scheduleGrid
$scheduleGrid.Add_SelectionChanged({
    if ($scheduleGrid.Focused -and $scheduleGrid.SelectedRows.Count -gt 0) {
        Set-FormFromSchedule (Get-SelectedSchedule)
    }
})

$queueCard = New-Card "Queue"
$queueCard.Controls.Add($scheduleGrid)
$queueCard.Add_Resize({ $scheduleGrid.SetBounds(16, 44, [math]::Max(0, $this.ClientSize.Width - 32), [math]::Max(0, $this.ClientSize.Height - 60)) })
$mainLayout.Controls.Add($queueCard, 0, 2)

# --- Log card ---
$logGrid = New-Object System.Windows.Forms.DataGridView
$logGrid.AllowUserToAddRows = $false
$logGrid.AllowUserToDeleteRows = $false
$logGrid.ReadOnly = $true
$logGrid.SelectionMode = "FullRowSelect"
$logGrid.MultiSelect = $false
$logGrid.AutoSizeColumnsMode = "Fill"
$logGrid.Columns.Add("Time", "Time") | Out-Null
$logGrid.Columns.Add("KeyName", "Key") | Out-Null
$logGrid.Columns.Add("Status", "Status") | Out-Null
$logGrid.Columns.Add("Details", "Details") | Out-Null
Style-FluentGrid $logGrid

$logCard = New-Card "Recent runs"
$logCard.Controls.Add($logGrid)
$logCard.Add_Resize({ $logGrid.SetBounds(16, 44, [math]::Max(0, $this.ClientSize.Width - 32), [math]::Max(0, $this.ClientSize.Height - 60)) })
$mainLayout.Controls.Add($logCard, 0, 3)

# --- Status bar ---
$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Dock = "Fill"
$statusLabel.TextAlign = "MiddleLeft"
$statusLabel.Font = $script:FontCaption
$statusLabel.ForeColor = $script:Palette.TextSecondary
$statusLabel.BackColor = $script:Palette.WinBg
$statusLabel.Text = "Ready. Keep this app running while schedules are active."
$mainLayout.Controls.Add($statusLabel, 0, 4)

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 500
$timer.Add_Tick({
    $now = Get-Date
    $due = @($script:Schedules | Where-Object {
        $_.Enabled -and $null -ne $_.NextRunAt -and $_.NextRunAt -le $now
    })

    if ($due.Count -eq 0) { return }

    foreach ($schedule in $due) {
        Invoke-Schedule $schedule
    }

    Save-Data
    Refresh-All
    $statusLabel.Text = "Last checked: $((Get-Date).ToString("HH:mm:ss"))"
})

$form.Add_Shown({
    # Match the title bar to the app's light/dark theme (Fluent).
    try {
        $darkFlag = [int]$script:IsDark
        [Native.Dwm]::DwmSetWindowAttribute($form.Handle, 20, [ref]$darkFlag, 4) | Out-Null
        [Native.Dwm]::DwmSetWindowAttribute($form.Handle, 19, [ref]$darkFlag, 4) | Out-Null
    }
    catch { }

    $scheduleGrid.SetBounds(16, 44, [math]::Max(0, $queueCard.ClientSize.Width - 32), [math]::Max(0, $queueCard.ClientSize.Height - 60))
    $logGrid.SetBounds(16, 44, [math]::Max(0, $logCard.ClientSize.Width - 32), [math]::Max(0, $logCard.ClientSize.Height - 60))

    Clear-FormSelection
    Refresh-All
    $timer.Start()
})

$form.Add_FormClosing({
    $timer.Stop()
    Save-Data
})

[System.Windows.Forms.Application]::EnableVisualStyles()
[void][System.Windows.Forms.Application]::Run($form)
