基于上游优秀的`mpv`配置 [mpv-config](https://github.com/dyphire/mpv-config)，针对我个人需求做了部分修改以及补充一些脚本（部分来自其他仓库,部分基本完全借助`ai`编写）

---

## 🚀 二次修改或者新增脚本说明

<details>
<summary>点击展开脚本说明</summary>

### `autocopyshot.lua`
* **功能描述**：在触发`mpv`原生视频截图的同时复制到系统剪贴板
* **`input.conf`写法示例**：

```ini
Ctrl+c      script-message screenshot-subtitles-copy   #menu: 截取 > 截屏 > Autocopyshot > 同源尺寸 - 有字幕 - 无 OSD-单帧

Ctrl+alt+c  script-message screenshot-video-copy       #menu: 截取 > 截屏 > Autocopyshot > 同源尺寸 - 无字幕 - 无 OSD-单帧

Ctrl+shift+c script-message screenshot-window-copy     #menu: 截取 > 截屏 > Autocopyshot > 实际尺寸 - 有字幕 - 有 OSD-单帧
```

### `bangumi_sync`
* **来源**：[x-Armin/mpv_bangumi_sync](https://github.com/x-Armin/mpv_bangumi_sync)
* **功能描述**：基于`uosc`框架，同步和回传 Bangumi 观看记录
* **`input.conf`写法示例**：参考原仓库说明

### `clock.lua`
* **功能描述**：实现时钟效果，显示当前系统时间、观看当前视频还需时间及视频结束时间
* **`input.conf`写法示例**：

```ini
t                 script-message-to clock toggle                                                                       #menu: 其他 > 开启/关闭 时间显示
```

### `cut_sub.lua`
* **功能描述**：裁剪与视频同目录下近似名称的字幕和弹幕文件
* **`input.conf`写法示例**：

```ini
#                script-message cut_sub_ab                                                                              #menu: 截取 > 字幕&弹幕 > 标记 A/B 点
#                script-message cut_sub_clear                                                                           #menu: 截取 > 字幕&弹幕 > 清除标记
```

### `dir_subs.lua`
* **功能描述**：记录和恢复视频的字幕大小和位置状态，会影响同目录下所有视频的字幕状态

### `embedded-lyrics.lua`
* **功能描述**：自动提取音乐文件中的内嵌歌词并以字幕形式加载
* **`input.conf`写法示例**：

```ini
#                script-message embedded-lyrics-toggle                                                                  #menu: 功能 > 歌词 > 开/关 自动加载内嵌歌词
#                script-message embedded-lyrics-save                                                                    #menu: 功能 > 歌词 > 提取并保存内嵌歌词
```

### `extract_fonts.lua`
* **功能描述**：导出视频中的内封字体
* **`input.conf`写法示例**：

```ini
Ctrl+S           script-binding extract-fonts                                                                           #menu: 截取 > 视频 > 提取MKV视频内封字体
```

### `music-reset.lua`
* **功能描述**：检测到带封面的音频文件时，自动将播放进度重置到开头，解决历史记录脚本对音乐文件恢复进度的问题

### `skip_sponsorblock.lua`
* **功能描述**：参考上游 [chapterskip.lua](https://github.com/dyphire/mpv-config/blob/master/scripts/chapterskip.lua) 与 [sponsorblock_minimal.lua](https://github.com/dyphire/mpv-config/blob/master/scripts/sponsorblock_minimal.lua)，实现流媒体播放时识别 B 站和 YouTube 的各种特殊片段，插入章节信息并提供交互按钮。可配合油猴脚本 [play-with-mpv](https://github.com/Ladersbt/userscript/tree/main/play-with-mpv)（参考修改自 [akiirui/userscript](https://github.com/akiirui/userscript/tree/main/play-with-mpv) 和 [LuckyPuppy514/external-player](https://github.com/LuckyPuppy514/external-player)）使用，在上游基础上增加了若干功能并调整了 UI

### `speed_manager.lua`
* **功能描述**：记录和恢复播放速度，支持回档至上次速度
* **`input.conf`写法示例**：

```ini
KP1              script-message toggle_speed; script-message-to uosc flash-speed                                        #menu: 播放 > 速度调整 > 速度 重置/恢复
```

### `sub_export.lua`
* **功能描述**：在上游 [sub_export.lua](https://github.com/dyphire/mpv-config/blob/master/scripts/sub_export.lua) 基础上实现导出 SRT 字幕的同时自动转换并生成一份 ASS 字幕
* **`input.conf`写法示例**：

```ini
CTRL+s           script-message-to sub_export export-selected-subtitles                                                 #menu: 字幕 > 导出当前内封字幕
```

### `uosc`
* **来源**：整合 [上游](https://github.com/dyphire/mpv-config/tree/master/scripts/uosc) 和 [hooke007/mpv_PlayKit](https://github.com/hooke007/mpv_PlayKit/tree/main/portable_config/scripts/uosc) 特性

### `uosc_webdav`
* **来源**：参考修改自 [webdav.lua](https://gist.github.com/HedioKojima/fdbfdd73570650b01c809afb5ae7829b)
* **功能描述**：基于`uosc`框架，实现 WebDAV 目录浏览与播放功能，支持多种排序、批量删除、外挂字幕自动匹配与内封字幕自动选轨、全目录连播列表、菜单实时搜索等
* **`input.conf`写法示例**：

```ini
#                script-message open-webdav                                                                             #menu: 导航 > WebDAV > 打开 WebDAV 目录
Q                script-message open-webdav-root                                                                        #menu: 导航 > WebDAV > 回到 WebDAV 根目录
q                script-message webdav-back                                                                             ## 返回上一级
c                script-message webdav-cycle-sort                                                                       #menu: 导航 > WebDAV > 切换 WebDAV 目录排序
#                script-message webdav-toggle-sync-sort                                                                 #menu: 导航 > WebDAV > 开/关 继承 WebDAV 目录排序
#                script-message webdav-toggle-video-only                                                                #menu: 导航 > WebDAV > 开/关 仅播放视频
```

> **Note**: 已由群组版本替代

### `uosc_history.lua`
* **来源**：[Koopex/uosc_history_menu](https://github.com/Koopex/uosc_history_menu)
* **功能描述**：基于`uosc`框架，实现历史记录与收藏夹功能
* **`input.conf`写法示例**：参考原仓库说明

### `winisland.lua`
* **功能描述**：与 [WinIsland](https://github.com/Eatgrapes/WinIsland) 联动以在 mpv 播放音乐时实现类似手机音乐软件的灵动岛效果

</details>

---

## 🔄 与上游同步说明
* 只保留和跟进经过二次修改后的上游脚本

## 🤝 致谢

* 感谢上游项目 [mpv-config](https://github.com/dyphire/mpv-config) 的优秀`mpv`配置
* 感谢 mpv 社区中的各位脚本开发者，收录了一些他们编写的实用脚本
* 感谢 mpv 社区中提供灵感与参考的各位，除了上游项目，还参考和借鉴了许多 github 内仓库中的`mpv`脚本