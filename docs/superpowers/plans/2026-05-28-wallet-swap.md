# Wallet Swap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement single-chain same-token swap (闪兑) in the Flutter wallet page, replacing the current "即将推出" placeholder.

**Architecture:** A `SwapProvider` abstract interface with **0x v2 (AllowanceHolder)** as the only landed implementation; 1inch / OKX DEX / Uniswap-Pancake are reserved as grayed-out UI options. Swap flow: getQuote → optional Approve → TOTP → sendRaw → result. New `EvmService.sendRaw` lets clients broadcast arbitrary aggregator calldata.

**Tech Stack:** Flutter 3.35 (FVM-pinned), GetX, dio 5.7, web3dart 2.7, 0x Swap API v2.

**Spec:** `docs/superpowers/specs/2026-05-28-wallet-swap-design.md`

**All commands assume `cd /Users/web1/go/im/im-wallet-app/` and `fvm flutter ...` (not system Flutter).**

---

## Task 1: Skeleton — files, routing, static UI

**Goal:** Tapping the Swap button on the wallet main view opens a real page (not a toast). UI shows the layout with hard-coded mock values. No network calls yet.

**Files:**
- Create: `lib/services/wallet/swap/swap_config.dart`
- Create: `lib/services/wallet/swap/swap_models.dart`
- Create: `lib/services/wallet/swap/swap_provider.dart`
- Create: `lib/pages/wallet/swap/swap_binding.dart`
- Create: `lib/pages/wallet/swap/swap_logic.dart`
- Create: `lib/pages/wallet/swap/swap_view.dart`
- Modify: `lib/pages/wallet/main/wallet_main_view.dart:152-156` (replace toast with route)

- [ ] **Step 1.1: Write `swap_config.dart`**

```dart
// lib/services/wallet/swap/swap_config.dart

/// 0x Swap API v2 key. Injected at compile time via:
///   fvm flutter run --dart-define=ZEROX_API_KEY=xxx
/// Empty string in non-prod builds; the UI shows a "未配置" banner when empty.
const String kZeroxApiKey =
    String.fromEnvironment('ZEROX_API_KEY', defaultValue: '');

/// Platform fee in basis points, applied via 0x `swapFeeBps`.
const int kSwapFeeBps = 30; // 0.30%

/// Per-chain fee recipient addresses. EMPTY = no fee for that chain.
/// Operations team supplies these before production launch.
const Map<String, String> kFeeRecipients = {
  'eth': '',
  'bsc': '',
  'polygon': '',
  'arbitrum': '',
  'optimism': '',
};

/// 0x AllowanceHolder contract — same address on every EVM chain. This is the
/// `spender` users approve ERC20 to. The /quote response also returns this in
/// `issues.allowance.spender`; we use the response value for safety and only
/// fall back to this constant for the static UI/tests.
const String kZeroxAllowanceHolder =
    '0x0000000000001fF3684f28c67538d4D072C22734';

/// EVM chain keys supported by 0x v2 in this app. Must be a subset of
/// `chains` in `chain_config.dart`. Drives Provider.supportsChain().
const List<String> kZeroxSupportedChains = [
  'eth', 'bsc', 'polygon', 'arbitrum', 'optimism',
];

/// Native-asset sentinel address used by 0x (and most aggregators).
const String kNativeTokenSentinel =
    '0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE';
```

- [ ] **Step 1.2: Commit**

```bash
git add lib/services/wallet/swap/swap_config.dart
git commit -m "feat(swap): add swap config constants"
```

- [ ] **Step 1.3: Write `swap_models.dart`**

```dart
// lib/services/wallet/swap/swap_models.dart

class SwapToken {
  final String chainKey;
  final String symbol;
  final int decimals;
  /// null = native token (ETH/BNB/POL/MATIC).
  final String? contractAddress;

  const SwapToken({
    required this.chainKey,
    required this.symbol,
    required this.decimals,
    this.contractAddress,
  });

  bool get isNative => contractAddress == null;

  @override
  bool operator ==(Object other) =>
      other is SwapToken &&
      other.chainKey == chainKey &&
      other.symbol == symbol &&
      other.contractAddress == contractAddress;

  @override
  int get hashCode => Object.hash(chainKey, symbol, contractAddress);
}

class SwapQuoteRequest {
  final String chainKey;
  final SwapToken sellToken;
  final SwapToken buyToken;
  final BigInt sellAmount;
  final String takerAddress;
  final int slippageBps; // 50 = 0.5%

  const SwapQuoteRequest({
    required this.chainKey,
    required this.sellToken,
    required this.buyToken,
    required this.sellAmount,
    required this.takerAddress,
    required this.slippageBps,
  });
}

class SwapFees {
  final BigInt? integratorFeeAmount;
  final String? integratorFeeToken;
  final BigInt? zeroExFeeAmount;
  final BigInt? gasFeeAmount;

  const SwapFees({
    this.integratorFeeAmount,
    this.integratorFeeToken,
    this.zeroExFeeAmount,
    this.gasFeeAmount,
  });
}

class ApprovalIssue {
  final String tokenAddress;
  final String spender;
  final BigInt requiredAmount;

  const ApprovalIssue({
    required this.tokenAddress,
    required this.spender,
    required this.requiredAmount,
  });
}

class SwapPriceResult {
  final BigInt buyAmount;
  final BigInt? gasEstimate;
  final SwapFees fees;
  final String providerId;

  const SwapPriceResult({
    required this.buyAmount,
    this.gasEstimate,
    required this.fees,
    required this.providerId,
  });
}

class SwapQuote {
  final BigInt buyAmount;
  final BigInt minBuyAmount;
  final String to;
  final String data;
  final BigInt value;
  final BigInt? gas;
  final BigInt? gasPrice;
  final ApprovalIssue? approval;
  final SwapFees fees;
  final String providerId;
  final DateTime? expiresAt;

  const SwapQuote({
    required this.buyAmount,
    required this.minBuyAmount,
    required this.to,
    required this.data,
    required this.value,
    this.gas,
    this.gasPrice,
    this.approval,
    required this.fees,
    required this.providerId,
    this.expiresAt,
  });
}

/// Reason for a quote/price failure. UI consumes this to pick the right
/// disabled-button text without parsing error strings.
enum SwapErrorKind {
  noApiKey,
  chainNotSupported,
  noLiquidity,
  rateLimited,
  network,
  invalidParams,
  unknown,
}

class SwapException implements Exception {
  final SwapErrorKind kind;
  final String message;
  const SwapException(this.kind, this.message);

  @override
  String toString() => 'SwapException($kind): $message';
}
```

- [ ] **Step 1.4: Write failing test for `SwapToken` equality**

```dart
// test/services/wallet/swap/swap_models_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:openim/services/wallet/swap/swap_models.dart';

void main() {
  group('SwapToken', () {
    test('two natives on same chain are equal', () {
      const a = SwapToken(chainKey: 'eth', symbol: 'ETH', decimals: 18);
      const b = SwapToken(chainKey: 'eth', symbol: 'ETH', decimals: 18);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('different contract addresses are not equal', () {
      const a = SwapToken(
        chainKey: 'eth', symbol: 'USDT', decimals: 6,
        contractAddress: '0xdAC17F958D2ee523a2206206994597C13D831ec7',
      );
      const b = SwapToken(
        chainKey: 'eth', symbol: 'USDT', decimals: 6,
        contractAddress: '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48',
      );
      expect(a == b, isFalse);
    });

    test('isNative reflects contractAddress', () {
      const a = SwapToken(chainKey: 'eth', symbol: 'ETH', decimals: 18);
      const b = SwapToken(
        chainKey: 'eth', symbol: 'USDT', decimals: 6,
        contractAddress: '0xdAC17F958D2ee523a2206206994597C13D831ec7',
      );
      expect(a.isNative, isTrue);
      expect(b.isNative, isFalse);
    });
  });
}
```

- [ ] **Step 1.5: Run the test and verify it passes**

```bash
fvm flutter test test/services/wallet/swap/swap_models_test.dart
```

Expected: 3 tests pass. (Equality/hashCode are already implemented in Step 1.3.)

- [ ] **Step 1.6: Commit**

```bash
git add lib/services/wallet/swap/swap_models.dart \
        test/services/wallet/swap/swap_models_test.dart
git commit -m "feat(swap): add swap data models with equality"
```

- [ ] **Step 1.7: Write `swap_provider.dart` — abstract interface**

```dart
// lib/services/wallet/swap/swap_provider.dart
import 'swap_models.dart';

abstract class SwapProvider {
  String get id;
  String get displayName;

  /// True iff this provider can return quotes for `chainKey`.
  bool supportsChain(String chainKey);

  /// Soft quote — used for live "you'll get X" preview as the user types.
  /// Throws `SwapException` on failure.
  Future<SwapPriceResult> getPrice(SwapQuoteRequest req);

  /// Firm quote — returns transaction calldata ready to broadcast.
  /// Throws `SwapException` on failure.
  Future<SwapQuote> getQuote(SwapQuoteRequest req);
}
```

- [ ] **Step 1.8: Commit**

```bash
git add lib/services/wallet/swap/swap_provider.dart
git commit -m "feat(swap): add SwapProvider abstract interface"
```

- [ ] **Step 1.9: Write `swap_logic.dart` skeleton (no network yet)**

```dart
// lib/pages/wallet/swap/swap_logic.dart
import 'package:get/get.dart';
import '../../../services/wallet/chain_config.dart';
import '../../../services/wallet/swap/swap_models.dart';
import '../wallet_logic.dart';

class SwapLogic extends GetxController {
  final WalletLogic _wallet = Get.find<WalletLogic>();

  /// Independent chain selection — does NOT mutate WalletLogic.selectedChainKey.
  final swapChainKey = 'eth'.obs;
  final sellToken = Rxn<SwapToken>();
  final buyToken = Rxn<SwapToken>();
  final sellAmountText = ''.obs;        // raw user input
  final priceResult = Rxn<SwapPriceResult>();
  final isFetchingPrice = false.obs;
  final lastError = Rxn<SwapException>();

  /// 50 = 0.5% — default per spec §1.
  final slippageBps = 50.obs;

  /// Which provider the user has selected. MVP: always 'zerox'.
  final providerId = 'zerox'.obs;

  WalletLogic get wallet => _wallet;

  String get takerAddress {
    final acc = _wallet.selectedAccount.value;
    if (acc == null) return '';
    return acc.addresses[swapChainKey.value] ?? '';
  }

  /// Swap From/To. Resets amount.
  void invertTokens() {
    final s = sellToken.value;
    final b = buyToken.value;
    sellToken.value = b;
    buyToken.value = s;
    sellAmountText.value = '';
    priceResult.value = null;
  }

  /// Switch active chain. Resets tokens + amount.
  void switchChain(String chainKey) {
    if (!chains.containsKey(chainKey)) return;
    swapChainKey.value = chainKey;
    sellToken.value = null;
    buyToken.value = null;
    sellAmountText.value = '';
    priceResult.value = null;
  }
}
```

- [ ] **Step 1.10: Write `swap_binding.dart`**

```dart
// lib/pages/wallet/swap/swap_binding.dart
import 'package:get/get.dart';
import 'swap_logic.dart';

class SwapBinding extends Bindings {
  @override
  void dependencies() {
    Get.lazyPut(() => SwapLogic());
  }
}
```

- [ ] **Step 1.11: Write `swap_view.dart` static layout (no network)**

