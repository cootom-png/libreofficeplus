function Get-LibreOfficeProcesses([string]$LibreOfficePath) {
    $roots = @($LibreOfficePath, (Join-Path $env:APPDATA 'LibreOffice'), (Join-Path $env:LOCALAPPDATA 'LibreOffice'))
    foreach ($process in @(Get-Process -Name 'soffice','soffice.bin','updater' -ErrorAction SilentlyContinue)) {
        $name = if ($process.ProcessName) { $process.ProcessName } else { $process.Name }
        if ($name -ne 'updater') { $process; continue }
        try { $path = $process.Path } catch { $path = $null }
        # 路径不可读时保守停止；路径明确属于其他应用的同名更新器不应拦截。
        if (!$path) { $process; continue }
        $path = [IO.Path]::GetFullPath($path)
        foreach ($root in $roots) {
            $prefix = [IO.Path]::GetFullPath($root).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
            if ($path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { $process; break }
        }
    }
}

function Format-LibreOfficeProcesses($Processes) {
    (@($Processes) | ForEach-Object {
        $name = if ($_.ProcessName) { $_.ProcessName } else { $_.Name }
        $idText = if ($_.Id) { $_.Id } else { '未知' }
        try { $path = $_.Path } catch { $path = $null }
        if (!$path) { $path = '路径无法读取，尚不能排除 LibreOffice 更新程序' }
        "$name（PID $idText，$path）"
    }) -join '；'
}
