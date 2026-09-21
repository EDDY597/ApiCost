# ApiCost - multi-vendor quota/balance tray for Windows (PowerShell + WinForms). Zero install.
# Hover shows the selected vendor's quota/balance. Right-click: 刷新额度 / 设置 / 退出.

param([switch]$SelfTest)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$ErrorActionPreference = 'SilentlyContinue'
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:SettingsPath = Join-Path $script:Root 'apicost.settings.json'
$script:Timer = $null
$script:Notify = $null

$script:Vendors = @(
  @{ id = 'opencode'; label = 'OpenCode Go' },
  @{ id = 'commandcode'; label = 'Command Code' },
  @{ id = 'siliconflow'; label = 'SiliconFlow 硅基流动' },
  @{ id = 'deepseek'; label = 'DeepSeek 官方' }
)

function Get-Settings {
  $s = [ordered]@{
    vendor = 'opencode'
    refreshSeconds = 60
    keys = [ordered]@{ opencode = ''; commandcode = ''; siliconflow = ''; deepseek = '' }
  }
  if (Test-Path -LiteralPath $script:SettingsPath) {
    try {
      $raw = Get-Content -LiteralPath $script:SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($raw.vendor) { $s['vendor'] = [string]$raw.vendor }
      if ($raw.refreshSeconds) { $s['refreshSeconds'] = [int]$raw.refreshSeconds }
      foreach ($v in $script:Vendors) {
        if ($raw.keys -and $raw.keys.($v.id)) { $s['keys'][$v.id] = [string]$raw.keys.($v.id) }
      }
    } catch { }
  }
  return $s
}

