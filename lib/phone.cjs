'use strict';
const {execFile} = require('node:child_process');
const {promisify} = require('node:util');
const LOCAL_PORT = 18199;
const PHONE_PORT = 8449;
const TARGET = `http://127.0.0.1:${LOCAL_PORT}`;
const COMMAND = `tailscale serve --bg --https=${PHONE_PORT} ${TARGET}`;

function validatePhone(input) {
  if (!input || typeof input.enabled !== 'boolean') throw new Error('Choose whether to enable Companion.');
  const hostname = String(input.hostname || '').trim().toLowerCase().replace(/\.$/, '');
  const owner = String(input.owner || '').trim();
  if (hostname && !/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.[a-z0-9-]+\.ts\.net$/.test(hostname)) throw new Error('Use this computer’s private Tailscale hostname.');
  if (owner && (owner.length > 120 || /[\s\x00-\x1f\x7f]/.test(owner))) throw new Error('Use your Tailscale account login.');
  if (input.enabled && (!hostname || !owner)) throw new Error('Detect this computer and its Tailscale owner first.');
  return {enabled: input.enabled, hostname, owner};
}

function routeState(status, hostname) {
  const key = `${hostname}:${PHONE_PORT}`;
  const web = status?.Web?.[key];
  const tcp = status?.TCP?.[String(PHONE_PORT)];
  const handlers = web?.Handlers || {};
  const owned = handlers['/']?.Proxy === TARGET && Object.keys(handlers).length === 1 && tcp?.HTTPS === true;
  const publicRoute = status?.AllowFunnel?.[key] === true;
  const occupied = Boolean(tcp || web || Object.keys(status?.Web || {}).some(k => k.endsWith(`:${PHONE_PORT}`)));
  return {owned, publicRoute, occupied};
}

class PhoneManager {
  constructor({configStore, run = promisify(execFile)}) { this.store = configStore; this.run = run; this.cache = null; }
  async command(args) {
    const result = await this.run('tailscale', args, {timeout:10000, maxBuffer:1024*1024, windowsHide:true, shell:false});
    return result.stdout;
  }
  async detect() {
    try {
      const state = JSON.parse(await this.command(['status','--json']));
      const self = state.Self || {};
      return {installed:true, online:state.BackendState === 'Running' && self.Online !== false,
        hostname:String(self.DNSName || '').replace(/\.$/, '').toLowerCase(),
        owner:String(state.User?.[self.UserID]?.LoginName || '')};
    } catch (error) {
      return {installed:error.code !== 'ENOENT', online:false, hostname:'',owner:'',error:'Tailscale is unavailable. Install it and sign in, then detect again.'};
    }
  }
  async status({fresh=false}={}) {
    const phone = this.store.read().phone;
    const key = JSON.stringify(phone);
    if (!fresh && this.cache?.key === key && Date.now()-this.cache.at < 5000) return this.cache.value;
    let connected = false;
    if (phone.enabled) {
      const self = await this.detect();
      if (self.online && self.hostname === phone.hostname && self.owner === phone.owner) {
        try {
          const route = routeState(JSON.parse(await this.command(['serve','status','--json'])),phone.hostname);
          connected = route.owned && !route.publicRoute;
        } catch { /* An unavailable route is disconnected, never assumed private. */ }
      }
    }
    const value = {enabled:phone.enabled,connected,url:phone.enabled?`https://${phone.hostname}:${PHONE_PORT}/`:'',command:COMMAND};
    this.cache = {key,at:Date.now(),value};
    return value;
  }
  async setup() {
    const self = await this.detect();
    if (!self.installed || !self.online) throw new Error('Install Tailscale on this computer and sign in, then try again.');
    const next = validatePhone({enabled:true, hostname:self.hostname, owner:self.owner});
    const previous = this.store.read().phone;
    if (previous.enabled && (previous.hostname !== next.hostname || previous.owner !== next.owner)) {
      throw new Error('Your Tailscale account or computer has changed. Turn off the existing phone setup before connecting this account.');
    }
    this.store.save({phone:next});
    // A failed route setup remains retryable and never claims to be connected.
    return this.connect();
  }
  async connect() {
    const phone = validatePhone(this.store.read().phone);
    if (!phone.enabled) throw new Error('Save and enable Companion first.');
    const self = await this.detect();
    if (!self.online || self.hostname !== phone.hostname || self.owner !== phone.owner) throw new Error('Tailscale must be online with the saved computer and owner. Detect and save again.');
    const route = routeState(JSON.parse(await this.command(['serve','status','--json'])),phone.hostname);
    if (route.publicRoute || (route.occupied && !route.owned)) throw new Error('Port 8449 is used by another or public route. Black Team will not overwrite it.');
    if (!route.owned) await this.command(['serve','--bg',`--https=${PHONE_PORT}`,'--yes',TARGET]);
    this.cache = null;
    const result = await this.status({fresh:true});
    if (!result.connected) throw new Error('Companion route could not be verified. Check Tailscale Serve configuration.');
    return result;
  }
  async disable() {
    // Stop accepting remote requests even if Tailscale is offline or route cleanup fails.
    this.store.save({phone:{...this.store.read().phone,enabled:false}});
    this.cache = null;
    try {await this.disconnect();return {disabled:true};}
    catch {return {disabled:true,warning:'Phone access is off. Its Tailscale route could not be removed; check Tailscale when it is available.'};}
  }
  async disconnect() {
    const phone = this.store.read().phone;
    const route = routeState(JSON.parse(await this.command(['serve','status','--json'])),phone.hostname);
    if (route.occupied && (!route.owned || route.publicRoute)) throw new Error('Port 8449 no longer belongs exclusively to Black Team. Adjust it in Tailscale.');
    if (route.owned) await this.command(['serve',`--https=${PHONE_PORT}`,'off']);
    this.cache = null;
    return this.status({fresh:true});
  }
}
module.exports = {PhoneManager, validatePhone, routeState, LOCAL_PORT, PHONE_PORT, TARGET, COMMAND};
