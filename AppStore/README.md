# 上架 Mac App Store · 操作清单

本目录是上架专用，**不影响本地开发与 `dolmo-paste/build.sh`**。
上架版走独立的 `Info-AppStore.plist`（版本 1.0.0）+ `DolmoPaste.entitlements`（开沙盒）。

## 关键前提（不可跳过）

1. **开发者账号已付费**并已接受最新协议。
2. **App Store Connect 已建 App 记录**：套装 ID `top.dolmo.paste.app`，平台 macOS。
   若该 ID 已被占用，需先改 `Info-AppStore.plist` 与 `DolmoPaste.entitlements` 里的 Bundle ID。
3. **发布证书**（本机已具备，无需再申请）：
   - `Apple Distribution: dolmo cheng` — 用来签 `.app`
   - `3rd Party Mac Developer Installer: dolmo cheng` — 用来签 `.pkg`

   查证书必须用 `security find-identity -v -p basic`，**不能用 `-p codesigning`**。
   安装器证书签的是安装包不是可执行代码，压根不出现在 codesigning 那张列表里，
   用 codesigning 查会误判成「没装」。
4. **描述文件**：Certificates, Identifiers & Profiles → Provisioning Profiles → Mac App Store，
   为 `top.dolmo.paste.app` 创建并下载，保存为 `AppStore/DolmoPaste.provisionprofile`。

> 脚本已能自动检测证书；缺证书时会直接告诉你去哪里加，不会静默失败。

## 步骤

```bash
# 1. 生成上架包（.app + .pkg）
./AppStore/build_appstore.sh
#   产出 AppStore/build/dolmo paste.app 与 AppStore/build/dolmo-paste.pkg

# 1.5 强烈建议：先把 .pkg 装起来实机跑一遍
#   本地开发一直是「非沙盒」构建，上架包第一次开沙盒，行为可能不同。
#   按 metadata.md 第 7 节的 8 条测试步骤走一遍再上传，比被拒一次省一周。

# 2. 上传（本机没装 Transporter，走命令行）
./AppStore/upload_appstore.sh
#   支持两种认证，脚本会自动判断：
#     A. 设了 ASC_API_KEY / ASC_API_ISSUER 环境变量 → 用 App Store Connect API Key
#     B. 都没设 → 交互式问 Apple ID + App 专用密码
#   上传成功后还要回 App Store Connect 网页做「配齐 + 提交审核」，见下面第 3 步
```

3. App Store Connect 填表：照 `metadata.md` 逐项粘贴。
4. 上传截图：`screenshots/01–06.png`（2880×1800）。
5. 图标：`icon-1024.png`（1024×1024，ASC 只收 PNG 不收 icns）。
6. 提交审核 → 选 **Manual Release**（手动发布），处理完成后自己点发布。

## 图片规格（已处理，别再退回带透明通道的版本）

App Store 会拒带 alpha 通道的图（图标报 ITMS-90717）：

- `icon-1024.png`：1024×1024，**必须 RGB 无 alpha**。原图带透明已扁平化，
  透明原稿留在 `icon-1024-with-alpha.orig.png`
- `screenshots/01–06.png`：2880×1800，**必须 RGB 无 alpha**。原本只是存成 RGBA
  （alpha 全 255），转 RGB 后画面无损

以后重新生成截图/图标后，用下面的命令确认一遍：

```bash
sips -g hasAlpha AppStore/icon-1024.png          # 必须是 no
sips -g hasAlpha AppStore/screenshots/01.png     # 必须是 no
```

## 已填好的字段

`metadata.md` 已无 `<TODO>`，取值如下，如与实际不符直接改：

| 字段 | 值 |
| --- | --- |
| 隐私政策 URL | `https://dolmo.top/dolmo-paste/privacy` |
| 支持 URL | `https://github.com/nature-tr/dolmo-paste` |
| 营销 URL（可选） | 同支持 URL |
| 版权 | `© 2026 dolmo cheng` |
| 价格 | 免费 |

隐私政策网页源文件在 `AppStore/site/privacy/index.html`，**需要先部署到 dolmo.top 才能访问**，
App Store 会检查这个 URL 是不是真的打得开。上线前记得核对页内的联系邮箱。

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
