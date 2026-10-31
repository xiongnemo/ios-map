# Map

一个不需要 GPU 的地图应用：OpenStreetMap 的栅格瓦片，每块是一个 CALayer，内容是在后台解码好的位图；
主线程只负责把这些图层摆到该在的位置，合成交给 Core Animation。进程里没有 Metal、没有 OpenGL ES，也不用 MapKit。

最早是为 Redmi K40（alioth）上的 iOS 16.5 移植写的：那里苹果的“地图”和 MapKit 什么都显示不出来
（MapKit 用 Metal 绘制，移植没有 Metal；OpenGL ES 只在窗口服务器里有）。普通 iPhone 上它就是一个普通应用。

- 瓦片：`https://tile.openstreetmap.org/{z}/{x}/{y}.png`，256 像素，缩放级别 2–19，Web Mercator，东西方向无限循环
- 缩放可以停在两级之间：显示最近一级的瓦片并缩放。捏合时只缩放已有的瓦片、不下载，松手后再加载最近的一级；
  新瓦片还没到的地方，先把上面一级（最多五级）的瓦片放大顶上，缩小时还会用刚才那一级的四块；都没有就是浅灰色
- 手势：拖动（松手后有惯性）、双指捏合（以两指中间为中心）、双击放大一级、双指轻点缩小一级、长按放一个图钉
- PNG 在后台队列解码（`UIImage imageWithData` 之后画进一张 BGRA 位图，让解码在那里发生，而不是在主线程第一次显示时）；
  同时最多下载 6 块，离开屏幕的立刻取消
- 缓存：解码后的瓦片放在 NSCache 里，按位图大小最多约 150 MB，收到内存警告时清空（屏幕上的不受影响）；
  PNG 由 NSURLCache 按 HTTP 缓存头缓存，磁盘只给 50 MB（K40 移植的数据盘在内存里）
- 定位：蓝点和浅蓝色的精度圈（按 horizontalAccuracy 和当前纬度、缩放换算成点）。右下角的定位按钮依次切换：
  不跟随 → 跟随 → 跟随并显示朝向。显示朝向时是一个半透明的扇形，随手机转动；`trueHeading` 有效时用真北，
  否则用磁北（headingAccuracy 为负时不显示）。这一版地图本身不旋转。拖动地图就不再跟随；
  跟随时捏合、双击都以自己的位置为中心。没有定位权限时点按钮会提示去“设置”里打开
- 搜索：顶部的搜索框，按回车才查 Nominatim（`format=jsonv2&limit=8`，不边输边查）；结果列在下面，
  选一个就移过去，按它的范围选缩放级别，放一个写着名字的图钉
- 图钉的气泡里有坐标（十进制度，5 位小数）、“Copy”（复制坐标）和关闭按钮；一次只有一个图钉
- 左下角是比例尺（米 / 公里）和当前缩放级别；右下角是“© OpenStreetMap contributors”，点一下打开
  https://www.openstreetmap.org/copyright
- 启动时回到上次离开时的位置和缩放级别（NSUserDefaults）；第一次启动时用系统记得的最后位置，
  没有就显示整个世界，第一次定位到之后移到那里
- 没有网络、没有定位权限、瓦片下载失败都不会崩溃：失败的瓦片是深一点的灰色，15 秒后再试（连续失败等待时间翻倍，最长 5 分钟）

- 包名：`com.anzupop.com.ios.map`
- 最低 iOS 15.0，iPhone，竖屏和横屏
- 只用 Objective-C 和系统框架（UIKit、Core Animation、Core Graphics、Core Location），`main.m` 和 `MapView.m`，
  没有 storyboard、asset catalog、Swift、MapKit
- 图标由 `mkicon.py` 生成（纯 Python）

## OpenStreetMap 的使用政策

瓦片和搜索都用 OpenStreetMap 基金会的公共服务器，按它们的政策来：

- 请求带一个能认出这个应用的 User-Agent：`Map/1.0 (iOS; https://github.com/xiongnemo/ios-map)`
- 瓦片按服务器给的 HTTP 缓存头缓存，不发 no-cache；不批量预取，只下载屏幕上看得到的
- Nominatim 每秒最多一个请求（一秒内再搜会等到满一秒），只在按回车时搜，结果用系统的首选语言
- 地图上一直看得到署名

## 换瓦片服务器

用户默认值 `TileURL` 可以换成别的瓦片服务器，`{z}`、`{x}`、`{y}` 会被替换，例如

```sh
defaults write com.anzupop.com.ios.map TileURL 'https://example.org/tiles/{z}/{x}/{y}.png'
```

换了之后请遵守那个服务器的条款和署名要求（右下角仍然写着 OpenStreetMap）。

## 编译

产物是 `build/Map.ipa`，没有苹果签名，只适合不校验签名的系统，比如上面那个移植，或者自己重新签名后安装。
有 `ldid` 时 `build.sh` 用它做一个 ad hoc 签名（不需要任何授权）。

```sh
./build.sh                                                   # macOS，用 Xcode
CC=xnu-clang SDK=$THEOS/sdks/iPhoneOS16.5.sdk ./build.sh     # Linux / WSL，需要能链接 iOS 的 clang + ld64
```

每次推送 GitHub Actions 都会在 macOS 上编一次（也可以手动运行 `build`），IPA 作为运行的产物保存。

## 许可

MIT，见 `LICENSE`。地图数据 © OpenStreetMap contributors，ODbL。

## 文件

| 文件 | 作用 |
|---|---|
| `main.m` | 地图周围的界面：搜索框和结果、定位按钮、比例尺、署名，以及定位 |
| `MapView.h` / `MapView.m` | 地图本身：瓦片的下载、解码、缓存，图层的排布，手势，蓝点和朝向，图钉 |
| `Info.plist` | 包名、版本、图标、方向、定位权限说明 |
| `mkicon.py` | 生成 60×60 @2x / @3x 图标 |
| `build.sh` | 编译并打包成 IPA |
