// Only a live job for the visible conversation may animate the assistant emblem.
// A saved `writing` message alone is not proof that the model is still running.
export function responseActivity({thread, threadId, job, connection}) {
  if (!threadId || job?.threadId !== threadId || job.state !== 'running' ||
      !['chat', 'agent'].includes(job.kind)) return null;

  const current = thread?.id === threadId ? thread : null;
  const last = current?.messages?.at(-1);
  if (last?.role === 'assistant' && last.state !== 'writing') return null;
  const messageId = last?.role === 'assistant' ? last.id : null;
  const result = (phase, label, glowing = false) => ({phase, label, glowing, messageId});

  if (connection !== 'online') return result('offline', 'Reconnecting');
  if (job.approval) return result('approval', 'Awaiting your approval');
  const progress = job.progress || '';
  if (/stopping|cancel/i.test(progress)) return result('stopping', 'Stopping');
  if (/writing a reply/i.test(progress)) return result('responding', 'Responding', true);
  if (/thinking/i.test(progress)) return result('thinking', 'Thinking', true);
  if (/using |finished |working|tools and workspace/i.test(progress)) return result('working', 'Working', true);
  if (!messageId || /preparing|loading|starting|reading/i.test(progress)) return result('preparing', 'Preparing', true);
  return result('processing', 'Processing', true);
}
