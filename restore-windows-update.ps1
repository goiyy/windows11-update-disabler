#Requires -RunAsAdministrator

$backupDir = "$env:ProgramData\ScriptBackup\WaaSMedicBackup"

$isZh = (Get-Culture).TwoLetterISOLanguageName -eq "zh"
function T($zh, $en) { if ($isZh) { $zh } else { $en } }

$host.UI.RawUI.WindowTitle = (T "Windows Update 恢复工具" "Windows Update Restorer")

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "     $(T "Windows 更新恢复 - 一键脚本" "Windows Update Restore - One-Click Script")" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host (T "[提示] 此操作将恢复 Windows 更新功能" "[Tip] This will restore Windows Update functionality") -ForegroundColor Yellow
Write-Host ""

$confirm = Read-Host (T "确认要继续吗? (输入 Y 继续, 其他键退出)" "Continue? (Y to proceed, any other key to cancel)")
if ($confirm -ne 'Y' -and $confirm -ne 'y') {
    Write-Host (T "已取消操作。" "Operation cancelled.") -ForegroundColor Gray
    exit
}

Write-Host ""
Write-Host "===== [1/5] $(T "恢复 DLL 文件" "Restore DLL Files") =====" -ForegroundColor Green

$waasDllBak = "$env:SystemRoot\System32\WaaSMedicSvc.dll.bak"
$waasDllPath = "$env:SystemRoot\System32\WaaSMedicSvc.dll"

if (Test-Path $waasDllBak) {
    try {
        takeown.exe /f $waasDllBak /a > $null 2>&1
        icacls.exe $waasDllBak /grant "Administrators:F" > $null 2>&1
        Rename-Item -Path $waasDllBak -NewName "WaaSMedicSvc.dll" -Force -ErrorAction Stop
        Write-Host "  [OK] WaaSMedicSvc.dll $(T "已恢复" "restored")" -ForegroundColor Green
    } catch {
        Write-Host "  [FAIL] $(T "恢复 WaaSMedicSvc.dll 失败" "Failed to restore WaaSMedicSvc.dll"): $_" -ForegroundColor Red
        Write-Host "  [HINT] $(T "可能需要使用 PsExec -s 以 SYSTEM 权限运行此脚本" "May need to run this script with SYSTEM privileges via PsExec -s")" -ForegroundColor DarkYellow
    }
} elseif (Test-Path $waasDllPath) {
    Write-Host "  [SKIP] WaaSMedicSvc.dll $(T "已存在，无需恢复" "already exists, no restore needed")" -ForegroundColor DarkGray
} else {
    Write-Host "  [SKIP] WaaSMedicSvc.dll $(T "备份不存在" "backup not found")" -ForegroundColor DarkGray
}

$wuauDllBak = "$env:SystemRoot\System32\wuaueng.dll.bak"
$wuauDllPath = "$env:SystemRoot\System32\wuaueng.dll"

if (Test-Path $wuauDllBak) {
    try {
        takeown.exe /f $wuauDllBak /a > $null 2>&1
        icacls.exe $wuauDllBak /grant "Administrators:F" > $null 2>&1
        Rename-Item -Path $wuauDllBak -NewName "wuaueng.dll" -Force -ErrorAction Stop
        Write-Host "  [OK] wuaueng.dll $(T "已恢复" "restored")" -ForegroundColor Green
    } catch {
        Write-Host "  [FAIL] $(T "恢复 wuaueng.dll 失败" "Failed to restore wuaueng.dll"): $_" -ForegroundColor Red
        Write-Host "  [HINT] $(T "可能需要使用 PsExec -s 以 SYSTEM 权限运行此脚本" "May need to run this script with SYSTEM privileges via PsExec -s")" -ForegroundColor DarkYellow
    }
} elseif (Test-Path $wuauDllPath) {
    Write-Host "  [SKIP] wuaueng.dll $(T "已存在，无需恢复" "already exists, no restore needed")" -ForegroundColor DarkGray
} else {
    Write-Host "  [SKIP] wuaueng.dll $(T "备份不存在" "backup not found")" -ForegroundColor DarkGray
}
Write-Host ""
Write-Host "===== [2/5] $(T "恢复 Windows Update 服务" "Restore Windows Update Services") =====" -ForegroundColor Green

$serviceName = "wuauserv"
try {
    Set-Service -Name $serviceName -StartupType Manual -ErrorAction Stop
    Start-Service -Name $serviceName -ErrorAction SilentlyContinue
    Write-Host "  [OK] wuauserv $(T "服务已恢复" "service restored")" -ForegroundColor Green
} catch {
    Write-Host "  [FAIL] wuauserv $(T "恢复失败" "restore failed"): $_" -ForegroundColor Red
}

