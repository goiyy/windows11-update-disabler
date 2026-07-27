#Requires -RunAsAdministrator
param([switch]$GuardMode, [switch]$DisableGuard, [switch]$EnableGuard)

$backupDir = "$env:ProgramData\ScriptBackup\WaaSMedicBackup"
$aclAlertFile = "$env:ProgramData\ScriptBackup\WaaSMedic_ACL_ALERT"

if ($DisableGuard) {
    $taskName = "DisableWindowsUpdateGuard"
    $markerFile = "$backupDir\guard.enabled"
    $guardFile = "$backupDir\disable-windows-update.ps1"

    $isZh = (Get-Culture).TwoLetterISOLanguageName -eq "zh"
    function T($zh, $en) { if ($isZh) { $zh } else { $en } }

    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($task) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host "[OK] $(T "守护任务已移除" "Guard task removed")" -ForegroundColor Green
    } else {
        Write-Host "[SKIP] $(T "守护任务不存在" "Guard task not found")" -ForegroundColor DarkGray
    }

    if (Test-Path $markerFile) {
        Remove-Item -Path $markerFile -Force -ErrorAction SilentlyContinue
        Write-Host "[OK] $(T "守护标记已移除" "Guard marker removed")" -ForegroundColor Green
    }

    if (Test-Path $guardFile) {
        Remove-Item -Path $guardFile -Force -ErrorAction SilentlyContinue
        Write-Host "[OK] $(T "守护脚本已删除" "Guard script deleted")" -ForegroundColor Green
    }

    exit
}

if ($EnableGuard) {
    $guardDst = "$backupDir\disable-windows-update.ps1"
    $markerFile = "$backupDir\guard.enabled"
    $taskName = "DisableWindowsUpdateGuard"

    $isZh = (Get-Culture).TwoLetterISOLanguageName -eq "zh"
    function T($zh, $en) { if ($isZh) { $zh } else { $en } }

    try {
        if (-not (Test-Path $backupDir)) { New-Item -Path $backupDir -ItemType Directory -Force | Out-Null }
        Copy-Item -Path $PSCommandPath -Destination $guardDst -Force -ErrorAction Stop
        Write-Host "[OK] $(T "守护脚本已部署" "Guard script deployed")" -ForegroundColor Green
    } catch {
        Write-Host "[FAIL] $(T "复制守护脚本失败" "Guard script copy failed"): $_" -ForegroundColor Red
    }

    try {
        New-Item -Path $markerFile -ItemType File -Force | Out-Null
        Write-Host "[OK] $(T "守护标记已创建" "Guard marker created")" -ForegroundColor Green
    } catch {
        Write-Host "[FAIL] $(T "创建守护标记失败" "Guard marker creation failed"): $_" -ForegroundColor Red
    }

    try {
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $trigger.Delay = "PT30S"
        $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -NoProfile -NonInteractive -WindowStyle Hidden -File `"$guardDst`" -GuardMode"
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
        Register-ScheduledTask -TaskName $taskName -Trigger $trigger -Action $action -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
        Write-Host "[OK] $(T "开机守护任务已注册 (开机30秒后自动检查)" "Boot guard task registered (auto-check 30s after boot)")" -ForegroundColor Green
    } catch {
        Write-Host "[FAIL] $(T "注册守护任务失败" "Guard task registration failed"): $_" -ForegroundColor Red
    }

    exit
}

