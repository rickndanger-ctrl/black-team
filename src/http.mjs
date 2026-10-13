// Requests from the window to the local Black Team service (or, on a phone, to the companion it serves).
export async function api(path, options = {}) {
  const controller = new AbortController();
  const timeout = window.setTimeout(() => controller.abort(), 20000);
  let response;
  try {
    response = await fetch(path, {credentials: 'same-origin', cache: 'no-store', ...options, signal: controller.signal, headers: {'Content-Type': 'application/json', ...options.headers}});
  } finally {window.clearTimeout(timeout);}
  if (!response.ok) {
    const error = new Error(response.status === 403 || response.status === 401 ? 'Connect to Tailscale and open the Companion pairing link from your Black Team desktop app.' : 'That request could not be completed. Check your computer’s connection and try again.');
    if (![401,403].includes(response.status)) {try {const value=await response.json();if(typeof value.error==='string')error.message=value.error;}catch{}}
    error.status = response.status;
    throw error;
  }
  return response.json();
}
export const post = (path, value) => api(path, {method: 'POST', body: JSON.stringify(value)});
export const call = (route, value) => value === undefined ? api(`/api/${route}`) : post(`/api/${route}`, value);