```dart
// lib/pages/wallet/swap/swap_view.dart
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:get/get.dart';
import 'package:openim_common/openim_common.dart';
import '../../../services/wallet/chain_config.dart';
import 'swap_logic.dart';

class SwapView extends StatelessWidget {
  const SwapView({super.key});

  @override
  Widget build(BuildContext context) {
    final logic = Get.find<SwapLogic>();
    return Scaffold(
      backgroundColor: Styles.c_F8F9FA,
      appBar: AppBar(
        backgroundColor: Styles.c_F8F9FA,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios, color: Styles.c_0C1C33, size: 18.w),
          onPressed: () => Get.back(),
        ),
        title: Text(
          '闪兑',
          style: TextStyle(
            fontSize: 18.sp,
            fontWeight: FontWeight.w600,
            color: Styles.c_0C1C33,
          ),
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.settings_outlined,
                color: Styles.c_0C1C33, size: 22.w),
            onPressed: () {},
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.all(16.w),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _ChainChip(logic: logic),
            SizedBox(height: 16.h),
            _TokenCard(
              label: '支付',
              tokenSymbol: 'ETH (mock)',
              amount: '1.0',
              isReadOnly: false,
            ),
            SizedBox(height: 12.h),
            Center(
              child: Container(
                width: 36.w,
                height: 36.w,
                decoration: BoxDecoration(
                  color: Styles.c_FFFFFF,
                  shape: BoxShape.circle,
                  border: Border.all(color: Styles.c_E8EAEF),
                ),
                child: Icon(Icons.swap_vert,
                    color: Styles.c_0089FF, size: 20.w),
              ),
            ),
            SizedBox(height: 12.h),
            _TokenCard(
              label: '获得',
              tokenSymbol: 'USDT (mock)',
              amount: '3232.50',
              isReadOnly: true,
            ),
            SizedBox(height: 20.h),
            _QuoteInfoRow(label: '报价方', value: '0x'),
            _QuoteInfoRow(label: '汇率', value: '1 ETH ≈ 3,232.50 USDT'),
            _QuoteInfoRow(label: '滑点', value: '0.5%'),
            _QuoteInfoRow(label: '最低获得', value: '3,216.34 USDT'),
            _QuoteInfoRow(label: '平台费', value: '0.3% (9.69 USDT)'),
            SizedBox(height: 24.h),
            SizedBox(
              width: double.infinity,
              height: 52.h,
              child: ElevatedButton(
                onPressed: null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Styles.c_0089FF,
                  disabledBackgroundColor: Styles.c_8E9AB0,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14.r),
                  ),
                  elevation: 0,
                ),
                child: Text('Swap (mock)',
                    style: TextStyle(
                        fontSize: 16.sp, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChainChip extends StatelessWidget {
  final SwapLogic logic;
  const _ChainChip({required this.logic});

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final key = logic.swapChainKey.value;
      final cfg = chains[key];
      return Container(
        padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 8.h),
        decoration: BoxDecoration(
          color: Styles.c_FFFFFF,
          borderRadius: BorderRadius.circular(20.r),
          border: Border.all(color: Styles.c_E8EAEF),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(cfg?.name ?? key,
                style:
                    TextStyle(fontSize: 13.sp, color: Styles.c_0C1C33)),
            SizedBox(width: 4.w),
            Icon(Icons.keyboard_arrow_down,
                size: 16.w, color: Styles.c_8E9AB0),
          ],
        ),
      );
    });
  }
}

class _TokenCard extends StatelessWidget {
  final String label;
  final String tokenSymbol;
  final String amount;
  final bool isReadOnly;

  const _TokenCard({
    required this.label,
    required this.tokenSymbol,
    required this.amount,
    required this.isReadOnly,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(14.w),
      decoration: BoxDecoration(
        color: Styles.c_FFFFFF,
        borderRadius: BorderRadius.circular(14.r),
        border: Border.all(color: Styles.c_E8EAEF),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(label,
                  style:
                      TextStyle(fontSize: 13.sp, color: Styles.c_8E9AB0)),
              const Spacer(),
              Text('余额: 0',
                  style:
                      TextStyle(fontSize: 13.sp, color: Styles.c_8E9AB0)),
            ],
          ),
          SizedBox(height: 8.h),
          Row(
            children: [
              Expanded(
                child: Text(
                  amount,
                  style: TextStyle(
                      fontSize: 22.sp,
                      fontWeight: FontWeight.w600,
                      color: Styles.c_0C1C33),
                ),
              ),
              Container(
                padding:
                    EdgeInsets.symmetric(horizontal: 10.w, vertical: 6.h),
                decoration: BoxDecoration(
                  color: Styles.c_F8F9FA,
                  borderRadius: BorderRadius.circular(20.r),
                ),
                child: Row(
                  children: [
                    Text(tokenSymbol,
                        style: TextStyle(
                            fontSize: 13.sp,
                            color: Styles.c_0C1C33,
                            fontWeight: FontWeight.w600)),
                    SizedBox(width: 4.w),
                    Icon(Icons.keyboard_arrow_down,
                        size: 16.w, color: Styles.c_8E9AB0),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _QuoteInfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _QuoteInfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 4.h),
      child: Row(
        children: [
          Text(label,
              style: TextStyle(fontSize: 13.sp, color: Styles.c_8E9AB0)),
          const Spacer(),
          Text(value,
              style: TextStyle(fontSize: 13.sp, color: Styles.c_0C1C33)),
        ],
      ),
    );
  }
}
```

- [ ] **Step 1.12: Wire route from `wallet_main_view.dart`**

In `lib/pages/wallet/main/wallet_main_view.dart`, find the existing block at lines 152-156:

```dart
          _ActionBtn(
            icon: Icons.swap_horiz,
            label: 'Swap',
            color: const Color(0xFFFF9F40),
            onTap: () => EasyLoading.showToast('即将推出'),
          ),
```

Replace with:

```dart
          _ActionBtn(
            icon: Icons.swap_horiz,
            label: 'Swap',
            color: const Color(0xFFFF9F40),
            onTap: () => Get.to(
              () => const SwapView(),
              binding: SwapBinding(),
            ),
          ),
```

Add at top of file (alongside existing imports):

```dart
import '../swap/swap_binding.dart';
import '../swap/swap_view.dart';
```

- [ ] **Step 1.13: Manually verify Task 1**

```bash
fvm flutter run -d "iPhone 17"
```

Steps in app:
1. Unlock wallet.
2. Tap "Swap" button on main view.
3. Confirm: swap page opens, chain chip shows "Ethereum", two mock token cards visible, "Swap (mock)" button disabled.
4. Tap back arrow → returns to wallet main.

If pass, continue. If fail, fix before committing.

- [ ] **Step 1.14: Commit**

```bash
git add lib/pages/wallet/swap/ \
        lib/pages/wallet/main/wallet_main_view.dart
git commit -m "feat(swap): static UI skeleton + route wired from wallet main"
```

---

## Task 2: 0x `getPrice` — live soft quotes as user types

**Goal:** When the user picks From/To tokens and types an amount, the To-amount updates live from the 0x `/price` endpoint.

**Files:**
- Create: `lib/services/wallet/swap/zerox_provider.dart`
- Create: `test/services/wallet/swap/zerox_provider_test.dart`
- Create: `lib/pages/wallet/swap/token_picker_sheet.dart`
- Modify: `lib/pages/wallet/swap/swap_logic.dart` (add debounce + getPrice call)
- Modify: `lib/pages/wallet/swap/swap_view.dart` (replace mock values + wire token picker)

- [ ] **Step 2.1: Write `ZeroExProvider` minimum API surface**

The provider takes a `Dio` instance for HTTP — this lets tests inject a `Dio` with a mock adapter.

```dart
// lib/services/wallet/swap/zerox_provider.dart
import 'package:dio/dio.dart';
import '../chain_config.dart';
import 'swap_config.dart';
import 'swap_models.dart';
import 'swap_provider.dart';

class ZeroExProvider implements SwapProvider {
  static const String baseUrl = 'https://api.0x.org';

  /// Maps wallet chain keys to 0x `chainId`.
  static const Map<String, int> _chainIds = {
    'eth': 1,
    'bsc': 56,
    'polygon': 137,
    'arbitrum': 42161,
    'optimism': 10,
  };

  final Dio _dio;
  final String _apiKey;

  ZeroExProvider({Dio? dio, String? apiKey})
      : _dio = dio ?? Dio(BaseOptions(connectTimeout: const Duration(seconds: 10), receiveTimeout: const Duration(seconds: 10))),
        _apiKey = apiKey ?? kZeroxApiKey;

  @override
  String get id => 'zerox';

  @override
  String get displayName => '0x';

  @override
  bool supportsChain(String chainKey) => _chainIds.containsKey(chainKey);

  String _toApiAddress(SwapToken t) =>
      t.isNative ? kNativeTokenSentinel : t.contractAddress!;

  Map<String, dynamic> _baseParams(SwapQuoteRequest req) {
    final params = <String, dynamic>{
      'chainId': _chainIds[req.chainKey],
      'sellToken': _toApiAddress(req.sellToken),
      'buyToken': _toApiAddress(req.buyToken),
      'sellAmount': req.sellAmount.toString(),
      'taker': req.takerAddress,
      'slippageBps': req.slippageBps,
    };
    final recipient = kFeeRecipients[req.chainKey];
    if (recipient != null && recipient.isNotEmpty) {
      params['swapFeeBps'] = kSwapFeeBps;
      params['swapFeeRecipient'] = recipient;
      params['swapFeeToken'] = _toApiAddress(req.buyToken);
    }
    return params;
  }

  Map<String, String> get _headers => {
        '0x-api-key': _apiKey,
        '0x-version': 'v2',
      };

  void _validateBeforeCall(SwapQuoteRequest req) {
    if (_apiKey.isEmpty) {
      throw const SwapException(SwapErrorKind.noApiKey, '0x API key not set');
    }
    if (!supportsChain(req.chainKey)) {
      throw SwapException(
          SwapErrorKind.chainNotSupported, 'Chain ${req.chainKey} not supported by 0x');
    }
  }

  @override
  Future<SwapPriceResult> getPrice(SwapQuoteRequest req) async {
    _validateBeforeCall(req);
    try {
      final resp = await _dio.get(
        '$baseUrl/swap/allowance-holder/price',
        queryParameters: _baseParams(req),
        options: Options(headers: _headers),
      );
      final data = resp.data as Map<String, dynamic>;
      return SwapPriceResult(
        buyAmount: BigInt.parse(data['buyAmount'] as String),
        gasEstimate: data['gas'] != null
            ? BigInt.tryParse(data['gas'].toString())
            : null,
        fees: _parseFees(data['fees']),
        providerId: id,
      );
    } on DioException catch (e) {
      throw _toSwapException(e);
    }
  }

  @override
  Future<SwapQuote> getQuote(SwapQuoteRequest req) async {
    _validateBeforeCall(req);
    try {
      final resp = await _dio.get(
        '$baseUrl/swap/allowance-holder/quote',
        queryParameters: _baseParams(req),
        options: Options(headers: _headers),
      );
      final data = resp.data as Map<String, dynamic>;
      final tx = data['transaction'] as Map<String, dynamic>? ?? data;
      final buyAmount = BigInt.parse(data['buyAmount'] as String);
      final slippageBps = req.slippageBps;
      final minBuy =
          buyAmount * BigInt.from(10000 - slippageBps) ~/ BigInt.from(10000);
      ApprovalIssue? approval;
      final issues = data['issues'] as Map<String, dynamic>?;
      final allowanceIssue = issues?['allowance'];
      if (allowanceIssue is Map<String, dynamic>) {
        approval = ApprovalIssue(
          tokenAddress: req.sellToken.contractAddress!,
          spender: allowanceIssue['spender'] as String,
          requiredAmount: req.sellAmount,
        );
      }
      return SwapQuote(
        buyAmount: buyAmount,
        minBuyAmount: minBuy,
        to: tx['to'] as String,
        data: tx['data'] as String,
        value: BigInt.parse((tx['value'] ?? '0').toString()),
        gas: tx['gas'] != null ? BigInt.tryParse(tx['gas'].toString()) : null,
        gasPrice: tx['gasPrice'] != null
            ? BigInt.tryParse(tx['gasPrice'].toString())
            : null,
        approval: approval,
        fees: _parseFees(data['fees']),
        providerId: id,
      );
    } on DioException catch (e) {
      throw _toSwapException(e);
    }
  }

  SwapFees _parseFees(dynamic raw) {
    if (raw is! Map<String, dynamic>) return const SwapFees();
    BigInt? amount(dynamic field) {
      if (field is Map<String, dynamic>) {
        final v = field['amount'];
        return v == null ? null : BigInt.tryParse(v.toString());
      }
      return null;
    }
    String? token(dynamic field) {
      if (field is Map<String, dynamic>) {
        return field['token'] as String?;
      }
      return null;
    }
    return SwapFees(
      integratorFeeAmount: amount(raw['integratorFee']),
      integratorFeeToken: token(raw['integratorFee']),
      zeroExFeeAmount: amount(raw['zeroExFee']),
      gasFeeAmount: amount(raw['gasFee']),
    );
  }

  SwapException _toSwapException(DioException e) {
    final status = e.response?.statusCode;
    if (status == null) return SwapException(SwapErrorKind.network, e.message ?? 'network');
    if (status == 429) return const SwapException(SwapErrorKind.rateLimited, 'rate limited');
    if (status == 422) return const SwapException(SwapErrorKind.noLiquidity, 'no liquidity');
    if (status >= 400 && status < 500) {
      return SwapException(
          SwapErrorKind.invalidParams, '0x ${status}: ${e.response?.data}');
    }
    return SwapException(SwapErrorKind.unknown, '0x ${status}: ${e.response?.data}');
  }
}
```

