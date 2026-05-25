# Group Enhancements Batch 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add admin permissions UI, group file library, and in-chat voting to the Flutter IM client.

**Architecture:** Three sequential phases. Phase 1 extends existing GroupManagePage with role/mute/kick controls. Phase 2 adds a file-sharing page (custom message type 914) and file bubble. Phase 3 adds polls (type 909 create + type 915 vote event) using the same event-message pattern as the existing editEvent (type 908).

**Tech Stack:** Flutter/GetX, flutter_openim_sdk 3.8.3, file_picker 10.3.3, uuid 4.2.1. All changes are pure Flutter — no backend changes.

---

## File Map

### Phase 1 — Admin Permissions UI

| File | Change |
|------|--------|
| `lib/pages/chat/group_setup/group_member_list/group_member_list_logic.dart` | Add `setAdmin`, `mute` to `GroupMemberOpType` enum; adjust filter + behavior |
| `lib/pages/chat/group_setup/group_manage/group_manage_logic.dart` | Add `adminList`, `loadAdminList`, `setAdmin`, `removeAdmin`, `muteUser`, `kickUser` |
| `lib/pages/chat/group_setup/group_manage/group_manage_view.dart` | Three new sections: admin list, mute entry, kick entry |

### Phase 2 — Group File Library

| File | Change |
|------|--------|
| `openim_common/lib/src/extension/message_manager.dart` | Add `groupFile = 914` + `createGroupFileMessage()` |
| `openim_common/lib/src/widgets/chat/chat_toolbox.dart` | Add `onTapFile` callback |
| `lib/pages/chat/chat_logic.dart` | Add `sendGroupFile()` |
| `lib/pages/chat/chat_view.dart` | Handle type-914 bubble; wire `onTapFile` |
| `lib/pages/chat/group_setup/group_setup_view.dart` | Add "群文件" entry |
| `lib/pages/chat/group_setup/group_setup_logic.dart` | Add `openGroupFiles()` |
| `lib/routes/app_routes.dart` | Add `groupFiles` constant |
| `lib/routes/app_pages.dart` | Register `/groupFiles` route |
| `lib/routes/app_navigator.dart` | Add `startGroupFiles()` |
| `lib/pages/chat/group_files/group_files_binding.dart` | **Create** |
| `lib/pages/chat/group_files/group_files_logic.dart` | **Create** |
| `lib/pages/chat/group_files/group_files_view.dart` | **Create** |

### Phase 3 — Voting

| File | Change |
|------|--------|
| `openim_common/lib/src/extension/message_manager.dart` | Add `poll = 909`, `pollVote = 915` |
| `openim_common/lib/src/widgets/chat/chat_toolbox.dart` | Add `onTapPoll` callback |
| `lib/pages/chat/create_poll_sheet.dart` | **Create** |
| `lib/pages/chat/poll_bubble.dart` | **Create** |
| `lib/pages/chat/chat_logic.dart` | Add `createPoll`, `votePoll`, `_applyVote`, `_parsePollVoteEvent` |
| `lib/pages/chat/chat_view.dart` | Handle type-909 bubble, hide type-915; wire `onTapPoll` |

---

## Phase 1 — Admin Permissions UI

### Task 1: Extend GroupMemberOpType with `setAdmin` and `mute`

**Files:**
- Modify: `lib/pages/chat/group_setup/group_member_list/group_member_list_logic.dart`

- [ ] **Step 1: Add two new opTypes to the enum**

In `group_member_list_logic.dart`, find the `GroupMemberOpType` enum (line 15) and add two values:

```dart
enum GroupMemberOpType {
  view,
  transferRight,
  call,
  at,
  del,
  setAdmin, // new
  mute,     // new
}
```

- [ ] **Step 2: Update `isMultiSelMode`**

`setAdmin` and `mute` are single-select, so no change needed — they're not in the `isMultiSelMode` list. Verify the getter is unchanged:

```dart
bool get isMultiSelMode =>
    opType == GroupMemberOpType.call || opType == GroupMemberOpType.at || opType == GroupMemberOpType.del;
```

- [ ] **Step 3: Update `excludeSelfFromList`**

Both `setAdmin` and `mute` should exclude the current user from the list. Modify:

```dart
bool get excludeSelfFromList =>
    opType == GroupMemberOpType.call ||
    opType == GroupMemberOpType.at ||
    opType == GroupMemberOpType.transferRight ||
    opType == GroupMemberOpType.setAdmin ||
    opType == GroupMemberOpType.mute;
```

- [ ] **Step 4: Update `_getGroupMembers` filter logic**

The filter for `setAdmin` should be regular members only (filter=3). The filter for `mute` depends on who is calling (owner can mute admins too, admin can only mute regular members). Add to the filter expression:

```dart
Future<List<GroupMembersInfo>> _getGroupMembers() {
  int filter = 0;
  if (isDelMember) {
    filter = isOwner ? 4 : (isAdmin ? 3 : 0);
  } else if (opType == GroupMemberOpType.setAdmin) {
    filter = 3; // regular members only — can only promote regular to admin
  } else if (opType == GroupMemberOpType.mute) {
    filter = isOwner ? 4 : 3; // owner: exclude owner (i.e. all others); admin: regular only
  }
  final result = OpenIM.iMManager.groupManager.getGroupMemberList(
    groupID: groupInfo.groupID,
    count: count,
    offset: memberList.length,
    filter: filter,
  );
  count = 100;
  return result;
}
```

- [ ] **Step 5: Update `clickMember` for new opTypes**

Both `setAdmin` and `mute` use single-select returning `GroupMembersInfo`. Add their cases before the `isMultiSelMode` check:

```dart
clickMember(GroupMembersInfo membersInfo) async {
  if (opType == GroupMemberOpType.transferRight) {
    _transferGroupRight(membersInfo);
    return;
  }
  if (opType == GroupMemberOpType.setAdmin || opType == GroupMemberOpType.mute) {
    Get.back(result: membersInfo);
    return;
  }
  if (isMultiSelMode) {
    if (isChecked(membersInfo)) {
      checkedList.remove(membersInfo);
    } else if (checkedList.length < maxLength) {
      checkedList.add(membersInfo);
    }
  } else {
    viewMemberInfo(membersInfo);
  }
}
```

- [ ] **Step 6: Verify compilation**

```bash
cd /Users/web1/go/im/im-wallet-app
fvm flutter analyze lib/pages/chat/group_setup/group_member_list/group_member_list_logic.dart
```

Expected: no errors.

---

### Task 2: Extend GroupManageLogic with admin/mute/kick methods

**Files:**
- Modify: `lib/pages/chat/group_setup/group_manage/group_manage_logic.dart`

- [ ] **Step 1: Replace the entire file content**

```dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_openim_sdk/flutter_openim_sdk.dart';
import 'package:get/get.dart';
import 'package:openim/pages/chat/group_setup/group_setup_logic.dart';
import 'package:openim_common/openim_common.dart';

import '../../../../routes/app_navigator.dart';
import '../group_member_list/group_member_list_logic.dart';

class GroupManageLogic extends GetxController {
  final groupSetupLogic = Get.find<GroupSetupLogic>();
  late StreamSubscription _mISub;

  Rx<GroupInfo> get groupInfo => groupSetupLogic.groupInfo;
  bool get isOwner => groupSetupLogic.isOwner;
  bool get isOwnerOrAdmin => groupSetupLogic.isOwnerOrAdmin;

  final adminList = <GroupMembersInfo>[].obs;

  @override
  void onInit() {
    final imLogic = groupSetupLogic.imLogic;
    _mISub = imLogic.memberInfoChangedSubject.listen((e) {
      if (e.groupID == groupInfo.value.groupID) _refreshAdminEntry(e);
    });
    super.onInit();
  }

  @override
  void onReady() {
    _loadAdminList();
    super.onReady();
  }

  @override
  void onClose() {
    _mISub.cancel();
    super.onClose();
  }

  Future<void> _loadAdminList() async {
    final list = await OpenIM.iMManager.groupManager.getGroupMemberList(
      groupID: groupInfo.value.groupID,
      filter: 2, // admins only
      count: 100,
      offset: 0,
    );
    adminList.assignAll(list);
  }

  void _refreshAdminEntry(GroupMembersInfo updated) {
    final idx = adminList.indexWhere((m) => m.userID == updated.userID);
    if (updated.roleLevel == GroupRoleLevel.admin) {
      if (idx < 0) adminList.add(updated);
    } else {
      if (idx >= 0) adminList.removeAt(idx);
    }
  }

  void transferGroupOwnerRight() async {
    var result = await AppNavigator.startGroupMemberList(
      groupInfo: groupInfo.value,
      opType: GroupMemberOpType.transferRight,
    );
    if (result is GroupMembersInfo) {
      await LoadingView.singleton.wrap(
        asyncFunction: () => OpenIM.iMManager.groupManager.transferGroupOwner(
          groupID: groupInfo.value.groupID,
          userID: result.userID!,
        ),
      );
      groupInfo.update((val) {
        val?.ownerUserID = result.userID;
      });
      Get.back();
    }
  }

  void setAdmin() async {
    final result = await AppNavigator.startGroupMemberList(
      groupInfo: groupInfo.value,
      opType: GroupMemberOpType.setAdmin,
    );
    if (result is GroupMembersInfo) {
      await LoadingView.singleton.wrap(
        asyncFunction: () => OpenIM.iMManager.groupManager.setGroupMemberInfo(
          groupMembersInfo: GroupMembersInfo(
            groupID: groupInfo.value.groupID,
            userID: result.userID,
            roleLevel: GroupRoleLevel.admin,
          ),
        ),
      );
      await _loadAdminList();
    }
  }

  void removeAdmin(GroupMembersInfo member) async {
    final confirm = await Get.dialog(CustomDialog(
      title: '确认撤销 ${member.nickname} 的管理员权限？',
    ));
    if (confirm != true) return;
    await LoadingView.singleton.wrap(
      asyncFunction: () => OpenIM.iMManager.groupManager.setGroupMemberInfo(
        groupMembersInfo: GroupMembersInfo(
          groupID: groupInfo.value.groupID,
          userID: member.userID,
          roleLevel: GroupRoleLevel.member,
        ),
      ),
    );
    await _loadAdminList();
  }

  void muteUser() async {
    final result = await AppNavigator.startGroupMemberList(
      groupInfo: groupInfo.value,
      opType: GroupMemberOpType.mute,
    );
    if (result is! GroupMembersInfo) return;
    final seconds = await _showMuteDurationDialog();
    if (seconds == null) return;
    await LoadingView.singleton.wrap(
      asyncFunction: () => OpenIM.iMManager.groupManager.changeGroupMemberMute(
        groupID: groupInfo.value.groupID,
        userID: result.userID!,
        seconds: seconds,
      ),
    );
  }

  void unmuteUser(GroupMembersInfo member) async {
    await LoadingView.singleton.wrap(
      asyncFunction: () => OpenIM.iMManager.groupManager.changeGroupMemberMute(
        groupID: groupInfo.value.groupID,
        userID: member.userID!,
        seconds: 0,
      ),
    );
  }

  void kickUser() async {
    final result = await AppNavigator.startGroupMemberList(
      groupInfo: groupInfo.value,
      opType: GroupMemberOpType.del,
    );
    if (result is List<GroupMembersInfo> && result.isNotEmpty) {
      await LoadingView.singleton.wrap(
        asyncFunction: () => OpenIM.iMManager.groupManager.kickGroupMember(
          groupID: groupInfo.value.groupID,
          userIDList: result.map((e) => e.userID!).toList(),
          reason: '',
        ),
      );
    }
  }

  Future<int?> _showMuteDurationDialog() => Get.dialog<int>(
        AlertDialog(
          title: const Text('选择禁言时长'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(title: const Text('10 分钟'), onTap: () => Get.back(result: 600)),
              ListTile(title: const Text('1 小时'), onTap: () => Get.back(result: 3600)),
              ListTile(title: const Text('1 天'), onTap: () => Get.back(result: 86400)),
              ListTile(title: const Text('永久'), onTap: () => Get.back(result: 2592000)),
            ],
          ),
        ),
      );
}
```

- [ ] **Step 2: Verify compilation**

```bash
fvm flutter analyze lib/pages/chat/group_setup/group_manage/group_manage_logic.dart
```

Expected: no errors.

---

### Task 3: Update GroupManagePage UI

**Files:**
- Modify: `lib/pages/chat/group_setup/group_manage/group_manage_view.dart`

- [ ] **Step 1: Replace the entire file content**

