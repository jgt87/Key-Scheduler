# Key Scheduler

A small Windows desktop utility for scheduling a keystroke to be sent to the app that is active when the schedule fires.

![Key Scheduler screenshot](docs/screenshot.png)

## Designs

The app ships in two visual styles. They are functionally identical &mdash; only the look differs, so pick whichever you prefer.

| Design | Source | Executable | Look |
| --- | --- | --- | --- |
| **Fluent** | `KeyScheduler.ps1` | `dist\KeySchedulerFluent.exe` | Windows 11 [Fluent Design](https://learn.microsoft.com/windows/apps/design/guidelines-overview): system accent color, automatic light/dark theme (including the title bar), Segoe UI type ramp, and rounded cards. |
| **Classic** | `KeyScheduler.Classic.ps1` | `dist\KeyScheduler.exe` | The original Windows Forms look with grouped panels. |

## Run

Portable executable:

```text
dist\KeySchedulerFluent.exe   # Fluent design
dist\KeyScheduler.exe         # Classic design
```

From PowerShell:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\KeyScheduler.ps1           # Fluent design
powershell.exe -ExecutionPolicy Bypass -File .\KeyScheduler.Classic.ps1   # Classic design
```

The app must remain running while schedules are active. Both designs read and write the same schedule and history files, so you can switch between them freely.

## Build The Executables

Each launcher embeds a script under the fixed resource name `KeyScheduler.ps1` and runs it with Windows PowerShell. The design is chosen by which source file you map to that resource name.

```powershell
# Fluent design -> dist\KeySchedulerFluent.exe
C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /nologo /target:winexe /out:.\dist\KeySchedulerFluent.exe /resource:.\KeyScheduler.ps1,KeyScheduler.ps1 .\KeySchedulerLauncher.cs

# Classic design -> dist\KeyScheduler.exe
C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /nologo /target:winexe /out:.\dist\KeyScheduler.exe /resource:.\KeyScheduler.Classic.ps1,KeyScheduler.ps1 .\KeySchedulerLauncher.cs
```

## Features

- Schedule a one-time, daily, or weekly keystroke.
- Send common keys such as Enter, Escape, Tab, Space, arrow keys, F1-F12, and simple Ctrl combinations.
- View pending schedules and recent run results.
- Edit, disable, or delete schedules.
- Persist schedules locally across restarts.

## Behavior

The keystroke is sent to whichever application has focus at the scheduled time. Version 1 does not target background windows or remember which app was active when the schedule was created.

If a schedule is more than 60 seconds late, it is marked as missed instead of firing late.

## Data Location

Schedules and recent run history are stored under:

```text
%LOCALAPPDATA%\KeyScheduler
```
