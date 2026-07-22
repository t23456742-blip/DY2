# DYSlimClean · 抖音精简清理

巨魔 TIPA：扫描抖音沙盒 `com.ss.iphone.ugc.Aweme`，按 H9-20-土 白名单一键删多余文件。

**环境：Dopamine + RootHide（iOS 15/16）+ TrollStore 安装。**  
权限直接对齐 FUCK 工具箱 entitlements（`no-sandbox` / `AppDataContainers` / 全盘读写等），不依赖 `/var/jb`（RootHide 随机路径也不影响 App 容器）。

## 用法

1. GitHub Actions 编出 `.tipa` → 巨魔安装  
2. 打开 App → **扫描抖音沙盒** → **一键删除多余文件**

## 编译（GitHub）

推送后：**Actions → Build TIPA → Run workflow**，下载 Artifact `DYSlimClean-tipa`。

```text
git add . && git commit -m "DYSlimClean" && git push
```

本地（macOS）：

```bash
brew install xcodegen ldid
xcodegen generate
xcodebuild -project DYSlimClean.xcodeproj -scheme DYSlimClean \
  -configuration Release -sdk iphoneos -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" build
bash scripts/package-tipa.sh
```

`scripts/package-tipa.sh` 会用 `DYSlimClean.entitlements` 对可执行文件 `ldid` 伪签名（巨魔必需）。

## 白名单

`DYSlimClean/Resources/keep_paths.txt` ≈ 3140 条（H9-20-土 全部 zip 并集）。

## 说明

- 必须巨魔安装；普通签名无权读写抖音容器  
- 定位顺序：`LSApplicationProxy` → 容器 metadata → `Aweme.db`/`mmkv` 特征  
- 不删 `.com.apple.mobile_container_manager.metadata.plist`  
- Bundle ID：`com.dyslim.cleaner`