- [ ] **Step 2.2: Write failing test — `getPrice` parses a happy-path response**

```dart
// test/services/wallet/swap/zerox_provider_test.dart
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openim/services/wallet/swap/swap_models.dart';
import 'package:openim/services/wallet/swap/zerox_provider.dart';

/// Minimal in-memory interceptor: returns canned responses for a list of
/// (matcher → response) pairs. No external dep beyond dio.
class _FakeAdapter extends HttpClientAdapter {
  final List<({bool Function(RequestOptions) match, ResponseBody body})> rules;
  _FakeAdapter(this.rules);

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<dynamic>? cancelFuture,
  ) async {
    for (final r in rules) {
      if (r.match(options)) return r.body;
    }
    return ResponseBody.fromString('{"reason":"unmatched"}', 404);
  }
}

ResponseBody _json(String body, int status) {
  return ResponseBody.fromString(body, status, headers: {
    'content-type': ['application/json'],
  });
}

Dio _makeDio(_FakeAdapter adapter) {
  final dio = Dio();
  dio.httpClientAdapter = adapter;
  return dio;
}

void main() {
  const ethToken =
      SwapToken(chainKey: 'eth', symbol: 'ETH', decimals: 18);
  const usdtToken = SwapToken(
    chainKey: 'eth',
    symbol: 'USDT',
    decimals: 6,
    contractAddress: '0xdAC17F958D2ee523a2206206994597C13D831ec7',
  );

  SwapQuoteRequest req() => SwapQuoteRequest(
        chainKey: 'eth',
        sellToken: ethToken,
        buyToken: usdtToken,
        sellAmount: BigInt.parse('1000000000000000000'),
        takerAddress: '0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045',
        slippageBps: 50,
      );

  test('getPrice parses buyAmount and integrator fee', () async {
    final adapter = _FakeAdapter([
      (
        match: (o) => o.path.contains('/swap/allowance-holder/price'),
        body: _json(
          '{"buyAmount":"3245100000","sellAmount":"1000000000000000000",'
          '"gas":"150000","fees":{"integratorFee":{"amount":"9690000",'
          '"token":"0xdAC17F958D2ee523a2206206994597C13D831ec7","type":"volume"}}}',
          200,
        ),
      ),
    ]);
    final p = ZeroExProvider(dio: _makeDio(adapter), apiKey: 'test');
    final r = await p.getPrice(req());
    expect(r.buyAmount, equals(BigInt.parse('3245100000')));
    expect(r.gasEstimate, equals(BigInt.from(150000)));
    expect(r.fees.integratorFeeAmount, equals(BigInt.from(9690000)));
    expect(r.providerId, equals('zerox'));
  });

  test('getPrice throws noApiKey when key empty', () async {
    final p = ZeroExProvider(dio: Dio(), apiKey: '');
    expect(
      () => p.getPrice(req()),
      throwsA(isA<SwapException>().having((e) => e.kind, 'kind',
          SwapErrorKind.noApiKey)),
    );
  });

  test('getPrice maps 422 to noLiquidity', () async {
    final adapter = _FakeAdapter([
      (
        match: (o) => o.path.contains('/price'),
        body: _json('{"reason":"INSUFFICIENT_ASSET_LIQUIDITY"}', 422),
      ),
    ]);
    final p = ZeroExProvider(dio: _makeDio(adapter), apiKey: 'test');
    expect(
      () => p.getPrice(req()),
      throwsA(isA<SwapException>().having((e) => e.kind, 'kind',
          SwapErrorKind.noLiquidity)),
    );
  });

  test('getPrice maps 429 to rateLimited', () async {
    final adapter = _FakeAdapter([
      (
        match: (o) => true,
        body: _json('{"reason":"throttled"}', 429),
      ),
    ]);
    final p = ZeroExProvider(dio: _makeDio(adapter), apiKey: 'test');
    expect(
      () => p.getPrice(req()),
      throwsA(isA<SwapException>().having((e) => e.kind, 'kind',
          SwapErrorKind.rateLimited)),
    );
  });

  test('supportsChain matches EVM mainnets only', () {
    final p = ZeroExProvider(dio: Dio(), apiKey: 'test');
    expect(p.supportsChain('eth'), isTrue);
    expect(p.supportsChain('polygon'), isTrue);
    expect(p.supportsChain('tron'), isFalse);
    expect(p.supportsChain('eth_sepolia'), isFalse);
  });
}
```

- [ ] **Step 2.3: Run the tests and verify they pass**

```bash
fvm flutter test test/services/wallet/swap/zerox_provider_test.dart
```

Expected: 5 tests pass.

- [ ] **Step 2.4: Commit**

```bash
git add lib/services/wallet/swap/zerox_provider.dart \
        test/services/wallet/swap/zerox_provider_test.dart
git commit -m "feat(swap): ZeroExProvider with getPrice/getQuote + JSON mapping tests"
```

- [ ] **Step 2.5: Add live price wiring to `swap_logic.dart`**