function Save-Settings($s) {
  ($s | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $script:SettingsPath -Encoding UTF8
}

function Vendor-Label($id) {
  foreach ($v in $script:Vendors) { if ($v.id -eq $id) { return $v.label } }
  return $id
}

function Period-Label($p) {
  switch ($p) { 'rolling' { '5h' } 'weekly' { '周' } 'monthly' { '月' } default { $p } }
}

function Format-Reset($iso) {
  try {
    $d = [datetime]::Parse($iso).ToLocalTime()
    if ($d.Date -eq (Get-Date).Date) { return $d.ToString('HH:mm') }
    return $d.ToString('MM-dd HH:mm')
  } catch { return [string]$iso }
}

function Query-OpenCode($key) {
  $r = Invoke-RestMethod -Uri 'https://opencode.ai/zen/go/v1/usage' -Headers @{ Authorization = "Bearer $key" } -TimeoutSec 10
  $lines = @()
  foreach ($p in @('rolling', 'weekly', 'monthly')) {
    $w = $r.usage.$p
    if ($null -eq $w) { continue }
    if ($null -eq $w.percent -or $null -eq $w.resetsAt) { continue }
    $lines += ('{0} {1}% {2}' -f (Period-Label $p), (100 - [int]$w.percent), (Format-Reset $w.resetsAt))
  }
  return $lines
}

function Query-CommandCode($key) {
  $base = 'https://api.commandcode.ai'
  $h = @{ Authorization = "Bearer $key"; accept = 'application/json' }
  $who = Invoke-RestMethod -Uri "$base/alpha/whoami" -Headers $h -TimeoutSec 15
  $orgId = $null
  if ($who.org) { $orgId = $who.org.id }
  $q = if ($orgId) { '?orgId=' + $orgId } else { '' }
  $lines = @()
  try {
    $cred = Invoke-RestMethod -Uri ("$base/alpha/billing/credits" + $q) -Headers $h -TimeoutSec 15
    $c = $cred.credits
    if ($c) {
      $remaining = 0.0
      foreach ($f in @('monthlyCredits', 'purchasedCredits', 'freeCredits')) { if ($c.$f) { $remaining += [double]$c.$f } }
      $lines += ('余额 $' + ([math]::Round($remaining, 2)))
    }
    $wl = $cred.windowLimits
    foreach ($w in @(@('fiveHour', '5h'), @('weekly', '周'))) {
      $e = $wl.($w[0])
      if ($null -eq $e) { continue }
      if ($null -eq $e.cap -or [double]$e.cap -le 0) { continue }
      $pct = [math]::Round(([double]$e.used / [double]$e.cap) * 100)
      $lines += ('{0} {1}%' -f $w[1], $pct)
    }
  } catch { }
  if ($lines.Count -eq 0) {
    try {
      $sum = Invoke-RestMethod -Uri ("$base/alpha/usage/summary" + $q) -Headers $h -TimeoutSec 15
      if ($sum.totalCost -ne $null) { $lines += ('本月已用 $' + $sum.totalCost) }
    } catch { }
  }
  return $lines
}

function Query-SiliconFlow($key) {
  $r = Invoke-RestMethod -Uri 'https://api.siliconflow.cn/v1/user/info' -Headers @{ Authorization = "Bearer $key" } -TimeoutSec 10
  $lines = @()
  if ($r.data) {
    if ($r.data.totalBalance) { $lines += ('余额 ¥' + $r.data.totalBalance) }
    elseif ($r.data.balance) { $lines += ('余额 ¥' + $r.data.balance) }
  }
  return $lines
}

function Query-DeepSeek($key) {
  $r = Invoke-RestMethod -Uri 'https://api.deepseek.com/user/balance' -Headers @{ Authorization = "Bearer $key" } -TimeoutSec 10
  $lines = @()
  if ($r.balance_infos -and $r.balance_infos.Count -gt 0) {
    $info = $r.balance_infos[0]
    $cur = if ($info.currency -eq 'USD') { '$' } else { '¥' }
    $lines += ('余额 ' + $cur + $info.total_balance)
  }
  return $lines
}

function Get-Quota {
  $s = Get-Settings
  $id = $s.vendor
  $key = $s['keys'][$id]
  $header = Vendor-Label $id
  if (-not $key) { return @{ header = $header; lines = @('未配置 API Key（右键 设置）') } }
  try {
    switch ($id) {
      'opencode' { $lines = Query-OpenCode $key }
      'commandcode' { $lines = Query-CommandCode $key }
      'siliconflow' { $lines = Query-SiliconFlow $key }
      'deepseek' { $lines = Query-DeepSeek $key }
      default { $lines = @() }
    }
    if (-not $lines -or $lines.Count -eq 0) { return @{ header = $header; lines = @('无可用数据') } }
    return @{ header = $header; lines = $lines }
  } catch {
    $msg = [string]$_.Exception.Message
    if ($msg -match '401|403|Unauthorized|Forbidden') { $msg = 'API Key 无效或无权限' }
    elseif ($msg -match 'timed out|超时|deadline') { $msg = '请求超时' }
    else { $msg = '查询失败' }
    return @{ header = $header; lines = @($msg) }
  }
}

function Vendor-Short($id) {
  switch ($id) { 'opencode' { 'OC' } 'commandcode' { 'CC' } 'siliconflow' { 'SF' } 'deepseek' { 'DS' } default { 'AC' } }
}

function Build-Tooltip {
  $s = Get-Settings
  $q = Get-Quota
  $lines = @((Vendor-Short $s.vendor)) + @($q.lines)
  $text = $lines -join [Environment]::NewLine
  if ($text.Length -gt 63) { $text = $text.Substring(0, 63) }
  return $text
}

function New-ApiCostIcon {
  $custom = Join-Path $script:Root 'apicost.ico'
  if (Test-Path -LiteralPath $custom) {
    try { return (New-Object System.Drawing.Icon($custom)) } catch { }
  }
  $size = 32
  $bmp = New-Object System.Drawing.Bitmap($size, $size)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
  $g.Clear([System.Drawing.Color]::Transparent)
  $bg = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 11, 18, 32))
  $g.FillEllipse($bg, 1, 1, $size - 3, $size - 3)
  $ring = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 34, 197, 94), 1.5)
  $g.DrawEllipse($ring, 1, 1, $size - 3, $size - 3)
  $font = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
  $brush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 74, 222, 128))
  $fmt = New-Object System.Drawing.StringFormat
  $fmt.Alignment = [System.Drawing.StringAlignment]::Center
  $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
  $rect = New-Object System.Drawing.RectangleF(0, 0, $size, $size)
  $g.DrawString('$', $font, $brush, $rect, $fmt)
  $g.Dispose(); $bg.Dispose(); $ring.Dispose(); $font.Dispose(); $brush.Dispose()
  return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}

function Update-Tray {
  if ($script:Notify) { $script:Notify.Text = Build-Tooltip }
}

