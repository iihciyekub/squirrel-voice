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

Squirrel Voice 是独立输入法，不要求系统预装官方 Squirrel。正常输入法进程启动不会注册、启用、禁用或切换 TIS 输入源。`--install` / `--enable-input-source` / `--disable-input-source` / `--select-input-source` 仅保留给开发和诊断使用。

公开 Homebrew Cask 只负责把 `Squirrel Voice.app` 安装到 `~/Library/Input Methods`。用户在系统设置里添加一次输入法即可；安装和升级过程中不主动修改当前 macOS 输入源状态。

本地更新先在输入法目录外准备并验证完整程序，再使用 `renamex_np(RENAME_SWAP)` 原子交换 `Contents`。安装路径及其 `Info.plist`、可执行文件始终存在；不能通过先删除 `Contents` 再复制来更新。更新前保存实际 TIS 启用模式与选择状态，更新后检查并恢复被系统丢失的状态，验证失败会交换回原程序。备份保存在 `~/Library/Application Support/Squirrel Voice/Legacy Backups`。

输入源排障应同时检查 TIS 和持久化配置。macOS 27.2 实机上，第三方输入源保存于 `com.apple.inputsources` 的 `AppleEnabledThirdPartyInputSources`；仅检查 `com.apple.HIToolbox` 的 `AppleEnabledInputSources` 会误判。重加输入源可以通过系统设置完成，无需重置整个键盘配置。

`SQUIRREL_VOICE_APP="/path/to/Squirrel Voice.app" ./scripts/install-local.sh` 可以安装指定的已签名程序。更新路径的原子性与回滚测试：`./scripts/test-atomic-install.sh`。

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
