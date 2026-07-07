# MacTools Icon Gallery

状态栏图标图库使用轻量 catalog + 按需下载素材。主应用只读取 `catalog.json`，用户选择某个素材后才下载对应帧，并从本地 `RemoteAssets` 播放。

## Catalog v1

```json
{
  "schemaVersion": 1,
  "generatedAt": "2026-05-20T00:00:00Z",
  "baseURL": "https://mactools.ggbond.app/icon-gallery/",
  "categories": [
    { "id": "featured", "title": "精选" }
  ],
  "assets": [
    {
      "id": "runcat",
      "title": "RunCat",
      "categoryID": "featured",
      "version": "1",
      "previewPath": "assets/runcat/preview.png",
      "archivePath": "assets/runcat/asset.zip",
      "archiveFramePathPattern": "frame-%03d.png",
      "frameCount": 5,
      "frameDuration": 0.1
    }
  ]
}
```

`archivePath` 推荐用于线上资源，减少多帧动画的请求次数。压缩包内只需要放帧文件，路径用 `archiveFramePathPattern` 描述。

也可以不用 zip，直接声明帧路径：

```json
{
  "id": "runcat",
  "title": "RunCat",
  "categoryID": "featured",
  "version": "1",
  "previewPath": "assets/runcat/preview.png",
  "framePathPattern": "assets/runcat/frames/frame-%03d.png",
  "frameCount": 5,
  "frameDuration": 0.1
}
```

## Runtime Behavior

- 正式环境默认读取 `https://mactools.ggbond.app/icon-gallery/catalog.json`。
- Debug 环境可用 `MACTOOLS_ICON_CATALOG_URL` 指定 `file://` 或 `https://` catalog。
- `make run` 会自动生成 `build/LocalIconGallery/catalog.dev.json` 并注入 `MACTOOLS_ICON_CATALOG_URL`。
- 远程素材下载到 `~/Library/Application Support/MacTools/MenuBarIcons/RemoteAssets/`，Debug 为 `MacTools Dev`。
- 当前选中的在线素材直接从 `RemoteAssets` 读帧，渲染后进入内存缓存；动画播放时不会访问网络。
- 选择新的在线素材后，会清理旧的 `RemoteAssets`，只保留当前选中素材。
- 最近使用会保留在线素材的本地缩略图和轻量引用；完整帧若已被清理，点击最近使用时会通过 catalog 重新下载。

## Local Debug Gallery

本地 Debug 会复制仓库内已提交的 `docs/icon-gallery`，并把 catalog 的 `baseURL` 改成本地 `file://` 地址：

```bash
make generate-icon-gallery
```

如果需要重写到其它静态目录：

```bash
./scripts/icons/generate-local-icon-gallery.py \
  --gallery-dir docs/icon-gallery \
  --output-dir build/LocalIconGallery
```

## Safety Limits

- 正式环境只允许 `https` 资源，Debug 的 `file://` 资源仅用于本地测试。
- 单帧最大 1 MB，zip 最大 25 MB。
- 单个素材最多 120 帧。
- 解码后单帧像素面积不超过 `512 * 512`。
- 素材完整下载、解压、校验成功后才切换当前图标。