function Show-Settings {
  $cfg = Get-Settings
  $form = New-Object System.Windows.Forms.Form
  $form.Text = 'ApiCost 设置'
  $form.StartPosition = 'CenterScreen'
  $form.FormBorderStyle = 'FixedDialog'
  $form.MaximizeBox = $false
  $form.MinimizeBox = $false
  $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

  $y = 12
  $grp = New-Object System.Windows.Forms.GroupBox
  $grp.Text = '供应商（单选）'
  $grp.Location = New-Object System.Drawing.Point(12, $y)
  $grp.Size = New-Object System.Drawing.Size(340, 112)
  $form.Controls.Add($grp)
  $iy = 22
  $rb = @{}
  foreach ($v in $script:Vendors) {
    $r = New-Object System.Windows.Forms.RadioButton
    $r.Text = $v.label
    $r.Location = New-Object System.Drawing.Point(14, $iy)
    $r.AutoSize = $true
    $r.Tag = $v.id
    if ($cfg.vendor -eq $v.id) { $r.Checked = $true }
    $grp.Controls.Add($r)
    $rb[$v.id] = $r
    $iy += 22
  }
  $y += 122

  $kb = @{}
  foreach ($v in $script:Vendors) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $v.id
    $l.Location = New-Object System.Drawing.Point(14, ($y + 3))
    $l.AutoSize = $true
    $form.Controls.Add($l)
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location = New-Object System.Drawing.Point(120, $y)
    $t.Width = 232
    $t.Text = [string]$cfg['keys'][$v.id]
    $form.Controls.Add($t)
    $kb[$v.id] = $t
    $y += 28
  }
  $y += 8

  $ok = New-Object System.Windows.Forms.Button
  $ok.Text = '保存'; $ok.Location = New-Object System.Drawing.Point(190, $y); $ok.Width = 80
  $cancel = New-Object System.Windows.Forms.Button
  $cancel.Text = '取消'; $cancel.Location = New-Object System.Drawing.Point(276, $y); $cancel.Width = 76
  $form.Controls.Add($ok); $form.Controls.Add($cancel)

  $cancel.Add_Click({ $form.Close() })
  $ok.Add_Click({
    $sel = 'opencode'
    foreach ($v in $script:Vendors) { if ($rb[$v.id].Checked) { $sel = $v.id } }
    $keys = [ordered]@{ opencode = ''; commandcode = ''; siliconflow = ''; deepseek = '' }
    foreach ($v in $script:Vendors) { $keys[$v.id] = $kb[$v.id].Text.Trim() }
    $s = [ordered]@{ vendor = $sel; refreshSeconds = [int]$cfg.refreshSeconds; keys = $keys }
    Save-Settings $s
    Update-Tray
    $form.Close()
  })

  $form.ClientSize = New-Object System.Drawing.Size(364, ($y + 46))
  $form.ShowDialog() | Out-Null
  $form.Dispose()
}

if ($SelfTest) {
  Write-Output ('root=' + $script:Root)
  $s = Get-Settings
  Write-Output ('vendor=' + $s.vendor)
  Write-Output ('hasKey=' + [bool]($s['keys'][$s.vendor]))
  Write-Output ('tooltip=' + (Build-Tooltip))
  Write-Output ('icon=' + (New-ApiCostIcon).Size)
  exit 0
}

$script:Created = $false
$script:Mutex = New-Object System.Threading.Mutex($true, 'Local\ApiCostTraySingleton', [ref]$script:Created)
if (-not $script:Created) { exit 0 }

$script:Notify = New-Object System.Windows.Forms.NotifyIcon
$script:Notify.Icon = New-ApiCostIcon
$script:Notify.Visible = $true
$script:Notify.Text = 'ApiCost'

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miRefresh = $menu.Items.Add('刷新额度')
$miSettings = $menu.Items.Add('设置')
$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$miExit = $menu.Items.Add('退出')
$miRefresh.Add_Click({ Update-Tray })
$miSettings.Add_Click({ Show-Settings })
$miExit.Add_Click({
  $script:Notify.Visible = $false
  [System.Windows.Forms.Application]::ExitThread()
})
$script:Notify.ContextMenuStrip = $menu

Update-Tray

$set = Get-Settings
$script:Timer = New-Object System.Windows.Forms.Timer
$script:Timer.Interval = [int]$set.refreshSeconds * 1000
$script:Timer.Add_Tick({ Update-Tray })
$script:Timer.Start()

$ctx = New-Object System.Windows.Forms.ApplicationContext
[System.Windows.Forms.Application]::Run($ctx)
$script:Notify.Visible = $false
$script:Notify.Dispose()
