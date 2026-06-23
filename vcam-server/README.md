# VCAM VIP Server

Authentication backend for the VCAM VIP virtual camera system.

## How it fits in

```
iPhone (mediaserverd)
  └─ POST https://YOUR_DOMAIN/user/login
        └─ XOR-encrypted body: username + MD5(password) + device_hash + timestamp
        ← XOR-encrypted JSON: {code:0} or {code:1, message:"..."}
```

The binary hardcodes `camserver.cyou`. NetHelper.dylib redirects that to whatever
domain you configure. When you have your domain, update one line in the dylib source
(see "Domain change" below) and rebuild.

---

## Setup

```bash
cd vcam-server
npm install

cp .env.example .env
# Edit .env: set PORT and ADMIN_KEY
```

Start the server:
```bash
npm start          # production
npm run dev        # auto-reload (nodemon)
```

The only port the binary talks to is 443 (HTTPS). Run the server behind **nginx** or
**Caddy** that terminates TLS, or use a platform like Railway/Render that does it
for you.

---

## User management

### CLI (easiest)
```bash
node cli.js add alice mypassword        # no expiry
node cli.js add alice mypassword 30     # expires in 30 days
node cli.js list
node cli.js disable alice
node cli.js enable  alice
node cli.js passwd  alice newpass
node cli.js delete  alice
```

### Admin HTTP API
All admin routes require header `X-Admin-Key: <your ADMIN_KEY>`.

```bash
# Add user (30-day expiry)
curl -X POST https://YOUR_DOMAIN/admin/users \
  -H "X-Admin-Key: YOUR_KEY" \
  -H "Content-Type: application/json" \
  -d '{"username":"alice","password":"secret","expiresAt":1780000000000}'

# List users
curl https://YOUR_DOMAIN/admin/users \
  -H "X-Admin-Key: YOUR_KEY"

# Disable user
curl -X PATCH https://YOUR_DOMAIN/admin/users/alice \
  -H "X-Admin-Key: YOUR_KEY" \
  -H "Content-Type: application/json" \
  -d '{"disabled":true}'

# Delete user
curl -X DELETE https://YOUR_DOMAIN/admin/users/alice \
  -H "X-Admin-Key: YOUR_KEY"
```

User fields:
| Field | Type | Description |
|---|---|---|
| username | string | login name (stored lowercase) |
| password | string | plaintext (server stores MD5) |
| expiresAt | ms epoch \| null | null = never expires |
| devices | string[] | empty = any device allowed |
| disabled | bool | block login without deleting |

---

## Domain change

When you have your domain, open `vcamera_source/VCamBridge/VCamBridge.m` and change:

```objc
[req setUrl:@"camserver.cyou"];  // ← change to your domain
```

And open `NetHelper_source/Hooks/NetHelperHooks.m` and change the redirect target:

```objc
// In hook_setUrl — change "bibq.net" to your domain
```

Then rebuild: `make clean && make package FINALPACKAGE=1`.

---

## nginx config (reference)

```nginx
server {
    listen 443 ssl;
    server_name YOUR_DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/YOUR_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/YOUR_DOMAIN/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
```

---

## Data

Users are stored in `data/users.json`. Back this file up — it is the only persistent
state the server has.
