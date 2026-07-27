# Windows 11 禁用更新

一键禁用/恢复 Windows 11/10 自动更新的 PowerShell 脚本。

## 用法

以管理员身份运行 PowerShell：

```powershell
# 禁用更新
.\disable-windows-update.ps1

# 恢复更新
.\restore-windows-update.ps1

# 仅关闭开机守护
.\disable-windows-update.ps1 -DisableGuard

# 仅开启开机守护
.\disable-windows-update.ps1 -EnableGuard
```

禁用脚本第 6 步会询问是否开启开机守护：

- **Y** → 开机 30 秒后自动检查，若微软恢复了更新服务则重新禁用
- **其他键** → 仅本次禁用，重启后可能被微软恢复

查看守护日志：

```powershell
Get-Content "C:\ProgramData\ScriptBackup\WaaSMedicBackup\guard.log"
```

## 做了什么

| 步骤 | 操作 |
|------|------|
| 1 | 禁用 wuauserv、UsoSvc、sedsvc 服务 |
| 2 | 配置注册表策略 NoAutoUpdate=1、DisableWindowsUpdateAccess=1 |
| 3 | 禁用 WindowsUpdate、UpdateOrchestrator、WaaSMedic 任务计划 |
| 4 | 禁用自动驱动更新 |
| 5 | 禁用 WaaSMedic 策略 AllowWaaSMedic=0 |
| 6 | 开机守护（可选）：巡检服务状态 + NoAutoUpdate + AllowWaaSMedic |

WaaSMedicSvc 受 `LaunchProtected=2` 保护，SCM 在开机时缓存此值，运行期间 `Set-Service` 无法修改启动类型。脚本通过 ACL 临时提权直接修改注册表 `Start` 值绕过 SCM，重启后生效。同时清零 FailureActions 防止崩溃自重启。

ACL 安全机制：修改前将原始 ACL 备份为 SDDL 文件；恢复时 3 次重试，若仍失败则从备份文件兜底恢复；restore 不会覆盖 disable 留下的备份，确保原始 ACL 可跨会话恢复。若所有恢复方式均失败，写入告警标记文件，下次运行脚本时自动检测并提示。

任务计划恢复：从备份 XML 重新注册时保留原始 Triggers，确保任务按原计划触发。

## 备份位置

`C:\ProgramData\ScriptBackup\WaaSMedicBackup\`

- `WaaSMedicSvc_FailureActions.bin` — 原始 FailureActions
- `WaaSMedicSvc_ACL.xml` — WaaSMedicSvc 注册表项 ACL (SDDL 格式)

- `tasks\*.xml` — 任务计划 XML 备份
- `disable-windows-update.ps1` — 守护模式脚本副本
- `guard.enabled` — 守护标记
- `guard.log` — 守护日志

## 告警文件

若 ACL 恢复失败，脚本在 `C:\ProgramData\ScriptBackup\` 下写入 `WaaSMedic_ACL_ALERT` 标记文件（位于备份目录外，不会被清理删除）。下次运行 disable 或 restore 脚本时自动检测：对比当前 ACL 与备份 SDDL，若仍异常则红色警告，若已修复则静默删除标记。

## ⚠️ 警告

禁用更新会导致安全漏洞无法修补，请确保你有其他安全措施。

## 要求

- Windows 11 / 10
- PowerShell 5.1+
- 管理员权限

## License

CC BY-NC 4.0