Replace the entire `swap_logic.dart` with this expanded version (Step 1.9's content + new logic):

```dart
// lib/pages/wallet/swap/swap_logic.dart
import 'dart:async';
import 'package:get/get.dart';
import '../../../services/wallet/chain_config.dart';
import '../../../services/wallet/swap/swap_models.dart';
import '../../../services/wallet/swap/swap_provider.dart';
import '../../../services/wallet/swap/zerox_provider.dart';
import '../wallet_logic.dart';

class SwapLogic extends GetxController {
  final WalletLogic _wallet = Get.find<WalletLogic>();

  final swapChainKey = 'eth'.obs;
  final sellToken = Rxn<SwapToken>();
  final buyToken = Rxn<SwapToken>();
  final sellAmountText = ''.obs;
  final priceResult = Rxn<SwapPriceResult>();
  final isFetchingPrice = false.obs;
  final lastError = Rxn<SwapException>();
  final slippageBps = 50.obs;
  final providerId = 'zerox'.obs;

  late final Map<String, SwapProvider> providers = {
    'zerox': ZeroExProvider(),
  };

  Timer? _debounce;
  int _priceSeq = 0;

  WalletLogic get wallet => _wallet;
  SwapProvider get activeProvider => providers[providerId.value]!;

  String get takerAddress {
    final acc = _wallet.selectedAccount.value;
    if (acc == null) return '';
    return acc.addresses[swapChainKey.value] ?? '';
  }

  /// sellAmount in raw BigInt units (10^decimals). Returns zero on parse failure
  /// or when sellToken not set.
  BigInt get sellAmountRaw {
    final t = sellToken.value;
    if (t == null) return BigInt.zero;
    final txt = sellAmountText.value;
    final dbl = double.tryParse(txt);
    if (dbl == null || dbl <= 0) return BigInt.zero;
    return BigInt.from(dbl * BigInt.from(10).pow(t.decimals).toDouble());
  }

  void onAmountInput(String text) {
    sellAmountText.value = text;
    _debounce?.cancel();
    _debounce =
        Timer(const Duration(milliseconds: 400), _fetchPriceIfReady);
  }

  void invertTokens() {
    final s = sellToken.value;
    final b = buyToken.value;
    sellToken.value = b;
    buyToken.value = s;
    sellAmountText.value = '';
    priceResult.value = null;
    lastError.value = null;
  }

  void switchChain(String chainKey) {
    if (!chains.containsKey(chainKey)) return;
    swapChainKey.value = chainKey;
    sellToken.value = null;
    buyToken.value = null;
    sellAmountText.value = '';
    priceResult.value = null;
    lastError.value = null;
  }

  void selectSellToken(SwapToken t) {
    sellToken.value = t;
    priceResult.value = null;
    _fetchPriceIfReady();
  }

  void selectBuyToken(SwapToken t) {
    buyToken.value = t;
    priceResult.value = null;
    _fetchPriceIfReady();
  }

  void setSlippageBps(int bps) {
    slippageBps.value = bps;
    _fetchPriceIfReady();
  }

  Future<void> _fetchPriceIfReady() async {
    final sell = sellToken.value;
    final buy = buyToken.value;
    final amt = sellAmountRaw;
    final taker = takerAddress;
    if (sell == null || buy == null || amt == BigInt.zero || taker.isEmpty) {
      priceResult.value = null;
      return;
    }
    if (sell == buy) {
      priceResult.value = null;
      return;
    }
    final req = SwapQuoteRequest(
      chainKey: swapChainKey.value,
      sellToken: sell,
      buyToken: buy,
      sellAmount: amt,
      takerAddress: taker,
      slippageBps: slippageBps.value,
    );
    final seq = ++_priceSeq;
    isFetchingPrice.value = true;
    lastError.value = null;
    try {
      final r = await activeProvider.getPrice(req);
      if (seq != _priceSeq) return; // stale; another call superseded
      priceResult.value = r;
    } on SwapException catch (e) {
      if (seq != _priceSeq) return;
      lastError.value = e;
      priceResult.value = null;
    } finally {
      if (seq == _priceSeq) isFetchingPrice.value = false;
    }
  }

  @override
  void onClose() {
    _debounce?.cancel();
    super.onClose();
  }
}
```

- [ ] **Step 2.6: Write `token_picker_sheet.dart` — picker for From/To**

```dart
// lib/pages/wallet/swap/token_picker_sheet.dart
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:get/get.dart';
import 'package:openim_common/openim_common.dart';
import '../../../services/wallet/chain_config.dart';
import '../../../services/wallet/swap/swap_models.dart';
import 'swap_logic.dart';

enum TokenPickerSide { sell, buy }

/// Returns the selected token, or null if dismissed.
Future<SwapToken?> showTokenPickerSheet(
    BuildContext context, TokenPickerSide side) async {
  final logic = Get.find<SwapLogic>();
  return showModalBottomSheet<SwapToken>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Styles.c_FFFFFF,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20.r)),
    ),
    builder: (_) => _TokenPickerSheet(logic: logic, side: side),
  );
}

class _TokenPickerSheet extends StatelessWidget {
  final SwapLogic logic;
  final TokenPickerSide side;
  const _TokenPickerSheet({required this.logic, required this.side});

  List<SwapToken> _candidates() {
    final chainKey = logic.swapChainKey.value;
    final cfg = chains[chainKey];
    if (cfg == null) return const [];

    if (side == TokenPickerSide.sell) {
      // From: only what the user actually holds on this chain.
      final held = logic.wallet.currentChainBalances
          .where((b) => b.chainKey == chainKey)
          .map((b) => SwapToken(
                chainKey: chainKey,
                symbol: b.symbol,
                decimals: b.decimals,
                contractAddress: b.contractAddress,
              ))
          .toList();
      return held;
    }

    // To: native + builtin tokens + custom tokens user added.
    final tokens = <SwapToken>[
      SwapToken(
        chainKey: chainKey,
        symbol: cfg.symbol,
        decimals: cfg.decimals,
      ),
      ...cfg.builtinTokens.map((t) => SwapToken(
            chainKey: chainKey,
            symbol: t.symbol,
            decimals: t.decimals,
            contractAddress: t.contractAddress,
          )),
      ...logic.wallet.settings.value.customTokens
          .where((c) => c.chainKey == chainKey)
          .map((c) => SwapToken(
                chainKey: chainKey,
                symbol: c.symbol,
                decimals: c.decimals,
                contractAddress: c.contractAddress,
              )),
    ];

    // Don't allow picking the same token as sell side.
    final excluded = logic.sellToken.value;
    return tokens.where((t) => t != excluded).toList();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = _candidates();
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.7,
      ),
      padding: EdgeInsets.fromLTRB(20.w, 16.h, 20.w, 16.h),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 36.w,
              height: 4.h,
              decoration: BoxDecoration(
                color: Styles.c_E8EAEF,
                borderRadius: BorderRadius.circular(2.r),
              ),
            ),
          ),
          SizedBox(height: 16.h),
          Text(side == TokenPickerSide.sell ? '选择支付代币' : '选择获得代币',
              style: TextStyle(
                  fontSize: 17.sp,
                  fontWeight: FontWeight.bold,
                  color: Styles.c_0C1C33)),
          SizedBox(height: 12.h),
          Expanded(
            child: tokens.isEmpty
                ? Center(
                    child: Text(
                        side == TokenPickerSide.sell
                            ? '当前链无持仓资产'
                            : '该链暂无可选代币',
                        style: TextStyle(
                            fontSize: 14.sp, color: Styles.c_8E9AB0)),
                  )
                : ListView.builder(
                    itemCount: tokens.length,
                    itemBuilder: (_, i) {
                      final t = tokens[i];
                      return ListTile(
                        contentPadding: EdgeInsets.symmetric(
                            horizontal: 0, vertical: 4.h),
                        leading: Container(
                          width: 40.w,
                          height: 40.w,
                          decoration: BoxDecoration(
                            color:
                                Styles.c_0089FF.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(12.r),
                          ),
                          child: Center(
                            child: Text(
                              t.symbol.substring(
                                  0, t.symbol.length.clamp(0, 3)),
                              style: TextStyle(
                                fontSize: 12.sp,
                                fontWeight: FontWeight.bold,
                                color: Styles.c_0089FF,
                              ),
                            ),
                          ),
                        ),
                        title: Text(t.symbol,
                            style: TextStyle(
                                fontSize: 15.sp,
                                color: Styles.c_0C1C33,
                                fontWeight: FontWeight.w600)),
                        subtitle: t.contractAddress != null
                            ? Text(
                                _shortAddr(t.contractAddress!),
                                style: TextStyle(
                                    fontSize: 11.sp,
                                    color: Styles.c_8E9AB0),
                              )
                            : Text('原生代币',
                                style: TextStyle(
                                    fontSize: 11.sp,
                                    color: Styles.c_8E9AB0)),
                        onTap: () => Get.back(result: t),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  String _shortAddr(String a) =>
      a.length > 12 ? '${a.substring(0, 6)}…${a.substring(a.length - 4)}' : a;
}
```

- [ ] **Step 2.7: Update `swap_view.dart` to use live data + open the picker**

Replace `lib/pages/wallet/swap/swap_view.dart` entirely:

```dart
// lib/pages/wallet/swap/swap_view.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:get/get.dart';
import 'package:openim_common/openim_common.dart';
import '../../../services/wallet/chain_config.dart';
import '../../../services/wallet/swap/swap_models.dart';
import 'swap_logic.dart';
import 'token_picker_sheet.dart';

class SwapView extends StatelessWidget {
  const SwapView({super.key});

  @override
  Widget build(BuildContext context) {
    final logic = Get.find<SwapLogic>();
    return Scaffold(
      backgroundColor: Styles.c_F8F9FA,
      appBar: AppBar(
        backgroundColor: Styles.c_F8F9FA,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios, color: Styles.c_0C1C33, size: 18.w),
          onPressed: () => Get.back(),
        ),
        title: Text('闪兑',
            style: TextStyle(
                fontSize: 18.sp,
                fontWeight: FontWeight.w600,
                color: Styles.c_0C1C33)),
        actions: [
          IconButton(
            icon: Icon(Icons.settings_outlined,
                color: Styles.c_0C1C33, size: 22.w),
            onPressed: () {},
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.all(16.w),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildChainChip(logic),
            SizedBox(height: 16.h),
            _SellCard(logic: logic),
            SizedBox(height: 12.h),
            _buildInvertButton(logic),
            SizedBox(height: 12.h),
            _BuyCard(logic: logic),
            SizedBox(height: 20.h),
            _QuoteSummary(logic: logic),
            SizedBox(height: 24.h),
            _MainButton(logic: logic),
          ],
        ),
      ),
    );
  }

  Widget _buildChainChip(SwapLogic logic) {
    return Obx(() {
      final key = logic.swapChainKey.value;
      final cfg = chains[key];
      return GestureDetector(
        onTap: () {
          // Chain picker bottom sheet — added in Task 5; static for now.
        },
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 8.h),
          decoration: BoxDecoration(
            color: Styles.c_FFFFFF,
            borderRadius: BorderRadius.circular(20.r),
            border: Border.all(color: Styles.c_E8EAEF),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(cfg?.name ?? key,
                  style:
                      TextStyle(fontSize: 13.sp, color: Styles.c_0C1C33)),
              SizedBox(width: 4.w),
              Icon(Icons.keyboard_arrow_down,
                  size: 16.w, color: Styles.c_8E9AB0),
            ],
          ),
        ),
      );
    });
  }

  Widget _buildInvertButton(SwapLogic logic) {
    return Center(
      child: GestureDetector(
        onTap: logic.invertTokens,
        child: Container(
          width: 40.w,
          height: 40.w,
          decoration: BoxDecoration(
            color: Styles.c_FFFFFF,
            shape: BoxShape.circle,
            border: Border.all(color: Styles.c_E8EAEF),
          ),
          child: Icon(Icons.swap_vert, color: Styles.c_0089FF, size: 22.w),
        ),
      ),
    );
  }
}

class _SellCard extends StatelessWidget {
  final SwapLogic logic;
  const _SellCard({required this.logic});

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final t = logic.sellToken.value;
      final balance = _balanceFor(logic, t);
      return _TokenCard(
        label: '支付',
        balanceText: balance,
        amountController: null,
        readOnly: false,
        token: t,
        amountValue: logic.sellAmountText.value,
        onAmountChanged: logic.onAmountInput,
        onPickToken: () async {
          final picked = await showTokenPickerSheet(
              context, TokenPickerSide.sell);
          if (picked != null) logic.selectSellToken(picked);
        },
        onMax: t == null
            ? null
            : () {
                final bal = balance;
                if (bal != null) logic.onAmountInput(bal);
              },
      );
    });
  }

  String? _balanceFor(SwapLogic logic, SwapToken? t) {
    if (t == null) return null;
    for (final b in logic.wallet.currentChainBalances) {
      if (b.symbol == t.symbol && b.contractAddress == t.contractAddress) {
        return b.balance.toString();
      }
    }
    return '0';
  }
}

class _BuyCard extends StatelessWidget {
  final SwapLogic logic;
  const _BuyCard({required this.logic});

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final t = logic.buyToken.value;
      final priceR = logic.priceResult.value;
      String amountStr = '';
      if (priceR != null && t != null) {
        amountStr =
            _formatBigInt(priceR.buyAmount, t.decimals);
      }
      return _TokenCard(
        label: '获得',
        balanceText: null,
        amountController: null,
        readOnly: true,
        token: t,
        amountValue: amountStr,
        onAmountChanged: (_) {},
        onPickToken: () async {
          final picked = await showTokenPickerSheet(
              context, TokenPickerSide.buy);
          if (picked != null) logic.selectBuyToken(picked);
        },
        onMax: null,
      );
    });
  }
}

class _TokenCard extends StatelessWidget {
  final String label;
  final String? balanceText;
  final TextEditingController? amountController;
  final bool readOnly;
  final SwapToken? token;
  final String amountValue;
  final ValueChanged<String> onAmountChanged;
  final VoidCallback onPickToken;
  final VoidCallback? onMax;

  const _TokenCard({
    required this.label,
    required this.balanceText,
    required this.amountController,
    required this.readOnly,
    required this.token,
    required this.amountValue,
    required this.onAmountChanged,
    required this.onPickToken,
    required this.onMax,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(14.w),
      decoration: BoxDecoration(
        color: Styles.c_FFFFFF,
        borderRadius: BorderRadius.circular(14.r),
        border: Border.all(color: Styles.c_E8EAEF),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(label,
                  style:
                      TextStyle(fontSize: 13.sp, color: Styles.c_8E9AB0)),
              const Spacer(),
              if (balanceText != null)
                Text('余额: $balanceText',
                    style: TextStyle(
                        fontSize: 13.sp, color: Styles.c_8E9AB0)),
            ],
          ),
          SizedBox(height: 8.h),
          Row(
            children: [
              Expanded(
                child: TextField(
                  enabled: !readOnly,
                  controller: amountController ??
                      TextEditingController(text: amountValue)
                    ..selection = TextSelection.collapsed(
                        offset: amountValue.length),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[\d.]')),
                  ],
                  style: TextStyle(
                      fontSize: 22.sp,
                      fontWeight: FontWeight.w600,
                      color: Styles.c_0C1C33),
                  decoration: const InputDecoration(
                    hintText: '0.0',
                    border: InputBorder.none,
                  ),
                  onChanged: onAmountChanged,
                ),
              ),
              if (onMax != null)
                TextButton(
                  onPressed: onMax,
                  child: Text('MAX',
                      style: TextStyle(
                          color: Styles.c_0089FF, fontSize: 12.sp)),
                ),
              GestureDetector(
                onTap: onPickToken,
                child: Container(
                  padding:
                      EdgeInsets.symmetric(horizontal: 10.w, vertical: 6.h),
                  decoration: BoxDecoration(
                    color: Styles.c_F8F9FA,
                    borderRadius: BorderRadius.circular(20.r),
                  ),
                  child: Row(
                    children: [
                      Text(token?.symbol ?? '选择代币',
                          style: TextStyle(
                              fontSize: 13.sp,
                              color: Styles.c_0C1C33,
                              fontWeight: FontWeight.w600)),
                      SizedBox(width: 4.w),
                      Icon(Icons.keyboard_arrow_down,
                          size: 16.w, color: Styles.c_8E9AB0),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _QuoteSummary extends StatelessWidget {
  final SwapLogic logic;
  const _QuoteSummary({required this.logic});

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final r = logic.priceResult.value;
      final sell = logic.sellToken.value;
      final buy = logic.buyToken.value;
      if (r == null || sell == null || buy == null) {
        return const SizedBox.shrink();
      }
      final sellAmt = logic.sellAmountRaw;
      final rate = sellAmt == BigInt.zero
          ? '-'
          : '${_formatBigInt(r.buyAmount, buy.decimals)} ${buy.symbol} / '
              '${_formatBigInt(sellAmt, sell.decimals)} ${sell.symbol}';
      final feeAmt = r.fees.integratorFeeAmount;
      return Column(
        children: [
          _row('报价方', '0x'),
          _row('汇率', rate),
          _row('滑点', '${(logic.slippageBps.value / 100).toStringAsFixed(2)}%'),
          if (feeAmt != null)
            _row('平台费',
                '0.30% (${_formatBigInt(feeAmt, buy.decimals)} ${buy.symbol})'),
        ],
      );
    });
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 4.h),
      child: Row(
        children: [
          Text(label,
              style: TextStyle(fontSize: 13.sp, color: Styles.c_8E9AB0)),
          const Spacer(),
          Text(value,
              style: TextStyle(fontSize: 13.sp, color: Styles.c_0C1C33)),
        ],
      ),
    );
  }
}

class _MainButton extends StatelessWidget {
  final SwapLogic logic;
  const _MainButton({required this.logic});

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final text = _resolveText(logic);
      final enabled = text == 'Swap';
      return SizedBox(
        width: double.infinity,
        height: 52.h,
        child: ElevatedButton(
          onPressed: enabled ? () {} : null, // wired in Task 3
          style: ElevatedButton.styleFrom(
            backgroundColor: Styles.c_0089FF,
            disabledBackgroundColor: Styles.c_8E9AB0,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14.r),
            ),
            elevation: 0,
          ),
          child: Text(text,
              style: TextStyle(
                  fontSize: 16.sp, fontWeight: FontWeight.w600)),
        ),
      );
    });
  }

  String _resolveText(SwapLogic logic) {
    if (logic.sellToken.value == null || logic.buyToken.value == null) {
      return '选择代币';
    }
    if (logic.sellAmountRaw == BigInt.zero) return '输入金额';
    if (logic.isFetchingPrice.value) return '查询报价中…';
    final err = logic.lastError.value;
    if (err != null) {
      switch (err.kind) {
        case SwapErrorKind.noApiKey:
          return 'Swap 未配置';
        case SwapErrorKind.noLiquidity:
          return '无可用路由';
        case SwapErrorKind.chainNotSupported:
          return '该链暂不支持 Swap';
        case SwapErrorKind.network:
          return '网络异常';
        case SwapErrorKind.rateLimited:
          return '请求过频';
        default:
          return '报价失败';
      }
    }
    if (logic.priceResult.value == null) return '输入金额';
    return 'Swap';
  }
}

String _formatBigInt(BigInt raw, int decimals) {
  if (raw == BigInt.zero) return '0';
  final divisor = BigInt.from(10).pow(decimals);
  final whole = raw ~/ divisor;
  final frac = raw - whole * divisor;
  if (frac == BigInt.zero) return whole.toString();
  var fracStr = frac.toString().padLeft(decimals, '0');
  // Trim trailing zeros, max 6 decimals shown
  fracStr = fracStr.length > 6 ? fracStr.substring(0, 6) : fracStr;
  fracStr = fracStr.replaceFirst(RegExp(r'0+$'), '');
  if (fracStr.isEmpty) return whole.toString();
  return '$whole.$fracStr';
}
```

- [ ] **Step 2.8: Manually verify Task 2**

```bash
fvm flutter run -d "iPhone 17" --dart-define=ZEROX_API_KEY=<paste-real-key>
```

In app:
1. Unlock wallet on Ethereum mainnet with some assets (or at least native).
2. Tap Swap → land on swap page.
3. Tap "选择代币" on the From card → token picker shows held assets → pick ETH.
4. Tap "选择代币" on the To card → picker shows USDT/USDC → pick USDT.
5. Type "0.001" in the amount field.
6. After ~400ms debounce: button changes from "输入金额" → "查询报价中…" → "Swap" (still wired to no-op).
7. Quote summary appears showing 0x as provider, rate, slippage, fee.

If pass, continue.

- [ ] **Step 2.9: Commit**

```bash
git add lib/pages/wallet/swap/swap_logic.dart \
        lib/pages/wallet/swap/swap_view.dart \
        lib/pages/wallet/swap/token_picker_sheet.dart
git commit -m "feat(swap): live 0x soft quotes with debounce + token picker"
```

---

## Task 3: Approve + sendRaw — make a swap actually execute

**Goal:** Tapping the Swap button broadcasts a real transaction. For ERC20 sells, an Approve transaction is sent first (with `MaxUint256`). No TOTP yet (that's Task 4); we use password-only auth for this slice to keep the diff testable.

**Files:**
- Modify: `lib/services/wallet/evm_service.dart` (add `sendRaw`, `sendApprove`, `getAllowance`, `getDecimals`, `waitForReceipt`)
- Create: `test/services/wallet/evm_service_test.dart` (test the helpers that don't need network — calldata encoding)
- Modify: `lib/pages/wallet/swap/swap_logic.dart` (add executeSwap that takes password)
- Modify: `lib/pages/wallet/swap/swap_view.dart` (wire main button to a password sheet → executeSwap)

- [ ] **Step 3.1: Add `sendRaw` + approval helpers to `EvmService`**

Edit `lib/services/wallet/evm_service.dart`. The existing class already has `sendNative` and `sendToken`. Append these new methods inside the `EvmService` class (before the `dispose()` method at the end):

```dart
  // ── Swap helpers ──────────────────────────────────────────────────────────

  /// ERC20 `decimals()` selector: 0x313ce567.
  Future<int> getDecimals(String contractAddress) async {
    final contract = DeployedContract(
      ContractAbi.fromJson(
          '[{"constant":true,"inputs":[],"name":"decimals","outputs":[{"name":"","type":"uint8"}],"type":"function"}]',
          'ERC20Decimals'),
      EthereumAddress.fromHex(contractAddress),
    );
    final fn = contract.function('decimals');
    final result = await _rpc(
      (c) => c.call(contract: contract, function: fn, params: []),
    );
    return (result.first as BigInt).toInt();
  }

  Future<BigInt> getAllowance({
    required String owner,
    required String spender,
    required String tokenContract,
  }) async {
    final contract = DeployedContract(
      ContractAbi.fromJson(
          '[{"constant":true,"inputs":[{"name":"o","type":"address"},{"name":"s","type":"address"}],"name":"allowance","outputs":[{"name":"","type":"uint256"}],"type":"function"}]',
          'ERC20Allowance'),
      EthereumAddress.fromHex(tokenContract),
    );
    final fn = contract.function('allowance');
    final result = await _rpc(
      (c) => c.call(
        contract: contract,
        function: fn,
        params: [
          EthereumAddress.fromHex(owner),
          EthereumAddress.fromHex(spender),
        ],
      ),
    );
    return result.first as BigInt;
  }

  /// Approves `spender` to spend `amount` of `tokenContract`. Returns tx hash.
  /// For swap flows callers should pass MaxUint256.
  Future<String> sendApprove({
    required EthPrivateKey senderKey,
    required String tokenContract,
    required String spender,
    required BigInt amount,
  }) async {
    final contract = DeployedContract(
      ContractAbi.fromJson(
          '[{"inputs":[{"name":"_s","type":"address"},{"name":"_v","type":"uint256"}],"name":"approve","outputs":[{"name":"","type":"bool"}],"type":"function"}]',
          'ERC20Approve'),
      EthereumAddress.fromHex(tokenContract),
    );
    final fn = contract.function('approve');
    return _rpc((c) async {
      final gasPrice = await c.getGasPrice();
      final tx = Transaction.callContract(
        contract: contract,
        function: fn,
        parameters: [EthereumAddress.fromHex(spender), amount],
        gasPrice: gasPrice,
        maxGas: 70000,
      );
      return c.sendTransaction(senderKey, tx, chainId: config.chainId);
    });
  }

  /// Broadcasts an arbitrary calldata transaction (e.g. 0x swap calldata).
  /// `dataHex` may or may not start with "0x".
  Future<String> sendRaw({
    required EthPrivateKey senderKey,
    required String to,
    required String dataHex,
    required BigInt value,
    BigInt? gasLimit,
    BigInt? gasPrice,
  }) async {
    final hex = dataHex.startsWith('0x') ? dataHex.substring(2) : dataHex;
    final bytes = Uint8List.fromList(
      [for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)],
    );
    return _rpc((c) async {
      final gp = gasPrice ?? await c.getGasPrice().then((g) => g.getInWei);
      final tx = Transaction(
        to: EthereumAddress.fromHex(to),
        value: EtherAmount.fromBigInt(EtherUnit.wei, value),
        data: bytes,
        gasPrice: EtherAmount.fromBigInt(EtherUnit.wei, gp),
        maxGas: gasLimit?.toInt() ?? 300000,
      );
      return c.sendTransaction(senderKey, tx, chainId: config.chainId);
    });
  }

  /// Polls receipt until status is known or timeout. Returns true iff status==1.
  Future<bool> waitForReceipt(String txHash, {Duration timeout = const Duration(seconds: 60)}) async {
    final start = DateTime.now();
    while (DateTime.now().difference(start) < timeout) {
      try {
        final receipt = await _rpc((c) => c.getTransactionReceipt(txHash));
        if (receipt != null) {
          return receipt.status == true;
        }
      } catch (_) {}
      await Future.delayed(const Duration(seconds: 3));
    }
    return false;
  }
```

- [ ] **Step 3.2: Write failing test for `sendRaw` calldata hex parsing**

We can't easily test the network call, but we CAN extract the hex parsing logic and test it:

```dart
// test/services/wallet/swap/swap_helpers_test.dart
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';

/// Reproduces the hex parser inside EvmService.sendRaw — keep in sync.
Uint8List parseHex(String dataHex) {
  final hex = dataHex.startsWith('0x') ? dataHex.substring(2) : dataHex;
  return Uint8List.fromList(
    [for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)],
  );
}

void main() {
  group('parseHex', () {
    test('strips 0x prefix', () {
      expect(parseHex('0x1234'), equals([0x12, 0x34]));
    });
    test('accepts no prefix', () {
      expect(parseHex('1234'), equals([0x12, 0x34]));
    });
    test('handles 32-byte word', () {
      final input = '0x' + ('ff' * 32);
      expect(parseHex(input).length, equals(32));
      expect(parseHex(input).every((b) => b == 0xff), isTrue);
    });
  });
}
```

- [ ] **Step 3.3: Run the test**

```bash
fvm flutter test test/services/wallet/swap/swap_helpers_test.dart
```

Expected: 3 tests pass.

- [ ] **Step 3.4: Commit**

```bash
git add lib/services/wallet/evm_service.dart \
        test/services/wallet/swap/swap_helpers_test.dart
git commit -m "feat(evm): add sendRaw / sendApprove / getAllowance / getDecimals helpers"
```

- [ ] **Step 3.5: Add `executeSwap` to `swap_logic.dart`**

Open `lib/pages/wallet/swap/swap_logic.dart`. Find the existing closing `}` of `class SwapLogic`. The snippet below contains:

1. The `executeSwap` method and `_maxUint256` constant — paste these **inside** `SwapLogic`, just before its existing closing brace.
2. A top-level `class SwapExecutionResult { ... }` — paste this **after** the closing brace of `SwapLogic`.

Both are shown together for clarity (note the explicit `}` separating them and the closing `}` on `SwapExecutionResult`):

```dart
  /// Result of executeSwap. Carries the broadcast tx hash, or an error
  /// description for the result page.
  Future<SwapExecutionResult> executeSwap({required String password}) async {
    final sell = sellToken.value;
    final buy = buyToken.value;
    final amt = sellAmountRaw;
    final taker = takerAddress;
    if (sell == null || buy == null || amt == BigInt.zero || taker.isEmpty) {
      return const SwapExecutionResult.failed('内部错误：缺少参数');
    }
    final account = _wallet.selectedAccount.value;
    if (account == null) {
      return const SwapExecutionResult.failed('未选择账户');
    }
    final chainKey = swapChainKey.value;
    final config = chains[chainKey];
    if (config == null) {
      return const SwapExecutionResult.failed('链配置缺失');
    }

    // Step 1: hard quote
    final req = SwapQuoteRequest(
      chainKey: chainKey,
      sellToken: sell,
      buyToken: buy,
      sellAmount: amt,
      takerAddress: taker,
      slippageBps: slippageBps.value,
    );
    SwapQuote quote;
    try {
      quote = await activeProvider.getQuote(req);
    } on SwapException catch (e) {
      return SwapExecutionResult.failed('报价失败: ${e.message}');
    }

    // Decrypt mnemonic → derive EVM key
    final svc = EvmService(config, chainKey);
    EthPrivateKey? evmKey;
    try {
      evmKey = await _wallet.vault.withMnemonic(password, (mBytes) async {
        final seed = WalletKey.mnemonicToSeed(mBytes);
        try {
          return WalletKey.deriveEVMKey(seed, account.index);
        } finally {
          seed.fillRange(0, seed.length, 0);
        }
      });
    } catch (e) {
      svc.dispose();
      return SwapExecutionResult.failed('密码错误或解密失败');
    }
    if (evmKey == null) {
      svc.dispose();
      return const SwapExecutionResult.failed('无法派生密钥');
    }

    try {
      // Step 2: Approve if needed
      if (quote.approval != null) {
        final approval = quote.approval!;
        try {
          final approveTx = await svc.sendApprove(
            senderKey: evmKey,
            tokenContract: approval.tokenAddress,
            spender: approval.spender,
            amount: _maxUint256,
          );
          final ok = await svc.waitForReceipt(approveTx);
          if (!ok) {
            return SwapExecutionResult.failed('授权交易未确认，请稍后重试');
          }
        } catch (e) {
          return SwapExecutionResult.failed('授权失败: $e');
        }

        // Re-quote — calldata + buyAmount may shift after approve confirmed.
        try {
          quote = await activeProvider.getQuote(req);
        } on SwapException catch (e) {
          return SwapExecutionResult.failed('重新报价失败: ${e.message}');
        }
      }

      // Step 3: send swap calldata
      final txHash = await svc.sendRaw(
        senderKey: evmKey,
        to: quote.to,
        dataHex: quote.data,
        value: quote.value,
        gasLimit: quote.gas,
        gasPrice: quote.gasPrice,
      );
      // Don't await final confirmation — return immediately.
      _wallet.refreshBalances();
      return SwapExecutionResult.success(
        txHash: txHash,
        chainKey: chainKey,
      );
    } catch (e) {
      return SwapExecutionResult.failed('Swap 失败: $e');
    } finally {
      svc.dispose();
    }
  }

  static final BigInt _maxUint256 =
      BigInt.parse('ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff', radix: 16);
}

class SwapExecutionResult {
  final bool ok;
  final String? txHash;
  final String? chainKey;
  final String? error;

  const SwapExecutionResult.success({required String this.txHash, required String this.chainKey})
      : ok = true, error = null;

  const SwapExecutionResult.failed(String this.error)
      : ok = false, txHash = null, chainKey = null;
}
```

Then add these imports to the top of `swap_logic.dart`:

```dart
import 'package:web3dart/web3dart.dart';
import '../../../services/wallet/evm_service.dart';
import '../../../services/wallet/wallet_key.dart';
```

- [ ] **Step 3.6: Wire main button to a password sheet that calls `executeSwap`**

In `swap_view.dart`, replace the `_MainButton` class with this version that opens a password sheet on tap:

```dart
class _MainButton extends StatelessWidget {
  final SwapLogic logic;
  const _MainButton({required this.logic});

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final text = _resolveText(logic);
      final enabled = text == 'Swap' || text.startsWith('授权');
      return SizedBox(
        width: double.infinity,
        height: 52.h,
        child: ElevatedButton(
          onPressed: enabled ? () => _onTap(context) : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: Styles.c_0089FF,
            disabledBackgroundColor: Styles.c_8E9AB0,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14.r),
            ),
            elevation: 0,
          ),
          child: Text(text,
              style: TextStyle(
                  fontSize: 16.sp, fontWeight: FontWeight.w600)),
        ),
      );
    });
  }

  void _onTap(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Styles.c_FFFFFF,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20.r)),
      ),
      builder: (_) => _PasswordSheet(logic: logic),
    );
  }

  String _resolveText(SwapLogic logic) {
    if (logic.sellToken.value == null || logic.buyToken.value == null) {
      return '选择代币';
    }
    if (logic.sellAmountRaw == BigInt.zero) return '输入金额';
    if (logic.isFetchingPrice.value) return '查询报价中…';
    final err = logic.lastError.value;
    if (err != null) {
      switch (err.kind) {
        case SwapErrorKind.noApiKey:
          return 'Swap 未配置';
        case SwapErrorKind.noLiquidity:
          return '无可用路由';
        case SwapErrorKind.chainNotSupported:
          return '该链暂不支持 Swap';
        case SwapErrorKind.network:
          return '网络异常';
        case SwapErrorKind.rateLimited:
          return '请求过频';
        default:
          return '报价失败';
      }
    }
    if (logic.priceResult.value == null) return '输入金额';
    return 'Swap';
  }
}

class _PasswordSheet extends StatefulWidget {
  final SwapLogic logic;
  const _PasswordSheet({required this.logic});

  @override
  State<_PasswordSheet> createState() => _PasswordSheetState();
}

class _PasswordSheetState extends State<_PasswordSheet> {
  final _pwdCtrl = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _pwdCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _sending = true);
    Get.back(); // close password sheet first
    EasyLoading.show(status: '提交中...');
    final result = await widget.logic.executeSwap(password: _pwdCtrl.text);
    EasyLoading.dismiss();
    if (result.ok) {
      EasyLoading.showSuccess('交易已广播\n${result.txHash}');
    } else {
      EasyLoading.showError(result.error ?? 'Swap 失败');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
          20.w, 20.h, 20.w, MediaQuery.of(context).viewInsets.bottom + 20.h),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('确认 Swap',
              style: TextStyle(
                  fontSize: 18.sp,
                  fontWeight: FontWeight.bold,
                  color: Styles.c_0C1C33)),
          SizedBox(height: 12.h),
          Text('输入钱包密码确认',
              style:
                  TextStyle(fontSize: 14.sp, color: Styles.c_8E9AB0)),
          SizedBox(height: 8.h),
          TextField(
            controller: _pwdCtrl,
            obscureText: true,
            style: TextStyle(fontSize: 16.sp),
            decoration: InputDecoration(
              hintText: '钱包密码',
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10.r)),
            ),
          ),
          SizedBox(height: 20.h),
          SizedBox(
            width: double.infinity,
            height: 50.h,
            child: ElevatedButton(
              onPressed: _sending ? null : _submit,
              style: ElevatedButton.styleFrom(
                backgroundColor: Styles.c_0089FF,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12.r)),
              ),
              child: Text('确认',
                  style: TextStyle(
                      fontSize: 16.sp, fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ),
    );
  }
}
```

Add these imports at top of `swap_view.dart`:

```dart
import 'package:flutter_easyloading/flutter_easyloading.dart';
```

- [ ] **Step 3.7: Manually verify Task 3**

```bash
fvm flutter run -d "iPhone 17" --dart-define=ZEROX_API_KEY=<key>
```

**Test A — native → token (no approve):**
1. Unlock wallet on Ethereum.
2. Swap: From=ETH, To=USDT, 0.0005 ETH.
3. Wait for quote, tap Swap → enter password → confirm.
4. Should see "交易已广播 0x...". Etherscan should show the swap transaction.

**Test B — token → native (with approve):**
1. Same wallet, ensure USDT balance > 0.5.
2. Swap: From=USDT, To=ETH, 0.5 USDT.
3. Submit → expect two sequential transactions (approve then swap), each with its own toast/loader.
4. On-chain: approve tx with `0xffffffff…` amount, then a settlement tx.

If both pass, continue.

- [ ] **Step 3.8: Commit**

```bash
git add lib/pages/wallet/swap/swap_logic.dart \
        lib/pages/wallet/swap/swap_view.dart
git commit -m "feat(swap): executeSwap with optional approve + password gate"
```

---

## Task 4: TOTP gate + Result page + Error matrix

**Goal:** Match `wallet_send_view.dart`'s TOTP gating (call `TotpService.status()`, then `showTotpVerifyDialog` if enabled). On success/failure, route to a dedicated `SwapResultView` that shows hash + explorer link. Fill in the §7 error matrix from the spec.

**Files:**
- Create: `lib/pages/wallet/swap/swap_result_view.dart`
- Modify: `lib/pages/wallet/swap/swap_logic.dart` (TOTP check before broadcast; richer error mapping; price-drift detection)
- Modify: `lib/pages/wallet/swap/swap_view.dart` (route to result page after submit; add no-API-key banner)

- [ ] **Step 4.1: Write `swap_result_view.dart`**

```dart
// lib/pages/wallet/swap/swap_result_view.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_easyloading/flutter_easyloading.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:get/get.dart';
import 'package:openim_common/openim_common.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../services/wallet/chain_config.dart';

class SwapResultView extends StatelessWidget {
  final bool success;
  final String? txHash;
  final String? chainKey;
  final String? errorMessage;

  const SwapResultView({
    super.key,
    required this.success,
    this.txHash,
    this.chainKey,
    this.errorMessage,
  });

  @override
  Widget build(BuildContext context) {
    final explorer = chainKey != null && txHash != null
        ? '${chains[chainKey!]?.txExplorerBase ?? ''}$txHash'
        : null;
    return Scaffold(
      backgroundColor: Styles.c_F8F9FA,
      appBar: AppBar(
        backgroundColor: Styles.c_F8F9FA,
        elevation: 0,
        title: Text(success ? '交易已提交' : '提交失败',
            style: TextStyle(
                fontSize: 18.sp,
                fontWeight: FontWeight.w600,
                color: Styles.c_0C1C33)),
        leading: IconButton(
          icon: Icon(Icons.close, color: Styles.c_0C1C33, size: 22.w),
          onPressed: () => Get.until((r) => r.isFirst || r.settings.name == '/'),
        ),
      ),
      body: Padding(
        padding: EdgeInsets.all(20.w),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(height: 40.h),
            Container(
              width: 80.w,
              height: 80.w,
              decoration: BoxDecoration(
                color: (success ? Colors.green : Colors.red).withAlpha(30),
                shape: BoxShape.circle,
              ),
              child: Icon(
                success ? Icons.check : Icons.close,
                color: success ? Colors.green : Colors.red,
                size: 40.w,
              ),
            ),
            SizedBox(height: 20.h),
            Text(
              success ? '已广播至区块链' : (errorMessage ?? '失败'),
              style: TextStyle(
                  fontSize: 16.sp,
                  fontWeight: FontWeight.w600,
                  color: Styles.c_0C1C33),
              textAlign: TextAlign.center,
            ),
            if (txHash != null) ...[
              SizedBox(height: 24.h),
              GestureDetector(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: txHash!));
                  EasyLoading.showToast('已复制');
                },
                child: Container(
                  padding: EdgeInsets.symmetric(
                      horizontal: 16.w, vertical: 12.h),
                  decoration: BoxDecoration(
                    color: Styles.c_FFFFFF,
                    borderRadius: BorderRadius.circular(12.r),
                    border: Border.all(color: Styles.c_E8EAEF),
                  ),
                  child: Text(
                    _short(txHash!),
                    style: TextStyle(
                        fontSize: 13.sp, color: Styles.c_0C1C33),
                  ),
                ),
              ),
            ],
            const Spacer(),
            if (explorer != null && explorer.isNotEmpty)
              SizedBox(
                width: double.infinity,
                height: 48.h,
                child: OutlinedButton(
                  onPressed: () => launchUrl(Uri.parse(explorer),
                      mode: LaunchMode.externalApplication),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Styles.c_0089FF,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12.r)),
                  ),
                  child: Text('查看链上详情',
                      style: TextStyle(
                          fontSize: 15.sp, fontWeight: FontWeight.w600)),
                ),
              ),
            SizedBox(height: 10.h),
            SizedBox(
              width: double.infinity,
              height: 48.h,
              child: ElevatedButton(
                onPressed: () =>
                    Get.until((r) => r.isFirst || r.settings.name == '/'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Styles.c_0089FF,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12.r)),
                ),
                child: Text('完成',
                    style: TextStyle(
                        fontSize: 15.sp, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _short(String h) =>
      h.length > 16 ? '${h.substring(0, 10)}…${h.substring(h.length - 8)}' : h;
}
```

- [ ] **Step 4.2: Add TOTP gate + price-drift check to `executeSwap`**

Modify `swap_logic.dart`. Inside `executeSwap`, after the password decryption succeeds but **before** Step 3 (sendRaw), add:

Replace this block:

```dart
      // Step 3: send swap calldata
      final txHash = await svc.sendRaw(
```

With:

```dart
      // Step 2.5: TOTP gate (if user has TOTP enabled)
      final totpEnabled = await TotpService.status();
      if (totpEnabled) {
        final ctx = Get.context;
        if (ctx == null) return const SwapExecutionResult.failed('上下文丢失');
        final ok = await showTotpVerifyDialog(ctx);
        if (!ok) return const SwapExecutionResult.failed('已取消');
      }

      // Step 2.7: price-drift check — re-fetch quote and compare buyAmount.
      // If drift > 1% from the original buyAmount, prompt user to confirm.
      try {
        final fresh = await activeProvider.getQuote(req);
        final drift = (fresh.buyAmount - quote.buyAmount).abs();
        final threshold =
            quote.buyAmount * BigInt.from(1) ~/ BigInt.from(100); // 1%
        if (drift > threshold) {
          final ctx = Get.context;
          if (ctx == null) return const SwapExecutionResult.failed('上下文丢失');
          final accepted = await _confirmPriceDrift(
              ctx, oldAmount: quote.buyAmount, newAmount: fresh.buyAmount);
          if (!accepted) return const SwapExecutionResult.failed('已取消（价格漂移）');
        }
        quote = fresh;
      } on SwapException catch (e) {
        return SwapExecutionResult.failed('重新报价失败: ${e.message}');
      }

      // Step 3: send swap calldata
      final txHash = await svc.sendRaw(
```

Add helper at end of `SwapLogic` class:

```dart
  Future<bool> _confirmPriceDrift(BuildContext ctx,
      {required BigInt oldAmount, required BigInt newAmount}) async {
    final buy = buyToken.value;
    if (buy == null) return false;
    String fmt(BigInt v) {
      final d = BigInt.from(10).pow(buy.decimals);
      final whole = v ~/ d;
      final frac = (v - whole * d).toString().padLeft(buy.decimals, '0');
      return '$whole.${frac.substring(0, frac.length.clamp(0, 6))}';
    }
    final result = await showDialog<bool>(
      context: ctx,
      builder: (c) => AlertDialog(
        title: const Text('价格已变动'),
        content: Text(
            '原报价: ${fmt(oldAmount)} ${buy.symbol}\n新报价: ${fmt(newAmount)} ${buy.symbol}\n是否按新价继续？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('继续')),
        ],
      ),
    );
    return result ?? false;
  }
```

Add these imports to `swap_logic.dart`:

```dart
import 'package:flutter/material.dart';
import '../../../services/totp_service.dart';
import '../send/totp_verify_dialog.dart';
```

- [ ] **Step 4.3: Route to `SwapResultView` after submit**

In `swap_view.dart`, modify `_PasswordSheetState._submit` to navigate to the result page:

```dart
  Future<void> _submit() async {
    setState(() => _sending = true);
    Get.back(); // close password sheet first
    EasyLoading.show(status: '提交中...');
    final result = await widget.logic.executeSwap(password: _pwdCtrl.text);
    EasyLoading.dismiss();
    Get.off(() => SwapResultView(
          success: result.ok,
          txHash: result.txHash,
          chainKey: result.chainKey,
          errorMessage: result.error,
        ));
  }
```

Add import to `swap_view.dart`:

```dart
import 'swap_result_view.dart';
```

- [ ] **Step 4.4: Show no-API-key banner at top of swap view**

In `swap_view.dart`, in `SwapView.build`, insert at the top of the body's `Column` (before `_buildChainChip`):

```dart
            if (kZeroxApiKey.isEmpty)
              Container(
                margin: EdgeInsets.only(bottom: 12.h),
                padding: EdgeInsets.all(12.w),
                decoration: BoxDecoration(
                  color: Colors.red.withAlpha(20),
                  borderRadius: BorderRadius.circular(8.r),
                ),
                child: Text('Swap 未配置，请联系运营',
                    style: TextStyle(
                        color: Colors.red[700], fontSize: 13.sp)),
              ),
```

Add import:

```dart
import '../../../services/wallet/swap/swap_config.dart';
```

- [ ] **Step 4.5: Manually verify Task 4**

Run with TOTP-enabled account on Ethereum:

1. Set up: ensure your test account has TOTP enabled in backend (existing send flow already triggers it).
2. Open Swap, set up an ETH → USDT swap.
3. Tap Swap → password sheet → enter password.
4. Expect: TOTP dialog appears next.
5. Enter valid TOTP → swap proceeds and lands on `SwapResultView` with success.
6. Tap "查看链上详情" → opens Etherscan in browser.

Test cancellation: cancel TOTP → result page shows failure "已取消".

Test no API key: run without `--dart-define=ZEROX_API_KEY=…` → see red banner; main button stays disabled.

- [ ] **Step 4.6: Commit**

```bash
git add lib/pages/wallet/swap/swap_logic.dart \
        lib/pages/wallet/swap/swap_view.dart \
        lib/pages/wallet/swap/swap_result_view.dart
git commit -m "feat(swap): TOTP gate, price-drift confirm, result page, no-key banner"
```

---

## Task 5: Chain selector + Slippage sheet + Provider switcher

**Goal:** All three controls become interactive. Chain chip opens a bottom sheet to pick among the 5 supported EVM chains. The gear icon opens a slippage sheet (0.1 / 0.5 / 1.0 / custom). The provider switcher appears in the quote summary as a non-functional dropdown that only allows 0x.

**Files:**
- Create: `lib/pages/wallet/swap/slippage_sheet.dart`
- Modify: `lib/pages/wallet/swap/swap_view.dart` (open both sheets; add provider dropdown)

- [ ] **Step 5.1: Write `slippage_sheet.dart`**

```dart
// lib/pages/wallet/swap/slippage_sheet.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:get/get.dart';
import 'package:openim_common/openim_common.dart';
import 'swap_logic.dart';

Future<void> showSlippageSheet(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Styles.c_FFFFFF,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20.r)),
    ),
    builder: (_) => const _SlippageSheet(),
  );
}

class _SlippageSheet extends StatefulWidget {
  const _SlippageSheet();

  @override
  State<_SlippageSheet> createState() => _SlippageSheetState();
}

class _SlippageSheetState extends State<_SlippageSheet> {
  static const _presets = [10, 50, 100]; // 0.1%, 0.5%, 1.0%
  final logic = Get.find<SwapLogic>();
  final _customCtrl = TextEditingController();

  String _label(int bps) => '${(bps / 100).toStringAsFixed(bps % 100 == 0 ? 1 : 2)}%';

  @override
  Widget build(BuildContext context) {
    final current = logic.slippageBps.value;
    return Padding(
      padding: EdgeInsets.fromLTRB(20.w, 16.h, 20.w,
          MediaQuery.of(context).viewInsets.bottom + 20.h),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 36.w,
              height: 4.h,
              decoration: BoxDecoration(
                color: Styles.c_E8EAEF,
                borderRadius: BorderRadius.circular(2.r),
              ),
            ),
          ),
          SizedBox(height: 16.h),
          Text('滑点设置',
              style: TextStyle(
                  fontSize: 17.sp,
                  fontWeight: FontWeight.bold,
                  color: Styles.c_0C1C33)),
          SizedBox(height: 16.h),
          Row(
            children: _presets.map((bps) {
              final selected = bps == current;
              return Expanded(
                child: GestureDetector(
                  onTap: () {
                    logic.setSlippageBps(bps);
                    Get.back();
                  },
                  child: Container(
                    margin: EdgeInsets.only(right: 8.w),
                    padding: EdgeInsets.symmetric(vertical: 10.h),
                    decoration: BoxDecoration(
                      color: selected
                          ? Styles.c_0089FF
                          : Styles.c_F8F9FA,
                      borderRadius: BorderRadius.circular(8.r),
                    ),
                    child: Center(
                      child: Text(_label(bps),
                          style: TextStyle(
                              fontSize: 14.sp,
                              color: selected
                                  ? Colors.white
                                  : Styles.c_0C1C33,
                              fontWeight: FontWeight.w600)),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          SizedBox(height: 12.h),
          Text('自定义',
              style:
                  TextStyle(fontSize: 13.sp, color: Styles.c_8E9AB0)),
          SizedBox(height: 6.h),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _customCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[\d.]')),
                  ],
                  decoration: InputDecoration(
                    hintText: '例如 0.75',
                    suffixText: '%',
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10.r)),
                  ),
                ),
              ),
              SizedBox(width: 12.w),
              ElevatedButton(
                onPressed: () {
                  final pct = double.tryParse(_customCtrl.text);
                  if (pct == null || pct <= 0 || pct > 50) return;
                  final bps = (pct * 100).round();
                  logic.setSlippageBps(bps);
                  Get.back();
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Styles.c_0089FF,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10.r)),
                ),
                child: const Text('应用'),
              ),
            ],
          ),
          SizedBox(height: 8.h),
          if (current >= 300)
            Padding(
              padding: EdgeInsets.only(top: 8.h),
              child: Text('⚠️ 高滑点会增加被夹击的风险',
                  style: TextStyle(
                      color: Colors.orange[700], fontSize: 12.sp)),
            ),
          SizedBox(height: 4.h),
        ],
      ),
    );
  }
}
```

- [ ] **Step 5.2: Wire chain chip + gear icon + provider dropdown in `swap_view.dart`**

In `swap_view.dart`:

(a) Replace the empty gear icon callback in the AppBar:

```dart
          IconButton(
            icon: Icon(Icons.settings_outlined,
                color: Styles.c_0C1C33, size: 22.w),
            onPressed: () => showSlippageSheet(context),
          ),
```

(b) Replace the empty `_buildChainChip` callback's `onTap` to open a chain picker:

```dart
        onTap: () => _showChainPicker(context, logic),
```

(c) Add this method at the top of `SwapView`:

```dart
  void _showChainPicker(BuildContext context, SwapLogic logic) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Styles.c_FFFFFF,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20.r)),
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 12.h),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: kZeroxSupportedChains.map((k) {
              final cfg = chains[k];
              if (cfg == null) return const SizedBox.shrink();
              return ListTile(
                title: Text(cfg.name, style: TextStyle(fontSize: 15.sp)),
                trailing: logic.swapChainKey.value == k
                    ? Icon(Icons.check_circle,
                        color: Styles.c_0089FF, size: 20.w)
                    : null,
                onTap: () {
                  logic.switchChain(k);
                  Get.back();
                },
              );
            }).toList(),
          ),
        ),
      ),
    );
  }
```

(d) Add provider dropdown in `_QuoteSummary` by replacing the `_row('报价方', '0x')` line with:

```dart
          _providerRow(),
```

And add this method to `_QuoteSummary`:

```dart
  Widget _providerRow() {
    final logic = Get.find<SwapLogic>();
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 4.h),
      child: Row(
        children: [
          Text('报价方',
              style: TextStyle(fontSize: 13.sp, color: Styles.c_8E9AB0)),
          const Spacer(),
          DropdownButton<String>(
            value: logic.providerId.value,
            isDense: true,
            underline: const SizedBox.shrink(),
            items: const [
              DropdownMenuItem(value: 'zerox', child: Text('0x')),
              DropdownMenuItem(
                  value: 'oneinch_disabled',
                  enabled: false,
                  child: Text('1inch（即将开放）')),
              DropdownMenuItem(
                  value: 'okx_disabled',
                  enabled: false,
                  child: Text('OKX DEX（即将开放）')),
              DropdownMenuItem(
                  value: 'uniswap_disabled',
                  enabled: false,
                  child: Text('Uniswap（即将开放）')),
            ],
            onChanged: (v) {
              if (v == 'zerox') logic.providerId.value = v!;
            },
          ),
        ],
      ),
    );
  }
```

Add imports:

```dart
import 'slippage_sheet.dart';
import '../../../services/wallet/swap/swap_config.dart';
```

- [ ] **Step 5.3: Manually verify Task 5**

1. Open Swap page.
2. Tap chain chip "Ethereum" → see 5-chain bottom sheet → tap "BNB Chain" → chip updates to BNB Chain, tokens reset.
3. Tap gear icon → slippage sheet → tap "1.0%" → sheet closes → quote summary shows "滑点 1.00%".
4. Open slippage sheet again → custom "3.5" + 应用 → warning text appears.
5. Quote summary's "报价方" row shows dropdown with 0x selected; 1inch/OKX/Uniswap visible but disabled (grayed).

- [ ] **Step 5.4: Commit**

```bash
git add lib/pages/wallet/swap/swap_view.dart \
        lib/pages/wallet/swap/slippage_sheet.dart
git commit -m "feat(swap): chain picker + slippage sheet + grayed-out provider dropdown"
```

---

## Task 6: Final tests + spec-§8 verification + cleanup

**Goal:** Run all manual test cases from spec §9 against the real app; verify the §7 error matrix; tidy any lingering issues.

**Files:**
- Modify: anything found broken during manual testing
- Create: `test/pages/wallet/swap/swap_logic_test.dart` (small state-machine coverage)

- [ ] **Step 6.1: Write a state-machine test for the main button text**

```dart
// test/pages/wallet/swap/swap_logic_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:openim/services/wallet/swap/swap_models.dart';

/// Mirrors _MainButton._resolveText. Kept here so we can drive it from a unit
/// test without spinning up the full GetX graph.
String resolveButtonText({
  required SwapToken? sell,
  required SwapToken? buy,
  required BigInt sellAmountRaw,
  required bool isFetchingPrice,
  required SwapException? lastError,
  required SwapPriceResult? priceResult,
}) {
  if (sell == null || buy == null) return '选择代币';
  if (sellAmountRaw == BigInt.zero) return '输入金额';
  if (isFetchingPrice) return '查询报价中…';
  if (lastError != null) {
    switch (lastError.kind) {
      case SwapErrorKind.noApiKey:
        return 'Swap 未配置';
      case SwapErrorKind.noLiquidity:
        return '无可用路由';
      case SwapErrorKind.chainNotSupported:
        return '该链暂不支持 Swap';
      case SwapErrorKind.network:
        return '网络异常';
      case SwapErrorKind.rateLimited:
        return '请求过频';
      default:
        return '报价失败';
    }
  }
  if (priceResult == null) return '输入金额';
  return 'Swap';
}

void main() {
  const eth =
      SwapToken(chainKey: 'eth', symbol: 'ETH', decimals: 18);
  const usdt = SwapToken(
      chainKey: 'eth',
      symbol: 'USDT',
      decimals: 6,
      contractAddress: '0xdAC17F958D2ee523a2206206994597C13D831ec7');

  SwapPriceResult fakePrice() => const SwapPriceResult(
      buyAmount: BigInt.from(123), fees: SwapFees(), providerId: 'zerox');

  test('no tokens → 选择代币', () {
    expect(
        resolveButtonText(
          sell: null, buy: null, sellAmountRaw: BigInt.zero,
          isFetchingPrice: false, lastError: null, priceResult: null,
        ),
        equals('选择代币'));
  });

  test('tokens set, no amount → 输入金额', () {
    expect(
        resolveButtonText(
          sell: eth, buy: usdt, sellAmountRaw: BigInt.zero,
          isFetchingPrice: false, lastError: null, priceResult: null,
        ),
        equals('输入金额'));
  });

  test('fetching → 查询报价中…', () {
    expect(
        resolveButtonText(
          sell: eth, buy: usdt, sellAmountRaw: BigInt.from(1),
          isFetchingPrice: true, lastError: null, priceResult: null,
        ),
        equals('查询报价中…'));
  });

  test('no-liquidity error → 无可用路由', () {
    expect(
        resolveButtonText(
          sell: eth, buy: usdt, sellAmountRaw: BigInt.from(1),
          isFetchingPrice: false,
          lastError: const SwapException(SwapErrorKind.noLiquidity, ''),
          priceResult: null,
        ),
        equals('无可用路由'));
  });

  test('no-api-key error → Swap 未配置', () {
    expect(
        resolveButtonText(
          sell: eth, buy: usdt, sellAmountRaw: BigInt.from(1),
          isFetchingPrice: false,
          lastError: const SwapException(SwapErrorKind.noApiKey, ''),
          priceResult: null,
        ),
        equals('Swap 未配置'));
  });

  test('quote returned → Swap', () {
    expect(
        resolveButtonText(
          sell: eth, buy: usdt, sellAmountRaw: BigInt.from(1),
          isFetchingPrice: false, lastError: null, priceResult: fakePrice(),
        ),
        equals('Swap'));
  });
}
```

- [ ] **Step 6.2: Run all tests**

```bash
fvm flutter test test/services/wallet/swap/ test/pages/wallet/swap/
```

Expected: all 14 tests pass (3 swap_models + 5 zerox_provider + 3 swap_helpers + 6 swap_logic).

- [ ] **Step 6.3: Run static analysis**

```bash
fvm flutter analyze lib/pages/wallet/swap/ lib/services/wallet/swap/
```

Expected: no errors. Fix any warnings related to swap code; ignore unrelated ones.

- [ ] **Step 6.4: Execute manual test script from spec §9**

Run each item and check off:

- [ ] (a) ETH mainnet, 0.001 ETH → USDT (native→token, no approve) — succeeds, sees result page with hash, Etherscan link works
- [ ] (b) ETH mainnet, 0.5 USDT → ETH (token→native, first approve) — both txs broadcast, result page shows swap hash
- [ ] (c) Polygon, 0.5 USDC → USDT — succeeds
- [ ] (d) Chain switch ETH → Arbitrum — tokens reset, fresh quote works
- [ ] (e) Slippage 0.1% on volatile pair → `PRICE_IMPACT_TOO_HIGH` shown as "无可用路由" or "报价失败"
- [ ] (f) Airplane mode → "网络异常" button text
- [ ] (g) Wrong TOTP code → dialog stays open with error; cancel → result page shows "已取消"
- [ ] (h) Large amount (~$10k equiv) — no extra dialog yet (this enhancement is in spec §7 but deferred to a follow-up; document in step 6.5)

- [ ] **Step 6.5: Document any gaps in spec coverage**

If step (h) was not actually implemented (large-amount confirmation dialog), add a note in spec §11 "Subsequent extensions" and skip — the spec lists this as a defensive measure and the rest is the MVP cut.

- [ ] **Step 6.6: Final commit**

```bash
git add test/pages/wallet/swap/swap_logic_test.dart
git commit -m "test(swap): main-button state-machine coverage"
```

---

## Self-Review Notes

- **Spec §1 (Scope/decisions):** Tasks 1–6 cover all rows. Decisions about TRON exclusion and EVM-only are reflected in `kZeroxSupportedChains`.
- **Spec §2 (Architecture):** SwapProvider in Task 1.7; ZeroExProvider in Task 2.1; EvmService.sendRaw in Task 3.1.
- **Spec §3 (File structure):** Every listed file is created in Tasks 1–5.
- **Spec §4 (Core interfaces):** Task 1 covers models + abstract interface; Task 2 covers 0x mapping per §4.3.
- **Spec §5 (UI layout):** Task 1 static + Task 2 live + Task 5 controls.
- **Spec §6 (Swap flow):** Task 3 base flow; Task 4 TOTP + drift check.
- **Spec §7 (Error matrix):** Task 4 covers no API key, no liquidity, network, TOTP cancel. Task 5 doesn't add new errors. **Coverage gap:** large-amount confirmation ($10k+) — documented in step 6.5 as deferred.
- **Spec §8 (Evm additions):** Task 3.1 adds all five methods.
- **Spec §9 (Testing):** Task 6 runs the full matrix.
- **Spec §10 (Slices):** Task 1 = slice 1, Task 2 = slice 2, Task 3 = slice 3, Task 4 = slice 4, Task 5 = slice 5, Task 6 = slice 6. 1:1.
- **Spec §12 (Operations config):** `kZeroxApiKey` injected via `--dart-define`; `kFeeRecipients` is the location for ops-supplied addresses (currently empty strings — no fee charged until populated, which is the desired default for dev).
