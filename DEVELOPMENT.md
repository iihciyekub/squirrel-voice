# Squirrel Voice 开发说明

普通用户请看 [README.md](README.md)。

## 本地构建

```bash
./build.sh
./scripts/build-squirrel.sh
./scripts/smoke-test.sh
```

本地安装：

```bash
./scripts/install-local.sh
```

## 安装初始化

Squirrel Voice 是独立输入法，不要求系统预装官方 Squirrel。`Squirrel Voice --install` 是统一初始化入口：首次安装会注册输入源、等待 TIS 刷新并启用默认模式，但不会强行切走用户当前正在使用的输入法；迁移或升级时如果 macOS 已恢复 Hans/Hant，则保留现有模式选择。

Homebrew Cask 的 `postflight` 调用同一个 `--install`，随后刷新 `TextInputMenuAgent`。卸载前会禁用 Squirrel Voice 输入源。

## 产品身份

- App：`Squirrel Voice.app`
- Bundle ID：`im.rime.inputmethod.SquirrelVoice`
- Input Source ID：`im.rime.inputmethod.SquirrelVoice`
- 用户 Rime 配置：继续使用 `~/Library/Rime`

Squirrel Voice 与官方 `Squirrel.app` 可以并存。

## GitHub Actions

`Verify`：每次 push / PR 在干净的 Apple Silicon macOS Runner 上构建并验证。

`Release`：推送 `v*` tag 后自动：

1. 导入 Developer ID Application 证书。
2. 构建并签名 `Squirrel Voice.app`。
3. 使用 App Store Connect API Key 提交 Apple notarization。
4. staple 公证票据并做 Gatekeeper 校验。
5. 生成 ZIP、SHA256 和 Homebrew Cask。
6. 创建 GitHub Release。
7. 把最新 Cask 写回 `Casks/squirrel-voice.rb`，供 Homebrew tap 使用。

Release 使用 GitHub Environment：`production-release`。

必需 secrets：

- `MAC_CSC_P12_BASE64`
- `MAC_CSC_KEY_PASSWORD`
- `APPLE_API_KEY_P8_BASE64`
- `APPLE_API_KEY_ID`
- `APPLE_API_ISSUER`

变量：

- `MAC_CSC_NAME=Yongjian Li (2NLAH5MYH8)`

可选 PKG secrets：

- `MAC_INSTALLER_P12_BASE64`
- `MAC_INSTALLER_P12_PASSWORD`

没有 Developer ID Installer 证书时，ZIP/Homebrew 发布仍然完整可用，只跳过 PKG。

## 版本

版本号保存在 `VERSION`。发布前修改版本并提交，然后推送同名 tag，例如：

```bash
printf '0.1.1\n' > VERSION
git tag -a v0.1.1 -m 'Squirrel Voice 0.1.1'
git push origin main v0.1.1
```

## 长语音

实时输入不会无限累计整段音频。当前策略：

- 5 秒后优先在约 300 ms 的自然停顿处分段；
- 8 秒后遇到约 100 ms 短间隙即可分段；
- 12 秒为硬上限；
- 分段只重置 ASR 内部状态，不停止麦克风或用户会话。

60.66 秒重复语音回归测试可以完整处理，实测处理时间约 39.5 秒。

## 推荐模型下载

`SquirrelVoiceModelDownloadManager` 使用原生 `URLSessionDownloadTask` 直接从官方 Hugging Face 仓库下载经过验证的 Q4_K_M 主模型和 F16 mmproj。

- 保存目录：`~/Library/Application Support/Squirrel Voice/Models/`
- 支持进度、速度、取消和断点续传
- 下载完成后检查 GGUF 文件头并自动扫描/选中
- LM Studio 和自定义目录仍保留为备用模型来源
