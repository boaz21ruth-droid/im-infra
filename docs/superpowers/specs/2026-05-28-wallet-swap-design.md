# Wallet Swap (闪兑) — Design Spec

- **Date**: 2026-05-28
- **Scope**: 在 `im-wallet-app` 的钱包页中实现单链同币种 Swap 功能
- **Target**: Flutter 客户端；不涉及 im-business 后端
- **Out of scope**: 跨链桥、TRON、Solana、CEX 出入金

---

## 1. 范围与决策

| 维度 | 决策 |
|---|---|
| 闪兑形态 | 单链同币种闪兑（同一条链内 token ↔ token） |
| 支持链（MVP） | Ethereum / BSC / Polygon / Arbitrum / Optimism（5 条 EVM 主网） |
| 排除 | TRON（签名与路由独立，列为下一期）；EVM 测试网（0x 不支持） |
| Provider 选型 | `SwapProvider` 抽象接口；MVP 仅落地 **0x v2 (AllowanceHolder)**；1inch / OKX DEX / Uniswap-Pancake 直连预留接口位，UI 灰显 |
| Provider 切换 | UI 顶部下拉切换；首发只有 0x 可选 |
| 链选择 | Swap 页内独立选链（与钱包主页当前链解耦） |
| Token 范围 | From = 本机已有资产；To = 本链 native + USDT + USDC + 用户已加的自定义代币 |
| 滑点 | 默认 0.5%；预设 0.1% / 0.5% / 1.0%；支持自定义；> 3% 警告 |
| 平台手续费 | 固定 0.3%（30 bps），走 0x `swapFeeBps` + `swapFeeRecipient` 参数 |
| 二次验证 | 复用现有 `totp_verify_dialog.dart`（Approve 与 Swap 两次） |
| API Key | `--dart-define=ZEROX_API_KEY=...` 编译期注入，不入仓 |

---

## 2. 架构概览

```
                                              ┌────────────────────────┐
WalletMainView ─[点 Swap]─► SwapPage          │ 0x Swap API v2         │
                              │                │ /swap/allowance-holder │
                              ▼                │   /price               │
                          SwapLogic ──HTTP──►  │   /quote               │
                              │                └────────────────────────┘
                              ▼
                          SwapProvider (抽象)
                              ├── ZeroExProvider     ← MVP
                              ├── OneInchProvider    ← 灰
                              ├── OkxDexProvider     ← 灰
                              └── UniswapV3Provider  ← 灰
                              │
                              ▼
                          EvmService (现有)
                              ├── getNativeBalance / getTokenBalance
                              ├── sendApprove        ← 新增
                              └── sendRaw            ← 新增（送任意 calldata）
```

`SwapLogic` 不直接调 0x；只通过 `SwapProvider` 接口。`EvmService` 是 swap 实际广播交易的执行层。

---

## 3. 文件结构

```
lib/pages/wallet/swap/
├── swap_view.dart           # 主页面 UI
├── swap_logic.dart          # GetX controller，独立于 WalletLogic
├── swap_binding.dart        # GetX binding（路由注入）
├── token_picker_sheet.dart  # From/To 代币选择底部弹窗
├── slippage_sheet.dart      # 滑点设置底部弹窗
└── swap_result_view.dart    # 提交成功/失败结果页

lib/services/wallet/swap/
├── swap_models.dart         # SwapQuote / SwapToken / SwapPriceResult / ApprovalIssue / SwapFees
├── swap_provider.dart       # abstract class SwapProvider
├── zerox_provider.dart      # 0x v2 实现
└── swap_config.dart         # 费率/费收地址/API Key 编译期常量
```

`wallet_main_view.dart:155` 的 `EasyLoading.showToast('即将推出')` 改为 `Get.to(() => const SwapPage(), binding: SwapBinding())`。`wallet_logic.dart` 不修改。

---

## 4. 核心接口

### 4.1 `SwapProvider`

```dart
abstract class SwapProvider {
  String get id;            // 'zerox' / 'oneinch' / 'okx' / 'uniswap'
  String get displayName;
  bool supportsChain(String chainKey);

  /// 软报价（debounce 400ms 调用，用于实时显示）
  Future<SwapPriceResult> getPrice(SwapQuoteRequest req);

  /// 硬报价 + calldata（用户点 Swap 时调用）
  Future<SwapQuote> getQuote(SwapQuoteRequest req);
}
```

### 4.2 数据模型

