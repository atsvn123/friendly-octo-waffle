// users.js
// Flat JSON file user store.
// Schema per entry:
//   username     (string, lowercase key)
//   passwordMD5  (string, hex — matches what the client sends after MD5-hashing)
//   createdAt    (ms epoch)
//   expiresAt    (ms epoch | null — null = never expires)
//   disabled     (bool)
//   devices      (string[] | [] — allowed device hashes; empty = any device allowed)
//   lastLoginAt  (ms epoch | null)

const fs   = require('fs');
const path = require('path');

const FILE = path.join(__dirname, 'data', 'users.json');

function _read() {
    try {
        return JSON.parse(fs.readFileSync(FILE, 'utf8'));
    } catch {
        return {};
    }
}

function _write(db) {
    fs.writeFileSync(FILE, JSON.stringify(db, null, 2));
}

function get(username) {
    return _read()[username.toLowerCase()] || null;
}

function all() {
    return _read();
}

function upsert({ username, passwordMD5, expiresAt = null, devices = [], disabled = false }) {
    const db = _read();
    const key = username.toLowerCase();
    db[key] = {
        username: key,
        passwordMD5,
        createdAt: db[key]?.createdAt || Date.now(),
        expiresAt,
        disabled,
        devices,
        lastLoginAt: db[key]?.lastLoginAt || null,
    };
    _write(db);
    return db[key];
}

function patch(username, fields) {
    const db = _read();
    const key = username.toLowerCase();
    if (!db[key]) return null;
    Object.assign(db[key], fields);
    _write(db);
    return db[key];
}

function remove(username) {
    const db = _read();
    const key = username.toLowerCase();
    if (!db[key]) return false;
    delete db[key];
    _write(db);
    return true;
}

function touchLogin(username) {
    patch(username, { lastLoginAt: Date.now() });
}

module.exports = { get, all, upsert, patch, remove, touchLogin };
