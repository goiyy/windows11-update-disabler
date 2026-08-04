#Requires -RunAsAdministrator

$backupDir = "$env:ProgramData\ScriptBackup\WaaSMedicBackup"

$isZh = (Get-Culture).TwoLetterISOLanguageName -eq "zh"
function T($zh, $en) { if ($isZh) { $zh } else { $en } }

$host.UI.RawUI.WindowTitle = (T "Windows Update 禁用工具" "Windows Update Disabler")

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "     $(T "Windows 永久禁用更新 - 一键脚本" "Windows Update Permanent Disable - One-Click Script")" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host (T "[警告] 此操作将永久禁用 Windows 更新!" "[WARNING] This will permanently disable Windows Update!") -ForegroundColor Yellow
Write-Host (T "[警告] 禁用更新可能导致安全漏洞无法修补!" "[WARNING] Disabling updates may leave security vulnerabilities unpatched!") -ForegroundColor Yellow
Write-Host ""

$confirm = Read-Host (T "确认要继续吗? (输入 Y 继续, 其他键退出)" "Continue? (Y to proceed, any other key to cancel)")
if ($confirm -ne 'Y' -and $confirm -ne 'y') {
    Write-Host (T "已取消操作。" "Operation cancelled.") -ForegroundColor Gray
    exit
}

Write-Host ""
Write-Host "===== [1/5] $(T "禁用 Windows Update 服务" "Disable Windows Update Services") =====" -ForegroundColor Green

$serviceName = "wuauserv"
try {
    Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
    Set-Service -Name $serviceName -StartupType Disabled -ErrorAction Stop
    Write-Host "  [OK] $serviceName $(T "服务已禁用" "service disabled")" -ForegroundColor Green
} catch {
    Write-Host "  [FAIL] $serviceName $(T "禁用失败" "disable failed"): $_" -ForegroundColor Red
}

$relatedServices = @("UsoSvc")
foreach ($svc in $relatedServices) {
    try {
        Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
        Set-Service -Name $svc -StartupType Disabled -ErrorAction Stop
        Write-Host "  [OK] $svc $(T "服务已禁用" "service disabled")" -ForegroundColor Green
    } catch {
        Write-Host "  [FAIL] $svc $(T "禁用失败" "disable failed"): $_" -ForegroundColor Red
    }
}

