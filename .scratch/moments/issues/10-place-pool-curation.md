# 10: 拍板：地点池怎么整理

Type: grilling
Status: open
Blocked by: none

## Question

调研定了地点池是仓库里的数据文件（示意 `characters/places.toml`），运行时不查地图服务，点开跳 openstreetmap.org 的标记链接，不申请 Google key。还要定：

- **字段**：地名（日文、中文？她在动态里怎么写、页面上显示哪种）、经纬度、类别、有关的偶像或组合、圣地的出处（哪张卡面、哪段剧情），要不要「适合的时段、季节」。
- **来源和许可**：圣地（粉丝考据，40–60 处）、Wikidata（CC0）、OSM（ODbL：要署名，派生数据库要同许可）、各区开放数据，各取多少；ODbL 的署名和同许可要求能不能接受（天气署名已定只进 README 的致谢），不能接受的话只用 CC0 和手工整理的。
- **规模和分配**：300–500 个，按类别和偶像怎么分；后加入、没有考据点位的偶像怎么补。
- **谁来整理、怎么校对**：代理按来源出初稿、用户校对（像照片的外貌 tag 那样），还是只人工挑。
- **点开地图跳哪家**：openstreetmap.org、Google Maps URLs，还是别的；大陆用户能不能打开（调研没核实）。

起点：远端分支 `research/moments-place-pool` 上的 `.scratch/moments/research/place-pool.md`（第 1.4 节圣地样例、第 3 节扩充来源、第 6 节数据文件形状）。
