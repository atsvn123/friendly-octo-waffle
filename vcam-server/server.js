// server.js
// VCAM VIP authentication backend.
//
// The binary flow (v2.20+, IDA-confirmed):
//   1. SpringBoard sends IPC code 1014 (login) to mediaserverd.
//   2. mediaserverd calls POST https://<domain>/user/login with a plain
//      URL-encoded body: username=X&password=MD5(pw)&hash=SHA256(device)&timestamp=ms
//      NO Encrypt-Body header, NO XOR.
//   3. This server returns plain JSON {code:0, token:"..."} on success
//      or {code:1, message:"..."} on failure.
//   4. The binary checks token != nil before starting RTMP.
//
// Legacy support: if Encrypt-Body: true is sent, body is XOR-decrypted
// and response is XOR-encrypted (backward compat with pre-v2.19 clients).
//
// Admin API (protected by X-Admin-Key header):
//   POST   /admin/users           — create/replace user
//   GET    /admin/users           — list all users
//   GET    /admin/users/:username — get one user
//   PATCH  /admin/users/:username — update fields
//   DELETE /admin/users/:username — delete user

require('dotenv').config();
const express   = require('express');
const crypto    = require('crypto');
const { encryptResponse, decryptBody } = require('./crypto');
const db        = require('./users');
const fs        = require('fs');
const path      = require('path');

// ── Ensure data dir ───────────────────────────────────────────────────────────
const dataDir = path.join(__dirname, 'data');
if (!fs.existsSync(dataDir)) fs.mkdirSync(dataDir, { recursive: true });
const usersFile = path.join(dataDir, 'users.json');
if (!fs.existsSync(usersFile)) fs.writeFileSync(usersFile, '{}');

// ── Config ────────────────────────────────────────────────────────────────────
const PORT      = parseInt(process.env.PORT  || '3000', 10);
const ADMIN_KEY = process.env.ADMIN_KEY || 'changeme';

if (ADMIN_KEY === 'changeme') {
    console.warn('[WARN] ADMIN_KEY is default "changeme" — set a real key in .env');
}

// ── App setup ─────────────────────────────────────────────────────────────────
const app = express();

// Capture raw body before any parser runs
app.use((req, res, next) => {
    const chunks = [];
    req.on('data', chunk => chunks.push(chunk));
    req.on('end', () => { req.rawBody = Buffer.concat(chunks); next(); });
    req.on('error', next);
});

// JSON parser for admin routes (applied per-route below)
const jsonParser = express.json();

// Simple request logger
app.use((req, res, next) => {
    const ts = new Date().toISOString();
    const ip = req.headers['x-forwarded-for'] || req.socket.remoteAddress;
    console.log(`[${ts}] ${req.method} ${req.path} — ${ip}`);
    next();
});

// ── POST /user/login ──────────────────────────────────────────────────────────
app.post('/user/login', (req, res) => {
    // Detect legacy encrypted clients (pre-v2.19)
    const encrypted = (req.headers['encrypt-body'] || '').toLowerCase() === 'true';

    function reply(code, message, token) {
        const obj = code === 0
            ? { code: 0, token: token || '' }
            : { code, message };
        if (encrypted) {
            res.set('Content-Type', 'application/octet-stream');
            return res.send(encryptResponse(obj));
        }
        // v2.20+: plain JSON response
        res.set('Content-Type', 'application/json');
        return res.send(JSON.stringify(obj));
    }

    // Decrypt body if legacy, otherwise read as UTF-8
    let bodyStr;
    try {
        bodyStr = encrypted
            ? decryptBody(req.rawBody)
            : req.rawBody.toString('utf8');
    } catch {
        return reply(400, 'Malformed request');
    }

    // Parse URL-encoded form: username, password (MD5 hex), hash, timestamp
    let params;
    try {
        params = new URLSearchParams(bodyStr);
    } catch {
        return reply(400, 'Malformed body');
    }

    const username   = (params.get('username') || '').trim().toLowerCase();
    const passHash   = (params.get('password') || '').trim().toLowerCase(); // MD5 hex
    const deviceHash = (params.get('hash')     || '').trim();

    if (!username || !passHash) {
        return reply(1, 'Missing credentials');
    }

    const user = db.get(username);

    if (!user) {
        return reply(1, 'Account does not exist');
    }

    if (user.disabled) {
        return reply(1, 'Account is disabled');
    }

    if (user.expiresAt && Date.now() > user.expiresAt) {
        return reply(1, 'Subscription expired');
    }

    // Password check: client already MD5-hashed it; compare directly
    if (passHash !== user.passwordMD5) {
        return reply(1, 'Wrong password');
    }

    // Device check: if the user has registered devices, enforce them
    if (user.devices && user.devices.length > 0) {
        if (!user.devices.includes(deviceHash)) {
            return reply(1, 'Unauthorized device');
        }
    }

    db.touchLogin(username);

    // Generate a session token — the binary checks token != nil before starting RTMP.
    // A random hex string is sufficient; it's not verified cryptographically by the client.
    const token = crypto.randomBytes(16).toString('hex');

    console.log(`  → login OK: ${username}  token=${token.slice(0,8)}...`);
    return reply(0, null, token);
});

