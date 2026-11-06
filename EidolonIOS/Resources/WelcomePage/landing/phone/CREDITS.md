# 落地页第 4 幕手机模型的来源

这个目录里的 `phone.gltf`、`phone.bin` 和 `*.webp` 是一个 3D 手机模型，由 `frontend/scripts/landing-phone.mjs` 从原始下载压缩、改色而来。

- 作品：「iPhone 17 Pro」，作者 Ranguel（https://sketchfab.com/Ranguel ）
- 来源：https://sketchfab.com/3d-models/iphone-17-pro-4541aa8a28324b33a2baaf81d263aaec （2026-10-12 下载，贴图最大 1024 的 GLB）
- 许可：CC BY 4.0（https://creativecommons.org/licenses/by/4.0/ ）

改动：

- 铝框和背面玻璃区改成同一种银色（仿 iPhone 18 Pro 的背面玻璃和铝框同色），去掉背面玻璃上那层半透明的着色层；铝框和背面玻璃的喷砂噪点法线贴图去掉。
- 屏幕换成模型自带的熄屏材质（另起名「Screen」，落地页亮屏时只点亮它）；模型自带的壁纸贴图不再使用，已删去。
- 去掉透射（KHR_materials_transmission）和镜面（KHR_materials_specular）扩展、切线、第二套 UV 和没有贴图的零件的 UV。
- 网格量化（KHR_mesh_quantization），贴图缩到 512 并转成 WebP；由 GLB 改存为 glTF 加单独的二进制和贴图文件。
- 几何形状没有改动。
- `still.webp` 是用改动后的模型渲染的一张正面、熄屏的图（`frontend/scripts/landing-phone-still.mjs`），给不播放动画的档位和 3D 画布出问题时用。

本模型仅用于展示，与模型所仿的产品的厂商没有关联，也未经其认可。
