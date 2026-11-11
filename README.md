# Cube Chat · OTA 通道

Android 客户端从这里读 `android.json`：按 `versionCode` 判断是否有新版本，下载同仓库的 APK 并校验 `sha256`。

清单结构（与 DSH Pocket 同构，便于两端共用同一套发布习惯）：

```json
{
  "version": "0.1.0",
  "versionCode": 1,
  "size": 1234567,
  "url": "https://github.com/ctomall/cube-chat-updates/releases/download/v0.1.0/cube-chat-0.1.0.apk",
  "fallback": "https://dsh.ila3.top/demo/cube-chat/cube-chat-0.1.0.apk",
  "sha256": "<64 hex>",
  "notes": ["首个版本"]
}
```

发布：

```bash
./release.sh 0.1.0 path/to/cube-chat-0.1.0.apk "首发"
```

`release.sh` 会核对 APK 内部 versionName/versionCode 与入参一致、计算 sha256、写清单、提交并推送。
首次发布前没有 `android.json`，客户端把 404 视为「无更新」，不报错。