```dart
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_openim_sdk/flutter_openim_sdk.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:get/get.dart';
import 'package:openim_common/openim_common.dart';

import 'group_manage_logic.dart';

class GroupManagePage extends StatelessWidget {
  final logic = Get.find<GroupManageLogic>();

  GroupManagePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: TitleBar.back(title: StrRes.groupManage),
      backgroundColor: Styles.c_F8F9FA,
      body: Obx(() => SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                10.verticalSpace,
                // ── Transfer ownership ──
                _buildItemView(
                  text: StrRes.transferGroupOwnerRight,
                  onTap: logic.transferGroupOwnerRight,
                  showRightArrow: true,
                  isTopRadius: true,
                  isBottomRadius: true,
                ),
                if (logic.isOwner) ...[
                  20.verticalSpace,
                  // ── Admin section (owner only) ──
                  Padding(
                    padding: EdgeInsets.only(left: 16.w, bottom: 6.h),
                    child: '管理员'.toText..style = Styles.ts_8E9AB0_14sp,
                  ),
                  Container(
                    margin: EdgeInsets.symmetric(horizontal: 10.w),
                    decoration: BoxDecoration(
                      color: Styles.c_FFFFFF,
                      borderRadius: BorderRadius.circular(6.r),
                    ),
                    child: Column(
                      children: [
                        ...logic.adminList.asMap().entries.map((entry) {
                          final member = entry.value;
                          final isLast = entry.key == logic.adminList.length - 1 && logic.adminList.isNotEmpty;
                          return _buildMemberRow(
                            member: member,
                            showDivider: !isLast,
                            trailing: GestureDetector(
                              onTap: () => logic.removeAdmin(member),
                              child: Container(
                                padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 4.h),
                                decoration: BoxDecoration(
                                  border: Border.all(color: Styles.c_E8EAEF),
                                  borderRadius: BorderRadius.circular(4.r),
                                ),
                                child: '撤销'.toText..style = Styles.ts_8E9AB0_14sp,
                              ),
                            ),
                          );
                        }),
                        _buildItemView(
                          text: '添加管理员',
                          onTap: logic.setAdmin,
                          showRightArrow: true,
                          isTopRadius: logic.adminList.isEmpty,
                          isBottomRadius: true,
                        ),
                      ],
                    ),
                  ),
                ],
                20.verticalSpace,
                // ── Mute section (owner + admin) ──
                Padding(
                  padding: EdgeInsets.only(left: 16.w, bottom: 6.h),
                  child: '禁言管理'.toText..style = Styles.ts_8E9AB0_14sp,
                ),
                _buildItemView(
                  text: '禁言成员',
                  onTap: logic.muteUser,
                  showRightArrow: true,
                  isTopRadius: true,
                  isBottomRadius: true,
                ),
                20.verticalSpace,
                // ── Kick section (owner + admin) ──
                Padding(
                  padding: EdgeInsets.only(left: 16.w, bottom: 6.h),
                  child: '成员管理'.toText..style = Styles.ts_8E9AB0_14sp,
                ),
                _buildItemView(
                  text: '移除成员',
                  onTap: logic.kickUser,
                  showRightArrow: true,
                  isTopRadius: true,
                  isBottomRadius: true,
                ),
                40.verticalSpace,
              ],
            ),
          )),
    );
  }

  Widget _buildMemberRow({
    required GroupMembersInfo member,
    bool showDivider = true,
    Widget? trailing,
  }) =>
      Column(
        children: [
          Container(
            height: 64.h,
            padding: EdgeInsets.symmetric(horizontal: 16.w),
            child: Row(
              children: [
                AvatarView(
                  url: member.faceURL,
                  text: member.nickname,
                  width: 44.w,
                  height: 44.h,
                ),
                10.horizontalSpace,
                Expanded(
                  child: (member.nickname ?? '').toText
                    ..style = Styles.ts_0C1C33_17sp
                    ..maxLines = 1
                    ..overflow = TextOverflow.ellipsis,
                ),
                if (trailing != null) trailing,
              ],
            ),
          ),
          if (showDivider)
            Container(
              height: 1,
              margin: EdgeInsets.only(left: 70.w),
              color: Styles.c_E8EAEF,
            ),
        ],
      );

  Widget _buildItemView({
    required String text,
    TextStyle? textStyle,
    String? value,
    bool isTopRadius = false,
    bool isBottomRadius = false,
    bool showRightArrow = false,
    Function()? onTap,
  }) =>
      GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.translucent,
        child: Container(
          height: 46.h,
          margin: EdgeInsets.symmetric(horizontal: 10.w),
          padding: EdgeInsets.symmetric(horizontal: 16.w),
          decoration: BoxDecoration(
            color: Styles.c_FFFFFF,
            borderRadius: BorderRadius.only(
              topRight: Radius.circular(isTopRadius ? 6.r : 0),
              topLeft: Radius.circular(isTopRadius ? 6.r : 0),
              bottomLeft: Radius.circular(isBottomRadius ? 6.r : 0),
              bottomRight: Radius.circular(isBottomRadius ? 6.r : 0),
            ),
          ),
          child: Row(
            children: [
              Expanded(child: text.toText..style = textStyle ?? Styles.ts_0C1C33_17sp),
              if (null != value) value.toText..style = Styles.ts_8E9AB0_14sp,
              if (showRightArrow)
                ImageRes.rightArrow.toImage
                  ..width = 24.w
                  ..height = 24.h,
            ],
          ),
        ),
      );
}
```

- [ ] **Step 2: Verify and run analyze**

```bash
fvm flutter analyze lib/pages/chat/group_setup/group_manage/
```

Expected: no errors.

- [ ] **Step 3: Commit Phase 1**

```bash
git add lib/pages/chat/group_setup/group_manage/ \
        lib/pages/chat/group_setup/group_member_list/group_member_list_logic.dart
git commit -m "feat: admin permissions UI — set/remove admin, mute, kick in GroupManagePage"
```

---

## Phase 2 — Group File Library

### Task 4: Add type-914 constant and createGroupFileMessage helper

**Files:**
- Modify: `openim_common/lib/src/extension/message_manager.dart`

- [ ] **Step 1: Add `groupFile = 914` to CustomMessageType**

Find the `class CustomMessageType` block (line 101) and add the constant:

```dart
class CustomMessageType {
  static const callingInvite = 200;
  static const callingAccept = 201;
  static const callingReject = 202;
  static const callingCancel = 203;
  static const callingHungup = 204;

  static const call = 901;
  static const emoji = 902;
  static const tag = 903;
  static const moments = 904;
  static const meeting = 905;
  static const blockedByFriend = 910;
  static const deletedByFriend = 911;
  static const removedFromGroup = 912;
  static const groupDisbanded = 913;

  static const gif = 906;
  static const sticker = 907;
  static const editEvent = 908;
  static const groupFile = 914; // new
}
```

- [ ] **Step 2: Add `createGroupFileMessage` extension method**

Below the existing `createCustomEmojiMessage` method in `MessageManagerExt`, add:

```dart
Future<Message> createGroupFileMessage({
  required String url,
  required String name,
  required int size,
  required String mimeType,
  required String uploaderID,
  required String uploaderName,
}) =>
    createCustomMessage(
      data: json.encode({
        'customType': CustomMessageType.groupFile,
        'data': {
          'url': url,
          'name': name,
          'size': size,
          'mimeType': mimeType,
          'uploaderID': uploaderID,
          'uploaderName': uploaderName,
        },
      }),
      extension: '',
      description: '[文件] $name',
    );
```

- [ ] **Step 3: Verify**

```bash
fvm flutter analyze openim_common/lib/src/extension/message_manager.dart
```

---

### Task 5: Add `onTapFile` to ChatToolBox

**Files:**
- Modify: `openim_common/lib/src/widgets/chat/chat_toolbox.dart`

- [ ] **Step 1: Add `onTapFile` parameter to ChatToolBox**

