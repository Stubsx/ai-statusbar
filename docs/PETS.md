# 桌宠创作与分享

在设置的「桌宠」页选择作品后，可检查素材、导出 ZIP；「作品目录与模板」提供可编辑的原创蓝点模板。目录目前仅包含项目自带模板，没有联网市场。导出 ZIP 后，可在另一台电脑或另一份素材库中通过「从 ZIP 导入形象」安装。

## 文件格式

ZIP 根目录或单层文件夹只放一套素材。基础姿势为 `idle.png`；可选 `working.png`、`loading.png`、`sleeping.png`、`celebrating.png`、`error.png`。眨眼槽位为 idle/working/loading/celebrating/error 加 `-blink.png`；打字帧是 `working-type-left.png` 和 `working-type-right.png`。缺少主姿势会回退空闲图，缺少动画帧会降级；只有显式结束信号才播放庆祝姿势。

```json
{
  "schema_version": 1,
  "name": "我的桌宠",
  "author": "创作者署名",
  "version": "1.0.0",
  "license": "请填写实际授权",
  "description": "作品介绍与素材来源",
  "preview": "preview.png",
  "nsfw": false
}
```

编辑器可填写作者、版本、授权和简介；已有的 nsfw 与附加元数据会保留。导出自动带上预览图、manifest 和创作说明。没有授权信息的已有素材标记为未声明，不会自动赋予 MIT 等授权；蓝点模板本身由项目按 MIT 授权。

## 素材检查

推荐同样大小的透明 PNG 画布，例如 1024 × 1024；保持主体中心和落脚位置一致。检查器会提示画布不一致、贴近边缘、动画主体偏移；不可读、全透明、链接文件、超过 4096 × 4096 或单张超过 32 MB 的素材会阻止导出与安装。边缘检查是透明像素范围启发式，仍需在动作预览中人工看一遍。

ZIP 不超过 100 MB。导入只提取已知 PNG 和 pet.json，忽略脚本及其他文件，拒绝路径穿越、重复素材、多套素材和超限解压输出。README 不作为程序执行。导入生成新的本地作品 ID，不覆盖同名作品；编辑使用草稿，保存失败保留原作品。自定义作品存放在 App 外的素材库，正常升级不会删除。

## 贡献到作品目录

在 `AIStatusBar/Resources/PetGallery/index.json` 新增条目，字段为 id/name/author/version/license/summary，`directory` 指向 bundle Resources 内的素材目录（例如 `Pet/example`）。同时提交合法授权的图片与 pet.json；当前模板条目使用 `template:true`。不添加脚本或远程自动下载。

验收：新建 → 编辑 → 导出 → 新素材库导入 → 再编辑导出；比较名称、元数据、图片和回退动作。`bash scripts/test-ecosystem.sh` 会在临时素材库执行这一流程，不改动真实作品。
