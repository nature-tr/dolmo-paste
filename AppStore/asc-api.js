#!/usr/bin/env node
/**
 * App Store Connect API 小工具。凭证从 AppStore/.env.local + ~/.private_keys 读，不落明文。
 *
 *   node AppStore/asc-api.js GET  /v1/apps
 *   node AppStore/asc-api.js POST /v1/xxx  '{"data":{...}}'
 *
 * 注意两个必踩的坑（都踩过了，别再踩）：
 * 1) ES256 的 JWT 签名必须是裸 r||s 各 32 字节，node crypto 默认给 DER，必须转换，否则一律 401
 * 2) 允许「查不到」的请求别用 set -e 包在 shell 里，这里统一返回 status，不做抛异常
 */
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const ROOT = __dirname;
const envFile = path.join(ROOT, '.env.local');
if (fs.existsSync(envFile)) {
  for (const line of fs.readFileSync(envFile, 'utf8').split('\n')) {
    const m = line.match(/^\s*export\s+([A-Z_]+)=(.+)$/);
    if (m) process.env[m[1]] = m[2].trim();
  }
}

const KEY_ID = process.env.ASC_API_KEY;
const ISSUER = process.env.ASC_API_ISSUER;
if (!KEY_ID || !ISSUER) {
  console.error('缺 ASC_API_KEY / ASC_API_ISSUER，检查 AppStore/.env.local');
  process.exit(1);
}
const PRIV = fs.readFileSync(path.join(process.env.HOME, '.private_keys', `AuthKey_${KEY_ID}.p8`), 'utf8');

const b64url = (s) => Buffer.from(s).toString('base64url');

/** DER 编码的 ECDSA 签名 → 裸 r||s（各 32 字节），ES256 只认后者 */
function derToRaw(der) {
  let o = 0;
  if (der[o++] !== 0x30) throw new Error('not DER');
  let L = der[o++];
  if (L & 0x80) o += L & 0x7f;
  if (der[o++] !== 0x02) throw new Error('no r');
  const rl = der[o++];
  let r = der.slice(o, o + rl);
  o += rl;
  if (der[o++] !== 0x02) throw new Error('no s');
  const sl = der[o++];
  let s = der.slice(o, o + sl);
  const trim = (b) => { let i = 0; while (i < b.length - 1 && b[i] === 0) i++; return b.slice(i); };
  r = trim(r); s = trim(s);
  const pad = (b) => Buffer.concat([Buffer.alloc(32 - b.length), b]);
  return Buffer.concat([pad(r), pad(s)]);
}

let cached = null, exp = 0;
function token() {
  const now = Math.floor(Date.now() / 1000);
  if (cached && now < exp - 60) return cached;
  const h = b64url(JSON.stringify({ alg: 'ES256', kid: KEY_ID, typ: 'JWT' }));
  const p = b64url(JSON.stringify({ iss: ISSUER, iat: now, exp: now + 1200, aud: 'appstoreconnect-v1' }));
  const input = h + '.' + p;
  const sg = crypto.createSign('sha256');
  sg.update(input);
  cached = input + '.' + derToRaw(sg.sign(PRIV)).toString('base64url');
  exp = now + 1200;
  return cached;
}

async function api(p, method = 'GET', body) {
  const res = await fetch('https://api.appstoreconnect.apple.com' + p, {
    method,
    headers: { Authorization: 'Bearer ' + token(), 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  });
  const txt = await res.text();
  let json = null;
  try { json = JSON.parse(txt); } catch (e) {}
  return { status: res.status, json, txt };
}

module.exports = { api };

if (require.main === module) {
  const [p, method = 'GET', raw] = process.argv.slice(2);
  if (!p) {
    console.error('用法: node AppStore/asc-api.js /v1/路径 [METHOD] [JSON]');
    process.exit(1);
  }
  api(p, method, raw ? JSON.parse(raw) : undefined).then((r) => {
    console.log('status:', r.status);
    console.log(r.json ? JSON.stringify(r.json, null, 2) : r.txt);
  });
}