```dart
class SwapToken {
  final String chainKey;
  final String symbol;
  final int decimals;
  final String? contractAddress;  // null = native
  bool get isNative => contractAddress == null;
}

class SwapQuoteRequest {
  final String chainKey;
  final SwapToken sellToken;
  final SwapToken buyToken;
  final BigInt sellAmount;
  final String takerAddress;
  final int slippageBps;          // 50 = 0.5%
}

class SwapPriceResult {
  final BigInt buyAmount;          // 预估
  final BigInt? gasEstimate;
  final SwapFees fees;
}

class SwapQuote {
  final BigInt buyAmount;
  final BigInt minBuyAmount;       // buyAmount * (1 - slippage)
  final String to;                 // 0x Settler 合约
  final String data;               // calldata (hex)
  final BigInt value;              // native swap 时 = sellAmount，token 时 = 0
  final BigInt? gas;
  final BigInt? gasPrice;
  final ApprovalIssue? approval;   // null 表示已授权
  final SwapFees fees;
  final String providerId;
  final DateTime? expiresAt;
}

class ApprovalIssue {
  final String tokenAddress;
  final String spender;            // 0x AllowanceHolder
  final BigInt requiredAmount;
}

class SwapFees {
  final BigInt? integratorFeeAmount;
  final String? integratorFeeToken;
  final BigInt? zeroExFeeAmount;
  final BigInt? gasFeeAmount;
}
```

### 4.3 0x API 映射

- Endpoint: `https://api.0x.org/swap/allowance-holder/{price|quote}`
- Headers: `0x-api-key: $ZEROX_API_KEY`, `0x-version: v2`
- Native sentinel: `0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE`
- 关键 query 参数：
  - `chainId`, `sellToken`, `buyToken`, `sellAmount`, `taker`
  - `swapFeeBps=30`
  - `swapFeeRecipient=<kFeeRecipient[chainKey]>`（每条链一个 EOA 地址，落地前由运营提供，写入 `swap_config.dart`）
  - `swapFeeToken=<buyToken>`（费用以 buy token 计）
  - `slippageBps=<UI 选项>`
- 响应字段映射：
  - `to / data / value` → `SwapQuote.to/data/value`
  - `buyAmount / sellAmount` → `SwapQuote.buyAmount` 等
  - `gas / gasPrice` → `SwapQuote.gas/gasPrice`
  - `issues.allowance` 非 null → 填入 `ApprovalIssue`
  - `issues.balance` 非 null → 客户端早已拦截，作防御性 toast
  - `fees.integratorFee / zeroExFee / gasFee` → `SwapFees`

---

## 5. UI 布局

```
┌────────────────────────────────────────┐
│  ←   闪兑                         ⚙  │  AppBar；齿轮 = 滑点设置
├────────────────────────────────────────┤
│  [ Ethereum ▾ ]                       │  链选择 chip（独立）
│                                        │
│  ┌──────────────────────────────────┐ │
│  │ 支付              余额: 1.2345    │ │
│  │ ┌──────────────┐ ┌─────────────┐ │ │
│  │ │ 1.0          │ │ [ETH] ▾     │ │ │  From：金额 + 代币 + MAX
│  │ └──────────────┘ └─────────────┘ │ │
│  │ ≈ $3,245.10                       │ │
│  └──────────────────────────────────┘ │
│                                        │
│              ⇅  反向按钮              │
│                                        │
│  ┌──────────────────────────────────┐ │
│  │ 获得              余额: 152.30    │ │
│  │ ┌──────────────┐ ┌─────────────┐ │ │
│  │ │ 3,232.50     │ │ [USDT] ▾    │ │ │  To：金额只读
│  │ └──────────────┘ └─────────────┘ │ │
│  │ ≈ $3,232.50                       │ │
│  └──────────────────────────────────┘ │
│                                        │
│  报价方   [ 0x ▾ ]                    │  Provider 切换器
│  汇率     1 ETH ≈ 3,232.50 USDT       │
│  滑点     0.5%                        │
│  最低获得 3,216.34 USDT               │
│  网络费   ≈ $1.82                     │
│  平台费   0.3% (9.69 USDT)            │
│                                        │
│  ┌──────────────────────────────────┐ │
│  │            Swap                   │ │
│  └──────────────────────────────────┘ │
└────────────────────────────────────────┘
```

**主按钮状态机**（按优先级判断）：