$svc = "sedsvc"
if (Get-Service -Name $svc -ErrorAction SilentlyContinue) {
    try {
        Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
        Set-Service -Name $svc -StartupType Disabled -ErrorAction Stop
        Write-Host "  [OK] $svc $(T "服务已禁用" "service disabled")" -ForegroundColor Green
    } catch {
        Write-Host "  [FAIL] $svc $(T "禁用失败" "disable failed"): $_" -ForegroundColor Red
    }
} else {
    Write-Host "  [SKIP] $svc $(T "服务不存在" "service not found")" -ForegroundColor DarkGray
}
Write-Host "  [INFO] $(T "正在强制禁用 WaaSMedicSvc (受保护服务)..." "Force-disabling WaaSMedicSvc (protected service)...")" -ForegroundColor DarkCyan
try {
    $waasSvcKey = "HKLM:\SYSTEM\CurrentControlSet\Services\WaaSMedicSvc"
    if (Test-Path $waasSvcKey) {
        try {
            Stop-Service -Name "WaaSMedicSvc" -Force -ErrorAction Stop
            Write-Host "  [OK] WaaSMedicSvc $(T "服务已停止" "service stopped")" -ForegroundColor Green
        } catch {
            Write-Host "  [WARN] SCM $(T "停止失败" "stop failed"): $_ ($(T "将继续通过注册表禁用" "will continue via registry"))" -ForegroundColor DarkYellow
        }

        $originalAcl = Get-Acl $waasSvcKey
        $admin = New-Object System.Security.Principal.NTAccount("BUILTIN\Administrators")
        $regRights = [System.Security.AccessControl.RegistryRights]::FullControl
        $inheritance = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
        $propagation = [System.Security.AccessControl.PropagationFlags]::None
        $accessRule = New-Object System.Security.AccessControl.RegistryAccessRule($admin, $regRights, $inheritance, $propagation, "Allow")

        if (-not (Test-Path $backupDir)) { New-Item -Path $backupDir -ItemType Directory -Force | Out-Null }
        $aclBackupPath = "$backupDir\WaaSMedicSvc_ACL.xml"
        try {
            [System.IO.File]::WriteAllText($aclBackupPath, $originalAcl.GetSecurityDescriptorSddlForm(), [System.Text.UTF8Encoding]::new($false))
        } catch {}

        $tempAcl = Get-Acl $waasSvcKey
        $tempAcl.SetAccessRule($accessRule)
        Set-Acl -Path $waasSvcKey -AclObject $tempAcl -ErrorAction Stop

        try {
            $failureActionsPath = "$backupDir\WaaSMedicSvc_FailureActions.bin"
            try {
                $failureActions = (Get-ItemProperty -Path $waasSvcKey -Name "FailureActions" -ErrorAction SilentlyContinue).FailureActions
                if ($failureActions) {
                    [System.IO.File]::WriteAllBytes($failureActionsPath, $failureActions)
                    Write-Host "  [OK] FailureActions $(T "已备份到" "backed up to") $backupDir\WaaSMedicSvc_FailureActions.bin" -ForegroundColor Green
                    Set-ItemProperty -Path $waasSvcKey -Name "FailureActions" -Value ([byte[]]@()) -Type Binary -Force -ErrorAction SilentlyContinue
                    Write-Host "  [OK] FailureActions $(T "已清零 (防止服务自重启)" "cleared (prevent auto-restart on crash)")" -ForegroundColor Green
                } else {
                    Write-Host "  [SKIP] FailureActions $(T "不存在，无需清零" "not found, skip clearing")" -ForegroundColor DarkGray
                }
            } catch {
                Write-Host "  [WARN] $(T "处理 FailureActions 失败" "FailureActions handling failed"): $_" -ForegroundColor DarkYellow
            }

            Set-ItemProperty -Path $waasSvcKey -Name "Start" -Value 4 -Type DWord -Force
            Write-Host "  [OK] WaaSMedicSvc $(T "已通过注册表强制禁用 (Start=4)" "force-disabled via registry (Start=4)")" -ForegroundColor Green
        } finally {
            $aclRestored = $false
            for ($retry = 1; $retry -le 3; $retry++) {
                try {
                    Set-Acl -Path $waasSvcKey -AclObject $originalAcl -ErrorAction Stop
                    Write-Host "  [OK] WaaSMedicSvc $(T "注册表 ACL 已恢复" "registry ACL restored")" -ForegroundColor Green
                    $aclRestored = $true
                    break
                } catch {
                    if ($retry -lt 3) { Start-Sleep -Milliseconds 500 }
                }
            }
            if (-not $aclRestored) {
                if (Test-Path $aclBackupPath) {
                    try {
                        $sddl = [System.IO.File]::ReadAllText($aclBackupPath)
                        $backupAcl = New-Object System.Security.AccessControl.RegistrySecurity
                        $backupAcl.SetSecurityDescriptorSddlForm($sddl)
                        Set-Acl -Path $waasSvcKey -AclObject $backupAcl -ErrorAction Stop
                        Write-Host "  [OK] WaaSMedicSvc $(T "ACL 已从备份文件恢复" "ACL restored from backup file")" -ForegroundColor Green
                        $aclRestored = $true
                    } catch {
                        Write-Host "  [WARN] $(T "从备份恢复 ACL 也失败" "ACL restore from backup also failed"): $_" -ForegroundColor DarkYellow
                    }
                }
                if (-not $aclRestored) {
                    Write-Host "  [WARN] $(T "恢复 ACL 失败，请手动检查注册表权限" "ACL restore failed, check registry permissions manually"): $waasSvcKey" -ForegroundColor DarkYellow
                }
            }
        }

        Write-Host "  [INFO] WaaSMedicSvc $(T "受 LaunchProtected=2 保护，SCM 缓存启动时值，Set-Service 无法修改" "protected by LaunchProtected=2, SCM caches at boot, Set-Service cannot modify")" -ForegroundColor DarkCyan
        Write-Host "  [INFO] $(T "注册表已设 Start=4，重启后 SCM 重读注册表生效" "Registry set Start=4, takes effect after reboot when SCM re-reads registry")" -ForegroundColor DarkCyan
    } else {
        Write-Host "  [SKIP] WaaSMedicSvc $(T "注册表项不存在" "registry key not found")" -ForegroundColor DarkGray
    }
} catch {
    Write-Host "  [FAIL] WaaSMedicSvc $(T "强制禁用失败" "force-disable failed"): $_" -ForegroundColor Red
    Write-Host "  [HINT] $(T "可尝试" "Try"): sc.exe config WaaSMedicSvc start=disabled" -ForegroundColor DarkYellow
}
Write-Host ""
Write-Host "===== [2/5] $(T "配置注册表禁用自动更新" "Configure Registry to Disable Auto Update") =====" -ForegroundColor Green

$wuKeyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
$auKeyPath = "$wuKeyPath\AU"

try {
    if (-not (Test-Path $wuKeyPath)) {
        New-Item -Path $wuKeyPath -Force | Out-Null
    }
    if (-not (Test-Path $auKeyPath)) {
        New-Item -Path $auKeyPath -Force | Out-Null
    }

    Set-ItemProperty -Path $auKeyPath -Name "NoAutoUpdate" -Value 1 -Type DWord -Force
    Write-Host "  [OK] NoAutoUpdate = 1 ($(T "禁用自动更新" "disable auto update"))" -ForegroundColor Green

    Set-ItemProperty -Path $wuKeyPath -Name "DisableWindowsUpdateAccess" -Value 1 -Type DWord -Force
    Write-Host "  [OK] DisableWindowsUpdateAccess = 1 ($(T "禁用更新访问" "disable update access"))" -ForegroundColor Green

    Set-ItemProperty -Path $wuKeyPath -Name "SetUpdateServiceDisabled" -Value 1 -Type DWord -Force
    Write-Host "  [OK] SetUpdateServiceDisabled = 1" -ForegroundColor Green
} catch {
    Write-Host "  [FAIL] $(T "注册表配置失败" "Registry configuration failed"): $_" -ForegroundColor Red
}

Write-Host ""
Write-Host "===== [3/5] $(T "禁用 Windows Update 相关任务计划" "Disable Windows Update Scheduled Tasks") =====" -ForegroundColor Green

$taskFolders = @(
    "$env:SystemRoot\System32\Tasks\Microsoft\Windows\WindowsUpdate",
    "$env:SystemRoot\System32\Tasks\Microsoft\Windows\UpdateOrchestrator",
    "$env:SystemRoot\System32\Tasks\Microsoft\Windows\WaaSMedic"
)

