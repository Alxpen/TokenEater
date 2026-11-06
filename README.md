# TokenEater

macOS 桌面小组件，用来看 **GPT（Codex）** 和 **Grok** 订阅还剩多少额度。显示的是当前时间窗口里的剩余百分比，以及何时重置，大约每分钟更新一次。

## 下载安装

需要 macOS 14 或更高版本。

1. 在本仓库下载 [`dist/TokenEater.dmg`](dist/TokenEater.dmg)。
2. 打开镜像，双击 **TokenEater**。
3. 应用会装进「应用程序」并打开。小组件出现在桌面右下角，普通窗口会盖住它，点一下桌面就能看到。

第一次从浏览器下载时，macOS 可能会拦住未签名的应用。在镜像里的 TokenEater 上右键，选择「打开」。

## 使用

- 拖动卡片可以挪位置，位置会记住。
- 双击刷新。
- 右键可以刷新、切换账号、让卡片浮在窗口上方，或退出。
- **设置…** 里可以开关开机自启动。默认打开，下次登录这台 Mac 时会自动出现。

切换 GPT 账号会打开 OpenAI 的官方登录页。新账号登录完成前，仍显示当前账号的额度。切换 Grok 账号会打开 Grok Bot，在里面登录或换账号后，小组件会读到新的额度。还没有登录时，第一次读取也会打开对应的登录。

## 额度从哪里来

| 订阅 | 条件 | 读到的内容 |
| --- | --- | --- |
| GPT | 本机已用 Codex CLI 登录（`codex login`） | 每周或 5 小时窗口的剩余百分比、重置时间、当前账号 |
| Grok | 已登录 Grok Bot，或已用 `grok` 登录 | Grok Bot 的每周额度；若存在 `~/.grok/auth.json`，则改读 Grok 订阅额度 |

这些订阅按时间窗口限流，官方不提供「还剩多少 token」的绝对数字。

登录状态只留在本机：GPT 走 Codex 已经保存的登录，Grok 读取 Grok Bot 或 Grok CLI 已有的会话。TokenEater 不另存一份 token，也不把登录信息发到别的地方。

## 从源码构建

```bash
./scripts/build.sh
open dist/TokenEater.dmg
```

构建需要 Xcode 命令行工具。产物是 `dist/TokenEater.dmg`。
