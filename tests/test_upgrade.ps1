$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot
$fixture=Join-Path $env:TEMP ('loup-' + [guid]::NewGuid().ToString('N').Substring(0,8))
$bundle=Join-Path $fixture 'bundle'
New-Item -ItemType Directory -Path $bundle -Force | Out-Null
Get-ChildItem -LiteralPath (Join-Path $repo 'package') | Copy-Item -Destination $bundle -Recurse
$upgrade=Join-Path $bundle 'upgrade.ps1'
$installer=Join-Path $bundle 'configure.ps1'
$payload=[Text.Encoding]::UTF8.GetBytes('synthetic signed MSI fixture; never executed')
$algorithm=[Security.Cryptography.SHA256]::Create()
$digest=([BitConverter]::ToString($algorithm.ComputeHash($payload))).Replace('-','').ToLowerInvariant()
$algorithm.Dispose()
$targets=ConvertFrom-Json -InputObject (Get-Content (Join-Path $bundle 'upgrade-targets.json') -Raw -Encoding UTF8)
$targets[0].SHA256=$digest
ConvertTo-Json -InputObject @($targets) | Set-Content (Join-Path $bundle 'upgrade-targets.json') -Encoding UTF8
$testState=@{}
$previousAppData=$env:APPDATA; $previousLocalAppData=$env:LOCALAPPDATA

