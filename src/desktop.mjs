export async function native(action, data = {}) {
  try { return await window.blackTeam.request(action, data); }
  catch (cause) {
    throw new Error(String(cause?.message || 'The desktop action could not finish.').replace(/^Error invoking remote method '[^']+':\s*(?:Error:\s*)?/, ''));
  }
}
