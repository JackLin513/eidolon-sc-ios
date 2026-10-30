# 11: 拍板：配图的提示词细节

Type: grilling
Status: open
Blocked by: 06, 10

## Question

构图枚举、前后缀、合照（两人和三人）、尺寸按构图定都已有结论（「调研：NovelAI 非自拍构图和多角色」第 6 节、「原型：配图实测」）。写规格前还要定这些细处：

- **风景在哪国**：只写 `street, dusk, city lights` 会画成俯瞰城市甚至欧洲小镇。补 `japan`，还是从地点池的条目带景物 tag（要地点池加字段的话，和「拍板：地点池怎么整理」对一下）；补了以后要不要出几张图验证。
- **桌边抓拍看镜头**：吃喝时 3/3 看镜头。接受（当成朋友对面拍她），还是修：抓拍默认补 `from side`/`profile`、正面写负权重 `-1::looking at viewer::`、吃喝时自动改成摆拍。修的话要出图验证。
- **她写的栏怎么清洗**：每种构图剥什么（无人构图剥 `1girl`、`solo`、`selfie`、`looking …`、`holding …`；单人和无人构图剥 `holding hands`），`people` 类补 `viewer holding phone`、`solo focus`，本地 tag 表补哪些种子、改写表加哪些（调研 6.3、6.4 的清单照搬还是删减）。
- **合照**：三人时 base 写 `group picture` 还是 `side-by-side`；「和谁」的人选范围（同组合、资料里有关系的）和任一人缺 `photo_tag`/`photo_appearance` 时怎么降级；OpenAI 形态的中转不提供合照时她怎么知道。
- **她给别的偶像拍**（单人提示词，主角换成别人）开不开放。
- 发请求时 `use_coords` 怎么写：返回的元数据把 `false` 记成了 `true`，要不要管。
