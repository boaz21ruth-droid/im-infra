# IM System — Workspace Overview

## Repository Layout

```
/Users/web1/go/im/
├── im-business/             ← our Go backend (primary work area) — see im-business/CLAUDE.md
├── im-wallet-app/           ← our Flutter client app             — see im-wallet-app/CLAUDE.md
├── open-im-server/          ← upstream OpenIM server, DO NOT MODIFY
└── openim-sdk-core/         ← upstream SDK core,    DO NOT MODIFY
```

---

## Architecture

```
Flutter App
├── POST /account/* → im-business:10008   (auth, registration)
├── POST /user/*    → im-business:10008   (profile, search)
│   (authenticated requests include header: "token: <chatToken>")
└── OpenIM SDK      → ws://host:10001     (messaging — OpenIM handles)
                      http://host:10002   (IM API — OpenIM handles)

im-business:10008
├── PostgreSQL:5432       (user table — im_business db)
├── Redis:6379/16379      (verification codes, db=5)
└── OpenIM API:10002      (register user, get imToken — admin calls)
```

**Token duality:**
- `chatToken` = HS256 JWT signed by im-business (7-day expiry)
- `imToken` = obtained from OpenIM `/auth/get_user_token` admin API

**Password flow:** Flutter sends `MD5(raw_password)` → backend stores `bcrypt(MD5_password)`

**errCode 1501** → Flutter auto-logout (`ErrUnauthorized` in `im-business/pkg/resp/resp.go`)

---

## Key Ports

| Port  | Service                          |
|-------|----------------------------------|
| 10008 | im-business HTTP API             |
| 10001 | OpenIM WebSocket (SDK)           |
| 10002 | OpenIM HTTP API                  |
| 16379 | Redis (exposed on host)          |
| 5432  | PostgreSQL                       |

---

## Full Stack Docker Startup Order

```bash
# 1. OpenIM infrastructure first
cd open-im-server
docker compose up -d

# 2. im-business (joins 'openim' docker network)
cd ../im-business
docker compose up -d --build
```