```dart
class ChatToolBox extends StatelessWidget {
  const ChatToolBox({
    super.key,
    this.onTapAlbum,
    this.onTapCall,
    this.onTapGif,
    this.onTapSticker,
    this.onTapFile,  // new
  });
  final Function()? onTapAlbum;
  final Function()? onTapCall;
  final Function()? onTapGif;
  final Function()? onTapSticker;
  final Function()? onTapFile;  // new
```

- [ ] **Step 2: Add file item to the items list in `build`**

After the `if (onTapSticker != null)` block, add:

```dart
if (onTapFile != null)
  ToolboxItemInfo(
    text: '文件',
    icon: ImageRes.toolboxAlbum,
    onTap: onTapFile,
    isFile: true,
  ),
```

- [ ] **Step 3: Add `isFile` field to `ToolboxItemInfo`**

```dart
class ToolboxItemInfo {
  String text;
  String icon;
  Function()? onTap;
  bool isGif;
  bool isSticker;
  bool isFile;  // new

  ToolboxItemInfo({
    required this.text,
    required this.icon,
    this.onTap,
    this.isGif = false,
    this.isSticker = false,
    this.isFile = false,  // new
  });
}
```

- [ ] **Step 4: Render file item in `itemBuilder`**

In the `itemBuilder` closure, add before the default `_buildItemView` call:

```dart
if (item.isFile) {
  return _buildTextItemView(text: '📁', label: item.text, onTap: item.onTap);
}
```

- [ ] **Step 5: Verify**

```bash
fvm flutter analyze openim_common/lib/src/widgets/chat/chat_toolbox.dart
```

---

### Task 6: Add `sendGroupFile` to ChatLogic

**Files:**
- Modify: `lib/pages/chat/chat_logic.dart`

- [ ] **Step 1: Add file_picker import if not present**

Check the top of `chat_logic.dart` for `file_picker` import. If missing, add:

```dart
import 'package:file_picker/file_picker.dart';
import 'dart:async';
```

(`dart:async` is likely already imported for StreamSubscription.)

- [ ] **Step 2: Add `sendGroupFile` method**

Add after the `sendSticker` method (around line 638):

```dart
// --- 群文件 ---
void sendGroupFile() async {
  final result = await FilePicker.platform.pickFiles(
    type: FileType.any,
    withData: false,
  );
  if (result == null || result.files.isEmpty) return;
  final file = result.files.first;
  if (file.path == null) return;

  final uploadId = DateTime.now().millisecondsSinceEpoch.toString();
  final completer = Completer<String>();
  OpenIM.iMManager.setUploadFileListener(OnUploadFileListener(
    onComplete: (id, size, url, type) {
      if (id == uploadId) completer.complete(url);
    },
  ));

  try {
    await LoadingView.singleton.wrap(asyncFunction: () async {
      await OpenIM.iMManager.uploadFile(
        id: uploadId,
        filePath: file.path!,
        fileName: file.name,
        contentType: file.extension != null ? 'application/${file.extension}' : 'application/octet-stream',
        cause: 'groupFile',
      );
      final url = await completer.future.timeout(const Duration(seconds: 60));
      final myInfo = appLogic.userInfo.value;
      final msg = await OpenIM.iMManager.messageManager.createGroupFileMessage(
        url: url,
        name: file.name,
        size: file.size,
        mimeType: file.extension != null ? 'application/${file.extension}' : 'application/octet-stream',
        uploaderID: OpenIM.iMManager.userID,
        uploaderName: myInfo.nickname ?? '',
      );
      await _sendMessage(msg);
    });
  } catch (e) {
    IMViews.showToast('文件上传失败: $e');
  }
}
```

- [ ] **Step 3: Verify**

```bash
fvm flutter analyze lib/pages/chat/chat_logic.dart
```

---

### Task 7: Wire `onTapFile` in ChatView + render type-914 bubble

**Files:**
- Modify: `lib/pages/chat/chat_view.dart`

- [ ] **Step 1: Wire `onTapFile` in the `ChatToolBox` instantiation** (around line 235)

```dart
toolbox: ChatToolBox(
  onTapAlbum: logic.onTapAlbum,
  onTapCall: logic.isGroupChat ? null : logic.call,
  onTapGif: () => _showGifPicker(context),
  onTapSticker: () => _showStickerPanel(context),
  onTapFile: logic.isGroupChat ? logic.sendGroupFile : null,  // new
),
```

- [ ] **Step 2: Add type-914 handler in `_buildCustomTypeItemView`**

Find the `} else if (viewType == CustomMessageType.sticker) {` block (around line 176) and add after it, before the closing `}`:

```dart
} else if (viewType == CustomMessageType.groupFile) {
  final fileData = data['data'] as Map<String, dynamic>? ?? {};
  final name = fileData['name'] as String? ?? '未知文件';
  final size = fileData['size'] as int? ?? 0;
  final url = fileData['url'] as String? ?? '';
  return CustomTypeInfo(
    GestureDetector(
      onTap: () async {
        if (url.isNotEmpty) await launchUrl(Uri.parse(url));
      },
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
        constraints: BoxConstraints(maxWidth: 220.w),
        decoration: BoxDecoration(
          color: Styles.c_FFFFFF,
          borderRadius: BorderRadius.circular(8.r),
          border: Border.all(color: Styles.c_E8EAEF),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            '📁'.toText..style = TextStyle(fontSize: 28.sp),
            10.horizontalSpace,
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  name.toText
                    ..style = Styles.ts_0C1C33_14sp
                    ..maxLines = 2
                    ..overflow = TextOverflow.ellipsis,
                  4.verticalSpace,
                  _formatFileSize(size).toText..style = Styles.ts_8E9AB0_12sp,
                ],
              ),
            ),
          ],
        ),
      ),
    ),
    false,
    true,
  );
}
```

- [ ] **Step 3: Add `_formatFileSize` helper at the bottom of `ChatPage`**

Add inside the `ChatPage` class (after the `_showStickerPanel` method):

```dart
String _formatFileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}
```

- [ ] **Step 4: Add `url_launcher` import if missing**

Check top of `chat_view.dart` for `url_launcher`. If missing:
```dart
import 'package:url_launcher/url_launcher.dart';
```

(Check `pubspec.yaml` — `url_launcher` is a standard dependency in this project.)

- [ ] **Step 5: Verify**

```bash
fvm flutter analyze lib/pages/chat/chat_view.dart
```

---

### Task 8: Create GroupFilesPage (binding + logic + view)

**Files:**
- Create: `lib/pages/chat/group_files/group_files_binding.dart`
- Create: `lib/pages/chat/group_files/group_files_logic.dart`
- Create: `lib/pages/chat/group_files/group_files_view.dart`

- [ ] **Step 1: Create the binding**

```dart
// lib/pages/chat/group_files/group_files_binding.dart
import 'package:get/get.dart';
import 'group_files_logic.dart';

class GroupFilesBinding extends Bindings {
  @override
  void dependencies() {
    Get.lazyPut<GroupFilesLogic>(() => GroupFilesLogic());
  }
}
```

