# ============================================================================
# git_onekey.ps1
# 作用: 多 git 仓库一键操作(项目拆成 server/client/docs/shared_config/tools
#       5 个独立 git 仓库,都指向同一个 GitHub 仓库的不同分支)
#
# 功能菜单:
#   0) 生成 diff 对比 review(改完代码必做, 调 gen_review_diff.ps1)
#   1) 一键拉取 (5 仓库统一 pull --rebase, 不产生 merge commit)
#   2) 一键提交并推送 (逐仓库确认提交信息, 推送前先 pull --rebase)
#   3) 退出
#
# 用法: 双击 tools/git一键操作.bat(入口), 或:
#       powershell -NoProfile -ExecutionPolicy Bypass -File tools\git_onekey.ps1
#       命令行模式: -File tools\git_onekey.ps1 status / pull / review
# ============================================================================
$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
$repos = @('server', 'client', 'docs', 'shared_config', 'tools')

function Write-Info($msg)  { Write-Host $msg -ForegroundColor Cyan }
function Write-Ok($msg)    { Write-Host $msg -ForegroundColor Green }
function Write-Warn($msg)  { Write-Host $msg -ForegroundColor Yellow }
function Write-Err($msg)   { Write-Host $msg -ForegroundColor Red }

# ---------------------------------------------------------------------------
# 确保当前分支有 upstream(没有则自动配置到第一个 remote), 返回是否就绪
# ---------------------------------------------------------------------------
function Ensure-Upstream($repoPath) {
    git -C $repoPath rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { return $true }
    $branch = (git -C $repoPath rev-parse --abbrev-ref HEAD).Trim()
    $remote = (git -C $repoPath remote | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($remote)) {
        Write-Err "  [SKIP] $($repoPath) 没有任何 remote, 跳过"
        return $false
    }
    Write-Warn "  $repoPath 分支 '$branch' 没有 upstream, 自动配置 -> $remote/$branch"
    git -C $repoPath branch --set-upstream-to="$remote/$branch" $branch | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# ---------------------------------------------------------------------------
# 0) 生成 diff 对比 review
# ---------------------------------------------------------------------------
function Invoke-ReviewDiff {
    Write-Info '==> 生成 diff 对比 review...'
    powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'gen_review_diff.ps1')
    $bat = Join-Path $root 'temp\review_diff\对比.bat'
    if (Test-Path $bat) {
        Write-Ok "对比脚本已生成: $bat"
        $open = Read-Host '  立即用 TortoiseMerge 打开对比? (y/n)'
        if ($open -eq 'y') { Start-Process $bat }
    } else {
        Write-Warn '  没有可对比的改动(全部已提交?)'
    }
}

# ---------------------------------------------------------------------------
# 1) 一键拉取: 5 仓库统一 pull --rebase(用 rebase 取代 merge, 不产生 merge commit)
# ---------------------------------------------------------------------------
function Invoke-PullAll {
    Write-Info '==> 一键拉取 (pull --rebase)...'
    $failed = @()
    foreach ($repo in $repos) {
        $repoPath = Join-Path $root $repo
        if (-not (Test-Path (Join-Path $repoPath '.git'))) { continue }
        Write-Info "  [$repo] pull --rebase ..."
        if (-not (Ensure-Upstream $repoPath)) { $failed += $repo; continue }
        git -C $repoPath pull --rebase 2>&1 | ForEach-Object { Write-Host "    $_" }
        if ($LASTEXITCODE -ne 0) {
            Write-Err "  [$repo] 拉取失败(可能有冲突), 请手动处理: cd $repoPath && git status"
            $failed += $repo
        } else {
            Write-Ok "  [$repo] 已更新"
        }
    }
    if ($failed.Count -gt 0) {
        Write-Err "完成, 但以下仓库失败: $($failed -join ', ')"
        exit 1
    }
    Write-Ok '全部仓库已更新'
}

