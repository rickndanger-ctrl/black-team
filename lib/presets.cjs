'use strict';

// What each known harness needs to talk to the model Black Team is using.
// A preset only supplies arguments, environment and, for one harness, a small
// settings file in Black Team's own data folder. It never edits the harness's own configuration.

const fs = require('node:fs');
const path = require('node:path');

const HOURS = 6 * 60 * 60 * 1000;

const PRESETS = {
  claude: {
    name: 'Claude Code', command: 'claude',
    // Needs a server that also speaks the Anthropic Messages API: llama.cpp, Ollama and LM Studio do.
    build: ({ endpoint, model, key, context }) => ({ args: [], env: {
      ANTHROPIC_BASE_URL: endpoint.replace(/\/v1\/?$/, ''), ANTHROPIC_AUTH_TOKEN: key, ANTHROPIC_MODEL: model,
      ANTHROPIC_DEFAULT_OPUS_MODEL: model, ANTHROPIC_DEFAULT_SONNET_MODEL: model, ANTHROPIC_DEFAULT_HAIKU_MODEL: model,
      ANTHROPIC_SMALL_FAST_MODEL: model, CLAUDE_CODE_SUBAGENT_MODEL: model,
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: '1', DISABLE_PROMPT_CACHING: '1',
      CLAUDE_CODE_MAX_CONTEXT_TOKENS: String(context), CLAUDE_CODE_MAX_OUTPUT_TOKENS: String(Math.min(8192, Math.floor(context / 4))),
      // A local model can take minutes to read a long prompt; the stock deadlines assume a data centre.
      API_TIMEOUT_MS: String(HOURS), CLAUDE_STREAM_FIRST_BYTE_TIMEOUT_MS: '1800000',
      CLAUDE_ENABLE_BYTE_WATCHDOG: '0', CLAUDE_ENABLE_STREAM_WATCHDOG: '0', API_FORCE_IDLE_TIMEOUT: '0',
    } }),
  },
  codex: {
    name: 'Codex', command: 'codex',
    build: ({ endpoint, model, context }) => ({ env: {}, args: [
      ['model_provider', 'black_team'], ['model_providers.black_team.name', 'Black Team'],
      ['model_providers.black_team.base_url', endpoint], ['model_providers.black_team.wire_api', 'responses'],
      ['model_providers.black_team.env_key', 'OPENAI_API_KEY'], ['model_providers.black_team.stream_idle_timeout_ms', HOURS],
      ['model', model], ['model_context_window', context], ['web_search', 'disabled'],
    ].flatMap(([name, value]) => ['-c', `${name}=${JSON.stringify(value)}`]) }),
  },
  pi: {
    name: 'Pi', command: 'pi',
    build: ({ endpoint, model, key, context, name, dir }) => ({
      args: ['--provider', 'black-team', '--model', model],
      env: { PI_CODING_AGENT_DIR: dir, PI_OFFLINE: '1', PI_TELEMETRY: '0' },
      files: { 'models.json': { providers: { 'black-team': { baseUrl: endpoint, api: 'openai-completions', apiKey: key,
        compat: { supportsDeveloperRole: false, maxTokensField: 'max_tokens' },
        models: [{ id: model, name, reasoning: false, input: ['text'], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
          contextWindow: context, maxTokens: Math.min(8192, Math.floor(context / 4)) }] } } } },
    }),
  },
  opencode: {
    name: 'OpenCode', command: 'opencode',
    build: ({ endpoint, model, key, name }) => ({ args: [], env: { OPENCODE_CONFIG_CONTENT: JSON.stringify({
      $schema: 'https://opencode.ai/config.json', model: `black-team/${model}`,
      provider: { 'black-team': { npm: '@ai-sdk/openai-compatible', name: 'Black Team', options: { baseURL: endpoint, apiKey: key }, models: { [model]: { name } } } },
    }) } }),
  },
  dsh: {
    name: 'DeepSeek Harness', command: 'dsh',
    // The patch switches its hosted providers off, so this launch can only reach the local model.
    build: ({ endpoint, model, context, name, dir }) => ({
      // "web" is the interface every DeepSeek Harness has. A terminal interface is a separate add-on
      // (it needs pnpm and a matching version), so a profile named for it cannot be counted on.
      args: ['--profile', 'web', '--patch', path.join(dir, 'black-team.patch.json')],
      env: { DSH_HOME: dir },
      // It serves a page on this computer; the launcher picks the port and opens the page.
      page: true,
      files: { 'black-team.patch.json': [
        { id: 'llm-deepseek', disabled: true }, { id: 'llm-deepseek-account', disabled: true },
        { id: 'llm-pi-ai', config: { providers: { 'black-team': { apiKeyEnv: 'OPENAI_API_KEY', api: 'openai-completions', baseURL: endpoint,
          models: [{ id: model, name, contextWindow: context, maxTokens: Math.min(8192, Math.floor(context / 4)), input: ['text'] }],
          compat: { supportsStore: false, supportsDeveloperRole: false, maxTokensField: 'max_tokens' },
          timeoutMs: 1800000, streamIdleTimeoutMs: 1800000 } } } },
        { id: 'agent-default-model', config: { provider: 'black-team', model } },
        { id: 'session-title-llm', disabled: true },
      ] },
    }),
  },
  aider: {
    name: 'Aider', command: 'aider',
    build: ({ endpoint, model }) => ({ args: ['--openai-api-base', endpoint, '--model', `openai/${model}`], env: {} }),
  },
};

// Turns a preset into what the launcher adds. Files are written privately: one can hold the model's key.
function applyPreset(id, values, stateDir) {
  const preset = PRESETS[id];
  if (!preset) throw new Error('This harness uses a connection Black Team does not know. Remove it and connect it again.');
  const dir = path.join(stateDir, 'harnesses', id);
  const built = preset.build({ ...values, dir });
  if (built.files) {
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
    for (const [name, content] of Object.entries(built.files)) {
      const file = path.join(dir, name);
      fs.writeFileSync(file, `${JSON.stringify(content, null, 2)}\n`, { mode: 0o600 });
      fs.chmodSync(file, 0o600);
    }
  }
  return { args: built.args, env: built.env, page: built.page === true };
}

module.exports = { PRESETS, applyPreset };
