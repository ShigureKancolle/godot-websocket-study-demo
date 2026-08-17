# ============================================================================
# gen_review_diff.ps1
# 作用: 生成「本次所有未提交改动」的 TortoiseMerge 图形化 diff 对比脚本
#
# 背景: 项目是多个独立 git 仓库(server/client/docs/shared_config/tools),
#       没有统一的 git 根,普通 diff 工具看不到全貌。
#       TortoiseSVN 自带的 TortoiseMerge.exe 是不依赖 SVN 的独立 diff 查看器,
#       可以对比任意两个文件(左=改前 HEAD 版本, 右=当前工作区)。
#
# 用法: 双击 tools/生成diff对比.bat(入口, 内部调用本脚本), 或:
#       powershell -NoProfile -ExecutionPolicy Bypass -File tools\gen_review_diff.ps1
#
# 输出: temp\review_diff\对比.bat —— 双击后逐个打开 TortoiseMerge 窗口,
#       关掉一个自动开下一个; 新文件(无改前版本)最后统一列清单。
# ============================================================================
$ErrorActionPreference = 'Stop'

# --- 控制台编码锁定为 GBK(936) --------------------------------------------
# .bat 入口已 chcp 936; 这里再锁 PS 的控制台编码, 保证传给 cmd 的命令行
# (含中文文件名, 如 生成diff对比.bat / 开发指南.md) 编码一致, 否则 cmd 解析
# 命令行会出现"文件名、目录名或卷标语法不正确"。
try { [Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding(936) } catch { }
try { [Console]::InputEncoding  = [System.Text.Encoding]::GetEncoding(936) } catch { }

# --- 配置 ---------------------------------------------------------------
$root = Split-Path $PSScriptRoot -Parent          # 项目根 D:\work2\godot_demo
$repos = @('server', 'client', 'docs', 'shared_config', 'tools')
$tm = 'C:\Program Files\TortoiseSVN\bin\TortoiseMerge.exe'
$outDir = Join-Path $root 'temp\review_diff'
$baseDir = Join-Path $outDir 'base'

if (-not (Test-Path $tm)) {
    Write-Host "ERROR: TortoiseMerge not found: $tm" -ForegroundColor Red
    Write-Host 'Please install TortoiseSVN (or change $tm at top of this script).'
    exit 1
}

# --- 收集改动 -----------------------------------------------------------
$changed = @()      # 有改前版本的修改文件
$untracked = @()    # 全新文件(无改前版本)

foreach ($repo in $repos) {
    $repoPath = Join-Path $root $repo
    if (-not (Test-Path (Join-Path $repoPath '.git'))) {
        Write-Host "skip (not a git repo): $repo"
        continue
    }

    # 修改文件(含已暂存+未暂存, 相对 HEAD)
    # core.quotepath=false: 中文文件名不做 \ooo 转义, 否则路径处理错乱
    $tmp = Join-Path $env:TEMP "gen_review_diff_$PID.txt"
    cmd /c "git -c core.quotepath=false -C `"$repoPath`" diff HEAD --name-only > `"$tmp`" 2>nul"
    $modified = @()
    if (Test-Path $tmp) {
        # git 输出的文件名固定是 UTF-8, 显式按 UTF-8 读取, 不受控制台代码页影响
        $modified = [System.IO.File]::ReadAllLines($tmp, (New-Object System.Text.UTF8Encoding($false))) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    }
    foreach ($p in $modified) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        $p = $p.Trim()
        $target = Join-Path $baseDir "$repo\$p"
        New-Item -ItemType Directory -Force (Split-Path $target -Parent) | Out-Null
        # cmd 重定向保持字节级, 避免 PowerShell 管道改编码; 2>nul 在 cmd 层吞 stderr
        # (PS 5.1 中外部命令 stderr 即使 2>$null 在 EAP=Stop 下也会抛 NativeCommandError)
        cmd /c "git -c core.quotepath=false -C `"$repoPath`" show `"HEAD:$p`" > `"$target`" 2>nul"
        if (Test-Path $target) {
            $changed += , @{ repo = $repo; path = $p }
        }
    }

    # 全新文件(未跟踪, 无改前版本)
    $tmp = Join-Path $env:TEMP "gen_review_diff_$PID.txt"
    cmd /c "git -c core.quotepath=false -C `"$repoPath`" status --porcelain > `"$tmp`" 2>nul"
    if (Test-Path $tmp) {
        $untracked += [System.IO.File]::ReadAllLines($tmp, (New-Object System.Text.UTF8Encoding($false))) |
            Where-Object { $_.StartsWith('??') } |
            ForEach-Object { @{ repo = $repo; path = $_.Substring(3) } }
    }
}

# --- 生成对比 bat --------------------------------------------------------
$n = $changed.Count
$bat = New-Object System.Collections.Generic.List[string]
$bat.Add('@echo off')
$bat.Add('chcp 936 >nul')
$bat.Add('set TM=' + $tm)
$bat.Add('echo ================================================')
$bat.Add('echo  本次改动 diff 对比 (左=改前HEAD, 右=当前工作区)')
$bat.Add('echo  逐个打开, 看完关掉窗口自动下一个')
$bat.Add('echo ================================================')
$bat.Add('')

$i = 0
foreach ($f in $changed) {
    $i++
    $base = Join-Path $baseDir "$($f.repo)\$($f.path)"
    $mine = Join-Path $root "$($f.repo)\$($f.path)"
    $bat.Add("echo [$i/$n] $($f.repo) / $($f.path)")
    $bat.Add('"%TM%" /base:"' + $base + '" /mine:"' + $mine + '"')
    $bat.Add('pause >nul')
    $bat.Add('')
}

if ($untracked.Count -gt 0) {
    $bat.Add('echo ================================================')
    $bat.Add('echo  以下为全新文件(无改前版本, 请手动打开查看):')
    $bat.Add('echo ================================================')
    foreach ($f in $untracked) {
        $bat.Add("echo   $($f.repo) / $($f.path)")
    }
    $bat.Add('')
}

$bat.Add('echo 全部对比完成!')
$bat.Add('pause')

Remove-Item (Join-Path $env:TEMP ("gen_review_diff_$PID.txt")) -Force -ErrorAction SilentlyContinue
$batPath = Join-Path $outDir '对比.bat'
New-Item -ItemType Directory -Force $outDir | Out-Null
[System.IO.File]::WriteAllLines($batPath, $bat, [System.Text.Encoding]::GetEncoding(936))

# --- 汇总输出 -----------------------------------------------------------
Write-Host ''
Write-Host "Diff base exported to: $baseDir"
Write-Host "Generated: $batPath"
Write-Host "Modified files: $n"
Write-Host "Untracked (new) files: $($untracked.Count)"
foreach ($f in $untracked) { Write-Host "  - $($f.repo) / $($f.path)" }
Write-Host ''
Write-Host 'Double-click temp\review_diff\对比.bat to review with TortoiseMerge.'
