# Windows 11 Update Disabler

One-click PowerShell scripts to disable/restore Windows 11/10 automatic updates.

## Usage

Run PowerShell as Administrator:

```powershell
# Disable updates
.\disable-windows-update.ps1

# Restore updates
.\restore-windows-update.ps1

# Disable boot guard only
.\disable-windows-update.ps1 -DisableGuard

# Enable boot guard only
.\disable-windows-update.ps1 -EnableGuard
```

Step 6 of the disable script asks whether to enable boot guard:

- **Y** → Auto-check 30s after each boot; re-disable if services were restored by Microsoft
- **Any other key** → Disable only for this session; Microsoft may restore services after reboot

View guard log:

```powershell
Get-Content "C:\ProgramData\ScriptBackup\WaaSMedicBackup\guard.log"
```

## What It Does

| Step | Action |
|------|--------|
| 1 | Disable wuauserv, UsoSvc, sedsvc services |
| 2 | Set registry policies NoAutoUpdate=1, DisableWindowsUpdateAccess=1 |
| 3 | Disable WindowsUpdate, UpdateOrchestrator, WaaSMedic scheduled tasks |
| 4 | Disable automatic driver updates |
| 5 | Set WaaSMedic policy AllowWaaSMedic=0 |
| 6 | Boot guard (optional): patrol service status + NoAutoUpdate + AllowWaaSMedic |

WaaSMedicSvc is protected by `LaunchProtected=2` — SCM caches this value at boot, so `Set-Service` cannot change its startup type at runtime. The script works around this by temporarily elevating ACL to write the registry `Start` value directly, which takes effect after reboot. FailureActions is also cleared to prevent crash-triggered restarts.

**ACL safety**: Original ACL is backed up as an SDDL file before modification. On restore, up to 3 retries are attempted; if all fail, the backup file is used as fallback. The restore script never overwrites the disable script's backup, ensuring the original ACL survives across sessions. If all restore methods fail, an alert marker file is written for detection on next run.

**Task restoration**: When re-registering tasks from backup XML, original Triggers are preserved so tasks fire on their original schedules.

## Backup Location

`C:\ProgramData\ScriptBackup\WaaSMedicBackup\`

- `WaaSMedicSvc_FailureActions.bin` — original FailureActions
- `WaaSMedicSvc_ACL.xml` — WaaSMedicSvc registry key ACL (SDDL format)
- `tasks\*.xml` — scheduled task XML backups
- `disable-windows-update.ps1` — guard mode script copy
- `guard.enabled` — guard marker
- `guard.log` — guard log

## Alert File

If ACL restore fails, an alert marker file `WaaSMedic_ACL_ALERT` is written to `C:\ProgramData\ScriptBackup\` (outside the backup directory, so it won't be deleted by backup cleanup). On the next run of either script, the current ACL is compared against the backed-up SDDL: if still incorrect, a red warning is shown; if already fixed, the marker is silently removed.

## ⚠️ Warning

Disabling updates leaves security vulnerabilities unpatched. Ensure you have alternative security measures in place.

## Requirements

- Windows 11 / 10
- PowerShell 5.1+
- Administrator privileges

## License

CC BY-NC 4.0