# 更新日志

> 总日志：所有版本更新统一记录在本文件，最新版本在最上方，时间精确到小时；同一版本内新小时在上、旧小时在下。

## v1.5.0（进行中）· Apple Music 第 5 音源接入 · 2026-09-13 19:00 起

### 21:00 · Apple Music iOS 登录打通（方案3 原生 Cookie 提取）· 09-14
- **iOS 原生通道打通**：`WKWebsiteDataStore.httpCookieStore.getAllCookies()` 提取完整 cookie（含 HttpOnly 的 media-user-token），
  提交长度从 len=246（仅裸 token）提升到 **len=1487（完整 7 键 cookie 串：itspod / pltvcid / pldfltcid / itua / media-user-token / acn1 / dslang）**
- 后端 `/apple/login/token` 接收保存成功，`apple-cookie.txt` 更新（1487 字节，token `0.AlHRG...`），`/apple/status` loggedIn=true
- **排查 /apple/user/playlist 502**：根因是当前账号**未订阅 Apple Music**，amp-api 返回 HTTP 400「Insufficient Privileges / CloudLibrary 权限不足」；
  订阅账号可正常获取歌单（免费账号仅能登录、拿不到资料库歌单），已确认非后端代码问题
- 遗留说明：账号订阅后 /v1/me/library/* 即可正常返回

### 20:00 · 局域网直连后端方案 · 09-14
- 确认后端监听 `0.0.0.0:41831`（`::`），Wi-Fi 局域网 IP `10.91.29.234`（DHCP 会变）
- Windows 防火墙无 41831 入站规则，需管理员执行 `netsh advfirewall firewall add rule name="liquid-music-backend-41831" dir=in action=allow protocol=TCP localport=41831` 放行
- iPhone 填 `http://10.91.29.234:41831` 即可同一 Wi-Fi 直连

### 19:00 · 安卓 Release 构建交付 · 09-14
- `app-release.apk`（57.9MB）构建完成，包含：歌单详情缓存、QQ 扫码文案修复、推荐页改动
- 已交付用户安装测试

### 18:00 · 服务器后端更新包 · 09-14
- 打包 `backend-server-update.zip`（95KB）：server.js / apple-api.js / kugou-api.js / qq-api.js / soda-api.js / admin-logger.js / package.json / package-lock.json / .npmrc
- **特意排除**所有 cookie/登录态文件（避免覆盖服务器已登录账号）、qr-decode 逆向工具、node_modules
- 服务器部署：解压覆盖 → `npm install --omit=dev` → `pm2 restart music-hook` → `curl localhost:41831/apple/status` 验证
- 注意：服务器需有有效 Apple cookie（iOS 登录提交或手动传 apple-cookie.txt）才能拉歌单

### 17:00 · 歌单详情缓存（秒开）· 09-14
- 打开歌单先读本地缓存立即显示（不转圈），后台静默拉网络刷新并更新缓存
- 网络刷新失败时保留缓存列表，仅轻提示「刷新失败，当前显示缓存内容」，不覆盖不报全屏错误
- 存储：SharedPreferences `playlist_cache_{source}_{id}`（歌曲列表 + 名称/封面/描述），覆盖 netease/kugou/qq/apple/soda 全部音源

### 16:00 · 推荐页分区排序 · 09-14
- 推荐页多分区（每日推荐 / 雷达歌单 / 酷狗日推 / 猜你喜欢 / QQ日推）支持长按拖动自定义排序，排序持久化
- 已输出前端提示词文档（docs/推荐页分区排序-前端提示词.md）

### 15:00 · QQ 扫码登录文案修复 · 09-14
- 登录入口文案由「请使用 QQ 音乐扫码登录」改为「请使用 QQ App 扫码登录」（实际是用 QQ 扫，不是 QQ 音乐）

### 13:00 · iOS 移植构建闭环（GitHub Actions 免费 macOS runner）· 09-14
- `flutter create --platforms=ios --org com.nini --project-name liquid_music` 生成 iOS 工程，Bundle ID `com.nini.liquidMusic`，Android 不动
- Info.plist：显示名「液态音乐」、`UIBackgroundModes=[audio]` 后台播放、`NSAllowsArbitraryLoads` 明文 http、MinOS 15.0
- **构建排坑**（多次失败 → 修复）：
  1. Flutter 3.44 默认 SPM 不产出 ipa → 加 Podfile + `flutter config --no-enable-swift-package-manager`
  2. 仍无产物 → 改 `flutter build ios --release --no-codesign` 产 Runner.app + 手动 `mkdir Payload && zip` 打 ipa
  3. Podfile platform 13.0→15.0（对齐 Flutter 3.44）+ workflow 全清 pod 重装（deintegrate + rm Pods/Podfile.lock + pod install + grep 校验）→ **构建全绿（7 pods）**
- 产物：`app-release-ios-unsigned`（ipa 8.1MB / Runner.app 19.4MB，单架构 arm64，体积比安卓小属正常），支持 iOS 15.0+
- 安装方式：爱思助手免费 Apple ID 自签（不上 App Store，免费自签 7 天需重签）
- iOS 差异：锁屏/通知栏仅标准媒体控制（无自定义滚动歌词/收藏按钮）；安卓专属插件（flutter_displaymode 高刷、MediaNotificationBridge）iOS 上 try/catch 兜底不崩

### 12:00 · AppleMusic 换源播放 · 09-14
- 输出前端提示词：播放页 Apple 音源歌曲直接调后端 `/apple/song/url` 取官方流，失败走换源链（网易云解锁 → QQ → B站兜底）
- Apple 歌单详情走 `/apple/playlist/detail` 返回曲目元数据，播放时按歌名+歌手匹配换源

### 21:00 · Apple 歌单实测与登录排查 · 09-13
- `/apple/user/playlist` 直测 200：神的歌单 95 首 + 喜爱歌曲 27 首（实时拉取，非缓存）
- 确认旧 cookie（`0.Agv5v7...`）仍有效；iOS WebView 的 `document.cookie` 读不到 media-user-token（HttpOnly）→ 需原生通道
- cpolar 隧道 `appppp` 建立：`https://16ea83d5.r10.cpolar.top` → 本地 41831

### 20:00 · Apple 登录方案2/3 开发 · 09-13
- 方案2（getCookies 兜底）：只取到裸 media-user-token（len=246），仍不满足
- 方案3（参考 Cider 源码）：Cider 登录实为网页登录 + Electron 原生 `session.cookies.get()` 提取 7 个关键 cookie；
  iOS 等价实现 `WKWebsiteDataStore.httpCookieStore.getAllCookies()`（能读 HttpOnly）
- 已实现：`AppDelegate.swift` 新增 MethodChannel `liquid_music/apple_cookies.getAllCookies`；前端登录页方案0 原生通道优先（iOS），安卓逻辑不变

### 19:00 · Apple Music 接入（⏸ 未完成，临时搁置先干别的）

**已完成：**
- 后端 `apple-api.js` 全部接口 + `server.js` 路由（`/apple/*`），本地实测通过：
  登录验证 `/apple/login/token`、状态 `/apple/status`、退出 `/apple/logout`、
  歌单 `/apple/user/playlist`、歌单详情 `/apple/playlist/detail`、
  收藏 `/apple/liked`、喜欢歌曲 `/apple/favorites`、推荐 `/apple/recommend`
- web token 提取链路（beta.music.apple.com 的 index JS 正则取 JWT，缓存 12h，401/403 自动刷新重试）
- 前端登录页：WebView 内嵌登录 + **JS 注入读 `document.cookie` 提取 media-user-token**
  （关键排查结论：`WebViewCookieManager.getCookies()` 在 Android 上读不到该 cookie 值（len=0），
  但同页面 JS `document.cookie` 能读到完整值 → 已切换 JS 注入方案，实测成功）
- 前端→后端提交链路打通（点「我已完成登录」会带 token 请求后端验证）

**未完成（下次从这里继续）：**
1. **【当前卡点】** 旧 media-user-token 已被 Apple 判过期（后端验证返回 401）：
   需在 WebView 里「退出登录 → 重新登录（含 2FA 验证码）→ 拿到新 token → 点我已完成登录」验证通过
2. 验证通过后：删除调试代码（`apple_music_login_page.dart` 中 `_showDebugDialog`、
   `_jsProbe`、多域扫描等调试逻辑），改为正式静默提交流程
3. Apple 歌单 / 收藏 / 推荐页面前端接入（我的页「Apple Music 歌单」分类）验收
4. 播放走换源链联调（apple 音源 → 失败换网易云解锁源 → …）
5. 后端部署到服务器（apple-api.js + server.js 需同步上传，pm2 restart music-hook）
- 本地后端 `localhost:41831` apple 路由已验证可用（`/apple/status` 200）

---

## v1.4.0 · 2026-09-12 14:00

### 13:00 · 推荐页紧凑化
- 各分区（每日推荐/雷达歌单/酷狗日推/猜你喜欢/QQ日推）间距 16→10px
- 列表底部留白 100px：滚到底时最后一行的歌名不再被底部播放胶囊遮挡

### 12:00 · 过渡动画修复
- **封面飞入不生效**（只有关闭时才飞）：详情页封面加载完成前未挂 Hero 导致两端不匹配，改为无条件挂载（空封面飞占位，加载后原位更新），打开/关闭双向飞
- **背景模糊无过渡**：打开歌单时模糊从清晰逐渐"糊开"（sigma 0→20）+ 黑色遮罩同步渐显（0→0.35，600ms）
- **沉浸歌词跟随滚动错位**：滚动用固定行高估算但实际行高自适应（当前行含翻译≈46px、普通行≈28px）。改为歌词列表固定行高（itemExtent 64×字号），滚动计算与布局完全一致，当前句精准垂直居中

### 12:00 · 新增：过渡动画设置系统
- 设置页新增「过渡动画」三级设置页，三个动画独立开关（默认全开，可自由组合）：
  1. **封面飞入**：点开歌单封面从列表卡片飞入详情页头部（Hero 动画）
  2. **页面转场**：整页淡入 + 轻微上滑 + 缩放（400ms），关闭反向 300ms
  3. **列表递进**：歌曲列表按序上浮淡入，间隔 40ms 逐项出现

### 11:00 · 歌单列表紧凑化
- 卡片间距、内边距、封面尺寸（46→40）、圆角（18→16）全面收紧，一屏显示更多歌曲

### 09:00 · 修复沉浸播放页"双黄线"
- 现象：沉浸层歌词/歌名/时长等所有文字下方出现黄色双横线，模拟器与真机均复现
- 根因：Text 缺少 Material 祖先时，Flutter 引擎强制绘制黄色双下划线提示（非渲染器/字体/背景问题）
- 修复：沉浸层外包透明 `Material(type: MaterialType.transparency)` + 所有文字显式 `decoration: TextDecoration.none`

---

## v1.3.0 · 2026-09-11 23:00

### 23:00 · 修复
- 修复播放胶囊布局撑满整页、列表无法滚动的 bug
- 修复白色档歌词面板、顶部导航栏灰色脏底问题
- 修复白色档迷你播放条两侧黑色阴影弥散成灰边的问题
- 修复沉浸歌词铺封面模式下换歌/暂停按钮失效、歌词不可滑动、点击歌词不能调进度的问题
- 修复沉浸页下滑关闭后无法上滑恢复的问题
- 排查沉浸页文字"双黄线"问题（当晚初步定位为框架文字绘制层问题，次日确认根因并修复，见 v1.4.0）

### 22:00 · 新增：沉浸歌词铺封面模式（仅液态玻璃主题生效）
- 播放页内一键切换，歌词直接铺在专辑封面上层，当前句高亮保证可读
- 换歌/暂停按钮缩小、歌名歌手下移，切换带过渡动画
- 歌词点击可跳转播放进度、支持滑动浏览、字体大小可调

### 20:00 · 优化
- 白色档全局语义化配色：暖白 `#F9FAF4` 底、主文字 `#1A1B1C`、次级文字 `#6B7280`、分隔线 `#E4E3DD`
- 状态栏图标颜色随主题深浅自动切换（浅色档深色图标、深色档浅色图标）
- 顶部导航栏、歌词面板在白色档改为纯白/暖白渐变，去除灰脏底色
- 歌曲卡片毛玻璃改为默认关闭（性能优先），可在设置中开启
- 首页整体改为 Stack 布局，播放胶囊悬浮于内容之上，界面不再被底部栏挤压

### 20:00 · 新增：界面风格系统
- 设置页新增「自定义界面」，四档风格一键切换，选择即生效并持久化（重启保留）：
  1. **液态玻璃**（默认）：黑底青绿光 Spotify 风，毛玻璃卡片
  2. **极简暗色**：深色扁平实色，去除毛玻璃
  3. **暗色透明**：保留深色氛围，去毛玻璃
  4. **极简白色**（暖白）：白底黑字极简风，全局无玻璃、无模糊
- 播放页底部「正在播放」改为**播放胶囊**悬浮样式：圆角胶囊 + 浅边框，滚动时歌曲列表从胶囊下方穿过，两侧透出列表内容（浅色档）

---

## v1.2.0 · 2026-09-10
- 自定义界面设置：歌曲卡片毛玻璃开关（默认关闭，性能优化）
- 底部播放栏优化，多音源聚合播放体验完善
- 多平台歌单同步（网易云 / QQ 音乐 / 酷狗音乐 / 汽水音乐）、多音源切换与匹配、歌词显示等（详见仓库 Release 说明）