if ($GuardMode) {
    $logFile = "$backupDir\guard.log"
    $markerFile = "$backupDir\guard.enabled"

    if (-not (Test-Path $markerFile)) { exit }

    if (-not (Test-Path $backupDir)) {
        New-Item -Path $backupDir -ItemType Directory -Force | Out-Null
    }

    function Write-GuardLog([string]$Msg) {
        $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        if ((Test-Path $logFile) -and ((Get-Item $logFile).Length -gt 1MB)) {
            $lines = Get-Content $logFile -Tail 500 -Encoding UTF8
            Set-Content -Path $logFile -Value $lines -Encoding UTF8
        }
        "$ts  $Msg" | Out-File -FilePath $logFile -Append -Encoding UTF8
    }

    Write-GuardLog "--- Guard check start ---"

    $services = @("wuauserv", "UsoSvc", "sedsvc")
    foreach ($name in $services) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if (-not $svc) { continue }
        if ($svc.StartType -eq 'Disabled') { continue }
        try {
            Stop-Service -Name $name -Force -ErrorAction SilentlyContinue
            Set-Service -Name $name -StartupType Disabled -ErrorAction Stop
            Write-GuardLog "Re-disabled $name (was $($svc.StartType))"
        } catch {
            Write-GuardLog "FAIL re-disable $name : $_"
        }
    }

    $svc = Get-Service -Name "WaaSMedicSvc" -ErrorAction SilentlyContinue
    if ($svc -and $svc.StartType -ne 'Disabled') {
        $key = "HKLM:\SYSTEM\CurrentControlSet\Services\WaaSMedicSvc"
        if (Test-Path $key) {
            try {
                Stop-Service -Name "WaaSMedicSvc" -Force -ErrorAction SilentlyContinue
                Set-Service -Name "WaaSMedicSvc" -StartupType Disabled -ErrorAction Stop
                Write-GuardLog "Re-disabled WaaSMedicSvc via SCM"
            } catch {
                try {
                    $origAcl = Get-Acl $key
                    $admin = New-Object System.Security.Principal.NTAccount("BUILTIN\Administrators")
                    $regRights = [System.Security.AccessControl.RegistryRights]::FullControl
                    $inherit = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
                    $prop = [System.Security.AccessControl.PropagationFlags]::None
                    $rule = New-Object System.Security.AccessControl.RegistryAccessRule($admin, $regRights, $inherit, $prop, "Allow")

                    $tmpAcl = Get-Acl $key
                    $tmpAcl.SetAccessRule($rule)
                    Set-Acl -Path $key -AclObject $tmpAcl -ErrorAction Stop

                    try {
                        Set-ItemProperty -Path $key -Name "Start" -Value 4 -Type DWord -Force
                        $fa = (Get-ItemProperty -Path $key -Name "FailureActions" -ErrorAction SilentlyContinue).FailureActions
                        if ($fa) {
                            Set-ItemProperty -Path $key -Name "FailureActions" -Value ([byte[]]@()) -Type Binary -Force -ErrorAction SilentlyContinue
                            Write-GuardLog "Re-cleared FailureActions on WaaSMedicSvc"
                        }
                        Write-GuardLog "Re-disabled WaaSMedicSvc via registry (Start=4)"
                    } finally {
                        $aclOk = $false
                        for ($gRetry = 1; $gRetry -le 3; $gRetry++) {
                            try {
                                Set-Acl -Path $key -AclObject $origAcl -ErrorAction Stop
                                $aclOk = $true
                                break
                            } catch {
                                if ($gRetry -lt 3) { Start-Sleep -Milliseconds 500 }
                            }
                        }
                        if (-not $aclOk) {
                            $aclBk = "$backupDir\WaaSMedicSvc_ACL.xml"
                            if (Test-Path $aclBk) {
                                try {
                                    $sddl = [System.IO.File]::ReadAllText($aclBk)
                                    $bkAcl = New-Object System.Security.AccessControl.RegistrySecurity
                                    $bkAcl.SetSecurityDescriptorSddlForm($sddl)
                                    Set-Acl -Path $key -AclObject $bkAcl -ErrorAction Stop
                                    $aclOk = $true
                                } catch {}
                            }
                            if (-not $aclOk) {
                                Write-GuardLog "WARN: ACL restore failed for WaaSMedicSvc"
                                try { [System.IO.File]::WriteAllText($aclAlertFile, (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), [System.Text.UTF8Encoding]::new($false)) } catch {}
                            }
                        }
                    }
                } catch {
                    Write-GuardLog "FAIL re-disable WaaSMedicSvc via registry: $_"
                }
            }
        }
    }

    $auKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
    if (Test-Path $auKey) {
        $val = (Get-ItemProperty -Path $auKey -Name "NoAutoUpdate" -ErrorAction SilentlyContinue).NoAutoUpdate
        if ($val -ne 1) {
            try {
                Set-ItemProperty -Path $auKey -Name "NoAutoUpdate" -Value 1 -Type DWord -Force
                Write-GuardLog "Re-set NoAutoUpdate=1"
            } catch {
                Write-GuardLog "FAIL re-set NoAutoUpdate: $_"
            }
        }
    }

    $waasMedicKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WaaSMedic"
    if (Test-Path $waasMedicKey) {
        $val = (Get-ItemProperty -Path $waasMedicKey -Name "AllowWaaSMedic" -ErrorAction SilentlyContinue).AllowWaaSMedic
        if ($val -ne 0) {
            try {
                Set-ItemProperty -Path $waasMedicKey -Name "AllowWaaSMedic" -Value 0 -Type DWord -Force
                Write-GuardLog "Re-set AllowWaaSMedic=0"
            } catch {
                Write-GuardLog "FAIL re-set AllowWaaSMedic: $_"
            }
        }
    }

    Write-GuardLog "--- Guard check end ---"
    exit
}

