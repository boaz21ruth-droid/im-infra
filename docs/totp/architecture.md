# 钱包转账 TOTP 二次校验 — 系统架构

**日期：** 2026-05-27
**范围：** im-business（Go 后端）+ im-wallet-app（Flutter 客户端）
**关联设计文档：** `/Users/web1/.claude/plans/app-tidy-iverson.md`

---

## 1. 背景与目标

### 现状
钱包是**完全客户端自托管**的：私钥派生自助记词，助记词以 AES-256-GCM + PBKDF2-310K 加密后存储在设备 Vault（Keychain / EncryptedSharedPreferences）。转账时用户输入钱包密码 → 解密助记词 → 本地签名 → 直接通过 EVM RPC / Tron API 广播。后端不参与签名链路。

唯一保护就是钱包密码——一旦设备被盗或密码泄露，资产可被立即转走。

### 目标
为转账新增一道独立于设备的二次校验，且**校验密钥与签名密钥分离**：
- TOTP secret 存在 **服务器**（AES-256-GCM 加密落库）
- 客户端转账前必须调用后端校验 6 位动态码
- 失败超阈值锁定，防止设备丢失后的暴力枚举

---

## 2. 安全边界

| 项 | 存储位置 | 加密方式 | 失泄场景影响 |
|---|---|---|---|
| 助记词 | 设备 Vault | AES-256-GCM + PBKDF2-310K | 设备被盗 + 密码泄露 → 资产可被转走 |
| TOTP secret | 后端 PostgreSQL | AES-256-GCM（服务端密钥） | 数据库被脱 + 加密密钥泄露 → 攻击者可生成正确动态码，但**仍需钱包密码**才能签名 |
| TOTP 加密密钥 | 后端服务器配置/Secret Manager | 明文 hex（32 字节） | 与 DB 同时泄露才有意义；和 JWT secret 同等敏感 |

**威胁模型分离**：
- 设备被盗 + 钱包密码泄露 → 攻击者**仍无法**通过 TOTP，因为 TOTP secret 不在设备上
- 服务器被攻破 → 攻击者**仍无法**签名交易，因为助记词不在服务器
- 钓鱼 TOTP 验证码 → 仅 30 秒有效，且 5 次失败锁 15 分钟

---

## 3. 顶层架构图

```
┌─────────────────────────────────────────────────────────────────┐
│                       im-wallet-app (Flutter)                   │
│                                                                  │
│  ┌──────────────────┐    ┌─────────────────────────────────┐   │
│  │ 我的→账号安全→    │    │ 钱包→发送                       │   │
│  │ Google 验证器     │    │  ┌─────────────────────────┐   │   │
│  │                  │    │  │ 1. 填表 + 钱包密码确认  │   │   │
│  │  - 绑定（QR）     │    │  └────────────┬────────────┘   │   │
│  │  - 解绑（6 位码）  │    │               ↓                 │   │
│  │                  │    │  ┌─────────────────────────┐   │   │
│  └────────┬─────────┘    │  │ 2. TotpService.status()  │   │   │
│           │              │  │    if enabled →          │   │   │
│           │              │  │    showTotpVerifyDialog  │   │   │
│           │              │  └────────────┬────────────┘   │   │
│           │              │               ↓                 │   │
│           │              │  ┌─────────────────────────┐   │   │
│           │              │  │ 3. vault.withMnemonic    │   │   │
│           │              │  │    → 本地签名 → 广播    │   │   │
│           │              │  └─────────────────────────┘   │   │
│           │              └──────────────┬──────────────────┘   │
│           │                             │                       │
│           ▼                             ▼                       │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │            TotpService (services/totp_service.dart)      │   │
│  │  setup() / enable() / disable() / status() /             │   │
│  │  verifyForTransfer()                                     │   │
│  └─────────────────────────────┬───────────────────────────┘   │
└────────────────────────────────│───────────────────────────────┘
                                 │ HTTP + JWT (token header)
                                 ▼
┌─────────────────────────────────────────────────────────────────┐
│                    im-business (Go, port 10008)                 │
│                                                                  │
│   handler/totp.go                                                │
│    POST /user/totp/setup    → 生成 secret → Redis 临时 (10min)  │
│    POST /user/totp/enable   → 校验 code → 加密落库 DB           │
│    POST /user/totp/disable  → 校验 code → 清空 DB               │
│    GET  /user/totp/status   → 返回 enabled                      │
│    POST /wallet/totp/verify → 防爆破 + 校验 → {valid:true}      │
│                  │                                               │
│                  ▼                                               │
│   service/totp.go                                                │
│    └── pkg/totp.Validate() (pquerna/otp, ±1 步偏移)              │
│    └── pkg/cryptoutil.{Encrypt,Decrypt}AESGCM                    │
│                  │                                               │
│         ┌────────┴────────┐                                      │
│         ▼                 ▼                                      │
│   ┌──────────┐     ┌─────────────────┐                          │
│   │  Redis   │     │  PostgreSQL     │                          │
│   │          │     │                 │                          │
│   │ setup    │     │ users 表新增：   │                          │
│   │ pending  │     │  totp_secret    │                          │
│   │ (10min)  │     │  totp_enabled   │                          │
│   │          │     │                 │                          │
│   │ fail     │     └─────────────────┘                          │
│   │ counter  │                                                   │
│   │ (5min /  │                                                   │
│   │ 15min锁) │                                                   │
│   └──────────┘                                                   │
└─────────────────────────────────────────────────────────────────┘
```

