---
status: accepted
---

# 选 LLM 的服务商和模型取自 models.dev，不自己维护一份

填 LLM 要写接口类型、接口地址和模型名三项，刚接触的用户多半只知道自己用的是哪家（DeepSeek、Gemini、智谱的编程套餐、ClinePass……），不知道这三项该怎么填（issue #146）。所以设置页的自带 LLM 和后台的模型上面加了「服务商」和「选择模型」两个可以搜索的下拉框：选了服务商就填好接口类型和地址，再选模型就填好模型名。名单取 models.dev：价格目录本来就每天拉它（`price_catalog.py`），它写了每家服务商的地址、用哪种 SDK（由此知道是哪种接口），以及每个模型能不能调用工具、是否已停用，还收录了各家的编程套餐。名单只用来填表：存下的仍然只是那三项，不记选的是哪家，保存时照常试调；三项也都还能手改，名单里没有的服务商和模型照旧手填。

## Considered Options

- **在前端写死一份常用服务商的表**：不依赖服务器拉没拉到目录，但服务商和编程套餐出得很快，每家又有好几个地址和模型，表很快就过时；理由同 ADR-0019 不维护兼容表。
- **填了地址和 key 后向服务商的 `/models` 现查模型**（magpie 的做法）：列出的是这把 key 实际能用的模型，最准，但要服务器拿用户的 key 去访问用户填的地址，得照 ADR-0022 再做一遍 SSRF 和代理的判断，而且各家 `/models` 的格式和是否开放不一。先不做，以后需要再加。

## Consequences

- 只列我们能说的接口：models.dev 记为 Anthropic SDK 的用 Anthropic Messages，OpenAI SDK 的用 Responses，Google、Bedrock 等自有协议的不列，其余按 OpenAI 兼容（Chat Completions）；模型写了 `shape` 的，按它在 Responses 和 Chat Completions 之间选。models.dev 没写地址的几家（OpenAI、Anthropic、Google 等）由代码给出地址，Google 用它的 OpenAI 兼容地址。不是 HTTPS、是 IP、`localhost`（连同 `*.localhost`）或模板地址（`${…}`）的不列。
- 同一家服务商的不同模型可能走不同接口（例如 CommandCode 的 Claude 走 Anthropic Messages），所以接口类型和地址按选的那个模型填，不只按服务商。
- 名单里的地址都是 ADR-0022 的已知服务商：模型自己写的地址（例如 freemodel 的 GPT 不在服务商的地址上）也一并记成已知服务商，所以选出来的 LLM 打开代理开关后都能走代理。
- 编辑已存的 LLM 时按地址认出是哪家，模型自己的地址也算；几家共用一个地址时（按量和编程套餐常这样，例如 MiniMax），认在这个地址有这个模型的那家。
- 服务器还没拉到目录（新部署、models.dev 访问不了）时没有名单，两个下拉框不显示，照旧手填；前端不记住空名单，下次打开表单再问。
- models.dev 只有英文名，搜「智谱」「火山」这类中文名靠前端一张只管搜索的别名表，连着打（「智谱套餐」）和隔开打一样；它不影响显示和填进去的值，过时了只是搜不到，选列表照样能用。
