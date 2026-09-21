# LLM Gateway tray for Windows (PowerShell + WinForms). Zero install.
# Hover shows quota; right-click opens a small config dialog; it supervises the node gateway.

param([switch]$SelfTest)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$ErrorActionPreference = 'SilentlyContinue'
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:Root = if (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $script:Here) 'gateway.config.json')) { Split-Path -Parent $script:Here } else { $script:Here }
$script:ConfigPath = Join-Path $script:Root 'gateway.config.json'
$script:SettingsPath = Join-Path $script:Here 'tray.settings.json'
$script:NodeExe = (Get-Command node -ErrorAction SilentlyContinue).Source
$script:Timer = $null
$script:Notify = $null

function Get-Settings {
  $s = [ordered]@{ refreshSeconds = 60 }
  if (Test-Path -LiteralPath $script:SettingsPath) {
    try {
      $raw = Get-Content -LiteralPath $script:SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
      foreach ($k in @($s.Keys)) { if ($null -ne $raw.$k) { $s[$k] = $raw.$k } }
    } catch { }
  }
  return $s
}

function Save-Settings($s) {
  ($s | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $script:SettingsPath -Encoding UTF8
}

function Get-GatewayConfig {
  if (Test-Path -LiteralPath $script:ConfigPath) {
    return (Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json)
  }
  return $null
}

function Save-GatewayConfig($cfg) {
  ($cfg | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $script:ConfigPath -Encoding UTF8
}

function Get-Base {
  $cfg = Get-GatewayConfig
  $port = if ($cfg -and $cfg.port) { [int]$cfg.port } else { 8787 }
  return "http://127.0.0.1:$port"
}

function Test-Gateway {
  try { Invoke-RestMethod -Uri ((Get-Base) + '/health') -TimeoutSec 2 | Out-Null; return $true } catch { return $false }
}

function Get-Usage {
  try { return Invoke-RestMethod -Uri ((Get-Base) + '/api/usage') -TimeoutSec 10 } catch { return $null }
}

function Start-Gateway {
  if (Test-Gateway) { return $true }
  if (-not $script:NodeExe) { return $false }
  Start-Process -FilePath $script:NodeExe -ArgumentList ('"' + (Join-Path $script:Root 'src\standalone.ts') + '"') -WorkingDirectory $script:Root -WindowStyle Hidden | Out-Null
  for ($i = 0; $i -lt 24; $i++) { Start-Sleep -Milliseconds 250; if (Test-Gateway) { break } }
  return (Test-Gateway)
}

function Stop-Gateway {
  Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
    Where-Object { $_.CommandLine -like '*standalone.ts*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
}

function Restart-Gateway {
  Stop-Gateway
  Start-Sleep -Milliseconds 600
  Start-Gateway | Out-Null
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

function Build-Tooltip {
  if (-not (Test-Gateway)) { return 'LLM Gateway：未运行（右键启动）' }
  $u = Get-Usage
  if ($null -eq $u) { return 'LLM Gateway：额度读取失败' }
  if ((-not $u.entries -or $u.entries.Count -eq 0) -and $u.errors -and $u.errors.Count -gt 0) {
    return 'LLM Gateway：额度错误 ' + $u.errors[0].code
  }
  $entries = @($u.entries)
  $names = @($entries | Select-Object -ExpandProperty name -Unique)
  $header = if ($names.Count -eq 1) { [string]$names[0] } else { 'LLM Gateway' }
  $lines = @($header)
  foreach ($e in $entries) {
    $lines += ('{0} {1}% {2}' -f (Period-Label $e.period), [int]$e.remaining, (Format-Reset $e.resetAt))
  }
  $text = $lines -join [Environment]::NewLine
  if ($text.Length -gt 63) { $text = $text.Substring(0, 63) }
  return $text
}

function Add-Label($form, $text, $y) {
  $l = New-Object System.Windows.Forms.Label
  $l.Text = $text
  $l.Location = New-Object System.Drawing.Point(15, $y)
  $l.AutoSize = $true
  $form.Controls.Add($l)
  return ($y + 22)
}

function Show-Config {
  $cfg = Get-GatewayConfig
  $set = Get-Settings
  if ($null -eq $cfg) {
    [System.Windows.Forms.MessageBox]::Show('找不到 gateway.config.json', 'LLM Gateway')
    return
  }

  $form = New-Object System.Windows.Forms.Form
  $form.Text = 'LLM Gateway 配置'
  $form.ClientSize = New-Object System.Drawing.Size(360, 400)
  $form.StartPosition = 'CenterScreen'
  $form.FormBorderStyle = 'FixedDialog'
  $form.MaximizeBox = $false
  $form.MinimizeBox = $false
  $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

  $y = 15
  $y = Add-Label $form '端口 (port)' $y
  $portBox = New-Object System.Windows.Forms.TextBox
  $portBox.Location = New-Object System.Drawing.Point(15, $y); $portBox.Width = 320
  $portBox.Text = [string]$cfg.port
  $form.Controls.Add($portBox); $y += 30

  $y = Add-Label $form '额度刷新间隔（秒）' $y
  $num = New-Object System.Windows.Forms.NumericUpDown
  $num.Location = New-Object System.Drawing.Point(15, $y); $num.Width = 100
  $num.Minimum = 10; $num.Maximum = 3600; $num.Value = [int]$set['refreshSeconds']
  $form.Controls.Add($num); $y += 30

  $pf = New-Object System.Windows.Forms.CheckBox
  $pf.Text = '强制参数兜底 (paramFallback)'; $pf.Location = New-Object System.Drawing.Point(15, $y); $pf.AutoSize = $true
  $allPf = $true
  foreach ($u in @($cfg.upstreams)) { if ($u.paramFallback -eq $false) { $allPf = $false } }
  $pf.Checked = $allPf; $form.Controls.Add($pf); $y += 28

  $y = Add-Label $form '上游与 API Key' $y
  $upChk = @()
  $upKey = @()
  $upId = @()
  foreach ($u in @($cfg.upstreams)) {
    $cb = New-Object System.Windows.Forms.CheckBox
    $cb.Text = [string]$u.id
    $cb.Location = New-Object System.Drawing.Point(15, $y)
    $cb.AutoSize = $true
    $cb.Checked = ($u.enabled -ne $false)
    $form.Controls.Add($cb); $y += 24

    $kl = New-Object System.Windows.Forms.Label
    $kl.Text = 'API Key'; $kl.Location = New-Object System.Drawing.Point(32, ($y + 3)); $kl.AutoSize = $true
    $form.Controls.Add($kl)

    $kb = New-Object System.Windows.Forms.TextBox
    $kb.Location = New-Object System.Drawing.Point(95, $y); $kb.Width = 260
    $kb.Text = [string]$u.apiKey
    $form.Controls.Add($kb); $y += 32

    $upChk += $cb
    $upKey += $kb
    $upId += [string]$u.id
  }
  $y += 4

  $ok = New-Object System.Windows.Forms.Button
  $ok.Text = '保存并重启'; $ok.Location = New-Object System.Drawing.Point(180, $y); $ok.Width = 90
  $cancel = New-Object System.Windows.Forms.Button
  $cancel.Text = '取消'; $cancel.Location = New-Object System.Drawing.Point(280, $y); $cancel.Width = 60
  $form.Controls.Add($ok); $form.Controls.Add($cancel)

  $cancel.Add_Click({ $form.Close() })
  $ok.Add_Click({
    $newPort = 0
    if (-not [int]::TryParse($portBox.Text.Trim(), [ref]$newPort)) {
      [System.Windows.Forms.MessageBox]::Show('端口必须是数字', 'LLM Gateway')
      return
    }
    $cfg.port = $newPort
    for ($i = 0; $i -lt $upId.Count; $i++) {
      foreach ($u in @($cfg.upstreams)) {
        if ([string]$u.id -eq $upId[$i]) {
          $u.enabled = [bool]$upChk[$i].Checked
          $u.apiKey = $upKey[$i].Text.Trim()
        }
      }
    }
    foreach ($u in @($cfg.upstreams)) { $u.paramFallback = [bool]$pf.Checked }
    Save-GatewayConfig $cfg
    $s = Get-Settings
    $s['refreshSeconds'] = [int]$num.Value
    Save-Settings $s
    if ($script:Timer) { $script:Timer.Interval = [int]$num.Value * 1000 }
    Restart-Gateway
    Update-Tray
    $form.Close()
  })

  $form.ClientSize = New-Object System.Drawing.Size(370, ($y + 54))
  $form.ShowDialog() | Out-Null
  $form.Dispose()
}

function Update-Tray {
  if ($script:Notify) { $script:Notify.Text = Build-Tooltip }
}

function New-GatewayIcon {
  $custom = Join-Path $script:Here 'tray.ico'
  if (Test-Path -LiteralPath $custom) {
    try { return (New-Object System.Drawing.Icon($custom)) } catch { }
  }
  $size = 32
  $bmp = New-Object System.Drawing.Bitmap($size, $size)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.Clear([System.Drawing.Color]::Transparent)
  $bg = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 11, 18, 32))
  $g.FillEllipse($bg, 1, 1, $size - 3, $size - 3)
  $ring = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 34, 197, 94), 1.5)
  $g.DrawEllipse($ring, 1, 1, $size - 3, $size - 3)
  $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 74, 222, 128), 3)
  $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
  $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
  $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
  $chevron = @(
    (New-Object System.Drawing.Point(11, 9)),
    (New-Object System.Drawing.Point(16, 16)),
    (New-Object System.Drawing.Point(11, 23))
  )
  $g.DrawLines($pen, $chevron)
  $g.DrawLine($pen, 18, 23, 24, 23)
  $g.Dispose(); $bg.Dispose(); $ring.Dispose(); $pen.Dispose()
  return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}