---

## 4. 数据模型

### PostgreSQL — `users` 表新增字段

| 字段 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `totp_secret` | `VARCHAR(256)` | `''` | AES-256-GCM 加密后的 base32 secret，base64 编码；空串=未绑定 |
| `totp_enabled` | `BOOL` | `false` | 是否已启用 |

GORM AutoMigrate 在启动时自动添加这两列；现有用户默认为未绑定。

### Redis 键

| 键 | 类型 | TTL | 用途 |
|---|---|---|---|
| `im:totp:setup:{userID}` | string | 10 分钟 | Setup 阶段临时存放未确认的 secret（Enable 时取出后删除） |
| `im:totp:fail:{userID}` | counter | 5 分钟 / 15 分钟 | 连续失败次数；≥5 时 TTL 升级到 15 分钟（锁定期） |

---

## 5. API 契约

所有端点除显式说明外均需 `token: <chatToken>` 头（JWT，HS256）。统一响应信封：
```json
{ "errCode": 0, "errMsg": "", "data": {...} }
```

### 5.1 POST `/user/totp/setup`

生成新 secret，缓存到 Redis 待 Enable。如果已启用返回 1602。

**Request：** `{}`
**Response：**
```json
{
  "errCode": 0,
  "data": {
    "secret": "JBSWY3DPEHPK3PXP",
    "otpauthUrl": "otpauth://totp/IM%20Wallet:alice@example.com?secret=JBSWY3DPEHPK3PXP&issuer=IM%20Wallet"
  }
}
```

### 5.2 POST `/user/totp/enable`

用 Authenticator 中的 6 位码确认绑定，写入 DB。

**Request：** `{"code": "123456"}`
**Errors：**
- `1600` 验证码错误
- `1602` 已绑定
- `1600` setup 已过期（10 分钟未确认） — 复用 invalid 码

### 5.3 POST `/user/totp/disable`

需要当前的 6 位码，证明用户仍持有 Authenticator。

**Request：** `{"code": "123456"}`
**Errors：** `1600` `1603`

### 5.4 GET `/user/totp/status`

**Response：** `{"errCode": 0, "data": {"enabled": true}}`

### 5.5 POST `/wallet/totp/verify`

转账门控。**对未启用 TOTP 的用户直接返回 valid=true**，简化前端逻辑。

**Request：** `{"code": "123456"}`
**Response：** `{"errCode": 0, "data": {"valid": true}}`
**Errors：**
- `1600` 验证码错误（同时累加 Redis 失败计数）
- `1601` 5 分钟内失败 ≥5 次，锁 15 分钟

### 5.6 错误码

| Code | 含义 | HTTP |
|---|---|---|
| 1600 | TOTP 验证码无效 | 400 |
| 1601 | TOTP 验证锁定 | 429 |
| 1602 | TOTP 已绑定 | 400 |
| 1603 | TOTP 未绑定 | 400 |

---

## 6. 关键代码路径

### 后端 (im-business)

