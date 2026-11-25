// Создаёт свежие App Store-профили для приложения и расширения через App Store Connect API
// и устанавливает их для Xcode. Профили пересоздаются при каждой сборке, чтобы в них
// попадали актуальные возможности App ID (App Group, Push).
// Переменные окружения: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH, DIST_CERT_ID.
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const E = process.env;
const PROFILES = [
  { bundle: 'info.codix.liniya2', name: 'Linia2 AppStore' },
  { bundle: 'info.codix.liniya2.NSExtension', name: 'Linia2 NSExtension AppStore' },
];

function token() {
  const b = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
  const now = Math.floor(Date.now() / 1000);
  const h = b({ alg: 'ES256', kid: E.ASC_KEY_ID, typ: 'JWT' });
  const p = b({ iss: E.ASC_ISSUER_ID, iat: now, exp: now + 900, aud: 'appstoreconnect-v1' });
  const s = crypto.sign('sha256', Buffer.from(h + '.' + p), { key: fs.readFileSync(E.ASC_KEY_PATH), dsaEncoding: 'ieee-p1363' }).toString('base64url');
  return `${h}.${p}.${s}`;
}
const TOKEN = token();
async function call(method, p, body) {
  const r = await fetch('https://api.appstoreconnect.apple.com' + p, {
    method, headers: { Authorization: 'Bearer ' + TOKEN, 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  });
  const j = r.status === 204 ? {} : await r.json();
  if (r.status >= 300) throw new Error(`${method} ${p}: ${r.status} ${JSON.stringify(j.errors?.map((e) => e.detail))}`);
  return j;
}

const dirs = [
  path.join(os.homedir(), 'Library/MobileDevice/Provisioning Profiles'),
  path.join(os.homedir(), 'Library/Developer/Xcode/UserData/Provisioning Profiles'),
];
dirs.forEach((d) => fs.mkdirSync(d, { recursive: true }));

const missing = [];
for (const { bundle, name } of PROFILES) {
  const bj = await call('GET', `/v1/bundleIds?filter[identifier]=${bundle}`);
  const b = bj.data.find((x) => x.attributes.identifier === bundle);
  if (!b) throw new Error('Bundle ID не зарегистрирован: ' + bundle);
  const old = await call('GET', `/v1/profiles?filter[name]=${encodeURIComponent(name)}&limit=50`);
  for (const p of old.data) await call('DELETE', `/v1/profiles/${p.id}`);
  const created = await call('POST', '/v1/profiles', {
    data: {
      type: 'profiles',
      attributes: { name, profileType: 'IOS_APP_STORE' },
      relationships: {
        bundleId: { data: { type: 'bundleIds', id: b.id } },
        certificates: { data: [{ type: 'certificates', id: E.DIST_CERT_ID }] },
      },
    },
  });
  const a = created.data.attributes;
  const content = Buffer.from(a.profileContent, 'base64');
  for (const d of dirs) fs.writeFileSync(path.join(d, `${a.uuid}.mobileprovision`), content);
  const groups = /application-groups<\/key>\s*<array>([\s\S]*?)<\/array>/.exec(content.toString('latin1'));
  console.log(`профиль «${name}» ${a.uuid}; app groups: ${groups ? groups[1].replace(/\s+/g, ' ').trim() || '(пусто)' : '(нет)'}`);
  if (!groups || !groups[1].includes('group.info.codix.liniya2.db')) missing.push(bundle);
}
if (missing.length) {
  console.log(`::error::App Group group.info.codix.liniya2.db не привязана к: ${missing.join(', ')}. ` +
    'Создайте её на developer.apple.com (Identifiers → App Groups) и включите в App ID, затем перезапустите сборку.');
  process.exit(1);
}
