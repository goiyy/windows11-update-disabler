# Windows 11 Update Disabler

One-click PowerShell scripts to disable/restore Windows 11/10 automatic updates.

## Usage

Run PowerShell as Administrator:

```powershell
# Disable updates
.\disable-windows-update.ps1

# Restore updates
.\restore-windows-update.ps1
```

## What It Does

| Step | Action |
|------|--------|
| 1 | Disable wuauserv, UsoSvc, sedsvc services + force-disable WaaSMedicSvc |
| 2 | Set registry policies NoAutoUpdate=1, DisableWindowsUpdateAccess=1 |
| 3 | Disable WindowsUpdate, UpdateOrchestrator, WaaSMedic scheduled tasks |
| 4 | Disable automatic driver updates + WaaSMedic policy AllowWaaSMedic=0 |
| 5 | Rename WaaSMedicSvc.dll, wuaueng.dll (root fix for self-repair) |

WaaSMedicSvc is protected by `LaunchProtected=2` — SCM caches this value at boot, so `Set-Service` cannot change its startup type at runtime. The script works around this by temporarily elevating ACL to write the registry `Start` value directly, which takes effect after reboot. FailureActions is also cleared to prevent crash-triggered restarts.

**DLL Renaming (root fix)**: Even with all the above measures, WaaSMedicSvc may still restore update services through the system's self-repair mechanism. The script renames `WaaSMedicSvc.dll` and `wuaueng.dll` to `.bak`, so the system cannot find the DLL and the service cannot start, blocking self-repair at the root. The restore script renames `.bak` files back to their original names.

**ACL safety**: Original ACL is backed up as an SDDL file before modification. On restore, up to 3 retries are attempted; if all fail, the backup file is used as fallback. The restore script never overwrites the disable script's backup, ensuring the original ACL survives across sessions.

**Task restoration**: When re-registering tasks from backup XML, original Triggers are preserved so tasks fire on their original schedules.

## Backup Location

`C:\ProgramData\ScriptBackup\WaaSMedicBackup\`

- `WaaSMedicSvc_FailureActions.bin` — original FailureActions
- `WaaSMedicSvc_ACL.xml` — WaaSMedicSvc registry key ACL (SDDL format)
- `tasks\*.xml` — scheduled task XML backups

DLL backups are located in `C:\Windows\System32\`:
- `WaaSMedicSvc.dll.bak` — renamed WaaSMedicSvc DLL
- `wuaueng.dll.bak` — renamed wuaueng DLL

## ⚠️ Warning

Disabling updates leaves security vulnerabilities unpatched. Ensure you have alternative security measures in place.

## Requirements

- Windows 11 / 10
- PowerShell 5.1+
- Administrator privileges

## License

CC BY-NC 4.0