- [ ] **Step 2: Create the logic**

```dart
// lib/pages/chat/group_files/group_files_logic.dart
import 'dart:convert';

import 'package:flutter_openim_sdk/flutter_openim_sdk.dart';
import 'package:get/get.dart';
import 'package:openim_common/openim_common.dart';

class GroupFileItem {
  final String url;
  final String name;
  final int size;
  final String mimeType;
  final String uploaderID;
  final String uploaderName;
  final int sendTime;

  GroupFileItem({
    required this.url,
    required this.name,
    required this.size,
    required this.mimeType,
    required this.uploaderID,
    required this.uploaderName,
    required this.sendTime,
  });

  factory GroupFileItem.fromMessage(Message msg) {
    final raw = json.decode(msg.customElem?.data ?? '{}');
    final d = raw['data'] as Map<String, dynamic>? ?? {};
    return GroupFileItem(
      url: d['url'] as String? ?? '',
      name: d['name'] as String? ?? '未知文件',
      size: d['size'] as int? ?? 0,
      mimeType: d['mimeType'] as String? ?? '',
      uploaderID: d['uploaderID'] as String? ?? '',
      uploaderName: d['uploaderName'] as String? ?? '',
      sendTime: msg.sendTime ?? 0,
    );
  }

  String get formattedSize {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    if (size < 1024 * 1024 * 1024) return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(size / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

class GroupFilesLogic extends GetxController {
  late String conversationID;
  final files = <GroupFileItem>[].obs;
  final isLoading = true.obs;
  int _pageIndex = 1;
  static const _pageSize = 40;
  bool _hasMore = true;

  @override
  void onInit() {
    conversationID = Get.arguments['conversationID'] as String;
    super.onInit();
  }

  @override
  void onReady() {
    _load();
    super.onReady();
  }

  Future<void> _load() async {
    if (!_hasMore) return;
    try {
      final result = await OpenIM.iMManager.messageManager.searchLocalMessages(
        conversationID: conversationID,
        messageTypeList: [MessageType.custom],
        pageIndex: _pageIndex,
        count: _pageSize,
      );
      final msgs = result.searchResultItems?.expand((item) => item.messageList ?? []).toList() ?? [];
      final filtered = msgs
          .where((m) {
            try {
              final raw = json.decode(m.customElem?.data ?? '{}');
              return raw['customType'] == CustomMessageType.groupFile;
            } catch (_) {
              return false;
            }
          })
          .map(GroupFileItem.fromMessage)
          .toList();
      filtered.sort((a, b) => b.sendTime.compareTo(a.sendTime));
      files.addAll(filtered);
      if (msgs.length < _pageSize) _hasMore = false;
      _pageIndex++;
    } catch (e) {
      IMViews.showToast('加载失败: $e');
    } finally {
      isLoading.value = false;
    }
  }

  Future<void> loadMore() => _load();

  void refresh() {
    files.clear();
    _pageIndex = 1;
    _hasMore = true;
    isLoading.value = true;
    _load();
  }
}
```

- [ ] **Step 3: Create the view**

```dart
// lib/pages/chat/group_files/group_files_view.dart
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:get/get.dart';
import 'package:openim_common/openim_common.dart';
import 'package:url_launcher/url_launcher.dart';

import 'group_files_logic.dart';

class GroupFilesPage extends StatelessWidget {
  final logic = Get.find<GroupFilesLogic>();

  GroupFilesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: TitleBar.back(title: '群文件'),
      backgroundColor: Styles.c_F8F9FA,
      body: Obx(() {
        if (logic.isLoading.value) {
          return const Center(child: CircularProgressIndicator());
        }
        if (logic.files.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                '📁'.toText..style = TextStyle(fontSize: 48.sp),
                16.verticalSpace,
                '暂无文件'.toText..style = Styles.ts_8E9AB0_14sp,
                8.verticalSpace,
                '在聊天中发送文件后将在此显示'.toText..style = Styles.ts_8E9AB0_12sp,
              ],
            ),
          );
        }
        return ListView.separated(
          itemCount: logic.files.length,
          separatorBuilder: (_, __) => Container(
            height: 1,
            margin: EdgeInsets.only(left: 72.w),
            color: Styles.c_E8EAEF,
          ),
          itemBuilder: (_, index) => _buildFileItem(logic.files[index]),
        );
      }),
    );
  }

  Widget _buildFileItem(GroupFileItem file) => GestureDetector(
        onTap: () async {
          if (file.url.isNotEmpty) await launchUrl(Uri.parse(file.url));
        },
        child: Container(
          height: 72.h,
          color: Styles.c_FFFFFF,
          padding: EdgeInsets.symmetric(horizontal: 16.w),
          child: Row(
            children: [
              Container(
                width: 44.w,
                height: 44.h,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Styles.c_F0F2F6,
                  borderRadius: BorderRadius.circular(8.r),
                ),
                child: '📁'.toText..style = TextStyle(fontSize: 22.sp),
              ),
              12.horizontalSpace,
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    file.name.toText
                      ..style = Styles.ts_0C1C33_15sp
                      ..maxLines = 1
                      ..overflow = TextOverflow.ellipsis,
                    4.verticalSpace,
                    Row(
                      children: [
                        file.formattedSize.toText..style = Styles.ts_8E9AB0_12sp,
                        4.horizontalSpace,
                        '·'.toText..style = Styles.ts_8E9AB0_12sp,
                        4.horizontalSpace,
                        file.uploaderName.toText..style = Styles.ts_8E9AB0_12sp,
                      ],
                    ),
                  ],
                ),
              ),
              ImageRes.rightArrow.toImage
                ..width = 20.w
                ..height = 20.h,
            ],
          ),
        ),
      );
}
```

- [ ] **Step 4: Verify all three files**

```bash
fvm flutter analyze lib/pages/chat/group_files/
```

---

### Task 9: Register route + navigator + group setup entry

**Files:**
- Modify: `lib/routes/app_routes.dart`
- Modify: `lib/routes/app_pages.dart`
- Modify: `lib/routes/app_navigator.dart`
- Modify: `lib/pages/chat/group_setup/group_setup_logic.dart`
- Modify: `lib/pages/chat/group_setup/group_setup_view.dart`

- [ ] **Step 1: Add route constant to `app_routes.dart`**

Inside `abstract class AppRoutes`, add:

```dart
static const groupFiles = '/group_files';
```

- [ ] **Step 2: Register route in `app_pages.dart`**

Add at the top, import the new binding and view:

```dart
import '../pages/chat/group_files/group_files_binding.dart';
import '../pages/chat/group_files/group_files_view.dart';
```

Add to the `routes` list (anywhere in the list):

```dart
_pageBuilder(
  name: AppRoutes.groupFiles,
  page: () => GroupFilesPage(),
  binding: GroupFilesBinding(),
),
```

- [ ] **Step 3: Add navigator method to `app_navigator.dart`**

