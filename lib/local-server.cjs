'use strict';

function localEndpoint(value) {
  let url;
  try { url = new URL(value); } catch { throw new Error('Enter a local server URL such as http://127.0.0.1:11434/v1.'); }
  if (url.protocol !== 'http:' || !['localhost', '127.0.0.1', '[::1]'].includes(url.hostname) ||
      !url.port || !['/v1', '/v1/'].includes(url.pathname) || url.username || url.password || url.search || url.hash) {
    throw new Error('Use a loopback HTTP address with a port and /v1 (localhost, 127.0.0.1, or [::1]).');
  }
  // Avoid DNS resolution for the common localhost spelling.
  if (url.hostname === 'localhost') url.hostname = '127.0.0.1';
  return `${url.origin}/v1`;
}

function serverHeaders(apiKey = '') {
  if (typeof apiKey !== 'string' || apiKey.length > 4096 || /[^\x21-\x7e]/.test(apiKey)) {
    throw new Error('The server API key must contain only printable characters without spaces.');
  }
  return apiKey ? { Authorization: `Bearer ${apiKey}` } : {};
}

async function discoverModels({endpoint, apiKey = '', fetch: fetcher = globalThis.fetch, signal}) {
  const base = localEndpoint(endpoint);
  const headers = serverHeaders(apiKey);
  let response;
  try {
    response = await fetcher(`${base}/models`, {headers, redirect: 'error', signal: AbortSignal.any([...(signal ? [signal] : []), AbortSignal.timeout(10000)])});
  } catch {
    signal?.throwIfAborted();
    throw new Error('Cannot reach the local model server. Start it, enable its local API, and check the address.');
  }
  if (!response.ok) {
    await response.body?.cancel();
    throw new Error([401, 403].includes(response.status) ? 'The local server requires a valid API key.' : `Local model discovery failed (HTTP ${response.status}).`);
  }
  let value;
  try { value = await response.json(); } catch { throw new Error('The local server returned an invalid model list.'); }
  if (!Array.isArray(value?.data)) throw new Error('This server must support OpenAI-compatible GET /v1/models.');
  const models = [...new Set(value.data.map(item => item?.id).filter(id => typeof id === 'string' && id.trim() && id.length <= 256 && !/[\x00-\x1f\x7f]/.test(id)))];
  if (!models.length) throw new Error('No models were reported. Download or load a model in your local server first.');
  return {endpoint: base, models};
}
module.exports = {localEndpoint, serverHeaders, discoverModels};