# 所有网络、签名和 Windows Installer 调用均在测试中替换，不下载或安装软件。
function Get-Item {
    param($LiteralPath)
    if ($LiteralPath -like '*\program\soffice.exe') { return [pscustomobject]@{VersionInfo=@{ProductVersion=(Get-Content (Join-Path (Split-Path $LiteralPath) 'product.txt') -Raw).Trim()}} }
    Microsoft.PowerShell.Management\Get-Item -LiteralPath $LiteralPath
}
function Get-Process { param($Name,$ErrorAction) if ($testState.Running) { [pscustomobject]@{Name='soffice'} } }
function Get-AuthenticodeSignature { param($LiteralPath) [pscustomobject]@{Status=$(if ($testState.BadSignature) { 'NotTrusted' } else { 'Valid' });SignerCertificate=@{Subject='CN=The Document Foundation, O=The Document Foundation, C=DE'}} }
function Invoke-WebRequest {
    param($Uri,$OutFile,[switch]$UseBasicParsing,$TimeoutSec)
    $testState.Downloads++
    if ($testState.NetworkFailure) { [IO.File]::WriteAllText($OutFile,'partial'); throw 'synthetic network failure' }
    [IO.File]::WriteAllBytes($OutFile,$payload)
}
function Start-Process {
    param($FilePath,$ArgumentList,$WindowStyle,[switch]$PassThru,[switch]$Wait)
    $testState.Installs++
    if ($FilePath -notlike '*\System32\msiexec.exe' -or $ArgumentList -notmatch '/norestart' -or $WindowStyle -ne 'Hidden') { throw '安装启动参数不正确' }
    if ($testState.ApplyInstall) {
        [IO.File]::WriteAllText("$($testState.FakeApp)\program\product.txt",'26.8.1.1')
        [IO.File]::WriteAllText("$($testState.FakeApp)\program\version.ini",'buildid=bf6ef2662401c7d6dce671ab4deb26ee0af3a7c1')
    }
    [pscustomobject]@{ExitCode=$testState.InstallExit}
}
function New-Case($name, $version='26.2.5.2', $buildId='cd7284b4cbbfeb507e630c1aac019f4157393acb') {
    $case=Join-Path $fixture $name
    $env:APPDATA=Join-Path $case 'roaming'; $env:LOCALAPPDATA=Join-Path $case 'local'
    $testState.FakeApp=Join-Path $case 'app'
    $testState.Config=Join-Path $env:APPDATA 'LibreOffice\4\user\registrymodifications.xcu'
    $testState.UpgradeRoot=Join-Path $env:LOCALAPPDATA 'LibreOfficePlus\upgrades'
    New-Item -ItemType Directory -Path (Split-Path $testState.Config),"$($testState.FakeApp)\program" -Force | Out-Null
    $bytes=New-Object byte[] 128; $bytes[0]=0x4d; $bytes[1]=0x5a; $bytes[60]=64; $bytes[64]=0x50; $bytes[65]=0x45; $bytes[68]=0x64; $bytes[69]=0x86
    [IO.File]::WriteAllBytes("$($testState.FakeApp)\program\soffice.exe",$bytes)
    [IO.File]::WriteAllText("$($testState.FakeApp)\program\product.txt",$version)
    [IO.File]::WriteAllText("$($testState.FakeApp)\program\version.ini","buildid=$buildId")
    [IO.File]::WriteAllText($testState.Config,'<oor:items xmlns:oor="http://openoffice.org/2001/registry"/>')
    $testState.Running=$false; $testState.BadSignature=$false; $testState.NetworkFailure=$false
    $testState.Downloads=0; $testState.Installs=0; $testState.InstallExit=0; $testState.ApplyInstall=$true
    & $installer -Modules 'Writer,Calc' -LibreOfficePath $testState.FakeApp -OnCheck { param($Result) } | Out-Null
}
function Run-Upgrade { & $upgrade -LibreOfficePath $testState.FakeApp -OnCheck { param($Result) } }
function Refused($message) {
    $refused=$false
    try { Run-Upgrade } catch { $refused=$true; if ($_.Exception.Message -notmatch $message) { throw } }
    if (!$refused) { throw '应停止的升级没有停止' }
}
try {
    New-Case 'check-only'
    $before=(Get-FileHash $testState.Config).Hash
    $plan=& $upgrade -CheckOnly -LibreOfficePath $testState.FakeApp
    if ($plan.Current.Version -ne '26.2.5.2' -or $plan.Target.Version -ne '26.8.1.1' -or ($plan.Modules -join ',') -ne 'Writer,Calc' -or (Test-Path $testState.UpgradeRoot) -or (Get-FileHash $testState.Config).Hash -ne $before) { throw '只读兼容预检不正确' }
    New-Case '26.2.4.2' '26.2.4.2' '0229ac93fcf0d7cbc6376066c6f35021cef002dc'
    $before=(Get-FileHash $testState.Config).Hash
    $plan=& $upgrade -CheckOnly -LibreOfficePath $testState.FakeApp
    if ($plan.Current.Version -ne '26.2.4.2' -or $plan.Target.Version -ne '26.8.1.1' -or (Test-Path $testState.UpgradeRoot) -or (Get-FileHash $testState.Config).Hash -ne $before) { throw '26.2.4.2 升级预检或只读状态不正确' }
    $firstBackup=(Get-FileHash (Join-Path $env:APPDATA 'LibreOffice\wps-ui-backup.xml')).Hash
    Run-Upgrade
    $state=ConvertFrom-Json -InputObject (Get-Content (Join-Path $env:APPDATA 'LibreOffice\wps-ui-files-backup\state.json') -Raw)
    if ($testState.Downloads -ne 1 -or $testState.Installs -ne 1 -or (Test-Path (Join-Path $testState.UpgradeRoot 'pending.json')) -or @($state | Where-Object { $_.BuildId -ne 'bf6ef2662401c7d6dce671ab4deb26ee0af3a7c1' }).Count -or (Get-FileHash (Join-Path $env:APPDATA 'LibreOffice\wps-ui-backup.xml')).Hash -ne $firstBackup) { throw '26.2.4.2 升级后重新配置或首次备份不正确' }
    New-Case 'success'
    $firstBackup=(Get-FileHash (Join-Path $env:APPDATA 'LibreOffice\wps-ui-backup.xml')).Hash
    Run-Upgrade
    if ($testState.Downloads -ne 1 -or $testState.Installs -ne 1 -or (Test-Path (Join-Path $testState.UpgradeRoot 'pending.json'))) { throw '成功升级状态不正确' }
    $state=ConvertFrom-Json -InputObject (Get-Content (Join-Path $env:APPDATA 'LibreOffice\wps-ui-files-backup\state.json') -Raw)
    if (@($state | Where-Object { $_.BuildId -ne 'bf6ef2662401c7d6dce671ab4deb26ee0af3a7c1' -or $_.Module -notin 'swriter','scalc' }).Count) { throw '未为全部已安装模块选择新版界面，或误新增模块' }
    if ((Get-FileHash (Join-Path $env:APPDATA 'LibreOffice\wps-ui-backup.xml')).Hash -ne $firstBackup) { throw '升级覆盖了首次备份' }
    Run-Upgrade
    if ($testState.Downloads -ne 1 -or $testState.Installs -ne 1) { throw '相同版本重复安装或下载' }
    New-Case 'offline-cache'
    $cache=Join-Path $testState.UpgradeRoot 'cache\bf6ef2662401c7d6dce671ab4deb26ee0af3a7c1'
    New-Item -ItemType Directory -Path $cache -Force | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $cache 'installer.msi'),$payload)
    $testState.NetworkFailure=$true
    Run-Upgrade
    if ($testState.Downloads -ne 0 -or $testState.Installs -ne 1) { throw '有效缓存没有离线复用' }
    New-Case 'corrupt-cache'
    $cache=Join-Path $testState.UpgradeRoot 'cache\bf6ef2662401c7d6dce671ab4deb26ee0af3a7c1'
    New-Item -ItemType Directory -Path $cache -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $cache 'installer.msi'),'tampered')
    Refused '校验值不匹配'
    if ($testState.Installs -or (Test-Path (Join-Path $testState.UpgradeRoot 'pending.json'))) { throw '损坏缓存触发了安装或配置写入' }
    New-Case 'bad-signature'
    $testState.BadSignature=$true
    Refused '数字签名验证失败'
    if ($testState.Installs -or (Get-ChildItem $testState.UpgradeRoot -Recurse -Filter '*.partial.msi')) { throw '无效签名触发安装或留下未验证缓存' }
    New-Case 'network-failure'
    $testState.NetworkFailure=$true
    Refused 'synthetic network failure'
    if ($testState.Installs -or (Get-ChildItem $testState.UpgradeRoot -Recurse -Filter '*.partial.msi')) { throw '下载失败触发安装或留下半成品' }
    New-Case 'running'
    $testState.Running=$true
    Refused '完全退出'
    if ($testState.Downloads -or $testState.Installs -or (Test-Path $testState.UpgradeRoot)) { throw '软件运行时仍开始缓存或安装' }
    New-Case 'installer-failure'
    $testState.InstallExit=1603; $testState.ApplyInstall=$false
    Refused '1603'
    $pending=Get-Content (Join-Path $testState.UpgradeRoot 'pending.json') -Raw | ConvertFrom-Json
    if (!(Test-Path (Join-Path $testState.UpgradeRoot ("transactions\"+$pending.Id+'\registrymodifications.xcu')))) { throw '安装失败未保留备份' }
    $testState.InstallExit=0; $testState.ApplyInstall=$true
    Run-Upgrade
    if ($testState.Downloads -ne 1 -or $testState.Installs -ne 2) { throw '安装失败重试没有复用缓存' }
    New-Case 'reboot-resume'
    $testState.InstallExit=3010
    Refused '要求重启'
    Run-Upgrade
    if ($testState.Installs -ne 1 -or (Test-Path (Join-Path $testState.UpgradeRoot 'pending.json'))) { throw '重启后继续配置时重复安装' }
    New-Case 'wrong-build'
    $testState.ApplyInstall=$false
    Refused '版本或构建不匹配'
    if (!(Test-Path (Join-Path $testState.UpgradeRoot 'pending.json'))) { throw '构建不匹配未保留恢复记录' }
    New-Case 'unknown-version'
    [IO.File]::WriteAllText("$($testState.FakeApp)\program\product.txt",'27.2.0.1')
    Refused '未适配'
    if ($testState.Installs -or $testState.Downloads) { throw '未知版本自动降级或下载' }
    New-Case 'shared-build'
    [IO.File]::WriteAllText("$($testState.FakeApp)\program\product.txt",'26.2.6.1')
    [IO.File]::WriteAllText("$($testState.FakeApp)\program\version.ini",'buildid=d1ee4fa77ef37aa4cfa80ea6fd156dcae5d60263')
    $plan=& $upgrade -CheckOnly -LibreOfficePath $testState.FakeApp
    if ($plan.Current.Version -ne '26.2.6.1' -or $plan.Target.Version -ne '26.8.1.1') { throw '共用资源构建未按完整版本和构建选择兼容升级目标' }
    New-Case 'configuration-resume'
    $variant=Join-Path $bundle 'variants\26.8.1\ui\swriter\notebookbar.ui'
    [IO.File]::Move($variant,"$variant.saved")
    Refused 'notebookbar.ui'
    [IO.File]::Move("$variant.saved",$variant)
    Run-Upgrade
    if ($testState.Installs -ne 1 -or (Test-Path (Join-Path $testState.UpgradeRoot 'pending.json'))) { throw '界面配置失败后未继续配置或重复安装本体' }
    New-Case 'changed-modules'
    $testState.InstallExit=1603; $testState.ApplyInstall=$false
    Refused '1603'
    & $installer -Restore -Modules Calc -OnCheck { param($Result) }
    Refused '无法匹配的未完成升级记录'
    if ($testState.Installs -ne 1) { throw '模块恢复后继续安装并重建了已恢复的模块' }
    New-Case 'retention'
    $transactions=Join-Path $testState.UpgradeRoot 'transactions'
    foreach ($number in 1..3) {
        $ident=[guid]::NewGuid().ToString('N'); $folder=Join-Path $transactions $ident
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        @{Owner='LibreOfficePlus';Id=$ident;Status='Completed';CompletedAt="2026-01-0$($number)T00:00:00Z"} | ConvertTo-Json | Set-Content (Join-Path $folder 'record.json') -Encoding UTF8
    }
    New-Item -ItemType Directory -Path (Join-Path $transactions 'unknown') | Out-Null
    Run-Upgrade
    if (@(Get-ChildItem $transactions -Directory | Where-Object { $_.Name -match '^[0-9a-f]{32}$' }).Count -ne 2 -or !(Test-Path (Join-Path $transactions 'unknown'))) { throw '已完成备份保留或未知文件保护不正确' }
    New-Case 'manifest-mismatch'
    $targets[0].BuildId='0000000000000000000000000000000000000000'
    ConvertTo-Json -InputObject @($targets) | Set-Content (Join-Path $bundle 'upgrade-targets.json') -Encoding UTF8
    Refused '清单与本包兼容版本不一致'
    if ($testState.Installs -or $testState.Downloads) { throw '未适配目标触发安装' }
    Write-Host '通过：兼容预检、离线缓存、哈希与签名拒绝、运行中阻止、升级重试、重启继续、完整构建核验、模块沿用与首次备份保护。'
} finally { $env:APPDATA=$previousAppData; $env:LOCALAPPDATA=$previousLocalAppData }