```dart
static startGroupFiles({required String conversationID}) =>
    Get.toNamed(AppRoutes.groupFiles, arguments: {'conversationID': conversationID});
```

- [ ] **Step 4: Add `openGroupFiles` to `group_setup_logic.dart`**

Add the method to `GroupSetupLogic`:

```dart
void openGroupFiles() {
  AppNavigator.startGroupFiles(
    conversationID: conversationInfo.value.conversationID,
  );
}
```

- [ ] **Step 5: Add "群文件" list item to `group_setup_view.dart`**

Find the `if (logic.isJoinedGroup.value)` section that shows `groupAnnouncement`, and add a "群文件" item after it:

```dart
if (logic.isJoinedGroup.value)
  _buildItemView(
    text: '群文件',
    showRightArrow: true,
    onTap: logic.openGroupFiles,
  ),
```

- [ ] **Step 6: Verify and commit**

```bash
fvm flutter analyze lib/routes/ lib/pages/chat/group_setup/
git add lib/pages/chat/group_files/ \
        openim_common/lib/src/extension/message_manager.dart \
        openim_common/lib/src/widgets/chat/chat_toolbox.dart \
        lib/pages/chat/chat_logic.dart \
        lib/pages/chat/chat_view.dart \
        lib/pages/chat/group_setup/group_setup_logic.dart \
        lib/pages/chat/group_setup/group_setup_view.dart \
        lib/routes/app_routes.dart \
        lib/routes/app_pages.dart \
        lib/routes/app_navigator.dart
git commit -m "feat: group file library — type-914 custom message, upload, GroupFilesPage"
```

---

## Phase 3 — Voting

### Task 10: Add type-909 and type-915 constants

**Files:**
- Modify: `openim_common/lib/src/extension/message_manager.dart`

- [ ] **Step 1: Add to `CustomMessageType`**

```dart
static const poll = 909;       // new: poll creation message
static const groupFile = 914;  // already added in Task 4
static const pollVote = 915;   // new: vote event (not rendered in bubble)
```

- [ ] **Step 2: Verify**

```bash
fvm flutter analyze openim_common/lib/src/extension/message_manager.dart
```

---

### Task 11: Create `CreatePollSheet`

**Files:**
- Create: `lib/pages/chat/create_poll_sheet.dart`

- [ ] **Step 1: Create the file**

```dart
// lib/pages/chat/create_poll_sheet.dart
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:get/get.dart';
import 'package:openim_common/openim_common.dart';

class CreatePollResult {
  final String question;
  final List<String> options;
  final bool multiVote;

  const CreatePollResult({
    required this.question,
    required this.options,
    required this.multiVote,
  });
}

class CreatePollSheet extends StatefulWidget {
  const CreatePollSheet({super.key});

  @override
  State<CreatePollSheet> createState() => _CreatePollSheetState();
}

class _CreatePollSheetState extends State<CreatePollSheet> {
  final _questionCtrl = TextEditingController();
  final _optionCtrls = [TextEditingController(), TextEditingController()];
  bool _multiVote = false;

  @override
  void dispose() {
    _questionCtrl.dispose();
    for (final c in _optionCtrls) c.dispose();
    super.dispose();
  }

  void _addOption() {
    if (_optionCtrls.length >= 5) return;
    setState(() => _optionCtrls.add(TextEditingController()));
  }

  void _submit() {
    final question = _questionCtrl.text.trim();
    if (question.isEmpty) {
      IMViews.showToast('请输入投票标题');
      return;
    }
    final options = _optionCtrls.map((c) => c.text.trim()).where((s) => s.isNotEmpty).toList();
    if (options.length < 2) {
      IMViews.showToast('至少需要 2 个选项');
      return;
    }
    Get.back(result: CreatePollResult(question: question, options: options, multiVote: _multiVote));
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(maxHeight: 600.h),
      decoration: BoxDecoration(
        color: Styles.c_FFFFFF,
        borderRadius: BorderRadius.vertical(top: Radius.circular(12.r)),
      ),
      child: Column(
        children: [
          Container(
            padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 14.h),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: Styles.c_E8EAEF)),
            ),
            child: Row(
              children: [
                GestureDetector(
                  onTap: Get.back,
                  child: '取消'.toText..style = Styles.ts_8E9AB0_17sp,
                ),
                const Spacer(),
                '发起投票'.toText..style = Styles.ts_0C1C33_17sp_medium,
                const Spacer(),
                GestureDetector(
                  onTap: _submit,
                  child: '发送'.toText..style = Styles.ts_0089FF_17sp,
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: EdgeInsets.all(16.w),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  '投票标题'.toText..style = Styles.ts_8E9AB0_14sp,
                  8.verticalSpace,
                  TextField(
                    controller: _questionCtrl,
                    maxLength: 100,
                    decoration: InputDecoration(
                      hintText: '请输入投票标题',
                      filled: true,
                      fillColor: Styles.c_F8F9FA,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8.r),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
                    ),
                  ),
                  16.verticalSpace,
                  '选项'.toText..style = Styles.ts_8E9AB0_14sp,
                  8.verticalSpace,
                  ...List.generate(_optionCtrls.length, (i) => Padding(
                    padding: EdgeInsets.only(bottom: 8.h),
                    child: TextField(
                      controller: _optionCtrls[i],
                      maxLength: 50,
                      decoration: InputDecoration(
                        hintText: '选项 ${i + 1}',
                        filled: true,
                        fillColor: Styles.c_F8F9FA,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8.r),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
                      ),
                    ),
                  )),
                  if (_optionCtrls.length < 5)
                    GestureDetector(
                      onTap: _addOption,
                      child: Container(
                        height: 44.h,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          border: Border.all(color: Styles.c_E8EAEF),
                          borderRadius: BorderRadius.circular(8.r),
                        ),
                        child: '+ 添加选项'.toText..style = Styles.ts_0089FF_17sp,
                      ),
                    ),
                  16.verticalSpace,
                  Row(
                    children: [
                      '允许多选'.toText..style = Styles.ts_0C1C33_17sp,
                      const Spacer(),
                      StatefulBuilder(
                        builder: (_, setState) => Switch(
                          value: _multiVote,
                          activeColor: Styles.c_0089FF,
                          onChanged: (v) => setState(() => _multiVote = v),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 2: Verify**

```bash
fvm flutter analyze lib/pages/chat/create_poll_sheet.dart
```

---

### Task 12: Create `PollBubble`

**Files:**
- Create: `lib/pages/chat/poll_bubble.dart`

- [ ] **Step 1: Create the file**

```dart
// lib/pages/chat/poll_bubble.dart
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:openim_common/openim_common.dart';

class PollBubble extends StatelessWidget {
  final Map<String, dynamic> data;
  final String myUserID;
  final void Function(int optionIndex) onVote;

  const PollBubble({
    super.key,
    required this.data,
    required this.myUserID,
    required this.onVote,
  });

