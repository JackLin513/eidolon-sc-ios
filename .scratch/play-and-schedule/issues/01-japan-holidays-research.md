# 01: 调研：日本节假日的数据从哪来

Type: research
Status: resolved
Blocked by: none

## Question

日历要显示日本的节假日，她也要知道当天是不是节假日。查清楚数据从哪来、怎么维护：

- 祝日法的规则：固定日期的、按「第几个星期一」的（ハッピーマンデー）、春分秋分（每年由官方公布）、振替休日、国民の休日；近年的特例（比如奥运那年挪过的日子）。
- 可选的数据源：Python 库（`holidays`、`jpholiday` 等，看维护情况、许可、能算到哪一年、春分秋分怎么处理）、内阁府公布的 CSV、自己写静态表。各要多少维护（每年要不要手动更新）。
- 节假日以外常被当成「放假」的日子要不要算：年末年始、お盆、GW 这种不是祝日的连休，和日历显示、她知不知道有关；列出常见做法即可，不替我们定。
- 前端日历要不要也拿到这份数据（后端算好下发，还是前端另装库）。

结论按 `research` skill 的格式写，开头一节给明确建议。

## Answer

详见 `research/japan-holidays` 分支（c0fb9cc，已推到 origin）的 `.scratch/play-and-schedule/research/japan-holidays.md`，看时 `git show origin/research/japan-holidays:.scratch/play-and-schedule/research/japan-holidays.md`。

- 后端用 PyPI 的 `holidays`（MIT）算祝日。本机实测 0.107 和内阁府 CSV 1955–2027 年逐日一致（奥运挪动、2019 即位特例、振替休日、国民の休日都对），春分秋分 2020–2050 与国立天文台一致；差不多每周发版，靠 Dependabot 升级，平常不用手动维护。代价是多装 `python-dateutil`，约 11 MB。轻量备选是 `jpholiday`（无依赖，2026 年以后结果相同，发版慢）。
- 前端不另装库，由后端按年或按月下发「日期 + 名称」，日历显示的和她知道的出自同一处。
- 判断「今天是不是祝日」按东京时间（`Asia/Tokyo`），和北京时间划天差一小时。
- 年末年始、お盆、GW 不是祝日，库不给；年末年始有法律依据（政府机关 12/29–1/3，银行 12/31–1/3，`holidays` 的 `categories=BANK` 能给出银行那四天），お盆和 GW 没有法律定义。算不算由日历票定。
