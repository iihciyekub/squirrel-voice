# Squirrel Voice

**一个独立的 macOS Rime 输入法，内置本地语音输入。**

Squirrel Voice 基于 Rime Squirrel，并加入了完全在 Mac 本机运行的语音转文字。

**不需要提前安装 Squirrel / 鼠须管，也不需要安装 LM Studio。**

- Apple Silicon 原生运行
- `llama.cpp + Metal`
- 本地流式语音输入
- 支持连续长时间语音输入
- 语音不会上传到云端
- 已使用 Apple Developer ID 签名并通过 Apple notarization

## 安装

支持 **Apple Silicon Mac（M1 / M2 / M3 / M4 / M5…）**，建议 macOS 13 或更新版本。

### Homebrew（推荐）

打开终端，依次执行：

```bash
brew tap iihciyekub/squirrel-voice https://github.com/iihciyekub/squirrel-voice.git
brew trust iihciyekub/squirrel-voice
brew install --cask squirrel-voice
```

安装完成后，Squirrel Voice 会自动注册并启用输入法。

然后从菜单栏输入法菜单切换到 **Squirrel Voice** 即可。

如果菜单栏没有马上刷新，打开一次 **系统设置 → 键盘 → 文本输入**，或者重新登录 macOS 即可。

以后升级：

```bash
brew update
brew upgrade --cask squirrel-voice
```

### 手动安装

1. 打开 [Releases](https://github.com/iihciyekub/squirrel-voice/releases)。
2. 下载最新的 `SquirrelVoice-*-arm64.zip`。
3. 解压后把 **Squirrel Voice.app** 放到 `~/Library/Input Methods/`。
4. 打开一次 **Squirrel Voice.app**。它会自动注册并启用输入法。

如果菜单栏没有马上出现，再打开一次 **系统设置 → 键盘 → 文本输入** 即可。

## 第一次使用：下载语音模型

切换到 **Squirrel Voice** 后，打开输入法菜单里的 **Voice Input Settings / 语音输入设置**。

点击：

```text
下载推荐模型
```

Squirrel Voice 会自动下载经过验证的本地模型：

- `Confucius4-R2T2-Q4_K_M.gguf`
- `mmproj-Confucius4-R2T2-f16.gguf`

总大小约 **1.75 GB**。

下载过程中会显示：

- 下载进度
- 已下载 / 总大小
- 下载速度
- 取消 / 继续下载
- 下载失败后的重试

下载完成后会自动扫描并选中模型，不需要再配置其它参数。

## 已经有模型？

如果你以前在 LM Studio 下载过 Confucius4-R2T2，可以在设置里点击 **扫描 LM Studio**，直接复用已有模型。

LM Studio 只是备用模型来源，**识别时不需要运行 LM Studio**。

也可以选择其它本地模型目录。

推荐模型页面：

[NetEase Youdao Confucius4-R2T2-GGUF](https://huggingface.co/netease-youdao/Confucius4-R2T2-GGUF)

## 使用

切换到 Squirrel Voice 后：

- `Command + Shift + Space`：开始 / 停止语音输入
- HUD 中的模型图标：打开语音模型设置
- HUD 中的 `×`：立即停止语音输入

可以连续长时间讲话。Squirrel Voice 会在后台自动滚动分段，避免语音越长越慢；分段不会停止麦克风，也不需要手动操作。

## 与官方 Squirrel 的关系

Squirrel Voice 自己已经包含运行所需的 Rime / Squirrel 组件，**不依赖官方 Squirrel.app**。

如果你的电脑已经安装官方 Squirrel，也可以保留；但为了避免两个输入法名称和设置入口混淆，建议普通用户只启用其中一个。

现有的 `~/Library/Rime` 配置可以继续使用。

## 隐私

识别过程全部在本机完成。除了下载模型或软件更新，正常语音输入不需要网络连接。

## 开源与许可

Squirrel Voice 基于 [Rime Squirrel](https://github.com/rime/squirrel) 修改，项目按 GPLv3 发布。第三方组件和模型仍遵循各自许可证；模型文件不由本项目重新分发。

开发、构建和 GitHub Actions 发布说明见 [DEVELOPMENT.md](DEVELOPMENT.md)。