if ($SelfTest) {
  Write-Output ('root=' + $script:Root)
  Write-Output ('node=' + $script:NodeExe)
  Write-Output ('base=' + (Get-Base))
  Write-Output ('gateway=' + (Test-Gateway))
  Write-Output ('tooltip=' + (Build-Tooltip))
  Write-Output ('icon=' + (New-GatewayIcon).Size)
  exit 0
}

$script:Notify = New-Object System.Windows.Forms.NotifyIcon
$script:Notify.Icon = New-GatewayIcon
$script:Notify.Visible = $true
$script:Notify.Text = 'LLM Gateway'

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miConfig = $menu.Items.Add('打开配置…')
$miRefresh = $menu.Items.Add('刷新额度')
$miStart = $menu.Items.Add('启动网关')
$miStop = $menu.Items.Add('停止网关')
$miRestart = $menu.Items.Add('重启网关')
$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$miExit = $menu.Items.Add('退出')

$miConfig.Add_Click({ Show-Config })
$miRefresh.Add_Click({ Update-Tray })
$miStart.Add_Click({ Start-Gateway | Out-Null; Update-Tray })
$miStop.Add_Click({ Stop-Gateway; Update-Tray })
$miRestart.Add_Click({ Restart-Gateway; Update-Tray })
$miExit.Add_Click({
  Stop-Gateway
  $script:Notify.Visible = $false
  [System.Windows.Forms.Application]::ExitThread()
})
$script:Notify.ContextMenuStrip = $menu
$script:Notify.Add_DoubleClick({ Show-Config })

$set = Get-Settings
Start-Gateway | Out-Null
Update-Tray

$script:Timer = New-Object System.Windows.Forms.Timer
$script:Timer.Interval = [int]$set['refreshSeconds'] * 1000
$script:Timer.Add_Tick({ Update-Tray })
$script:Timer.Start()

$ctx = New-Object System.Windows.Forms.ApplicationContext
[System.Windows.Forms.Application]::Run($ctx)
$script:Notify.Visible = $false
$script:Notify.Dispose()