$isZh = (Get-Culture).TwoLetterISOLanguageName -eq "zh"
function T($zh, $en) { if ($isZh) { $zh } else { $en } }

if (Test-Path $aclAlertFile) {
    $waasKey4Check = "HKLM:\SYSTEM\CurrentControlSet\Services\WaaSMedicSvc"
    $aclAlertReal = $false
    try {
        $curAcl = Get-Acl $waasKey4Check -ErrorAction Stop
        $aclBk4Check = "$backupDir\WaaSMedicSvc_ACL.xml"
        if (Test-Path $aclBk4Check) {
            $expectedSddl = [System.IO.File]::ReadAllText($aclBk4Check)
            if ($curAcl.GetSecurityDescriptorSddlForm() -ne $expectedSddl) { $aclAlertReal = $true }
        } else { $aclAlertReal = $true }
    } catch { $aclAlertReal = $true }
    if ($aclAlertReal) {
        Write-Host ""
        Write-Host "  [ALERT] $(T "WaaSMedicSvc 注册表 ACL 可能异常！" "WaaSMedicSvc registry ACL may be incorrect!")" -ForegroundColor Red
        Write-Host "  [ALERT] $(T "请手动检查" "Please check manually"): $waasKey4Check" -ForegroundColor Red
        Write-Host ""
    }
    Remove-Item $aclAlertFile -Force -ErrorAction SilentlyContinue
}

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
Write-Host "===== [1/6] $(T "禁用 Windows Update 服务" "Disable Windows Update Services") =====" -ForegroundColor Green

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
            Write-Host "  [WARN] SCM $(T "停止失败" "stop failed"): $_ ($(T "将继续通过注册表禁用" "will continue via registry")" -ForegroundColor DarkYellow
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
                    try { [System.IO.File]::WriteAllText($aclAlertFile, (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), [System.Text.UTF8Encoding]::new($false)) } catch {}
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
Write-Host "===== [2/6] $(T "配置注册表禁用自动更新" "Configure Registry to Disable Auto Update") =====" -ForegroundColor Green

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
    Write-Host "  [OK] NoAutoUpdate = 1 ($(T "禁用自动更新" "disable auto update")" -ForegroundColor Green

    Set-ItemProperty -Path $wuKeyPath -Name "DisableWindowsUpdateAccess" -Value 1 -Type DWord -Force
    Write-Host "  [OK] DisableWindowsUpdateAccess = 1 ($(T "禁用更新访问" "disable update access")" -ForegroundColor Green

    Set-ItemProperty -Path $wuKeyPath -Name "SetUpdateServiceDisabled" -Value 1 -Type DWord -Force
    Write-Host "  [OK] SetUpdateServiceDisabled = 1" -ForegroundColor Green
} catch {
    Write-Host "  [FAIL] $(T "注册表配置失败" "Registry configuration failed"): $_" -ForegroundColor Red
}

Write-Host ""
Write-Host "===== [3/6] $(T "禁用 Windows Update 相关任务计划" "Disable Windows Update Scheduled Tasks") =====" -ForegroundColor Green

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
Write-Host "===== [4/6] $(T "禁用自动驱动更新" "Disable Auto Driver Update") =====" -ForegroundColor Green

$driverKeyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching"
try {
    if (-not (Test-Path $driverKeyPath)) {
        New-Item -Path $driverKeyPath -Force | Out-Null
    }
    Set-ItemProperty -Path $driverKeyPath -Name "SearchOrderConfig" -Value 0 -Type DWord -Force
    Write-Host "  [OK] SearchOrderConfig = 0 ($(T "禁用自动驱动更新" "disable auto driver update")" -ForegroundColor Green
} catch {
    Write-Host "  [FAIL] $(T "驱动更新注册表配置失败" "Driver update registry configuration failed"): $_" -ForegroundColor Red
}