# ---------------------------------------------------------------------------
# 2) 一键提交并推送
# ---------------------------------------------------------------------------
function Invoke-CommitPush {
    Write-Info '==> 一键提交并推送...'
    $committed = @()

    # 先显示总览
    Write-Info '--- 各仓库未提交改动总览 ---'
    foreach ($repo in $repos) {
        $repoPath = Join-Path $root $repo
        if (-not (Test-Path (Join-Path $repoPath '.git'))) { continue }
        $cnt = (git -c core.quotepath=false -C $repoPath status --porcelain | Measure-Object).Count
        $color = if ($cnt -gt 0) { 'Yellow' } else { 'DarkGray' }
        Write-Host ("  [{0,-13}] {1} 个改动" -f $repo, $cnt) -ForegroundColor $color
    }

    # 逐仓库提交
    foreach ($repo in $repos) {
        $repoPath = Join-Path $root $repo
        if (-not (Test-Path (Join-Path $repoPath '.git'))) { continue }
        $status = git -c core.quotepath=false -C $repoPath status --porcelain
        if (-not $status) {
            Write-Info "  [$repo] 无改动, 跳过"
            continue
        }
        Write-Info "  [$repo] 改动清单:"
        $status | ForEach-Object { Write-Host "    $_" }
        $msg = Read-Host "  [$repo] 提交信息(直接回车=跳过该仓库)"
        if ([string]::IsNullOrWhiteSpace($msg)) {
            Write-Warn "  [$repo] 已跳过"
            continue
        }
        git -c core.quotepath=false -C $repoPath add -A
        git -C $repoPath commit -m $msg 2>&1 | ForEach-Object { Write-Host "    $_" }
        if ($LASTEXITCODE -ne 0) {
            Write-Err "  [$repo] 提交失败, 停止"
            exit 1
        }
        Write-Ok "  [$repo] 已提交: $msg"
        $committed += $repo
    }

    if ($committed.Count -eq 0) {
        Write-Warn '没有任何仓库被提交, 结束'
        return
    }

    # 推送
    $push = Read-Host "已提交 $($committed -join ', '), 是否推送? (y/n)"
    if ($push -ne 'y') { Write-Warn '已提交未推送, 结束'; return }

    $failed = @()
    foreach ($repo in $committed) {
        $repoPath = Join-Path $root $repo
        Write-Info "  [$repo] 推送前同步 (pull --rebase) ..."
        if (-not (Ensure-Upstream $repoPath)) { $failed += $repo; continue }
        git -C $repoPath pull --rebase 2>&1 | ForEach-Object { Write-Host "    $_" }
        if ($LASTEXITCODE -ne 0) {
            Write-Err "  [$repo] 推送前同步失败(冲突?), 停止推送, 请手动处理"
            $failed += $repo
            continue
        }
        git -C $repoPath push 2>&1 | ForEach-Object { Write-Host "    $_" }
        if ($LASTEXITCODE -ne 0) {
            Write-Err "  [$repo] 推送失败"
            $failed += $repo
        } else {
            Write-Ok "  [$repo] 已推送"
        }
    }
    if ($failed.Count -gt 0) {
        Write-Err "推送完成, 但以下仓库失败: $($failed -join ', ')"
        exit 1
    }
    Write-Ok '全部推送完成'
}

# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------
if ($args.Count -gt 0) {
    switch ($args[0]) {
        'status' {
            foreach ($repo in $repos) {
                $repoPath = Join-Path $root $repo
                if (-not (Test-Path (Join-Path $repoPath '.git'))) { continue }
                Write-Info "  [$repo]"
                git -c core.quotepath=false -C $repoPath status --short | ForEach-Object { Write-Host "    $_" }
            }
            exit 0
        }
        'review' { Invoke-ReviewDiff; exit 0 }
        'pull'   { Invoke-PullAll; exit 0 }
        default  { Write-Err "未知命令: $($args[0])"; exit 1 }
    }
}

# 交互菜单
while ($true) {
    Write-Host ''
    Write-Info '================ Git 一键操作 ================'
    Write-Host '  0) 生成 diff 对比 review (改完代码必做)'
    Write-Host '  1) 一键拉取 (pull --rebase, 5 仓库)'
    Write-Host '  2) 一键提交并推送'
    Write-Host '  3) 退出'
    Write-Info '==============================================='
    $choice = Read-Host '请选择'
    switch ($choice) {
        '0' { Invoke-ReviewDiff }
        '1' { Invoke-PullAll }
        '2' { Invoke-CommitPush }
        '3' { Write-Ok '再见'; break }
        default { Write-Warn '无效选择' }
    }
}