$relatedServices = @("UsoSvc")
foreach ($svc in $relatedServices) {
    try {
        Set-Service -Name $svc -StartupType Manual -ErrorAction Stop
        Start-Service -Name $svc -ErrorAction SilentlyContinue
        Write-Host "  [OK] $svc $(T "服务已恢复" "service restored")" -ForegroundColor Green
    } catch {
        Write-Host "  [FAIL] $svc $(T "恢复失败" "restore failed"): $_" -ForegroundColor Red
    }
}

$svc = "sedsvc"
if (Get-Service -Name $svc -ErrorAction SilentlyContinue) {
    try {
        Set-Service -Name $svc -StartupType Manual -ErrorAction Stop
        Write-Host "  [OK] $svc $(T "服务已恢复" "service restored")" -ForegroundColor Green
    } catch {
        Write-Host "  [FAIL] $svc $(T "恢复失败" "restore failed"): $_" -ForegroundColor Red
    }
} else {
    Write-Host "  [SKIP] sedsvc $(T "服务不存在" "service not found")" -ForegroundColor DarkGray
}

Write-Host "  [INFO] $(T "正在恢复 WaaSMedicSvc (受保护服务)..." "Restoring WaaSMedicSvc (protected service)...")" -ForegroundColor DarkCyan
try {
    $waasSvcKey = "HKLM:\SYSTEM\CurrentControlSet\Services\WaaSMedicSvc"
    if (Test-Path $waasSvcKey) {
        $originalAcl = Get-Acl $waasSvcKey
        $admin = New-Object System.Security.Principal.NTAccount("BUILTIN\Administrators")
        $regRights = [System.Security.AccessControl.RegistryRights]::FullControl
        $inheritance = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
        $propagation = [System.Security.AccessControl.PropagationFlags]::None
        $accessRule = New-Object System.Security.AccessControl.RegistryAccessRule($admin, $regRights, $inheritance, $propagation, "Allow")

        if (-not (Test-Path $backupDir)) { New-Item -Path $backupDir -ItemType Directory -Force | Out-Null }
        $aclBackupPath = "$backupDir\WaaSMedicSvc_ACL.xml"
        if (-not (Test-Path $aclBackupPath)) {
            try {
                [System.IO.File]::WriteAllText($aclBackupPath, $originalAcl.GetSecurityDescriptorSddlForm(), [System.Text.UTF8Encoding]::new($false))
            } catch {}
        }

        $tempAcl = Get-Acl $waasSvcKey
        $tempAcl.SetAccessRule($accessRule)
        Set-Acl -Path $waasSvcKey -AclObject $tempAcl -ErrorAction Stop

        try {
            $failureActionsPath = "$backupDir\WaaSMedicSvc_FailureActions.bin"
            if (Test-Path $failureActionsPath) {
                try {
                    $failureActions = [System.IO.File]::ReadAllBytes($failureActionsPath)
                    Set-ItemProperty -Path $waasSvcKey -Name "FailureActions" -Value $failureActions -Type Binary -Force -ErrorAction SilentlyContinue
                    Write-Host "  [OK] FailureActions $(T "已从备份恢复" "restored from backup")" -ForegroundColor Green
                } catch {
                    Write-Host "  [WARN] $(T "恢复 FailureActions 失败" "FailureActions restore failed"): $_" -ForegroundColor DarkYellow
                }
            } else {
                Write-Host "  [SKIP] FailureActions $(T "备份不存在，跳过恢复" "backup not found, skip restore")" -ForegroundColor DarkGray
            }

            Set-ItemProperty -Path $waasSvcKey -Name "Start" -Value 3 -Type DWord -Force
            Write-Host "  [OK] WaaSMedicSvc $(T "已通过注册表恢复 (Start=3)" "restored via registry (Start=3)")" -ForegroundColor Green
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
    } else {
        Write-Host "  [SKIP] WaaSMedicSvc $(T "注册表项不存在" "registry key not found")" -ForegroundColor DarkGray
    }
} catch {
    Write-Host "  [FAIL] WaaSMedicSvc $(T "恢复失败" "restore failed"): $_" -ForegroundColor Red
}

Write-Host "  [INFO] WaaSMedicSvc $(T "受 LaunchProtected=2 保护，SCM 缓存启动时值，Set-Service 无法修改" "protected by LaunchProtected=2, SCM caches at boot, Set-Service cannot modify")" -ForegroundColor DarkCyan
Write-Host "  [INFO] $(T "注册表已设 Start=3，重启后 SCM 重读注册表生效" "Registry set Start=3, takes effect after reboot when SCM re-reads registry")" -ForegroundColor DarkCyan
Write-Host ""
Write-Host "===== [3/5] $(T "恢复注册表自动更新设置" "Restore Registry Auto Update Settings") =====" -ForegroundColor Green

$wuKeyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
$auKeyPath = "$wuKeyPath\AU"

try {
    if (Test-Path $auKeyPath) {
        Remove-ItemProperty -Path $auKeyPath -Name "NoAutoUpdate" -ErrorAction SilentlyContinue
        Write-Host "  [OK] $(T "已删除 NoAutoUpdate" "NoAutoUpdate removed")" -ForegroundColor Green
    }
    if (Test-Path $wuKeyPath) {
        Remove-ItemProperty -Path $wuKeyPath -Name "DisableWindowsUpdateAccess" -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $wuKeyPath -Name "SetUpdateServiceDisabled" -ErrorAction SilentlyContinue
        Write-Host "  [OK] $(T "已恢复更新访问策略" "Update access policy restored")" -ForegroundColor Green
    }
} catch {
    Write-Host "  [FAIL] $(T "注册表恢复失败" "Registry restore failed"): $_" -ForegroundColor Red
}

Write-Host ""
Write-Host "===== [4/5] $(T "恢复 Windows Update 相关任务计划" "Restore Windows Update Scheduled Tasks") =====" -ForegroundColor Green

$taskFolders = @(
    "$env:SystemRoot\System32\Tasks\Microsoft\Windows\WindowsUpdate",
    "$env:SystemRoot\System32\Tasks\Microsoft\Windows\UpdateOrchestrator",
    "$env:SystemRoot\System32\Tasks\Microsoft\Windows\WaaSMedic"
)

$taskBackupDir = "$backupDir\tasks"

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

    $bakFiles = Get-ChildItem -Path $folder -Filter "*.bak" -File -ErrorAction SilentlyContinue
    foreach ($bak in $bakFiles) {
        try {
            $originalName = $bak.Name -replace '\.bak$', ''
            $originalPath = Join-Path $folder $originalName
            if (Test-Path $originalPath) {
                Write-Host "  [SKIP] Task file exists: $originalName ($(T "无需恢复" "no restore needed"))" -ForegroundColor DarkGray
                continue
            }
            Rename-Item -Path $bak.FullName -NewName $originalName -Force -ErrorAction Stop
            Write-Host "  [OK] $(T "已恢复任务文件" "Task file restored"): $originalName" -ForegroundColor Green
        } catch {
            Write-Host "  [FAIL] $(T "恢复任务文件失败" "Task file restore failed"): $($bak.Name)" -ForegroundColor Red
        }
    }

    $taskPathMapped = switch ($folderName) {
        "WindowsUpdate" { "\Microsoft\Windows\WindowsUpdate\" }
        "UpdateOrchestrator" { "\Microsoft\Windows\UpdateOrchestrator\" }
        "WaaSMedic" { "\Microsoft\Windows\WaaSMedic\" }
    }

    $tasks = Get-ScheduledTask -TaskPath $taskPathMapped -ErrorAction SilentlyContinue
    foreach ($t in $tasks) {
        try {
            if ($t.State -eq 'Disabled') {
                Enable-ScheduledTask -TaskPath $t.TaskPath -TaskName $t.TaskName -ErrorAction Stop | Out-Null
                Write-Host "  [OK] $(T "已启用" "Enabled"): $($t.TaskName)" -ForegroundColor Green
            } else {
                Write-Host "  [SKIP] $(T "已启用" "Already enabled"): $($t.TaskName)" -ForegroundColor DarkGray
            }
        } catch {
            $registered = $false
            $taskFolderName = ($t.TaskPath.Trim('\') -replace '\\', '_')
            $safeTaskName = $t.TaskName -replace '[^\w\-]', '_'
            $backupFile = "$taskBackupDir\${taskFolderName}_${safeTaskName}.xml"
            if (Test-Path $backupFile) {
                try {
                    $taskXml = Get-Content $backupFile -Raw -Encoding UTF8
                    Register-ScheduledTask -Xml $taskXml -TaskName $t.TaskName -TaskPath $t.TaskPath -Force -ErrorAction Stop | Out-Null
                    Write-Host "  [OK] $(T "已重新注册" "Re-registered"): $($t.TaskName)" -ForegroundColor Green
                    $registered = $true
                } catch {
                    Write-Host "  [WARN] $(T "重新注册失败" "Re-registration failed"): $($t.TaskName) - $_" -ForegroundColor DarkYellow
                }
            }
            if (-not $registered) {
                Write-Host "  [FAIL] $(T "启用失败" "Enable failed"): $($t.TaskName)" -ForegroundColor Red
            }
        }
    }
}
Write-Host ""
Write-Host "===== [5/5] $(T "恢复自动驱动更新 + WaaSMedic 策略" "Restore Auto Driver Update + WaaSMedic Policy") =====" -ForegroundColor Green

$driverKeyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching"
try {
    if (Test-Path $driverKeyPath) {
        Remove-ItemProperty -Path $driverKeyPath -Name "SearchOrderConfig" -ErrorAction SilentlyContinue
        Write-Host "  [OK] $(T "已恢复驱动更新设置" "Driver update settings restored")" -ForegroundColor Green
    }
} catch {
    Write-Host "  [FAIL] $(T "驱动更新恢复失败" "Driver update restore failed"): $_" -ForegroundColor Red
}

$waasKeyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WaaSMedic"
try {
    if (Test-Path $waasKeyPath) {
        Remove-ItemProperty -Path $waasKeyPath -Name "AllowWaaSMedic" -ErrorAction SilentlyContinue
        Write-Host "  [OK] $(T "已恢复 WaaSMedic" "WaaSMedic restored")" -ForegroundColor Green
    }
} catch {
    Write-Host "  [FAIL] WaaSMedic $(T "恢复失败" "restore failed"): $_" -ForegroundColor Red
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  $(T "恢复完成! Windows 更新已重新启用。" "Restore complete! Windows Update re-enabled.")" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

$svc = Get-Service -Name "wuauserv" -ErrorAction SilentlyContinue
if ($svc) {
    Write-Host "  Windows Update $(T "服务状态" "service status"): $($svc.Status)" -ForegroundColor $(if ($svc.Status -eq 'Running') {'Green'} else {'Yellow'})
    Write-Host "  Windows Update $(T "启动类型" "start type"): $($svc.StartType)" -ForegroundColor $(if ($svc.StartType -eq 'Manual') {'Green'} else {'Yellow'})
}

$waasDllStatus = if (Test-Path "$env:SystemRoot\System32\WaaSMedicSvc.dll") { "WaaSMedicSvc.dll $(T "已恢复" "restored")" } elseif (Test-Path "$env:SystemRoot\System32\WaaSMedicSvc.dll.bak") { "WaaSMedicSvc.dll $(T "仍为备份" "still backed up")" } else { "WaaSMedicSvc.dll $(T "不存在" "not found")" }
Write-Host "  DLL: $waasDllStatus" -ForegroundColor $(if (Test-Path "$env:SystemRoot\System32\WaaSMedicSvc.dll") {'Green'} else {'Yellow'})

$wuauDllStatus = if (Test-Path "$env:SystemRoot\System32\wuaueng.dll") { "wuaueng.dll $(T "已恢复" "restored")" } elseif (Test-Path "$env:SystemRoot\System32\wuaueng.dll.bak") { "wuaueng.dll $(T "仍为备份" "still backed up")" } else { "wuaueng.dll $(T "不存在" "not found")" }
Write-Host "  DLL: $wuauDllStatus" -ForegroundColor $(if (Test-Path "$env:SystemRoot\System32\wuaueng.dll") {'Green'} else {'Yellow'})

if (Test-Path $backupDir) {
    Write-Host ""
    $cleanConfirm = Read-Host (T "是否清理备份目录? (输入 Y 清理, 其他键保留)" "Clean up backup directory? (Y to clean, any other key to keep)")
    if ($cleanConfirm -eq 'Y' -or $cleanConfirm -eq 'y') {
        try {
            Remove-Item -Path $backupDir -Recurse -Force -ErrorAction Stop
            Write-Host "  [OK] $(T "备份目录已清理" "Backup directory cleaned"): $backupDir" -ForegroundColor Green
        } catch {
            Write-Host "  [FAIL] $(T "清理备份目录失败" "Backup directory cleanup failed"): $_" -ForegroundColor Red
        }
    }
}

Write-Host ""
Write-Host (T "[提示] 建议重启计算机以使所有更改生效" "[Tip] Reboot is recommended for all changes to take effect") -ForegroundColor Yellow
Write-Host ""
Read-Host (T "按回车键退出" "Press Enter to exit")