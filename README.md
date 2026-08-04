# Windows 11 禁用更新

一键禁用/恢复 Windows 11/10 自动更新的 PowerShell 脚本。

## 用法

以管理员身份运行 PowerShell：

```powershell
# 禁用更新
.\disable-windows-update.ps1

# 恢复更新
.\restore-windows-update.ps1
```

## 做了什么

| 步骤 | 操作 |
|------|------|
| 1 | 禁用 wuauserv、UsoSvc、sedsvc 服务 + 强制禁用 WaaSMedicSvc |
| 2 | 配置注册表策略 NoAutoUpdate=1、DisableWindowsUpdateAccess=1 |
| 3 | 禁用 WindowsUpdate、UpdateOrchestrator、WaaSMedic 任务计划 |
| 4 | 禁用自动驱动更新 + WaaSMedic 策略 AllowWaaSMedic=0 |
| 5 | 重命名 WaaSMedicSvc.dll、wuaueng.dll（根治自修复） |

WaaSMedicSvc 受 `LaunchProtected=2` 保护，SCM 在开机时缓存此值，运行期间 `Set-Service` 无法修改启动类型。脚本通过 ACL 临时提权直接修改注册表 `Start` 值绕过 SCM，重启后生效。同时清零 FailureActions 防止崩溃自重启。

**DLL 重命名（根治方案）**：即使以上措施全部生效，WaaSMedicSvc 仍可能通过系统自修复机制恢复更新服务。脚本将 `WaaSMedicSvc.dll` 和 `wuaueng.dll` 重命名为 `.bak`，系统找不到 DLL 则服务无法启动，从根本上阻止自修复。恢复脚本会将 `.bak` 文件重命名回原文件名。

ACL 安全机制：修改前将原始 ACL 备份为 SDDL 文件；恢复时 3 次重试，若仍失败则从备份文件兜底恢复；restore 不会覆盖 disable 留下的备份，确保原始 ACL 可跨会话恢复。

任务计划恢复：从备份 XML 重新注册时保留原始 Triggers，确保任务按原计划触发。

## 备份位置

`C:\ProgramData\ScriptBackup\WaaSMedicBackup\`

- `WaaSMedicSvc_FailureActions.bin` — 原始 FailureActions
- `WaaSMedicSvc_ACL.xml` — WaaSMedicSvc 注册表项 ACL (SDDL 格式)
- `tasks\*.xml` — 任务计划 XML 备份

DLL 备份位于 `C:\Windows\System32\`：
- `WaaSMedicSvc.dll.bak` — 重命名后的 WaaSMedicSvc DLL
- `wuaueng.dll.bak` — 重命名后的 wuaueng DLL

## ⚠️ 警告

禁用更新会导致安全漏洞无法修补，请确保你有其他安全措施。

## 要求

- Windows 11 / 10
- PowerShell 5.1+
- 管理员权限

## License

CC BY-NC 4.0