| 优先级 | 条件 | 文案 | 可点 |
|---|---|---|---|
| 1 | From/To 未选 | 选择代币 | ✗ |
| 2 | 金额为 0/空 | 输入金额 | ✗ |
| 3 | sellAmount > 余额 | 余额不足 | ✗ |
| 4 | gas 估算 > native 余额 | ETH 不足支付 Gas | ✗ |
| 5 | 报价加载中 | 查询报价中… | ✗ |
| 6 | 报价失败 | 无可用路由 | ✗ |
| 7 | quote.approval != null | 授权 {symbol} | ✓ |
| 8 | 已就绪 | Swap | ✓ |

**反向按钮 ⇅**：交换 From/To 的代币；金额重置为空。

**Provider 切换器**：下拉中"0x"可选；"1inch" / "OKX DEX" / "Uniswap-Pancake" 显示为灰色 + "即将开放"标签。

---

## 6. 完整 Swap 流程

```
用户点 [Swap]
   │
   ▼
Step 1 ─ getQuote(req) → SwapQuote
   │     失败 → toast "报价失败，请重试"，退出
   │
   ▼
quote.approval == null ?
   │ Yes → Step 4
   │ No  → 继续
   ▼
Step 2 ─ TOTP 验证（首次 approve）
   │     取消 → 退出流程
   │
   ▼
Step 3 ─ EvmService.sendApprove(token, spender, MaxUint256)
   │     EasyLoading "授权中..."
   │     轮询 receipt 1 confirmation，超时 60s
   │     失败 → toast "授权失败：<reason>"，退出
   │
   ▼
Step 4 ─ refreshQuote(req)
   │     对比 buyAmount 漂移 > 1% → 弹 AlertDialog 确认按新价继续
   │
   ▼
Step 5 ─ TOTP 验证（swap 交易）
   │     取消 → 退出流程
   │
   ▼
Step 6 ─ EvmService.sendRaw({to, data, value, gasLimit}) → txHash
   │     EasyLoading "广播中..."
   │     失败 → toast，保留页面
   │
   ▼
Step 7 ─ 跳到 SwapResultView
         ✓ 交易已提交
         hash + 浏览器链接（txExplorerBase + hash）
         后台触发 walletLogic.refreshBalances()
```

**关键约束：**

- Approve 走 `MaxUint256`，避免重复 approve（业界惯例）。Spender 取 `quote.approval.spender` 而非硬编码。
- Native swap（ETH → USDT）：`value = sellAmount`，`approval == null`；跳 Step 2/3。
- Token → Native swap：可能需要 approve；0x 自动处理 unwrap，无需额外步骤。
- 不轮询 swap tx 最终状态；广播成功即跳结果页，刷余额在后台。

**报价自动刷新：**

- 用户输入金额时 debounce 400ms 调 `getPrice`（软报价，便宜）。
- 进入 Step 1 / Step 4 用 `getQuote`（硬报价含 calldata）。
- Step 4 失败 → 回滚到 Step 1 quote 值并提示用户重点 Swap。

---

## 7. 错误处理矩阵

| 场景 | 触发条件 | 处理 |
|---|---|---|
| 无 API Key | 启动时 `kZeroxApiKey` 为空 | 页面顶部红条："Swap 未配置，请联系运营"；主按钮禁用 |
| 链不支持 | provider 不支持当前链 | Provider 切换器全灰；主按钮 "该链暂不支持 Swap" |
| 代币对无路由 | quote 返回 422 / NO_LIQUIDITY | 主按钮 "无可用路由"；隐藏汇率行 |
| 余额不足 (sell) | sellAmount > balance | 主按钮 "余额不足" |
| Gas 不足 | native balance < estGas（sellToken 非 native 时） | 主按钮 "ETH 不足支付 Gas" |
| 报价过期 | quote.expiresAt 已过 | Step 4 自动重拉；二次仍过期 → 提示用户重点 Swap |
| 价格漂移 | Step 4 二次 quote buyAmount 与首次差 > 1% | AlertDialog 新旧价格对比，[取消] / [按新价继续] |
| Approve 卡住 | 60s 内未上链 | EasyLoading 关闭，toast "授权交易未确认，请稍后重试"；不自动重试 |
| Swap 链上失败 | 已广播但 receipt status=0 | 结果页失败态，显示 hash + revert reason；提供浏览器链接 |
| TOTP 失败/取消 | totp_verify_dialog 返回 false | 退出流程，保留页面，不消耗 quote |
| 网络异常 | HTTP 失败 | toast "网络异常，请检查连接"；按钮恢复可点 |
| Decimals 不匹配 | 自定义代币 decimals 与链上不符 | 拉报价前 `EvmService.getDecimals()` 校验；不符则 toast 拒绝 |

