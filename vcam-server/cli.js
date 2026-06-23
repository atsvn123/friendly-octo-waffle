#!/usr/bin/env node
// cli.js — User management from the command line.
//
// Usage:
//   node cli.js add <username> <password> [days]    — add user (optional expiry in days)
//   node cli.js list                                 — list all users
//   node cli.js delete <username>                    — delete user
//   node cli.js disable <username>                   — disable user
//   node cli.js enable  <username>                   — re-enable user
//   node cli.js passwd  <username> <newpassword>     — change password
//
// Examples:
//   node cli.js add alice secret123          # no expiry
//   node cli.js add alice secret123 30       # expires in 30 days
//   node cli.js list
//   node cli.js delete alice

const crypto = require('crypto');
const db = require('./users');
const fs = require('fs');
const path = require('path');

const dataDir = path.join(__dirname, 'data');
const usersFile = path.join(dataDir, 'users.json');
if (!fs.existsSync(dataDir)) fs.mkdirSync(dataDir, { recursive: true });
if (!fs.existsSync(usersFile)) fs.writeFileSync(usersFile, '{}');

const [,, cmd, ...args] = process.argv;

function md5(str) {
    return crypto.createHash('md5').update(str).digest('hex');
}

function fmtDate(ms) {
    if (!ms) return 'never';
    const d = new Date(ms);
    return d.toISOString().slice(0, 10);
}

function fmtExpiry(ms) {
    if (!ms) return 'never';
    const remaining = ms - Date.now();
    if (remaining <= 0) return `EXPIRED (${fmtDate(ms)})`;
    const days = Math.ceil(remaining / 86400000);
    return `${fmtDate(ms)} (${days}d left)`;
}

switch (cmd) {
    case 'add': {
        const [username, password, daysStr] = args;
        if (!username || !password) {
            console.error('Usage: node cli.js add <username> <password> [days]');
            process.exit(1);
        }
        const expiresAt = daysStr
            ? Date.now() + parseInt(daysStr, 10) * 86400 * 1000
            : null;
        const user = db.upsert({
            username,
            passwordMD5: md5(password),
            expiresAt,
            devices: [],
            disabled: false,
        });
        console.log(`Added: ${user.username}  expires: ${fmtExpiry(user.expiresAt)}`);
        break;
    }

    case 'list': {
        const all = db.all();
        const entries = Object.values(all);
        if (entries.length === 0) {
            console.log('No users.');
            break;
        }
        console.log(`${'Username'.padEnd(20)} ${'Expires'.padEnd(22)} ${'Disabled'.padEnd(10)} Last Login`);
        console.log('-'.repeat(72));
        for (const u of entries) {
            const dis  = u.disabled ? 'YES' : 'no';
            const last = u.lastLoginAt ? fmtDate(u.lastLoginAt) : 'never';
            console.log(`${u.username.padEnd(20)} ${fmtExpiry(u.expiresAt).padEnd(22)} ${dis.padEnd(10)} ${last}`);
        }
        break;
    }

    case 'delete': {
        const [username] = args;
        if (!username) { console.error('Usage: node cli.js delete <username>'); process.exit(1); }
        const ok = db.remove(username);
        console.log(ok ? `Deleted: ${username}` : `Not found: ${username}`);
        break;
    }

    case 'disable': {
        const [username] = args;
        if (!username) { console.error('Usage: node cli.js disable <username>'); process.exit(1); }
        const u = db.patch(username, { disabled: true });
        console.log(u ? `Disabled: ${u.username}` : `Not found: ${username}`);
        break;
    }

    case 'enable': {
        const [username] = args;
        if (!username) { console.error('Usage: node cli.js enable <username>'); process.exit(1); }
        const u = db.patch(username, { disabled: false });
        console.log(u ? `Enabled: ${u.username}` : `Not found: ${username}`);
        break;
    }

    case 'passwd': {
        const [username, newPassword] = args;
        if (!username || !newPassword) {
            console.error('Usage: node cli.js passwd <username> <newpassword>');
            process.exit(1);
        }
        const u = db.patch(username, { passwordMD5: md5(newPassword) });
        console.log(u ? `Password updated: ${u.username}` : `Not found: ${username}`);
        break;
    }

    default:
        console.log(`VCAM VIP CLI

Commands:
  node cli.js add     <username> <password> [days]
  node cli.js list
  node cli.js delete  <username>
  node cli.js disable <username>
  node cli.js enable  <username>
  node cli.js passwd  <username> <newpassword>`);
}