| 文件 | 职责 |
|---|---|
| `pkg/cryptoutil/aesgcm.go` | `EncryptAESGCM/DecryptAESGCM/DecodeKey` — 标准库 AES-GCM 封装 |
| `pkg/totp/totp.go` | `Setup/Validate` — pquerna/otp 封装，issuer="IM Wallet"，±1 步偏移 |
| `internal/service/totp.go` | `TotpService` — 绑定/解绑/验证业务逻辑 + 防爆破 |
| `internal/handler/totp.go` | 5 个 HTTP handler |
| `internal/handler/router.go` | 注册路由 |
| `internal/model/user.go` | `TotpSecret/TotpEnabled` 字段 |
| `internal/config/config.go` | `TOTPConfig.EncryptKey` |
| `pkg/resp/resp.go` | 1600–1603 错误码 |
| `cmd/server/main.go` | wire 起来：`cryptoutil.DecodeKey(cfg.TOTP.EncryptKey)` |

### 前端 (im-wallet-app)

| 文件 | 职责 |
|---|---|
| `lib/services/totp_service.dart` | 5 个 API 调用 + `TotpException` 错误映射 |
| `lib/pages/mine/account_setup/totp_setup_view.dart` | 绑定页（QR + secret 复制 + 6 位码确认） |
| `lib/pages/mine/account_setup/totp_disable_view.dart` | 解绑页 |
| `lib/pages/wallet/send/totp_verify_dialog.dart` | 转账门控弹框（输完自动校验） |
| `lib/pages/mine/account_setup/account_setup_view.dart` | 设置页菜单项 |
| `lib/pages/mine/account_setup/account_setup_logic.dart` | `toggleTotp/refreshTotpStatus` |
| `lib/pages/wallet/send/wallet_send_view.dart` | `_sendTransaction` 加门控 |

---

## 7. 关键时序

### 绑定流程

```
User                  App                      im-business              Redis        DB
 │                     │                            │                     │           │
 │ 点开"Google 验证器"  │                            │                     │           │
 │ (未开启)            │                            │                     │           │
 ├────────────────────►│                            │                     │           │
 │                     │ POST /user/totp/setup      │                     │           │
 │                     ├───────────────────────────►│                     │           │
 │                     │                            │ 生成 secret         │           │
 │                     │                            ├────────────────────►│           │
 │                     │                            │ SET setup:{uid}=... │           │
 │                     │                            │ EX 600              │           │
 │                     │ {secret, otpauthUrl}       │                     │           │
 │                     │◄───────────────────────────┤                     │           │
 │ 显示 QR 码          │                            │                     │           │
 │◄────────────────────┤                            │                     │           │
 │                     │                            │                     │           │
 │ Authenticator 扫码  │                            │                     │           │
 │ 显示 123456         │                            │                     │           │
 │                     │                            │                     │           │
 │ 输入 123456         │                            │                     │           │
 ├────────────────────►│                            │                     │           │
 │                     │ POST /user/totp/enable     │                     │           │
 │                     │ {"code":"123456"}          │                     │           │
 │                     ├───────────────────────────►│                     │           │
 │                     │                            │ GET setup:{uid}     │           │
 │                     │                            ├────────────────────►│           │
 │                     │                            │◄────────────────────┤           │
 │                     │                            │ Validate(code)      │           │
 │                     │                            │ AES-GCM(secret)     │           │
 │                     │                            ├────────────────────────────────►│
 │                     │                            │ UPDATE users SET    │           │
 │                     │                            │ totp_secret=...,    │           │
 │                     │                            │ totp_enabled=true   │           │
 │                     │                            │                     │           │
 │                     │                            │ DEL setup:{uid}     │           │
 │                     │                            ├────────────────────►│           │
 │                     │ OK                         │                     │           │
 │                     │◄───────────────────────────┤                     │           │
 │ 已开启              │                            │                     │           │
 │◄────────────────────┤                            │                     │           │
```

### 转账门控

