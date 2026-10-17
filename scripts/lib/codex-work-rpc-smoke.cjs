#!/usr/bin/env node

const endpointIndex = process.argv.indexOf('--endpoint');
const endpoint = endpointIndex >= 0 ? process.argv[endpointIndex + 1] : 'ws://127.0.0.1:43123';
const turnSmoke = process.argv.includes('--turn-smoke');
const modelIndex = process.argv.indexOf('--model');
const requestedModel = modelIndex >= 0 ? process.argv[modelIndex + 1] : null;

if (typeof WebSocket !== 'function') {
  console.error('Node.js WebSocket is unavailable; use Node.js 22 or newer.');
  process.exit(2);
}

const socket = new WebSocket(endpoint);
const pending = new Map();
let nextId = 1;
let threadId = null;
let reply = '';
let selectedModel = null;
let modelCount = 0;
let provider = null;
let tier = null;
const timeout = setTimeout(() => fail('RPC smoke timed out'), turnSmoke ? 120000 : 30000);

function fail(message) {
  clearTimeout(timeout);
  console.error(message);
  try { socket.close(); } catch {}
  process.exit(1);
}

function call(method, params) {
  const id = nextId++;
  pending.set(id, method);
  const message = {jsonrpc: '2.0', id, method};
  if (params !== undefined) message.params = params;
  socket.send(JSON.stringify(message));
}

function finish(ok, result) {
  clearTimeout(timeout);
  console.log(JSON.stringify(result));
  try { socket.close(); } catch {}
  process.exit(ok ? 0 : 1);
}

socket.onerror = () => fail(`Unable to connect to ${endpoint}`);
socket.onopen = () => call('initialize', {
  clientInfo: {name: 'codex-work-bridge-smoke', version: '0.1.0'},
});
socket.onmessage = (event) => {
  let message;
  try { message = JSON.parse(event.data); } catch { return fail('App-server returned invalid JSON'); }
  if (message.id !== undefined) {
    const method = pending.get(message.id);
    pending.delete(message.id);
    if (message.error) return fail(`${method || 'RPC'} failed: ${message.error.message || 'unknown error'}`);
    if (method === 'initialize') {
      return call('model/list', {includeHidden: true, limit: 100});
    }
    if (method === 'model/list') {
      const models = Array.isArray(message.result?.data) ? message.result.data : [];
      modelCount = models.length;
      selectedModel = models.find((item) => item.id === requestedModel)
        || models.find((item) => item.isDefault)
        || models[0];
      if (!selectedModel) return fail('model/list returned no models');
      const params = {model: selectedModel.id};
      if (selectedModel.serviceTiers?.some((item) => item.id === 'priority')) params.serviceTier = 'priority';
      return call('thread/start', params);
    }
    if (method === 'thread/start') {
      threadId = message.result?.thread?.id || null;
      provider = message.result?.modelProvider || null;
      tier = message.result?.serviceTier || 'default';
      if (!threadId || !provider) return fail('thread/start did not return a provider and thread id');
      if (!turnSmoke) return finish(true, {
        endpoint,
        modelCount,
        model: message.result.model,
        modelProvider: provider,
        serviceTier: tier,
        turnSmoke: false,
      });
      return call('turn/start', {
        threadId,
        input: [{type: 'text', text: 'Reply with exactly CODEX_WORK_BRIDGE_SMOKE_OK.'}],
        effort: 'low',
        ...(tier === 'default' ? {} : {serviceTier: tier}),
      });
    }
    if (method === 'turn/start') return;
    return;
  }
  if (message.method === 'item/agentMessage/delta') reply += message.params?.delta || '';
  if (message.method === 'turn/completed') {
    const status = message.params?.turn?.status || 'unknown';
    finish(status === 'completed' && reply.includes('CODEX_WORK_BRIDGE_SMOKE_OK'), {
      endpoint,
      modelCount,
      model: selectedModel?.id || null,
      modelProvider: provider,
      serviceTier: tier,
      turnSmoke: true,
      turnStatus: status,
      marker: reply.includes('CODEX_WORK_BRIDGE_SMOKE_OK'),
    });
  }
};