  factory PollBubble.fromJson({
    required String rawData,
    required String myUserID,
    required void Function(int) onVote,
  }) {
    final parsed = json.decode(rawData) as Map<String, dynamic>;
    return PollBubble(
      data: parsed['data'] as Map<String, dynamic>? ?? {},
      myUserID: myUserID,
      onVote: onVote,
    );
  }

  List<Map<String, dynamic>> get _options =>
      (data['options'] as List? ?? []).cast<Map<String, dynamic>>();

  bool get _multiVote => data['multiVote'] as bool? ?? false;

  String get _question => data['question'] as String? ?? '';

  bool _hasVoted(Map<String, dynamic> option) =>
      (option['voterIDs'] as List? ?? []).contains(myUserID);

  bool get _iHaveVoted => _options.any(_hasVoted);

  int get _totalVotes =>
      _options.fold(0, (sum, o) => sum + ((o['voterIDs'] as List?)?.length ?? 0));

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(maxWidth: 240.w),
      padding: EdgeInsets.all(12.w),
      decoration: BoxDecoration(
        color: Styles.c_FFFFFF,
        borderRadius: BorderRadius.circular(8.r),
        border: Border.all(color: Styles.c_E8EAEF),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              '📊'.toText..style = TextStyle(fontSize: 14.sp),
              6.horizontalSpace,
              Expanded(
                child: _question.toText
                  ..style = Styles.ts_0C1C33_15sp_medium
                  ..maxLines = 3
                  ..overflow = TextOverflow.ellipsis,
              ),
            ],
          ),
          12.verticalSpace,
          ..._options.asMap().entries.map((entry) {
            final idx = entry.key;
            final opt = entry.value;
            final votes = (opt['voterIDs'] as List?)?.length ?? 0;
            final ratio = _totalVotes > 0 ? votes / _totalVotes : 0.0;
            final myVote = _hasVoted(opt);

            return Padding(
              padding: EdgeInsets.only(bottom: 8.h),
              child: GestureDetector(
                onTap: _iHaveVoted ? null : () => onVote(idx),
                child: Container(
                  height: 40.h,
                  clipBehavior: Clip.hardEdge,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(6.r),
                    border: Border.all(
                      color: myVote ? Styles.c_0089FF : Styles.c_E8EAEF,
                      width: myVote ? 1.5 : 1,
                    ),
                  ),
                  child: Stack(
                    children: [
                      // progress bar background
                      if (_iHaveVoted)
                        FractionallySizedBox(
                          widthFactor: ratio,
                          child: Container(
                            color: myVote
                                ? Styles.c_0089FF.withOpacity(0.15)
                                : Styles.c_E8EAEF.withOpacity(0.5),
                          ),
                        ),
                      // option text + vote count
                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: 10.w),
                        child: Row(
                          children: [
                            Expanded(
                              child: (opt['text'] as String? ?? '').toText
                                ..style = myVote
                                    ? Styles.ts_0089FF_14sp
                                    : Styles.ts_0C1C33_14sp
                                ..maxLines = 1
                                ..overflow = TextOverflow.ellipsis,
                            ),
                            if (_iHaveVoted)
                              '$votes票'.toText..style = Styles.ts_8E9AB0_12sp,
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
          4.verticalSpace,
          '$_totalVotes 人参与'.toText..style = Styles.ts_8E9AB0_12sp,
        ],
      ),
    );
  }
}
```

- [ ] **Step 2: Verify**

```bash
fvm flutter analyze lib/pages/chat/poll_bubble.dart
```

---

### Task 13: Add poll methods to ChatLogic

**Files:**
- Modify: `lib/pages/chat/chat_logic.dart`

- [ ] **Step 1: Add `createPoll` method**

Add after the `sendGroupFile` method:

```dart
// --- 投票 ---
void createPoll() async {
  final result = await Get.bottomSheet<CreatePollResult>(
    const CreatePollSheet(),
    isScrollControlled: true,
  );
  if (result == null) return;

  final pollId = const Uuid().v4();
  final payload = json.encode({
    'customType': CustomMessageType.poll,
    'data': {
      'pollId': pollId,
      'question': result.question,
      'options': result.options.map((text) => {'text': text, 'voterIDs': <String>[]}).toList(),
      'multiVote': result.multiVote,
      'creatorID': OpenIM.iMManager.userID,
      'createdAt': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    },
  });
  final msg = await OpenIM.iMManager.messageManager.createCustomMessage(
    data: payload,
    extension: '',
    description: '[投票] ${result.question}',
  );
  await _sendMessage(msg);
}
```

- [ ] **Step 2: Add `votePoll` method**

```dart
void votePoll(Message pollMsg, int optionIndex) async {
  final myID = OpenIM.iMManager.userID;
  final rawStr = pollMsg.customElem?.data ?? '{}';
  final raw = json.decode(rawStr) as Map<String, dynamic>;
  final pollData = raw['data'] as Map<String, dynamic>;
  final options = (pollData['options'] as List).cast<Map<String, dynamic>>();
  final multiVote = pollData['multiVote'] as bool? ?? false;

  // Prevent duplicate vote
  final alreadyVoted = options.any((o) => (o['voterIDs'] as List).contains(myID));
  if (!multiVote && alreadyVoted) return;
  if (multiVote && (options[optionIndex]['voterIDs'] as List).contains(myID)) return;

  // Optimistic local update
  _applyVote(pollMsg.clientMsgID!, optionIndex, myID);

  // Broadcast vote event to group
  final votePayload = json.encode({
    'customType': CustomMessageType.pollVote,
    'data': {
      'pollMsgID': pollMsg.clientMsgID,
      'optionIndex': optionIndex,
      'voterID': myID,
    },
  });
  try {
    final voteMsg = await OpenIM.iMManager.messageManager.createCustomMessage(
      data: votePayload,
      extension: '',
      description: '',
    );
    await _sendMessage(voteMsg);
  } catch (e) {
    // Roll back on failure
    _removeVote(pollMsg.clientMsgID!, optionIndex, myID);
    IMViews.showToast('投票失败，请重试');
  }
}
```

- [ ] **Step 3: Add `_applyVote` and `_removeVote` helpers**

```dart
void _applyVote(String pollMsgID, int optionIndex, String voterID) {
  final idx = messageList.indexWhere((m) => m.clientMsgID == pollMsgID);
  if (idx < 0) return;
  try {
    final raw = json.decode(messageList[idx].customElem!.data!) as Map<String, dynamic>;
    final options = (raw['data']['options'] as List).cast<Map<String, dynamic>>();
    if (optionIndex < options.length) {
      final voters = (options[optionIndex]['voterIDs'] as List);
      if (!voters.contains(voterID)) {
        voters.add(voterID);
        messageList[idx].customElem!.data = json.encode(raw);
        messageList.refresh();
      }
    }
  } catch (_) {}
}

void _removeVote(String pollMsgID, int optionIndex, String voterID) {
  final idx = messageList.indexWhere((m) => m.clientMsgID == pollMsgID);
  if (idx < 0) return;
  try {
    final raw = json.decode(messageList[idx].customElem!.data!) as Map<String, dynamic>;
    final options = (raw['data']['options'] as List).cast<Map<String, dynamic>>();
    if (optionIndex < options.length) {
      (options[optionIndex]['voterIDs'] as List).remove(voterID);
      messageList[idx].customElem!.data = json.encode(raw);
      messageList.refresh();
    }
  } catch (_) {}
}
```

- [ ] **Step 4: Add `_parsePollVoteEvent` and wire it into message receipt**

Add the parser:

```dart
bool _parsePollVoteEvent(Message msg) {
  if (msg.contentType != MessageType.custom) return false;
  try {
    final raw = json.decode(msg.customElem?.data ?? '{}') as Map<String, dynamic>;
    if (raw['customType'] != CustomMessageType.pollVote) return false;
    final d = raw['data'] as Map<String, dynamic>;
    _applyVote(
      d['pollMsgID'] as String,
      d['optionIndex'] as int,
      d['voterID'] as String,
    );
    return true;
  } catch (_) {
    return false;
  }
}
```

Now wire it into the existing new-message handler. Search for `_parseEditEvent` call in `chat_logic.dart` (the code path where incoming messages are processed). It will be in the `_onReceiveMsg` or similar method. Add `_parsePollVoteEvent` call alongside `_parseEditEvent`:

```dart
// Wherever _parseEditEvent(msg) is called, add:
_parsePollVoteEvent(msg);
```

- [ ] **Step 5: Add imports for CreatePollSheet and Uuid**

At the top of `chat_logic.dart`, add:

```dart
import 'package:uuid/uuid.dart';
import 'create_poll_sheet.dart';
```

- [ ] **Step 6: Verify**

```bash
fvm flutter analyze lib/pages/chat/chat_logic.dart
```

---

### Task 14: Add poll UI to ChatView and wire `onTapPoll`

**Files:**
- Modify: `lib/pages/chat/chat_view.dart`
- Modify: `openim_common/lib/src/widgets/chat/chat_toolbox.dart`

- [ ] **Step 1: Add `onTapPoll` to ChatToolBox**

In `chat_toolbox.dart`, add parameter alongside `onTapFile`:

```dart
const ChatToolBox({
  super.key,
  this.onTapAlbum,
  this.onTapCall,
  this.onTapGif,
  this.onTapSticker,
  this.onTapFile,
  this.onTapPoll,  // new
});
final Function()? onTapPoll;  // new
```

Add to the items list:

```dart
if (onTapPoll != null)
  ToolboxItemInfo(
    text: '投票',
    icon: ImageRes.toolboxAlbum,
    onTap: onTapPoll,
    isPoll: true,
  ),
```

Add `isPoll` field to `ToolboxItemInfo`:

```dart
class ToolboxItemInfo {
  // ...existing fields...
  bool isPoll;

  ToolboxItemInfo({
    // ...
    this.isPoll = false,
  });
}
```

Add render in `itemBuilder`:

```dart
if (item.isPoll) {
  return _buildTextItemView(text: '🗳️', label: item.text, onTap: item.onTap);
}
```

- [ ] **Step 2: Wire `onTapPoll` in `chat_view.dart`**

```dart
toolbox: ChatToolBox(
  onTapAlbum: logic.onTapAlbum,
  onTapCall: logic.isGroupChat ? null : logic.call,
  onTapGif: () => _showGifPicker(context),
  onTapSticker: () => _showStickerPanel(context),
  onTapFile: logic.isGroupChat ? logic.sendGroupFile : null,
  onTapPoll: logic.isGroupChat ? logic.createPoll : null,  // new
),
```

- [ ] **Step 3: Add type-909 bubble handler in `_buildCustomTypeItemView`**

Add after the `groupFile` block:

```dart
} else if (viewType == CustomMessageType.poll) {
  return CustomTypeInfo(
    PollBubble.fromJson(
      rawData: msg.customElem!.data!,
      myUserID: OpenIM.iMManager.userID,
      onVote: (idx) => logic.votePoll(msg, idx),
    ),
    false,
    true,
  );
} else if (viewType == CustomMessageType.pollVote) {
  return CustomTypeInfo(const SizedBox.shrink(), false, false);
}
```

- [ ] **Step 4: Add imports for PollBubble and CreatePollSheet in `chat_view.dart`**

```dart
import 'create_poll_sheet.dart';
import 'poll_bubble.dart';
```

- [ ] **Step 5: Verify**

```bash
fvm flutter analyze lib/pages/chat/chat_view.dart openim_common/lib/src/widgets/chat/chat_toolbox.dart
```

- [ ] **Step 6: Commit Phase 3**

```bash
git add openim_common/lib/src/extension/message_manager.dart \
        openim_common/lib/src/widgets/chat/chat_toolbox.dart \
        lib/pages/chat/create_poll_sheet.dart \
        lib/pages/chat/poll_bubble.dart \
        lib/pages/chat/chat_logic.dart \
        lib/pages/chat/chat_view.dart
git commit -m "feat: poll — type-909 create, type-915 vote event, PollBubble, CreatePollSheet"
```

---

## Manual Verification Checklist

### Phase 1 — Admin UI
- [ ] Open a group chat as owner → Chat setup → 群管理
- [ ] Verify three sections visible: 管理员设置, 禁言管理, 成员管理
- [ ] Tap 添加管理员 → member list shows only regular members → select one → confirm → admin appears in list
- [ ] Tap 撤销 next to admin → confirm → admin removed from list
- [ ] Tap 禁言成员 → member list → select one → duration picker → confirm → SDK call succeeds (no error toast)
- [ ] Open group as admin → 群管理 → 管理员设置 section is hidden (only owner sees it)

### Phase 2 — Group Files
- [ ] Open a group chat → input bar `+` menu → 文件 item appears (group chat only)
- [ ] Tap 文件 → file picker opens → select a file → upload progress → file bubble appears in chat
- [ ] Chat setup → "群文件" entry visible → tap → GroupFilesPage opens
- [ ] GroupFilesPage shows the uploaded file with name, size, uploader
- [ ] Tap file in list → browser opens the URL

### Phase 3 — Voting
- [ ] Open a group chat → input bar `+` menu → 投票 item appears (group chat only)
- [ ] Tap 投票 → CreatePollSheet opens → fill question + 2 options → tap 发送 → poll bubble appears in chat
- [ ] Poll bubble shows question, options, 0 票
- [ ] Tap an option → option highlights blue, vote count increases
- [ ] Open the same chat on second device → vote count updates when first device votes

---

## Analyze All Changes

After all tasks complete, run full analysis:

```bash
fvm flutter analyze lib/ openim_common/lib/
```

Expected: no errors (warnings from upstream code are acceptable).
