# Squirrel Voice

**给 macOS 鼠须管 / Rime 加上本地语音输入。**

Squirrel Voice 是一个独立的 macOS 输入法，基于 Rime Squirrel，并加入了本地语音转文字。语音识别直接在 Mac 上运行，不需要云端接口，也不需要一直开着 LM Studio。

- 本地运行，语音不会上传到云端
- 使用 `llama.cpp + Metal`
- 支持本地流式语音输入
- 支持连续长时间语音输入，内部会自动滚动分段，不需要手动停下来
- 与官方 Squirrel 可以同时安装
- 已使用 Apple Developer ID 签名并通过 Apple notarization

## 安装

目前支持 **Apple Silicon Mac（M1 / M2 / M3 / M4 / M5…）**，建议 macOS 13 或更新版本。

### 方法一：Homebrew（推荐）

打开终端，依次执行：

```bash
brew tap iihciyekub/squirrel-voice https://github.com/iihciyekub/squirrel-voice.git
brew trust iihciyekub/squirrel-voice
brew install --cask squirrel-voice
```

安装完成后：

1. 打开 **系统设置 → 键盘 → 文本输入 → 编辑**。
2. 点击 `+`，找到并添加 **Squirrel Voice**。
3. 切换到 **Squirrel Voice** 输入法。

如果刚安装后列表里还没有出现，退出登录一次再进入即可。

以后升级：

```bash
brew update
brew upgrade --cask squirrel-voice
```

### 方法二：手动安装

1. 打开 [Releases](https://github.com/iihciyekub/squirrel-voice/releases)。
2. 下载最新的 `SquirrelVoice-*-arm64.zip`。
3. 解压后把 **Squirrel Voice.app** 放到 `~/Library/Input Methods/`。
4. 按上面的步骤，在系统设置里添加 **Squirrel Voice**。

## 准备语音模型

模型不会包含在安装包里，需要单独下载一次。

推荐模型：

[NetEase Youdao Confucius4-R2T2-GGUF](https://huggingface.co/netease-youdao/Confucius4-R2T2-GGUF)

最简单的方法是用 **LM Studio** 下载：

- `Confucius4-R2T2-Q4_K_M.gguf`
- `mmproj-Confucius4-R2T2-f16.gguf`（或 Q8_0 版本）

Squirrel Voice 会自动扫描 LM Studio 默认模型目录，**识别时不需要启动 LM Studio**。

也可以点击语音 HUD 里的模型图标，打开 **语音输入设置**，手动选择模型所在目录。

## 使用

切换到 Squirrel Voice 后：

- `Command + Shift + Space`：开始 / 停止语音输入
- HUD 中的模型图标：打开语音模型设置
- HUD 中的 `×`：立即停止语音输入

你可以连续说很久。Squirrel Voice 会在后台自动把长语音分成小段处理，麦克风不会因为分段而停止。

## 隐私

识别过程全部在本机完成。除非你自己下载模型或更新软件，正常语音输入不需要网络连接。

## 开源与许可

Squirrel Voice 基于 [Rime Squirrel](https://github.com/rime/squirrel) 修改，项目按 GPLv3 发布。第三方组件和模型仍遵循各自的许可证；模型文件不由本项目重新分发。

开发、构建和 GitHub Actions 发布说明见 [DEVELOPMENT.md](DEVELOPMENT.md)。