```
User      App                   im-business              Redis              EVM/Tron
 │         │                         │                     │                    │
 │ 填表    │                         │                     │                    │
 │ 点发送  │                         │                     │                    │
 ├────────►│                         │                     │                    │
 │         │ 弹密码确认               │                     │                    │
 │ 输密码  │                         │                     │                    │
 │ 点确认  │                         │                     │                    │
 ├────────►│                         │                     │                    │
 │         │ GET /user/totp/status   │                     │                    │
 │         ├────────────────────────►│                     │                    │
 │         │ {"enabled": true}       │                     │                    │
 │         │◄────────────────────────┤                     │                    │
 │         │                         │                     │                    │
 │         │ 弹 TOTP 输入框           │                     │                    │
 │ 输 6 位 │                         │                     │                    │
 ├────────►│                         │                     │                    │
 │         │ POST /wallet/totp/verify│                     │                    │
 │         │ {"code":"654321"}       │                     │                    │
 │         ├────────────────────────►│                     │                    │
 │         │                         │ GET fail:{uid}      │                    │
 │         │                         ├────────────────────►│                    │
 │         │                         │ count < 5 ✓         │                    │
 │         │                         │ AES-GCM decrypt     │                    │
 │         │                         │ Validate(code) ✓    │                    │
 │         │                         │ DEL fail:{uid}      │                    │
 │         │                         ├────────────────────►│                    │
 │         │ {"valid": true}         │                     │                    │
 │         │◄────────────────────────┤                     │                    │
 │         │                         │                     │                    │
 │         │ vault.withMnemonic(pwd) │                     │                    │
 │         │ 派生私钥 → 签名 → 广播  │                     │                    │
 │         ├──────────────────────────────────────────────────────────────────►│
 │         │ TxHash                  │                     │                    │
 │         │◄──────────────────────────────────────────────────────────────────┤
 │ 成功    │                         │                     │                    │
 │◄────────┤                         │                     │                    │
```

### 失败锁定

```
错误码 1 ──┐
错误码 2 ──┤  INCR fail:{uid}
错误码 3 ──┤  TTL 维持 5 分钟
错误码 4 ──┤
错误码 5 ──┘  INCR 命中 5
              EXPIRE fail:{uid} 900  (升级到 15 分钟锁)
                ↓
              此后所有 verify 直接返回 1601，直到键过期
```

---

## 8. 设计取舍说明

| 决策 | 理由 | 替代方案 |
|---|---|---|
| TOTP secret 存后端而非设备 | 与签名密钥（设备）分离，达成"两个独立秘密"的安全模型 | 本地校验：边界不变，提升有限 |
| 后端验证而非短效令牌 | 实现简单、状态最少；每笔多 100–300ms 网络往返可接受 | 校验后发短效 ticket：复杂度高，未启用时回退路径多 |
| AES-256-GCM 存 secret 而非 bcrypt | 校验需要可逆（要还原 secret 算 TOTP） | 客户端预计算交给服务器哈希比对：客户端能算就说明 secret 在客户端 |
| 未启用直接放行而非 400 | 客户端不必读 status 后才决定是否调；幂等更简单 | 客户端读 status 自决：多一次请求 |
| 防爆破计数器：5/5min → 15min 锁 | 简单可解释；TOTP 30s 一窗口，5 次几乎一定不是人工 | 指数退避：复杂；TOTP 场景收益小 |
| Setup secret 走 Redis 10min | 用户可断 App 再回来扫码；不污染 DB | 直接写 DB + status="pending"：DB 字段语义更乱 |

---

## 9. 兼容性与回滚

**前向兼容：**
- 老版本 App（无 TOTP 调用）→ 后端忽略，沿用旧路径，无任何影响
- 新版本 App vs 老后端 → `/user/totp/status` 返回 404，`TotpService.status()` 用 try/catch 返回 false，转账正常走旧流程

**回滚：**
- 移除路由 + 移除前端调用 → 数据库字段保留即可，无破坏性
- AutoMigrate 不会删字段；若要回收空间需手动 DROP COLUMN

**密钥轮换：**
当前实现**未支持** TOTP 加密密钥轮换。轮换 `totp.encrypt_key` 会导致已绑定用户全部解密失败。如需轮换：
1. 同时支持新旧两个密钥（解密时尝试两次）
2. 后台 job 重加密所有 secret
3. 完成后下线旧密钥

详见"未来工作"。

---

## 10. 未来工作

- **备份码（recovery codes）**：丢手机时可凭一次性备份码解绑。当前丢手机后无法转账，但仍可访问账号其他功能；用户可去客服或重置流程。
- **TOTP 密钥轮换**：上线后视实际威胁评估再做。
- **设备绑定**：限制同时只有 1 个 Authenticator 实例（防止 secret 被截图泄露后多端同步）— TOTP 协议本身不支持，需另设计。
- **审计日志**：绑定/解绑/失败/锁定事件写入独立审计表，便于事后追溯。
- **大额转账强制 TOTP**：即便用户未启用，超过某阈值的转账强制走 TOTP（需要先把用户引导到绑定）。
