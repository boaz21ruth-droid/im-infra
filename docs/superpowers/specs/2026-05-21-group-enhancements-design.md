# 群聊增强第二批 — 设计规格

**日期：** 2026-05-21  
**范围：** im-wallet-app（纯前端）  
**不涉及：** im-business 后端、open-im-server、openim-sdk-core

---

## 模块一：管理员权限 UI

### 目标

群主可在"群管理"页设置/撤销管理员、禁言/解禁成员；管理员可禁言普通成员；踢人入口统一移到群管理页。

### 涉及文件

| 文件 | 变更类型 |
|------|---------|
| `pages/chat/group_setup/group_manage/group_manage_view.dart` | 扩展 UI：新增管理员区块 + 禁言区块 + 踢人入口 |
| `pages/chat/group_setup/group_manage/group_manage_logic.dart` | 新增 setAdmin / removeAdmin / muteUser / unmuteUser / kickUser 方法 |
| `pages/chat/group_setup/group_member_list/group_member_list_logic.dart` | 新增 `setAdmin` opType |
| `pages/chat/group_setup/group_member_list/group_member_list_view.dart` | 禁言成员头像加 🔇 角标 |

### 数据来源

- `GroupMembersInfo.roleLevel`：`GroupRoleLevel.owner=3 / admin=2 / member=1`
- `GroupMembersInfo.muteEndTime`：`> DateTime.now()` 即禁言中

### SDK 调用

```dart
// 设置/撤销管理员（群主专属）—— setGroupMemberRoleLevel 已 deprecated，底层均为 setGroupMemberInfo
OpenIM.iMManager.groupManager.setGroupMemberInfo(
  groupMembersInfo: GroupMembersInfo(
    groupID: groupID, userID: userID, roleLevel: GroupRoleLevel.admin /* or member */));

// 禁言（群主 + 管理员）：seconds > 0
OpenIM.iMManager.groupManager.changeGroupMemberMute(
  groupID: groupID, userID: userID, seconds: 86400 /* 1天 */);

// 解禁：seconds = 0
OpenIM.iMManager.groupManager.changeGroupMemberMute(
  groupID: groupID, userID: userID, seconds: 0);

// 踢人（群主 + 管理员）
OpenIM.iMManager.groupManager.kickGroupMember(
  groupID: groupID, userIDList: [userID], reason: '');
```

### GroupManagePage 布局

```
群管理
├── [区块 1] 管理员设置（仅群主可见）
│   ├── 当前管理员列表（头像行 + "撤销"按钮）
│   └── "添加管理员" → 成员选择页（opType: setAdmin）
├── [区块 2] 禁言管理（群主 + 管理员可见）
│   └── "禁言成员" → 成员选择页（opType: mute）→ 选择时长弹窗
└── [区块 3] 踢人
    └── "移除成员" → 成员选择页（opType: del，现有逻辑）
```

### 权限矩阵

| 操作 | 群主 | 管理员 | 普通成员 |
|------|:---:|:---:|:---:|
| 设置/撤销管理员 | ✅ | ❌ | ❌ |
| 禁言/解禁成员 | ✅ | ✅（不含其他管理员）| ❌ |
| 踢人 | ✅ | ✅（不含其他管理员）| ❌ |

### 禁言时长选项

弹窗提供：10 分钟 / 1 小时 / 1 天 / 永久（`seconds=0` 在 SDK 中表示永久）。

### 错误处理

SDK 调用失败时 `IMViews.showToast(e.toString())`，操作回滚（不更新本地状态）。

---

## 模块二：群文件库

### 目标

群成员可上传文件；群设置页有"群文件"入口；文件列表支持下载；使用自定义消息类型 914，无需后端改动。

### 自定义消息类型

```dart
// openim_common/lib/src/extension/message_manager.dart
class CustomMessageType {
  // ... existing ...
  static const groupFile = 914;
}
```

### 消息 Payload

