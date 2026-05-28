# 钱包转账 TOTP 二次校验 — 部署文档

**日期：** 2026-05-27
**适用版本：** im-business（含 `pkg/totp`、`/user/totp/*`、`/wallet/totp/verify`）+ im-wallet-app（含 `services/totp_service.dart`）

> 架构与设计取舍见 `architecture.md`。本文只覆盖**上线步骤**。

---

## 1. 上线前 Checklist

- [ ] 生成 32 字节随机 AES 密钥
- [ ] 将密钥写入 **生产** config 的 `totp.encrypt_key`（**禁用** 仓库默认占位）
- [ ] 密钥已备份到秘密管理系统（1Password / AWS Secrets Manager / Vault）
- [ ] PostgreSQL 用户对 `users` 表有 ALTER 权限（GORM AutoMigrate 需要加列）
- [ ] Redis db=5 可用（与 OpenIM 现有用法保持一致）
- [ ] 已停掉旧版 im-business 服务，准备热替换
- [ ] App 商店已发布或灰度推送了支持 TOTP 的 Flutter 客户端

---

## 2. 生成加密密钥

`totp.encrypt_key` 是 32 字节 AES-256 密钥，hex 编码（64 个十六进制字符）。

```bash
openssl rand -hex 32
# 示例输出：
# 4a7d2c8f9b0e1d3f5c6a8b9e0d2f4c6a8b9e0d2f4c6a8b9e0d2f4c6a8b9e0d2f
```

> **极其重要**：此密钥一旦生效（用于加密任何 secret），**永远不要更换**——否则所有已绑定用户的 secret 都将无法解密，导致全员无法转账（TOTP 校验全部失败）。如确需轮换，需先实现"双密钥并行解密 + 后台 re-encrypt"，参见 architecture.md §9。

把密钥同时存到秘密管理系统（建议）：

```bash
# 1Password CLI 示例
op item create --category=password --title='im-business TOTP encrypt_key' \
  --vault=Production password="$(openssl rand -hex 32)"
```

---

## 3. 配置变更

### 3.1 本地开发 — `config/config.yaml`

```yaml
totp:
  encrypt_key: "<你的 64 hex 字符>"
```

### 3.2 Docker 部署 — `config/docker.config.yaml`

```yaml
totp:
  encrypt_key: "<你的 64 hex 字符>"
```

或通过环境变量覆盖（viper 已配置 `.` → `_` replacer）：
```bash
TOTP_ENCRYPT_KEY="<64 hex>"
```

### 3.3 验证配置加载

启动时若密钥无效，会在 `cmd/server/main.go` 立即 `log.Fatal`：
```
{"level":"fatal","msg":"totp encrypt_key invalid","error":"aes key must be 16/24/32 bytes, got N"}
```

---

## 4. 数据库迁移

无需手动建表/加字段。**GORM AutoMigrate** 在服务启动时自动执行：

```go
// internal/db/db.go
db.AutoMigrate(&model.User{}, ...)
```

启动后用 `psql` 验证：

```bash
psql -h localhost -U im_business -d im_business -c "\d users" | grep totp
# totp_secret      | character varying(256)   |           | not null | ''::character varying
# totp_enabled     | boolean                  |           | not null | false
```

回滚字段（不推荐，除非整个功能下线）：

```sql
ALTER TABLE users DROP COLUMN totp_secret;
ALTER TABLE users DROP COLUMN totp_enabled;
```

---

## 5. 部署步骤

### 5.1 本地（开发）

```bash
cd /Users/web1/go/im/im-business

# 拉最新代码后，确保依赖到位
go mod tidy

# 跑测试（pquerna/otp 网络下载会触发，首次较慢）
go test ./...

# 启动
go run cmd/server/main.go -config config/config.yaml
```

预期日志：
```
{"level":"info","msg":"im-business starting","port":10008}
```

### 5.2 Docker

```bash
cd /Users/web1/go/im/im-business

# 重新构建镜像 + 重启容器（会自动跑 AutoMigrate）
docker compose up -d --build
```

如使用 docker-compose secrets，可把 `encrypt_key` 注入：

```yaml
# docker-compose.yaml 片段
services:
  im-business:
    environment:
      TOTP_ENCRYPT_KEY: ${TOTP_ENCRYPT_KEY}
```

```bash
TOTP_ENCRYPT_KEY=$(op read 'op://Production/im-business TOTP encrypt_key/password') \
  docker compose up -d --build
```

