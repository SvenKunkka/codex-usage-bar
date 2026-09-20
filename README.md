# Codex Usage Bar

[![Build and test](https://github.com/SvenKunkka/codex-usage-bar/actions/workflows/build.yml/badge.svg)](https://github.com/SvenKunkka/codex-usage-bar/actions/workflows/build.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A lightweight, native macOS menu bar app that displays your remaining Codex usage.

一款轻量的原生 macOS 菜单栏工具，用于显示 Codex 剩余用量。

## Features / 功能

- Shows the remaining percentage directly in the macOS menu bar
- Lists all available quota windows and their reset times
- Refreshes every five minutes, with a manual refresh option
- Optional launch at login
- Reuses the local Codex login without reading or storing account tokens

---

- 在 macOS 顶部菜单栏直接显示剩余用量百分比
- 下拉查看所有额度窗口和重置时间
- 每五分钟自动刷新，也支持手动刷新
- 可选登录时启动
- 复用本机 Codex 登录，不读取或保存账号令牌

## Requirements / 系统要求

- macOS 13 or later
- Codex CLI or the Codex app installed and signed in

## Build / 构建

```bash
./scripts/test.sh
./scripts/build-app.sh
```

The app bundle is generated at:

```text
dist/Codex Usage Bar.app
```

Move the app to `/Applications`, open it once, and look for `Codex 83%`-style text in the menu bar. The percentage is dynamic and reflects the currently preferred quota window.

构建后将 App 移动到“应用程序”文件夹并打开。它不会显示在 Dock，只会常驻顶部菜单栏。

## How it works / 工作原理

The app starts the locally installed Codex App Server over stdio and calls the official JSON-RPC method `account/rateLimits/read`. Remaining usage is calculated as `100 - usedPercent`.

It does not access token files directly, copy credentials, consume reset credits, or modify Codex configuration.

应用通过本机 `codex app-server --stdio` 调用官方 `account/rateLimits/read` 方法。它不会直接读取令牌文件、复制凭据、消耗重置次数或修改 Codex 配置。

Official reference: [Codex App Server](https://developers.openai.com/codex/app-server/)

## Privacy / 隐私

All communication is between this app and the Codex process running locally on your Mac. No analytics or third-party network services are included in this project.

## License

[MIT](LICENSE)

## Disclaimer

This is an unofficial community project and is not affiliated with or endorsed by OpenAI. Codex and OpenAI are trademarks of their respective owners.