**安全防护：**

- `quote.to` 白名单校验：限定为 0x 已知 Settler / AllowanceHolder 合约地址（在 `swap_config.dart` 维护按 chainId 的列表）；不匹配则拒绝发送。
- 单笔 sellAmount 等值 > $10,000 → 二次 AlertDialog 确认（与现有 send 一致）。
- API Key 仅通过 `--dart-define=ZEROX_API_KEY=...` 注入；CI/dev 通过 `.env.local` 加载，与 `_host` 同套机制。

---

## 8. 新增/修改的 EvmService 方法

```dart
// EvmService 新增
Future<int> getDecimals(String contractAddress);

Future<BigInt> getAllowance({
  required String owner,
  required String spender,
  required String tokenContract,
});

Future<String> sendApprove({
  required EthPrivateKey senderKey,
  required String tokenContract,
  required String spender,
  required BigInt amount,        // MaxUint256
});

Future<String> sendRaw({
  required EthPrivateKey senderKey,
  required String to,
  required String dataHex,
  required BigInt value,
  BigInt? gasLimit,
  BigInt? gasPrice,
});

Future<bool> waitForReceipt(String txHash, {Duration timeout});
```

`sendRaw` 是 swap 能跑的关键：现有 `sendNative`/`sendToken` 只支持固定函数签名，无法发送 0x 返回的任意 calldata。

---

## 9. 测试策略

**单元/Widget 测试**（不跑链上）：

- `swap_models_test.dart`：BigInt ↔ decimal 字符串往返；minBuyAmount 计算（slippageBps 边界）。
- `zerox_provider_test.dart`：用 `http_mock_adapter` 喂 6 个固化 JSON：
  1. ETH→USDT 成功（无 approve）
  2. USDT→ETH 成功（需 approve）
  3. 无路由 422
  4. fees 字段齐全
  5. issues.allowance 非 null
  6. 限流 429
- `swap_logic_test.dart`：主按钮状态机 8 个分支用表驱动；debounce 行为；反向按钮重置金额。
- 一个 Widget 测试：点 ⇅ 后 From/To 互换。

**手测脚本**（必须全通过）：

1. ETH 主网 0.001 ETH → USDT（native → token，无 approve）
2. ETH 主网 0.5 USDT → ETH（token → native，首次 approve）
3. Polygon 主网 0.5 USDC → USDT（token → token）
4. 切链：ETH → Arbitrum，确认报价能拉到，余额刷新
5. 滑点改 0.1% 触发 `PRICE_IMPACT_TOO_HIGH` 错误分支
6. 飞行模式打开点 Swap → 网络异常分支
7. TOTP 输错 → 取消分支
8. 等价 $10,000+ 触发大额确认弹窗

---

## 10. 落地切片（推荐执行顺序）

每个切片可独立验收、独立提交，按顺序合并。

| # | 切片 | 验收标志 |
|---|---|---|
| 1 | 文件骨架 + 路由 + UI 静态版（mock 数据） | 点主页 Swap 按钮能进页，UI 完整 |
| 2 | `SwapProvider` 接口 + `ZeroExProvider.getPrice` | 输入金额能拉到真实软报价 |
| 3 | `getQuote` + `evmService.sendRaw` + Approve 流 | ERC20→ERC20 能完整成交一笔 |
| 4 | TOTP 集成 + 结果页 + 错误处理矩阵 | §7 表格里每行都能复现 |
| 5 | Provider 切换器 + 滑点设置 + 链切换 | 全 UI 交互完备 |
| 6 | 单元测试 + 手测脚本走完 | 上线就绪 |

---

## 11. 后续扩展（不在 MVP）

- 加入 1inch / OKX DEX / Uniswap 直连 Provider —— 实现新的 `SwapProvider` 子类即可
- "自动取最优"模式：并发拉 N 家报价，取 net buyAmount 最大
- TRON swap（独立路径：OKX DEX 或 SunSwap）
- 跨链桥（LI.FI / Squid）
- 限价单 / DCA
- Swap 历史记录页（链上 hash + 本地索引）

---

## 12. 待运营确认的配置项

落地前需要由运营/产品提供，写入 `swap_config.dart`：

- 0x API Key（生产 + 测试两套）
- 每条链 swap fee 收款地址（5 个 EOA 地址，与 im-business 财务对账）
- 0x AllowanceHolder / Settler 合约白名单（按 chainId）
