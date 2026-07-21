Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

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

Load-Data

$form = New-Object System.Windows.Forms.Form
$form.Text = $AppName
$form.Size = New-Object System.Drawing.Size(900, 620)
$form.MinimumSize = New-Object System.Drawing.Size(780, 520)
$form.StartPosition = "CenterScreen"

$mainLayout = New-Object System.Windows.Forms.TableLayoutPanel
$mainLayout.Dock = "Fill"
$mainLayout.ColumnCount = 1
$mainLayout.RowCount = 4
$mainLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 126))) | Out-Null
$mainLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 58))) | Out-Null
$mainLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 42))) | Out-Null
$mainLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 32))) | Out-Null
$form.Controls.Add($mainLayout)

$inputPanel = New-Object System.Windows.Forms.GroupBox
$inputPanel.Text = "Queue"
$inputPanel.Dock = "Fill"
$mainLayout.Controls.Add($inputPanel, 0, 0)

$keyLabel = New-Object System.Windows.Forms.Label
$keyLabel.Text = "Key"
$keyLabel.Location = New-Object System.Drawing.Point(16, 28)
$keyLabel.AutoSize = $true
$inputPanel.Controls.Add($keyLabel)

$keyCombo = New-Object System.Windows.Forms.ComboBox
$keyCombo.DropDownStyle = "DropDownList"
$keyCombo.Location = New-Object System.Drawing.Point(16, 50)
$keyCombo.Width = 150
$KeyOptions.Keys | ForEach-Object { [void]$keyCombo.Items.Add($_) }
$keyCombo.SelectedIndex = 0
$inputPanel.Controls.Add($keyCombo)

$repeatLabel = New-Object System.Windows.Forms.Label
$repeatLabel.Text = "Repeat"
$repeatLabel.Location = New-Object System.Drawing.Point(184, 28)
$repeatLabel.AutoSize = $true
$inputPanel.Controls.Add($repeatLabel)

$repeatCombo = New-Object System.Windows.Forms.ComboBox
$repeatCombo.DropDownStyle = "DropDownList"
$repeatCombo.Location = New-Object System.Drawing.Point(184, 50)
$repeatCombo.Width = 130
$RepeatOptions | ForEach-Object { [void]$repeatCombo.Items.Add($_) }
$repeatCombo.SelectedIndex = 0
$inputPanel.Controls.Add($repeatCombo)

$dateLabel = New-Object System.Windows.Forms.Label
$dateLabel.Text = "Date"
$dateLabel.Location = New-Object System.Drawing.Point(332, 28)
$dateLabel.AutoSize = $true
$inputPanel.Controls.Add($dateLabel)

$datePicker = New-Object System.Windows.Forms.DateTimePicker
$datePicker.Format = "Short"
$datePicker.Location = New-Object System.Drawing.Point(332, 50)
$datePicker.Width = 130
$inputPanel.Controls.Add($datePicker)

$timeLabel = New-Object System.Windows.Forms.Label
$timeLabel.Text = "Time"
$timeLabel.Location = New-Object System.Drawing.Point(480, 28)
$timeLabel.AutoSize = $true
$inputPanel.Controls.Add($timeLabel)

$timePicker = New-Object System.Windows.Forms.DateTimePicker
$timePicker.Format = "Time"
$timePicker.ShowUpDown = $true
$timePicker.Location = New-Object System.Drawing.Point(480, 50)
$timePicker.Width = 120
$inputPanel.Controls.Add($timePicker)

$saveButton = New-Object System.Windows.Forms.Button
$saveButton.Text = "Add to Queue"
$saveButton.Location = New-Object System.Drawing.Point(16, 86)
$saveButton.Width = 112
$saveButton.Add_Click({
    try {
        Upsert-ScheduleFromForm
    }
    catch {
        Show-AppError "Could not save the schedule." $_
    }
})
$inputPanel.Controls.Add($saveButton)

$deleteButton = New-Object System.Windows.Forms.Button
$deleteButton.Text = "Delete"
$deleteButton.Location = New-Object System.Drawing.Point(136, 86)
$deleteButton.Width = 92
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
$inputPanel.Controls.Add($deleteButton)

$noteLabel = New-Object System.Windows.Forms.Label
$noteLabel.Text = "The key is sent to whichever app is active when the schedule fires."
$noteLabel.Location = New-Object System.Drawing.Point(332, 91)
$noteLabel.AutoSize = $true
$inputPanel.Controls.Add($noteLabel)

$scheduleGrid = New-Object System.Windows.Forms.DataGridView
$scheduleGrid.Dock = "Fill"
$scheduleGrid.AllowUserToAddRows = $false
$scheduleGrid.AllowUserToDeleteRows = $false
$scheduleGrid.ReadOnly = $true
$scheduleGrid.SelectionMode = "FullRowSelect"
$scheduleGrid.MultiSelect = $false
$scheduleGrid.AutoSizeColumnsMode = "Fill"
$scheduleGrid.RowHeadersVisible = $false
$scheduleGrid.Columns.Add("KeyName", "Key") | Out-Null
$scheduleGrid.Columns.Add("Repeat", "Repeat") | Out-Null
$scheduleGrid.Columns.Add("NextRunAt", "Next run") | Out-Null
$scheduleGrid.Columns.Add("Status", "Status") | Out-Null
$scheduleGrid.Add_SelectionChanged({
    if ($scheduleGrid.Focused -and $scheduleGrid.SelectedRows.Count -gt 0) {
        Set-FormFromSchedule (Get-SelectedSchedule)
    }
})

$queuePanel = New-Object System.Windows.Forms.GroupBox
$queuePanel.Text = "Queue"
$queuePanel.Dock = "Fill"
$queuePanel.Controls.Add($scheduleGrid)
$mainLayout.Controls.Add($queuePanel, 0, 1)

$logGrid = New-Object System.Windows.Forms.DataGridView
$logGrid.Dock = "Fill"
$logGrid.AllowUserToAddRows = $false
$logGrid.AllowUserToDeleteRows = $false
$logGrid.ReadOnly = $true
$logGrid.SelectionMode = "FullRowSelect"
$logGrid.MultiSelect = $false
$logGrid.AutoSizeColumnsMode = "Fill"
$logGrid.RowHeadersVisible = $false
$logGrid.Columns.Add("Time", "Time") | Out-Null
$logGrid.Columns.Add("KeyName", "Key") | Out-Null
$logGrid.Columns.Add("Status", "Status") | Out-Null
$logGrid.Columns.Add("Details", "Details") | Out-Null

$logPanel = New-Object System.Windows.Forms.GroupBox
$logPanel.Text = "Log"
$logPanel.Dock = "Fill"
$logPanel.Controls.Add($logGrid)
$mainLayout.Controls.Add($logPanel, 0, 2)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Dock = "Fill"
$statusLabel.TextAlign = "MiddleLeft"
$statusLabel.Text = "Ready. Keep this app running while schedules are active."
$mainLayout.Controls.Add($statusLabel, 0, 3)

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
