$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot) 'package/process-check.ps1')
$app = 'C:\Apps\LibreOffice'
function Get-Process { param($Name,$ErrorAction) $script:processFixture }
foreach ($case in @(
    @{Name='无进程';Processes=@();Expected=@()},
    @{Name='文档后台进程';Processes=@([pscustomobject]@{ProcessName='soffice.bin';Id=11;Path="$app\program\soffice.bin"});Expected=@(11)},
    @{Name='其他版本文档进程';Processes=@([pscustomobject]@{ProcessName='soffice';Id=12;Path='D:\OtherOffice\program\soffice.exe'});Expected=@(12)},
    @{Name='官方安装目录更新器';Processes=@([pscustomobject]@{ProcessName='updater';Id=21;Path="$app\program\updater.exe"});Expected=@(21)},
    @{Name='用户缓存更新器';Processes=@([pscustomobject]@{ProcessName='updater';Id=22;Path=(Join-Path $env:LOCALAPPDATA 'LibreOffice\updates\updater.exe')});Expected=@(22)},
    @{Name='用户配置更新器';Processes=@([pscustomobject]@{ProcessName='updater';Id=23;Path=(Join-Path $env:APPDATA 'LibreOffice\4\updates\updater.exe')});Expected=@(23)},
    @{Name='其他应用同名更新器';Processes=@([pscustomobject]@{ProcessName='updater';Id=31;Path='C:\Apps\OtherApp\updater.exe'});Expected=@()},
    @{Name='相似目录不误判';Processes=@([pscustomobject]@{ProcessName='updater';Id=32;Path='C:\Apps\LibreOfficeOther\updater.exe'});Expected=@()},
    @{Name='无法核验更新器路径';Processes=@([pscustomobject]@{ProcessName='updater';Id=41;Path=$null});Expected=@(41)}
)) {
    $script:processFixture = $case.Processes
    $actual = @(Get-LibreOfficeProcesses $app)
    if ((@($actual | ForEach-Object Id) -join ',') -ne ($case.Expected -join ',')) { throw "进程检查错误：$($case.Name)" }
    if ($actual.Count -and (Format-LibreOfficeProcesses $actual) -notmatch "PID $($actual[0].Id)") { throw '缺少实际阻止进程编号' }
    Write-Host "通过：$($case.Name)"
}