```json
{
  "customType": 914,
  "data": {
    "name": "项目报告.pdf",
    "size": 204800,
    "url": "https://oss.example.com/files/xxx",
    "mimeType": "application/pdf",
    "uploaderID": "uid_123",
    "uploaderName": "张三"
  }
}
```

### 涉及文件

| 文件 | 变更类型 |
|------|---------|
| `openim_common/lib/src/extension/message_manager.dart` | 新增 `groupFile = 914` 常量 + `createGroupFileMessage()` 扩展方法 |
| `pages/chat/group_setup/group_setup_view.dart` | 新增"群文件"列表项（joined 成员可见）|
| `pages/chat/group_setup/group_setup_logic.dart` | 新增 `openGroupFiles()` 导航方法 |
| `routes/app_pages.dart` | 注册 `/groupFiles` 路由 |
| `routes/app_navigator.dart` | 新增 `startGroupFiles()` 方法 |
| `pages/chat/group_files/group_files_page.dart`（新建） | 文件列表页（binding + logic + view） |

### 上传流程

1. 输入框 `+` 菜单新增"发文件"条目（使用 `file_picker` 包）
2. 用户选文件 → `FilePickerResult`
3. 调用 `OpenIM.iMManager.uploadFile(file: path, name: name, cause: 'groupFile')` → 获得 `url`
4. 调用 `createCustomMessage` 发送 type-914 消息
5. 消息出现在聊天记录中（chat_view 渲染为文件气泡），同时进入群文件库

### 群文件页

- **数据获取：** `searchLocalMessages(conversationID, messageTypeList: [MessageType.custom])` 过滤 `customType == 914`
- **列表项：** 文件图标（按 mimeType）+ 文件名 + 文件大小（格式化）+ 上传者昵称 + 上传时间 + 下载按钮
- **下载：** `launchUrl(Uri.parse(url))`（浏览器打开）或 `Dio` 下载到本地相册/文件夹
- **空状态：** "暂无文件，发送文件后将在此显示"

### chat_view 文件气泡

在 `_buildCustomTypeItemView` 中处理 `customType == 914`，渲染简洁文件行（图标 + 名称 + 大小），点击下载。

---

## 模块三：投票

### 目标

任意群成员可在聊天中发起投票；气泡实时展示票数；每人限投一次（`multiVote=false` 默认）；通过 `editMessage` 更新票数，无需后端。

### 自定义消息类型

```dart
static const poll = 909;
```

### 消息 Payload

```json
{
  "customType": 909,
  "data": {
    "pollId": "550e8400-e29b-41d4-a716-446655440000",
    "question": "下次团建去哪？",
    "options": [
      {"text": "海边", "voterIDs": []},
      {"text": "山里", "voterIDs": ["uid_1", "uid_2"]}
    ],
    "multiVote": false,
    "creatorID": "uid_123",
    "createdAt": 1716288000
  }
}
```

### 涉及文件

| 文件 | 变更类型 |
|------|---------|
| `openim_common/lib/src/extension/message_manager.dart` | 新增 `poll = 909` 常量 + `createPollMessage()` 扩展方法 |
| `pages/chat/chat_logic.dart` | 新增 `createPoll()` 方法；处理 `messageEdited` 事件刷新投票气泡；新增 `votePoll()` 方法 |
| `pages/chat/chat_view.dart` | `_buildCustomTypeItemView` 处理 type-909，渲染 `PollBubble` |
| `widgets/poll_bubble.dart`（新建） | 投票气泡 Widget（StatelessWidget，从消息 data 读取） |
| `widgets/create_poll_sheet.dart`（新建） | 创建投票 BottomSheet |
| `pages/chat/chat_view.dart` | 输入框 `+` 菜单新增"投票"条目 |

### CreatePollSheet

- 标题输入框（必填）
- 2~5 个选项输入框（默认 2 个，"+ 添加选项"按钮动态增加）
- "允许多选"开关（默认关）
- "发起投票"按钮 → 生成 UUID → `createCustomMessage(type=909)` → 发送

### PollBubble 渲染

