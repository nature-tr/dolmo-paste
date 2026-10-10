# 上架 Mac App Store · 操作清单

本目录是上架专用，**不影响本地开发与 `dolmo-paste/build.sh`**。
上架版走独立的 `Info-AppStore.plist`（版本 1.0.0）+ `DolmoPaste.entitlements`（开沙盒）。

## 关键前提（不可跳过）

1. **开发者账号已付费**并已接受最新协议。
2. **App Store Connect 已建 App 记录**：套装 ID `top.dolmo.paste.app`，平台 macOS。
   若该 ID 已被占用，需先改 `Info-AppStore.plist` 与 `DolmoPaste.entitlements` 里的 Bundle ID。
3. **发布证书**：Xcode → Settings → Accounts → 选账号 → Manage Certificates → 添加
   - `Apple Distribution`（或 `3rd Party Mac Developer Application`）
   - `Mac Installer Distribution`（或 `3rd Party Mac Developer Installer`）
4. **描述文件**：Certificates, Identifiers & Profiles → Provisioning Profiles → Mac App Store，
   为 `top.dolmo.paste.app` 创建并下载，保存为 `AppStore/DolmoPaste.provisionprofile`。

> 脚本已能自动检测证书；缺证书时会直接告诉你去哪里加，不会静默失败。

## 步骤

```bash
# 1. 生成上架包（.app + .pkg）
./AppStore/build_appstore.sh
#   产出 AppStore/build/dolmo paste.app 与 AppStore/build/dolmo-paste.pkg

# 2. 上传
#   方式 A：Xcode → Open Developer Tool → Transporter，拖入 .pkg
#   方式 B：命令行（App Store Connect API Key）
xcrun altool --upload-app -f AppStore/build/dolmo-paste.pkg -t macos \
  --apiKey <AuthKey_XXX.p8> --apiIssuer <issuer-id>
```

3. App Store Connect 填表：照 `metadata.md` 逐项粘贴。
4. 上传截图：`screenshots/01–06.png`（2880×1800）。
5. 图标：`icon-1024.png`（1024×1024，ASC 只收 PNG 不收 icns）。
6. 提交审核 → 选 **Manual Release**（手动发布），处理完成后自己点发布。

## 待你补齐的三处

`metadata.md` 里标了 `<TODO>`：

- 隐私政策 URL（先把 `privacy.md` 发成网页；可用仓库 GitHub Pages）
- 支持 URL（可用 `https://github.com/nature-tr/dolmo-paste`）
- 版权持有人名称

## 已知审核风险（重要）

- **辅助功能权限**：本应用用它模拟 `⌘V` 直接粘贴，以及读取聚焦输入框位置来定位浮窗。
  MAS 审核在 **2.4.5 / 5.1.1** 条款下对这类权限一向严格，被拒概率偏高。
  `metadata.md` 第 7 节的审核备注已如实说明用途、降级方式和测试步骤。
- 若被拒，可选改法：上架版去掉模拟 `⌘V`，只写回剪贴板让用户自己按 `⌘V`，过审概率会高很多。
- 沙盒下数据会落到容器（`~/Library/Containers/top.dolmo.paste.app/`），
  当前 `ClipStore` 用的是 `~/Library/Application Support/dolmo-paste/`，
  沙盒内会自动重定向，功能不受影响，但**旧数据不会自动迁移过来**。

## 版本号注意

本地版本是 `0.6.0 (13)`，上架版 `Info-AppStore.plist` 用的是 `1.0.0 (1)`。
后续每次上传，**Build 号必须递增**，否则 ASC 会拒绝接收。