// ── Admin middleware ──────────────────────────────────────────────────────────
function requireAdmin(req, res, next) {
    const key = req.headers['x-admin-key'] || '';
    if (!key || key !== ADMIN_KEY) {
        return res.status(403).json({ error: 'Forbidden' });
    }
    next();
}

// POST /admin/users — create or replace a user
app.post('/admin/users', requireAdmin, jsonParser, (req, res) => {
    const { username, password, expiresAt, devices, disabled } = req.body || {};

    if (!username || !password) {
        return res.status(400).json({ error: 'username and password are required' });
    }

    const passwordMD5 = crypto.createHash('md5').update(password).digest('hex');
    const user = db.upsert({
        username,
        passwordMD5,
        expiresAt: expiresAt   || null,
        devices:   devices     || [],
        disabled:  disabled    ?? false,
    });

    res.json({ ok: true, user: { ...user, passwordMD5: '[hidden]' } });
});

// GET /admin/users — list all users (passwords hidden)
app.get('/admin/users', requireAdmin, (req, res) => {
    const all = db.all();
    const safe = {};
    for (const [k, v] of Object.entries(all)) {
        safe[k] = { ...v, passwordMD5: '[hidden]' };
    }
    res.json(safe);
});

// GET /admin/users/:username
app.get('/admin/users/:username', requireAdmin, (req, res) => {
    const user = db.get(req.params.username);
    if (!user) return res.status(404).json({ error: 'Not found' });
    res.json({ ...user, passwordMD5: '[hidden]' });
});

// PATCH /admin/users/:username — update individual fields
app.patch('/admin/users/:username', requireAdmin, jsonParser, (req, res) => {
    const key  = req.params.username.toLowerCase();
    const user = db.get(key);
    if (!user) return res.status(404).json({ error: 'Not found' });

    const updates = {};
    if (req.body.password !== undefined) {
        updates.passwordMD5 = crypto.createHash('md5').update(req.body.password).digest('hex');
    }
    if (req.body.disabled  !== undefined) updates.disabled  = !!req.body.disabled;
    if (req.body.expiresAt !== undefined) updates.expiresAt = req.body.expiresAt;
    if (req.body.devices   !== undefined) updates.devices   = req.body.devices;

    const updated = db.patch(key, updates);
    res.json({ ok: true, user: { ...updated, passwordMD5: '[hidden]' } });
});

// DELETE /admin/users/:username
app.delete('/admin/users/:username', requireAdmin, (req, res) => {
    const ok = db.remove(req.params.username);
    if (!ok) return res.status(404).json({ error: 'Not found' });
    res.json({ ok: true });
});

// ── Health check ──────────────────────────────────────────────────────────────
app.get('/health', (req, res) => res.json({ ok: true, ts: Date.now() }));

// ── Start ─────────────────────────────────────────────────────────────────────
app.listen(PORT, () => {
    console.log(`VCAM VIP server listening on port ${PORT}`);
    console.log(`Login endpoint : POST /user/login`);
    console.log(`Admin endpoint : /admin/users  (X-Admin-Key: ${ADMIN_KEY})`);
});
