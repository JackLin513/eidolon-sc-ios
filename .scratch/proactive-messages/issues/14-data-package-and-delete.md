# 14: 数据包和删除带上搭话

**What to build:** 她搭的话和对话里的其他内容一样，跟着对话导出、导入、删除。导出的数据包里有搭话；导入到另一个部署后照原样显示，并算作看过。删历史对话或删账号时，搭话和它的日程一起删掉。规格见 `../spec.md`「数据包、删除、备份」。

**Blocked by:** 08

**Status:** ready-for-agent

- [ ] **导出**：每段对话的搭话（时间、原文、日语、字幕、分段）写进数据包，格式版本升一号。
- [ ] **导入**：
  - 新版本数据包带来的搭话照原样进对话，算作看过。
  - 旧版本的数据包照常能导入；比本版本新的照旧拒绝。
  - 用户的开关和搭话日程不进数据包。
- [ ] **删除**：删历史对话、删账号时，「搭话」和「搭话日程」两张表的数据一起删。表在 08 已登记过，这里补上测试和遗漏的删除路径。
- [ ] 格式说明文档跟着改。
- [ ] **测试**（后端）：
  - 导出的数据包里有搭话。
  - 导入后对话记录里有搭话，列表上不标「没看过」。
  - 旧版本的数据包照常能导入。
  - 删历史对话、删账号后没有残留。
  - 先例：`test_data_package_conversations.py`、`test_data_package.py`、`test_delete_past_conversations.py`。
- [ ] `sh scripts/affected-tests.sh <基点>` 通过，推送后 CI 全绿。

## Comments

### 票 08 交接

- 两张表已登记进 `database.USER_DATA` 和 `CONVERSATION_DATA`（顺序在 `conversations` 前面），删号时一起删已有测试（`test_deleting_the_user_deletes_them_and_when_she_was_to_come`）；删历史对话还没测。
- `Store.whole_conversations` 和 `add_carried_conversation` 还不带搭话。

### 票 13 交接

- 用户的开关（表 `reach_outs_off`）已经登记进 `USER_DATA`，删号时一起删，测试在 `test_reach_outs.py` 的删号测试里。数据包不导出它，导入也不碰它。