### 5.3 Kubernetes（如适用）

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: im-business-totp
type: Opaque
stringData:
  encrypt_key: "<64 hex>"

---
apiVersion: apps/v1
kind: Deployment
spec:
  template:
    spec:
      containers:
        - name: im-business
          env:
            - name: TOTP_ENCRYPT_KEY
              valueFrom:
                secretKeyRef:
                  name: im-business-totp
                  key: encrypt_key
```

---

## 6. Flutter 客户端发布

### 6.1 依赖确认

`pubspec.yaml` 已有 `qr_flutter: ^4.0.0`，无需新增依赖。

### 6.2 构建

```bash
cd /Users/web1/go/im/im-wallet-app
fvm flutter pub get
fvm flutter build ios --release         # iOS
fvm flutter build apk --release          # Android
```

### 6.3 关键配置

`openim_common/lib/src/config.dart` 的 `_host` 仍指向后端 IP/域名。
TOTP 功能复用现有 `Config.appAuthUrl`（即 `http://<host>:10008`），**无需新配置**。

### 6.4 灰度策略建议

- 第 1 周：仅"我的"页可绑定，转账门控**通过 server-side feature flag 关闭**（当前实现未带 flag，可通过临时改 service.Verify 提前 return nil 实现）
- 第 2 周：开门控，监控失败/锁定率
- 第 3 周：全量

---

## 7. 端到端验收

### 7.1 后端 smoke test（curl）

假设已有用户 `alice@example.com`，密码 MD5 已知，先登录拿 chatToken：

```bash
HOST=http://localhost:10008
TOKEN=$(curl -s -X POST $HOST/account/login \
  -H 'Content-Type: application/json' \
  -d '{"account":"alice@example.com","password":"098f6bcd4621d373cade4e832627b4f6","platform":2}' \
  | jq -r .data.chatToken)
echo "TOKEN=$TOKEN"

# Status：未绑定
curl -s $HOST/user/totp/status -H "token: $TOKEN"
# {"errCode":0,"errMsg":"","data":{"enabled":false}}

# Setup：拿 secret
SECRET=$(curl -s -X POST $HOST/user/totp/setup -H "token: $TOKEN" \
  | jq -r .data.secret)
echo "SECRET=$SECRET"

# 用 oathtool 或 Python 算当前 code（这里展示 oathtool）
CODE=$(oathtool --totp -b "$SECRET")
echo "CODE=$CODE"

# Enable
curl -s -X POST $HOST/user/totp/enable \
  -H "token: $TOKEN" -H 'Content-Type: application/json' \
  -d "{\"code\":\"$CODE\"}"
# {"errCode":0,"errMsg":"","data":null}

# Verify（转账门控）
CODE=$(oathtool --totp -b "$SECRET")
curl -s -X POST $HOST/wallet/totp/verify \
  -H "token: $TOKEN" -H 'Content-Type: application/json' \
  -d "{\"code\":\"$CODE\"}"
# {"errCode":0,"errMsg":"","data":{"valid":true}}

# 错误码示例：故意输错
curl -s -X POST $HOST/wallet/totp/verify \
  -H "token: $TOKEN" -H 'Content-Type: application/json' \
  -d '{"code":"000000"}'
# {"errCode":1600,"errMsg":"验证码无效"}

# 连续 5 次错误后
for i in 1 2 3 4 5; do
  curl -s -X POST $HOST/wallet/totp/verify \
    -H "token: $TOKEN" -H 'Content-Type: application/json' \
    -d '{"code":"000000"}'
  echo
done
# 第 6 次会变 1601
curl -s -X POST $HOST/wallet/totp/verify \
  -H "token: $TOKEN" -H 'Content-Type: application/json' \
  -d '{"code":"000000"}'
# {"errCode":1601,"errMsg":"验证失败次数过多，请稍后再试"}

# Disable
CODE=$(oathtool --totp -b "$SECRET")
curl -s -X POST $HOST/user/totp/disable \
  -H "token: $TOKEN" -H 'Content-Type: application/json' \
  -d "{\"code\":\"$CODE\"}"
```

### 7.2 App 验收

按"我的 → 账号安全 → Google 验证器"路径：