foreach ($folder in $taskFolders) {
    if (-not (Test-Path $folder)) {
        Write-Host "  [SKIP] $(T "目录不存在" "Directory not found"): $folder" -ForegroundColor DarkGray
        continue
    }

    $folderName = Split-Path $folder -Leaf
    Write-Host "  [INFO] $(T "处理目录" "Processing directory"): $folderName" -ForegroundColor DarkCyan

    takeown.exe /f $folder /a > $null 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Host "  [WARN] takeown $(T "失败" "failed") ($LASTEXITCODE): $folderName" -ForegroundColor DarkYellow }
    icacls.exe $folder /grant "Administrators:F" /t > $null 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Host "  [WARN] icacls $(T "失败" "failed") ($LASTEXITCODE): $folderName" -ForegroundColor DarkYellow }

    $taskFiles = Get-ChildItem -Path $folder -File -ErrorAction SilentlyContinue
    foreach ($file in $taskFiles) {
        takeown.exe /f $file.FullName /a > $null 2>&1
        if ($LASTEXITCODE -ne 0) { Write-Host "  [WARN] takeown $(T "失败" "failed") ($LASTEXITCODE): $($file.Name)" -ForegroundColor DarkYellow }
        icacls.exe $file.FullName /grant "Administrators:F" > $null 2>&1
        if ($LASTEXITCODE -ne 0) { Write-Host "  [WARN] icacls $(T "失败" "failed") ($LASTEXITCODE): $($file.Name)" -ForegroundColor DarkYellow }
    }

    $taskPathMapped = switch ($folderName) {
        "WindowsUpdate" { "\Microsoft\Windows\WindowsUpdate\" }
        "UpdateOrchestrator" { "\Microsoft\Windows\UpdateOrchestrator\" }
        "WaaSMedic" { "\Microsoft\Windows\WaaSMedic\" }
    }

    $tasks = Get-ScheduledTask -TaskPath $taskPathMapped -ErrorAction SilentlyContinue
    foreach ($t in $tasks) {
        try {
            if ($t.State -ne 'Disabled') {
                $taskBackupDir = "$backupDir\tasks"
                if (-not (Test-Path $taskBackupDir)) { New-Item -Path $taskBackupDir -ItemType Directory -Force | Out-Null }
                $taskFolderName = ($t.TaskPath.Trim('\') -replace '\\', '_')
                $safeTaskName = $t.TaskName -replace '[^\w\-]', '_'
                $backupFile = "$taskBackupDir\${taskFolderName}_${safeTaskName}.xml"
                try {
                    $taskXml = Export-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction Stop
                    [System.IO.File]::WriteAllText($backupFile, $taskXml, [System.Text.UTF8Encoding]::new($true))
                } catch {
                    Write-Host "  [WARN] $(T "备份失败" "Backup failed"): $($t.TaskName) - $_" -ForegroundColor DarkYellow
                }
                Disable-ScheduledTask -TaskPath $t.TaskPath -TaskName $t.TaskName -ErrorAction Stop | Out-Null
                Write-Host "  [OK] $(T "已禁用" "Disabled"): $($t.TaskName)" -ForegroundColor Green
            } else {
                Write-Host "  [SKIP] $(T "已禁用" "Already disabled"): $($t.TaskName)" -ForegroundColor DarkGray
            }
        } catch {
            try {
                $taskFile = Join-Path $folder "$($t.TaskName)"
                if (Test-Path $taskFile) {
                    Rename-Item -Path $taskFile -NewName "$($t.TaskName).bak" -Force -ErrorAction Stop
                    Write-Host "  [OK] $(T "已重命名任务文件" "Renamed task file"): $($t.TaskName) -> $($t.TaskName).bak" -ForegroundColor Green
                }
            } catch {
                Write-Host "  [FAIL] $($t.TaskName): $(T "无法禁用也无法重命名" "cannot disable or rename")" -ForegroundColor Red
            }
        }
    }
}
Write-Host ""
Write-Host "===== [4/5] $(T "禁用自动驱动更新 + WaaSMedic 策略" "Disable Auto Driver Update + WaaSMedic Policy") =====" -ForegroundColor Green

$driverKeyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching"
try {
    if (-not (Test-Path $driverKeyPath)) {
        New-Item -Path $driverKeyPath -Force | Out-Null
    }
    Set-ItemProperty -Path $driverKeyPath -Name "SearchOrderConfig" -Value 0 -Type DWord -Force
    Write-Host "  [OK] SearchOrderConfig = 0 ($(T "禁用自动驱动更新" "disable auto driver update"))" -ForegroundColor Green
} catch {
    Write-Host "  [FAIL] $(T "驱动更新注册表配置失败" "Driver update registry configuration failed"): $_" -ForegroundColor Red
}

$waasKeyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WaaSMedic"
try {
    if (-not (Test-Path $waasKeyPath)) {
        New-Item -Path $waasKeyPath -Force | Out-Null
    }
    Set-ItemProperty -Path $waasKeyPath -Name "AllowWaaSMedic" -Value 0 -Type DWord -Force
    Write-Host "  [OK] AllowWaaSMedic = 0 ($(T "防止系统自动修复更新服务" "prevent system from auto-repairing update service"))" -ForegroundColor Green
} catch {
    Write-Host "  [FAIL] WaaSMedic $(T "注册表配置失败" "registry configuration failed"): $_" -ForegroundColor Red
}

Write-Host ""
Write-Host "===== [5/5] $(T "重命名 WaaSMedicSvc DLL (根治自修复)" "Rename WaaSMedicSvc DLL (root fix for self-repair)") =====" -ForegroundColor Green

Write-Host "  [INFO] $(T "WaaSMedicSvc 即使被禁用，仍可能被系统自修复恢复。重命名其 DLL 可从根本上阻止服务启动。" "Even if disabled, WaaSMedicSvc may be self-repaired by the system. Renaming its DLL prevents the service from starting at the root.")" -ForegroundColor DarkCyan

$waasDllPath = "$env:SystemRoot\System32\WaaSMedicSvc.dll"
$waasDllBak = "$env:SystemRoot\System32\WaaSMedicSvc.dll.bak"

if (Test-Path $waasDllBak) {
    Write-Host "  [SKIP] $(T "DLL 备份已存在，无需重复操作" "DLL backup already exists, skip")" -ForegroundColor DarkGray
} elseif (-not (Test-Path $waasDllPath)) {
    Write-Host "  [SKIP] $(T "WaaSMedicSvc.dll 不存在" "WaaSMedicSvc.dll not found")" -ForegroundColor DarkGray
} else {
    try {
        takeown.exe /f $waasDllPath /a > $null 2>&1
        if ($LASTEXITCODE -ne 0) { Write-Host "  [WARN] takeown $(T "失败" "failed") ($LASTEXITCODE)" -ForegroundColor DarkYellow }
        icacls.exe $waasDllPath /grant "Administrators:F" > $null 2>&1
        if ($LASTEXITCODE -ne 0) { Write-Host "  [WARN] icacls $(T "失败" "failed") ($LASTEXITCODE)" -ForegroundColor DarkYellow }

        Rename-Item -Path $waasDllPath -NewName "WaaSMedicSvc.dll.bak" -Force -ErrorAction Stop
        Write-Host "  [OK] WaaSMedicSvc.dll $(T "已重命名为" "renamed to") WaaSMedicSvc.dll.bak" -ForegroundColor Green
    } catch {
        Write-Host "  [FAIL] $(T "重命名 WaaSMedicSvc.dll 失败" "Failed to rename WaaSMedicSvc.dll"): $_" -ForegroundColor Red
        Write-Host "  [HINT] $(T "可能需要使用 PsExec -s 以 SYSTEM 权限运行此脚本" "May need to run this script with SYSTEM privileges via PsExec -s")" -ForegroundColor DarkYellow
    }
}

$wuauDllPath = "$env:SystemRoot\System32\wuaueng.dll"
$wuauDllBak = "$env:SystemRoot\System32\wuaueng.dll.bak"

if (Test-Path $wuauDllBak) {
    Write-Host "  [SKIP] $(T "wuaueng.dll 备份已存在，无需重复操作" "wuaueng.dll backup already exists, skip")" -ForegroundColor DarkGray
} elseif (-not (Test-Path $wuauDllPath)) {
    Write-Host "  [SKIP] $(T "wuaueng.dll 不存在" "wuaueng.dll not found")" -ForegroundColor DarkGray
} else {
    try {
        takeown.exe /f $wuauDllPath /a > $null 2>&1
        if ($LASTEXITCODE -ne 0) { Write-Host "  [WARN] takeown $(T "失败" "failed") ($LASTEXITCODE)" -ForegroundColor DarkYellow }
        icacls.exe $wuauDllPath /grant "Administrators:F" > $null 2>&1
        if ($LASTEXITCODE -ne 0) { Write-Host "  [WARN] icacls $(T "失败" "failed") ($LASTEXITCODE)" -ForegroundColor DarkYellow }

        Rename-Item -Path $wuauDllPath -NewName "wuaueng.dll.bak" -Force -ErrorAction Stop
        Write-Host "  [OK] wuaueng.dll $(T "已重命名为" "renamed to") wuaueng.dll.bak" -ForegroundColor Green
    } catch {
        Write-Host "  [FAIL] $(T "重命名 wuaueng.dll 失败" "Failed to rename wuaueng.dll"): $_" -ForegroundColor Red
        Write-Host "  [HINT] $(T "可能需要使用 PsExec -s 以 SYSTEM 权限运行此脚本" "May need to run this script with SYSTEM privileges via PsExec -s")" -ForegroundColor DarkYellow
    }
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  $(T "操作完成! 以下是当前状态:" "Done! Current status:")" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

$svc = Get-Service -Name "wuauserv" -ErrorAction SilentlyContinue
if ($svc) {
    Write-Host "  Windows Update $(T "服务状态" "service status"): $($svc.Status)" -ForegroundColor $(if ($svc.Status -eq 'Stopped') {'Green'} else {'Yellow'})
    Write-Host "  Windows Update $(T "启动类型" "start type"): $($svc.StartType)" -ForegroundColor $(if ($svc.StartType -eq 'Disabled') {'Green'} else {'Yellow'})
}

$waasDllStatus = if (Test-Path "$env:SystemRoot\System32\WaaSMedicSvc.dll.bak") { "WaaSMedicSvc.dll $(T "已重命名" "renamed")" } elseif (Test-Path "$env:SystemRoot\System32\WaaSMedicSvc.dll") { "WaaSMedicSvc.dll $(T "未重命名" "not renamed")" } else { "WaaSMedicSvc.dll $(T "不存在" "not found")" }
Write-Host "  DLL: $waasDllStatus" -ForegroundColor $(if (Test-Path "$env:SystemRoot\System32\WaaSMedicSvc.dll.bak") {'Green'} else {'Yellow'})

$wuauDllStatus = if (Test-Path "$env:SystemRoot\System32\wuaueng.dll.bak") { "wuaueng.dll $(T "已重命名" "renamed")" } elseif (Test-Path "$env:SystemRoot\System32\wuaueng.dll") { "wuaueng.dll $(T "未重命名" "not renamed")" } else { "wuaueng.dll $(T "不存在" "not found")" }
Write-Host "  DLL: $wuauDllStatus" -ForegroundColor $(if (Test-Path "$env:SystemRoot\System32\wuaueng.dll.bak") {'Green'} else {'Yellow'})

Write-Host ""
Write-Host (T "[提示] 如需恢复更新，请运行 restore-windows-update.ps1" "[Tip] To restore updates, run restore-windows-update.ps1") -ForegroundColor Yellow
Write-Host ""
Read-Host (T "按回车键退出" "Press Enter to exit")