```
┌─────────────────────────────┐
│ 📊 下次团建去哪？             │
│                             │
│ ○ 海边  ████░░░░░  2票 40% │  ← 已投票时高亮
│ ○ 山里  ██░░░░░░░  1票 20% │
│                             │
│ 共 3 人参与                  │
└─────────────────────────────┘
```

- 未投票：选项可点击
- 已投票：显示进度条 + 票数，已选选项蓝色高亮，其他选项 disabled
- 自己是创建者：可看到所有投票详情（同已投票视图）

### 投票事件消息类型

SDK 无原生 editMessage 广播机制，采用与 type-908 editEvent **完全相同的事件消息模式**：

```dart
// openim_common/lib/src/extension/message_manager.dart
static const pollVote = 915;  // 新增
```

投票事件 Payload：
```json
{
  "customType": 915,
  "data": {
    "pollMsgID": "clientMsgID_of_type_909_message",
    "optionIndex": 1,
    "voterID": "uid_xxx"
  }
}
```

### 投票流程

```dart
void votePoll(Message pollMsg, int optionIndex) async {
  final myID = OpenIM.iMManager.userID;
  // 本地防重校验
  final data = json.decode(pollMsg.customElem!.data!)['data'];
  final alreadyVoted = (data['options'] as List)
      .any((o) => (o['voterIDs'] as List).contains(myID));
  if (alreadyVoted) return;
  // 本地立即更新（乐观）
  _applyVote(pollMsg.clientMsgID!, optionIndex, myID);
  // 广播 type-915 事件消息给其他成员
  final payload = json.encode({
    'customType': CustomMessageType.pollVote,
    'data': {'pollMsgID': pollMsg.clientMsgID, 'optionIndex': optionIndex, 'voterID': myID},
  });
  final voteMsg = await OpenIM.iMManager.messageManager.createCustomMessage(
    data: payload, extension: '', description: '');
  await _sendMessage(voteMsg);
}

void _applyVote(String pollMsgID, int optionIndex, String voterID) {
  final idx = messageList.indexWhere((m) => m.clientMsgID == pollMsgID);
  if (idx < 0) return;
  final raw = json.decode(messageList[idx].customElem!.data!);
  (raw['data']['options'][optionIndex]['voterIDs'] as List).add(voterID);
  messageList[idx].customElem!.data = json.encode(raw);
  messageList.refresh();
}
```

### type-915 事件接收处理

在 `chat_logic.dart` 的新消息监听处（已有 `_parseEditEvent`）新增 `_parsePollVoteEvent`：

```dart
bool _parsePollVoteEvent(Message msg) {
  if (msg.contentType != MessageType.custom) return false;
  try {
    final raw = json.decode(msg.customElem?.data ?? '{}');
    if (raw['customType'] != CustomMessageType.pollVote) return false;
    final d = raw['data'] as Map<String, dynamic>;
    _applyVote(d['pollMsgID'], d['optionIndex'], d['voterID']);
    return true;
  } catch (_) {
    return false;
  }
}
```

type-915 事件消息本身**不渲染气泡**（在 `_buildCustomTypeItemView` 中返回 `SizedBox.shrink()`）。

### 错误处理

- 网络失败：`showToast('投票失败，请重试')`，本地状态回滚
- 并发冲突（极低概率）：下次 `messageEdited` 事件到来时自动纠正

---

## 新增路由

```dart
// app_pages.dart
static const groupFiles = '/groupFiles';
```

## 自定义消息类型汇总

| 类型 | 值 | 说明 |
|------|----|----|
| `emoji` (reaction) | 902 | 已实现 |
| `gif` | 906 | 已实现 |
| `sticker` | 907 | 已实现 |
| `editEvent` | 908 | 已实现 |
| **`poll`** | **909** | **本批新增（投票创建消息）** |
| **`groupFile`** | **914** | **本批新增** |
| **`pollVote`** | **915** | **本批新增（投票事件，不渲染气泡）** |

## 实现顺序

1. 管理员权限 UI（纯逻辑，依赖最少）
2. 群文件库（需新路由 + 新 Widget）
3. 投票（最复杂，依赖事件消息基础设施）