| # | 动作 | 期望 |
|---|---|---|
| 1 | 点开菜单项 | 进入 TotpSetupPage，QR 显示，secret 可复制 |
| 2 | 用 Google Authenticator 扫码 | App 显示新条目"IM Wallet (alice@example.com)" |
| 3 | 输入 6 位码 → 确认绑定 | toast"已开启 Google 验证器"，返回设置页显示"已开启" |
| 4 | 钱包转账 → 填表 → 确认密码 | 弹出 TOTP 输入框 |
| 5 | 输入正确 6 位码 | 弹框关闭，"发送中..."，链上可见 TX |
| 6 | 故意输错 6 位码 | 提示"验证码错误"，输入框清空，仍可重试 |
| 7 | 输错 5 次 | 提示"失败次数过多，请稍后再试"，等 15 分钟才能再试 |
| 8 | 设置页再次点菜单项 | 进入 TotpDisablePage |
| 9 | 输入当前 6 位码 → 确认关闭 | toast"已关闭"，回设置页显示"未开启"，再转账不再弹 TOTP |

---

## 8. 监控与告警

### 关键指标

| 指标 | 来源 | 阈值建议 |
|---|---|---|
| `/wallet/totp/verify` 失败率 | gin access log（errCode=1600 占比） | > 30% 持续 5 分钟 → 告警（可能后端时钟漂） |
| `/wallet/totp/verify` 锁定率 | errCode=1601 计数 | > 0.5% 5xx 同等优先级 |
| Setup → Enable 转化率 | (enable 成功 / setup 调用)，Redis 或 DB | < 50% → UX 有问题 |
| AES decrypt 失败 | service/totp.go 中的 `decrypt: %w` 错误日志 | > 0 → 加密密钥被换了或 DB 数据损坏 |

### 服务器时钟

TOTP 容许 ±30 秒偏移。如果服务器时钟漂移超过 1 分钟，所有用户的 verify 都会失败 → **务必启用 chrony/ntpd**。

```bash
# 检查 NTP 状态
chronyc tracking | grep "System time"
# System time     : 0.000000123 seconds slow of NTP time
```

---

## 9. 常见问题

### Q1: 老用户升级后会被强制开 TOTP 吗？
不会。`totp_enabled` 默认 false，转账逻辑只在 `status=true` 时弹框。用户主动到设置页开启才生效。

### Q2: 用户丢手机/换手机怎么办？
当前**没有备份码机制**。用户需要联系客服走身份核验后由后台手动 `UPDATE users SET totp_enabled=false, totp_secret='' WHERE user_id=...`。这是有意为之的最小可用版本——后续会加 backup codes，参见 architecture.md §10。

### Q3: 后端时钟漂移大可以怎么补救？
临时把 `pkg/totp/totp.go` 的 `skew` 从 1 调到 2（容许 ±60s），改完重启。**不要永久放宽**——会降低安全性。

### Q4: AES 密钥泄露怎么办？
1. 立即生成新密钥
2. **不要**直接换 config——所有用户会失效
3. 修改 `service.totp.go` 同时尝试新旧两个密钥解密
4. 跑后台 job 把所有 `totp_secret` 用新密钥重加密
5. 完成后下线旧密钥
6. 同时强制所有当前 session 退出，要求所有用户重新登录

### Q5: 能否禁用 TOTP 功能 kill switch？
当前没有 feature flag。临时禁用方法：在 `service.Verify` 入口直接 `return nil`，或注释掉 `wallet_send_view.dart` 的 `if (totpEnabled) {...}` 块并发新版。

### Q6: 跨多个后端实例（横向扩展）下表现如何？
- TOTP secret 在 DB（共享），无问题
- Setup 临时 secret 在 Redis（共享），无问题
- 失败计数器在 Redis（共享），无问题
- 全部组件都是 stateless，可任意水平扩展

---

## 10. 回滚

如果发现严重 bug 需回滚：

```bash
# 1. 把代码切到上一版（移除 TOTP 相关 commit）
git revert <commit-sha>

# 2. 重新构建/部署
docker compose up -d --build

# 3. 数据库字段保留即可（无破坏性，下一版再用）
#    如真要清理：
#    psql -c "ALTER TABLE users DROP COLUMN totp_secret, DROP COLUMN totp_enabled;"
```

回滚后已绑定用户的 `totp_enabled=true` 字段仍在，但因为路由没了/客户端没了，等同于关闭。再次上线时数据可直接复用。

---

## 11. 责任人 / 联系方式

| 角色 | 负责事项 |
|---|---|
| Backend on-call | im-business 服务、AES 密钥保管、监控告警响应 |
| Mobile on-call | Flutter 客户端发版、客户端崩溃排查 |
| Security | 密钥轮换计划、威胁模型评审 |

具体姓名/Slack channel 待团队补充。