Write-Host ""
Write-Host "===== [5/6] $(T "禁用 Windows Update 医疗服务(WaaSMedic)" "Disable Windows Update Medic (WaaSMedic)") =====" -ForegroundColor Green

$waasKeyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WaaSMedic"
try {
    if (-not (Test-Path $waasKeyPath)) {
        New-Item -Path $waasKeyPath -Force | Out-Null
    }
    Set-ItemProperty -Path $waasKeyPath -Name "AllowWaaSMedic" -Value 0 -Type DWord -Force
    Write-Host "  [OK] AllowWaaSMedic = 0 ($(T "防止系统自动修复更新服务" "prevent system from auto-repairing update service")" -ForegroundColor Green
} catch {
    Write-Host "  [FAIL] WaaSMedic $(T "注册表配置失败" "registry configuration failed"): $_" -ForegroundColor Red
}

Write-Host ""
Write-Host "===== [6/6] $(T "开机守护任务 (可选)" "Boot Guard Task (Optional)") =====" -ForegroundColor Green
Write-Host "  [$(T "说明" "Note")] $(T "开机守护可在每次开机时自动检查并重新禁用被微软恢复的更新服务" "Boot guard checks at each startup and re-disables update services if restored by Microsoft")" -ForegroundColor DarkCyan
Write-Host "  [$(T "说明" "Note")] $(T "不开启则仅本次禁用生效，微软可能在重启后恢复更新服务" "Without guard, changes apply only this session; Microsoft may restore services after reboot")" -ForegroundColor DarkCyan
Write-Host ""

$guardConfirm = Read-Host (T "是否开启开机守护? (输入 Y 开启, 其他键跳过)" "Enable boot guard? (Y to enable, any other key to skip)")

if ($guardConfirm -eq 'Y' -or $guardConfirm -eq 'y') {
    $guardDst = "$backupDir\disable-windows-update.ps1"
    $markerFile = "$backupDir\guard.enabled"

    try {
        if (-not (Test-Path (Split-Path $guardDst -Parent))) {
            New-Item -Path (Split-Path $guardDst -Parent) -ItemType Directory -Force | Out-Null
        }
        Copy-Item -Path $PSCommandPath -Destination $guardDst -Force -ErrorAction Stop
        Write-Host "  [OK] $(T "守护脚本已部署" "Guard script deployed")" -ForegroundColor Green
    } catch {
        Write-Host "  [FAIL] $(T "复制守护脚本失败" "Guard script copy failed"): $_" -ForegroundColor Red
    }

    try {
        New-Item -Path $markerFile -ItemType File -Force | Out-Null
        Write-Host "  [OK] $(T "守护标记已创建" "Guard marker created")" -ForegroundColor Green
    } catch {
        Write-Host "  [FAIL] $(T "创建守护标记失败" "Guard marker creation failed"): $_" -ForegroundColor Red
    }

    try {
        $taskName = "DisableWindowsUpdateGuard"
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $trigger.Delay = "PT30S"
        $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -NoProfile -NonInteractive -WindowStyle Hidden -File `"$guardDst`" -GuardMode"
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

        Register-ScheduledTask -TaskName $taskName -Trigger $trigger -Action $action -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
        Write-Host "  [OK] $(T "开机守护任务已注册 (开机30秒后自动检查)" "Boot guard task registered (auto-check 30s after boot)")" -ForegroundColor Green
    } catch {
        Write-Host "  [FAIL] $(T "注册守护任务失败" "Guard task registration failed"): $_" -ForegroundColor Red
    }
} else {
    Write-Host "  [SKIP] $(T "已跳过开机守护任务" "Boot guard task skipped")" -ForegroundColor DarkGray
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

Write-Host ""
Write-Host (T "[提示] 如需恢复更新，请运行 restore-windows-update.ps1" "[Tip] To restore updates, run restore-windows-update.ps1") -ForegroundColor Yellow
Write-Host ""
Read-Host (T "按回车键退出" "Press Enter to exit")
