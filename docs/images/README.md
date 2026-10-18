# 图片资源

README 里展示用到的图片都放在这个目录。

| 文件 | 用途 |
| --- | --- |
| `icon.png` | 顶部应用图标（取自 `mipmap-xxxhdpi/ic_launcher.png`） |
| `screen-player.png` | 界面预览：直播播放，建议 960×540 |
| `screen-channels.png` | 界面预览：频道列表，建议 960×540 |
| `screen-epg.png` | 界面预览：节目单 / 回看，建议 960×540 |

三张 `screen-*.png` 目前是占位图，用手机截的实际界面覆盖同名文件即可，README 不用改。

## 写法速查

**1. 基本语法**（路径相对 README 所在目录）

```markdown
![直播播放](docs/images/screen-player.png)
```

**2. 控制宽度**：Markdown 语法本身不能设尺寸，用 HTML 的 `width`

```html
<img src="docs/images/screen-player.png" width="360" alt="直播播放">
```

**3. 居中 + 并排**：外面套一层 `<p align="center">`，或写进表格

```html
<p align="center">
  <img src="docs/images/screen-player.png" width="320">
  <img src="docs/images/screen-channels.png" width="320">
</p>
```

```markdown
| 直播播放 | 频道列表 |
| :---: | :---: |
| <img src="docs/images/screen-player.png" width="290"> | <img src="docs/images/screen-channels.png" width="290"> |
```

**4. 点图片跳转**：图片外面包一个链接

```html
<a href="https://github.com/mychb112/chengtv/releases/latest">
  <img src="docs/images/screen-player.png" width="360">
</a>
```

## 几个坑

- 路径是**相对 README 所在目录**，不是相对仓库根目录；`docs/images/xx.png` 在 README 里写成 `docs/images/xx.png` 就对了。
- 仓库里图片按分支保存：在 `main` 上写的相对路径，切到别的分支看 README 时取的是那个分支的图。
- 文件名大小写敏感，Linux 上的 CI 与 GitHub 页面都区分 `PNG` / `png`。
- 也可以直接把图片拖进 GitHub 的 README 编辑框，它会生成 `https://github.com/user-attachments/assets/...` 形式的链接；这种链接不占仓库体积，但图片不随仓库克隆。
