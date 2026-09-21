# ApiCost

Windows 托盘小工具：**在托盘 hover 上显示所选 AI 供应商的额度 / 余额**。

零安装、零依赖（只用系统自带 PowerShell + WinForms），不需要 Node。

## 支持的供应商

| 供应商 | 接口 | 显示内容 |
|---|---|---|
| **OpenCode Go** | `GET https://opencode.ai/zen/go/v1/usage` | 5 小时 / 每周 / 每月 剩余百分比 + 重置时间 |
| **Command Code** | `GET https://api.commandcode.ai/alpha/*`（未公开 alpha） | 余额（credit）+ 5 小时 / 每周 用量百分比 |
| **SiliconFlow 硅基流动** | `GET https://api.siliconflow.cn/v1/user/info` | 余额 ¥（`totalBalance`） |
| **DeepSeek 官方** | `GET https://api.deepseek.com/user/balance` | 余额（`total_balance`） |

均为 `Authorization: Bearer <你的 API Key>`。

## 运行

双击 **`apicost-hidden.vbs`**（无窗口）。托盘出现后：

- **鼠标悬停** → 显示当前所选供应商的额度。
- **右键** → `刷新额度` / `设置` / `退出`。

想开机自启：把 `apicost-hidden.vbs` 的快捷方式放进 `Win+R` → `shell:startup`。

## 配置

右键 **设置** → 勾选（单选）一个供应商 → 在对应行填入它的 **API Key** → 保存。

- 钩哪个就用哪个；hover 显示该供应商的数据。
- 每个供应商的 Key 分别保存，切换供应商不用重填。
- 设置写入同目录的 `apicost.settings.json`。

```json
{
  "vendor": "opencode",
  "refreshSeconds": 60,
  "keys": {
    "opencode": "sk-...",
    "commandcode": "...",
    "siliconflow": "sk-...",
    "deepseek": "sk-..."
  }
}
```

首次没有配置时 hover 显示「未配置 API Key（右键 设置）」。

## 说明与限制

- **仅 Windows**（依赖 PowerShell + WinForms）。无需 Node。
- **Command Code 走未公开 alpha 接口**，可能随官方改动而失效；其余三家为公开接口。
- API Key **以明文存本地** `apicost.settings.json`（已在 `.gitignore` 中，勿提交）。
- 托盘提示文字受 Windows 限制（约 63 字符），内容会截断。
- 刷新间隔默认 60 秒（`refreshSeconds`）。
- 自定义图标：放 `apicost.ico` 到本目录即可覆盖默认图标。
- 已加单实例保护：重复启动不会出现多个托盘图标。

## 文件

```
apicost.ps1            # 托盘主程序（PowerShell）
apicost.cmd            # 带控制台启动（调试）
apicost-hidden.vbs     # 无窗口启动（推荐）
apicost.settings.json  # 本地配置（gitignore）
```

## 许可

MIT
