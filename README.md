# Map

一个真正的矢量地图应用：道路、水面、建筑、地名都由 GPU 按屏幕的分辨率现画，任何缩放下都是清楚的，
两根手指可以把地图转起来。绘制有两套，OpenGL ES 和 Metal，画出来的地图一样，在设置里切换。

最早是为 Redmi K40（alioth）上的 iOS 16.5 移植写的：苹果的“地图”要苹果的服务器认得这台手机才拿得到数据，
在那里什么也显示不出来。普通 iPhone 上它就是一个普通应用。不用 MapKit。

- 数据：[OpenFreeMap](https://openfreemap.org) 的矢量瓦片（OpenStreetMap 的数据，[OpenMapTiles](https://openmaptiles.org)
  的格式，不要账号、不要 key）。启动时先取 TileJSON（`https://tiles.openfreemap.org/planet`，瓦片地址里带版本号），
  结果记一天。数据最深到 14 级，更近的缩放把 14 级的瓦片放大——矢量放大不会糊；地图最多放大到 21 级
- 解码：`mvt.c` 自己读 Mapbox Vector Tile（protobuf），不依赖任何库；`earcut.c` 是 Mapbox earcut 2.2.4 的 C 移植（ISC），
  把带洞的多边形切成三角形；`tessellate.c` 把一块瓦片做成一份面的网格和一份线的网格，每个顶点记着它属于哪一类
  （`style.h` 的“桶”），每类一段索引。线是中心线加法向量，线宽在顶点着色器里按屏幕上的点数往两边推，所以缩放时
  线宽不变；拐角斜接，太尖的切角；边缘留一个像素的羽化
- 样式：`style.c`，浅色和深色两套颜色（深色接近黑，OLED 上省电也不刺眼），道路按等级分颜色和宽度，有描边；
  线宽按缩放级别插值。跟随系统的深色模式，也可以在设置里固定
- 绘制：一帧是几趟——所有瓦片的面，水和跑道之类的线，道路的描边，道路和边界——每块瓦片每趟一次绘制调用；
  每块瓦片在片段着色器里按自己的范围裁掉缓冲区，相邻瓦片之间没有缝也不会重叠。四倍多重采样
  - `MapRendererGL.m`：EAGLContext（OpenGL ES 3.0，没有就 2.0）+ CAEAGLLayer，GLSL ES 1.00 着色器，
    多重采样的渲染缓冲 resolve 到图层上
  - `MapRendererMetal.m`：CAMetalLayer，同样的着色器写成 Metal 着色语言、运行时编译，memoryless 的多重采样纹理
    resolve 进 drawable
  - 拿不到 Metal 设备时（例如 K40 移植上这个 App 不在 Metal 的允许名单里）设置里 Metal 那一项是灰的，用 OpenGL ES 画
- 地名：`MapLabels.m`，每帧按重要程度放标签，和已放的重叠就不放；文字带光晕，由 Core Text 按屏幕的倍数画进
  一张图集，之后每个标签就是图集里的一块四边形。路名沿着那条路最长的一段放，字永远不倒过来；同一条路在相邻瓦片里
  的名字不重复。地名语言跟随系统（中文系统用 `name:zh`，没有就用当地名），也可以选当地名、中文优先、英文优先
- 瓦片：同时最多下载 6 块，只下载屏幕上看得到的，离开屏幕的立刻取消；失败的 15 秒后再试（连续失败等待翻倍，
  最长 5 分钟）。新瓦片没到的地方先用上一级（最多六级）或下一级已有的顶上。捏合时不换级别、不下载，松手后再加载
- 只在有变化的时候画（手势、动画、新瓦片到达）：地图不动就不画，CADisplayLink 也停掉
- 手势：拖动（松手后有惯性）、捏合、双指旋转（转过 12° 才开始转，免得捏合时误转）、双击放大一级、双指轻点缩小一级、
  长按放一个图钉。地图转了以后右下角出现指北针，点一下转回正北
- 定位：蓝点、精度圈；定位按钮依次切换 不跟随 → 跟随 → 跟随并显示朝向（扇形，随地图的方位转）
- 搜索：Nominatim，按回车才查，选一个就移过去并放一个图钉；图钉的气泡里有坐标和“复制”
- 设置：iOS 的“设置”里有 Map 的一页（`Settings.bundle`），App 里右下角的齿轮弹出同样的四项：渲染器、样式、
  地名语言、显示帧率。两边写同一套键，改了当场生效（换渲染器时瓦片的几何留着，交给新的渲染器重新上传）
- 署名一直显示在右下角：“© OpenFreeMap © OpenMapTiles © OpenStreetMap”，点开可以去三家的版权页

- 包名：`com.anzupop.com.ios.map`，版本 2.0
- 最低 iOS 15.0，iPhone，竖屏和横屏
- Objective-C 和 C，系统框架（UIKit、Core Animation、Core Text、Core Location、OpenGL ES、Metal），zlib；
  没有 storyboard、Swift、MapKit
- 图标由 `mkicon.py` 生成（纯 Python）

## 在 K40 移植上（iOS 16.5，Adreno 650）

2026-11-10 在手机上用自检量过（一处稠密的市中心，15 级，6 块瓦片、21.5 万个三角形）：

| 渲染器 | 转动和缩放时的帧率 | 说明 |
|---|---|---|
| OpenGL ES 3.0（Mesa 25.0.7 freedreno），4 倍多重采样 | 62 帧/秒 | 移植的 GL 按屏幕的刷新节奏交帧，每帧画图本身 0.2 ms |
| Metal，4 倍多重采样 | 39–40 帧/秒 | 移植的 Metal 在 `-commit` 时逐个绘制调用执行、每个都等 GPU（约 1 ms 一个） |

两种画出来的地图一样（读回的帧 99.3% 有内容）。Metal 需要这个 App 在移植的 Metal 允许名单里
（启动参数 `metal_apps=com.anzupop.com.ios.map`），否则设置里 Metal 那一项是灰的。移植那边为它修了两处：
片段着色器里的临时变量被当成写深度而拒绝管线（hakios-alioth 11d331a），以及 GL 上下文刚交过一帧就释放时
主线程上的一个块读已释放的内存（49d3826、5b7b688）。

## 自检

`map://test?renderer=gl|metal|both&at=纬度,经度,缩放`（默认 `both`，巴黎市中心，15 级）：每个渲染器各一遍——移到那里，
等屏幕上的瓦片都到齐，读回一帧看看画了多少、有几种颜色，静止 4 秒，再转四分之一圈、放大缩小一级 3 秒，量帧率。
结果写在控制台里，每行以 `mapcheck: ` 开头。

## 数据和服务的条款

- OpenFreeMap：只下载屏幕上看得到的瓦片，不批量预取；User-Agent 是
  `Map/2.0 (iOS; https://github.com/xiongnemo/ios-map)`；一直显示署名
- Nominatim：每秒最多一个请求，只在按回车时搜，结果用系统的首选语言
- 用户默认值 `TileURL` 可以换成自己的矢量瓦片服务器（OpenMapTiles 格式，`{z}`、`{x}`、`{y}` 会被替换），
  这时不再取 TileJSON；请遵守那个服务器的条款和署名要求

## 编译

产物是 `build/Map.ipa`，没有苹果签名，只适合不校验签名的系统，比如上面那个移植，或者自己重新签名后安装。
有 `ldid` 时 `build.sh` 用它做一个 ad hoc 签名（不需要任何授权）。

```sh
./build.sh                                                   # macOS，用 Xcode
CC=xnu-clang SDK=$THEOS/sdks/iPhoneOS16.5.sdk ./build.sh     # Linux / WSL，需要能链接 iOS 的 clang + ld64
```

每次推送 GitHub Actions 都会在 macOS 上编一次，IPA 作为运行的产物保存；打 `v` 开头的标签会发布到 Releases。

`tests/` 里的两个小程序在电脑上用：`mvtdump` 打印一块瓦片里有什么，`tilepng` 把一块瓦片按地图的切法画成 PNG
（`cc -O2 -o tilepng tests/tilepng.c tessellate.c style.c mvt.c earcut.c -lm -lz`）。

## 许可

MIT，见 `LICENSE`。`earcut.c` 移植自 Mapbox 的 earcut，ISC 许可，见文件开头。
地图数据 © OpenStreetMap contributors（ODbL），瓦片 © OpenMapTiles，由 OpenFreeMap 提供。

## 文件

| 文件 | 作用 |
|---|---|
| `main.m` | 地图周围的界面：搜索、定位、指北针和设置按钮、比例尺、署名、设置页、自检 |
| `MapView.h` / `MapView.m` | 地图本身：相机（中心、缩放、方位）、每帧画哪些瓦片画在哪里、手势、蓝点和朝向、图钉 |
| `MapSource.h` / `MapSource.m` | TileJSON、下载、gzip、后台切三角形、缓存 |
| `MapRenderer.h` | 两个渲染器共同的接口：一帧要画什么 |
| `MapRendererGL.m` / `MapRendererMetal.m` | OpenGL ES 和 Metal 的渲染器 |
| `MapLabels.h` / `MapLabels.m` | 地名：放置、避让、Core Text 图集 |
| `mvt.c/.h`、`earcut.c/.h`、`tessellate.c/.h`、`style.c/.h` | 解码、切三角形、生成顶点、样式 |
| `Settings.bundle/` | iOS“设置”里的 Map 页（英文、简体中文） |
| `strings/` | App 自己的文字（英文、简体中文） |
| `tests/` | 电脑上看瓦片的小程序 |
| `Info.plist` | 包名、版本、图标、方向、定位权限说明、`map://` |
| `mkicon.py` | 生成图标 |
| `build.sh` | 编译并打包成 IPA |
