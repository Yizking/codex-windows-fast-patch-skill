const ENDPOINT = "ws://127.0.0.1:43123/ws";
const state = {
  socket: null,
  nextId: 1,
  pending: new Map(),
  threadId: null,
  activeTurnId: null,
  reconnectTimer: null,
  models: [],
  assistantNode: null,
};

const $ = (id) => document.getElementById(id);
const connection = $("connection");
const connectionLabel = $("connection-label");
const providerLabel = $("provider-label");
const modelSelect = $("model");
const reasoningSelect = $("reasoning");
const speedSelect = $("speed");
const cwdInput = $("cwd");
const messages = $("messages");
const emptyState = $("empty-state");
const statusLine = $("status-line");
const promptInput = $("prompt");
const sendButton = $("send");
const stopButton = $("stop");

function setConnection(stateName, label) {
  connection.dataset.state = stateName;
  connectionLabel.textContent = label;
}

function setStatus(message) {
  statusLine.textContent = message || "";
}

function rejectPending(reason) {
  for (const pending of state.pending.values()) pending.reject(new Error(reason));
  state.pending.clear();
}

function rpc(method, params, timeoutMs = 60000) {
  if (!state.socket || state.socket.readyState !== WebSocket.OPEN) {
    return Promise.reject(new Error("The local Codex app-server is offline."));
  }
  const id = state.nextId++;
  const message = {jsonrpc: "2.0", id, method};
  if (params !== undefined) message.params = params;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      state.pending.delete(id);
      reject(new Error(`${method} timed out`));
    }, timeoutMs);
    state.pending.set(id, {
      resolve: (value) => { clearTimeout(timer); resolve(value); },
      reject: (error) => { clearTimeout(timer); reject(error); },
    });
    try {
      state.socket.send(JSON.stringify(message));
    } catch (error) {
      state.pending.delete(id);
      clearTimeout(timer);
      reject(error);
    }
  });
}

function addMessage(kind, text) {
  if (!text) return null;
  emptyState.hidden = true;
  const node = document.createElement("div");
  node.className = `message ${kind}`;
  node.textContent = text;
  messages.appendChild(node);
  messages.scrollTop = messages.scrollHeight;
  return node;
}

function appendAssistantDelta(text) {
  if (!state.assistantNode) state.assistantNode = addMessage("assistant", "");
  state.assistantNode.textContent += text;
  messages.scrollTop = messages.scrollHeight;
}

function getTextFromItem(item) {
  if (!item || typeof item !== "object") return "";
  if (typeof item.text === "string") return item.text;
  if (!Array.isArray(item.content)) return "";
  return item.content.map((part) => {
    if (typeof part === "string") return part;
    return typeof part?.text === "string" ? part.text : "";
  }).join("");
}

function handleNotification(message) {
  const params = message.params || {};
  switch (message.method) {
    case "item/agentMessage/delta":
      appendAssistantDelta(params.delta || "");
      break;
    case "item/commandExecution/outputDelta":
    case "item/fileChange/outputDelta":
      setStatus("Codex is working...");
      break;
    case "item/started":
      if (params.item?.type === "agentMessage") state.assistantNode = null;
      break;
    case "item/completed": {
      const text = getTextFromItem(params.item);
      if (params.item?.type === "agentMessage" && text && !state.assistantNode) addMessage("assistant", text);
      break;
    }
    case "turn/completed":
      state.activeTurnId = null;
      stopButton.hidden = true;
      sendButton.disabled = false;
      setStatus(params.turn?.status === "completed" ? "Ready" : (params.turn?.error?.message || "Turn finished"));
      break;
    case "warning":
    case "configWarning":
      setStatus(params.message || params.summary || "Desktop configuration warning");
      break;
    default:
      break;
  }
}

function handleMessage(event) {
  let message;
  try { message = JSON.parse(event.data); } catch { return; }
  if (message.id !== undefined) {
    const pending = state.pending.get(message.id);
    if (!pending) return;
    state.pending.delete(message.id);
    if (message.error) pending.reject(new Error(message.error.message || "Codex request failed"));
    else pending.resolve(message.result);
    return;
  }
  if (message.method) handleNotification(message);
}

function modelById(id) { return state.models.find((model) => model.id === id); }

function renderSpeedOptions(model) {
  const tiers = new Set((model?.serviceTiers || []).map((tier) => tier.id));
  const current = speedSelect.value;
  speedSelect.replaceChildren();
  for (const option of [
    ["default", "Default", true],
    ["priority", "Fast", tiers.has("priority")],
    ["ultrafast", "Ultrafast", tiers.has("ultrafast")],
  ]) {
    const node = document.createElement("option");
    node.value = option[0];
    node.textContent = option[1] + (option[2] ? "" : " (unavailable)");
    node.disabled = !option[2];
    speedSelect.appendChild(node);
  }
  speedSelect.value = [...speedSelect.options].some((option) => option.value === current && !option.disabled)
    ? current : "default";
}

function renderModels(models) {
  state.models = models.filter((model) => !model.hidden);
  modelSelect.replaceChildren();
  for (const model of state.models) {
    const option = document.createElement("option");
    option.value = model.id;
    option.textContent = model.displayName || model.id;
    modelSelect.appendChild(option);
  }
  const saved = modelSelect.dataset.saved;
  const defaultModel = state.models.find((model) => model.isDefault) || state.models[0];
  modelSelect.value = modelById(saved)?.id || defaultModel?.id || "";
  renderReasoningOptions(modelById(modelSelect.value));
  renderSpeedOptions(modelById(modelSelect.value));
  if (defaultModel) providerLabel.textContent = `${defaultModel.displayName || defaultModel.id}`;
}

function renderReasoningOptions(model) {
  const supported = new Set((model?.supportedReasoningEfforts || []).map((item) => item.reasoningEffort));
  for (const option of reasoningSelect.options) option.disabled = supported.size > 0 && !supported.has(option.value);
  if (reasoningSelect.selectedOptions[0]?.disabled) reasoningSelect.value = model?.defaultReasoningEffort || "medium";
}

async function startThread() {
  state.threadId = null;
  state.activeTurnId = null;
  const params = {};
  if (modelSelect.value) params.model = modelSelect.value;
  if (cwdInput.value.trim()) params.cwd = cwdInput.value.trim();
  if (speedSelect.value !== "default") params.serviceTier = speedSelect.value;
  const result = await rpc("thread/start", params);
  state.threadId = result.thread.id;
  providerLabel.textContent = `${result.modelProvider} / ${result.model}`;
  setStatus(`Thread ready: ${result.modelProvider}`);
}

async function connect() {
  if (state.socket && state.socket.readyState <= WebSocket.OPEN) return;
  setConnection("offline", "Connecting...");
  const socket = new WebSocket(ENDPOINT, "codex-jsonrpc-v1");
  state.socket = socket;
  socket.onopen = async () => {
    setConnection("ready", "Desktop connected");
    try {
      await rpc("initialize", {clientInfo: {name: "codex-desktop-work-extension", version: "0.1.0"}});
      const models = await rpc("model/list", {includeHidden: true, limit: 100});
      renderModels(models.data || []);
      await startThread();
    } catch (error) {
      setConnection("error", "Protocol error");
      setStatus(error.message);
    }
  };
  socket.onmessage = handleMessage;
  socket.onerror = () => setConnection("error", "App-server unavailable");
  socket.onclose = () => {
    if (state.socket !== socket) return;
    rejectPending("The local Codex app-server disconnected.");
    state.threadId = null;
    state.activeTurnId = null;
    setConnection("offline", "Offline");
    stopButton.hidden = true;
    sendButton.disabled = false;
    if (!state.reconnectTimer) state.reconnectTimer = setTimeout(() => { state.reconnectTimer = null; connect(); }, 2500);
  };
}

async function activeTabContext() {
  if (!$("tab-context").checked || !chrome.tabs?.query) return "";
  try {
    const [tab] = await chrome.tabs.query({active: true, currentWindow: true});
    if (!tab) return "";
    const title = typeof tab.title === "string" ? tab.title : "";
    const url = typeof tab.url === "string" ? tab.url : "";
    return `\n\n[Active browser tab]\nTitle: ${title}\nURL: ${url}`;
  } catch { return ""; }
}

async function sendTurn(text) {
  if (!state.threadId) await startThread();
  addMessage("user", text);
  state.assistantNode = null;
  sendButton.disabled = true;
  stopButton.hidden = false;
  setStatus("Codex is working...");
  const params = {
    threadId: state.threadId,
    input: [{type: "text", text}],
  };
  if (modelSelect.value) params.model = modelSelect.value;
  if (reasoningSelect.value) params.effort = reasoningSelect.value;
  if (speedSelect.value !== "default") params.serviceTier = speedSelect.value;
  const result = await rpc("turn/start", params);
  state.activeTurnId = result.turn.id;
}

$("composer").addEventListener("submit", async (event) => {
  event.preventDefault();
  const prompt = promptInput.value.trim();
  if (!prompt || sendButton.disabled) return;
  promptInput.value = "";
  try { await sendTurn(prompt + await activeTabContext()); }
  catch (error) {
    sendButton.disabled = false;
    stopButton.hidden = true;
    addMessage("error", error.message);
    setStatus("Request failed");
  }
});

stopButton.addEventListener("click", async () => {
  if (!state.threadId || !state.activeTurnId) return;
  stopButton.disabled = true;
  try { await rpc("turn/interrupt", {threadId: state.threadId, turnId: state.activeTurnId}); }
  catch (error) { setStatus(error.message); }
  finally { stopButton.disabled = false; }
});

$("new-thread").addEventListener("click", async () => {
  try { await startThread(); setStatus("New thread ready"); }
  catch (error) { addMessage("error", error.message); }
});

modelSelect.addEventListener("change", () => {
  renderReasoningOptions(modelById(modelSelect.value));
  renderSpeedOptions(modelById(modelSelect.value));
});

chrome.storage?.local?.get(["codexWorkModel", "codexWorkCwd", "codexWorkReasoning", "codexWorkSpeed"]).then((saved) => {
  modelSelect.dataset.saved = saved.codexWorkModel || "";
  cwdInput.value = saved.codexWorkCwd || "";
  if (saved.codexWorkReasoning) reasoningSelect.value = saved.codexWorkReasoning;
  if (saved.codexWorkSpeed) speedSelect.value = saved.codexWorkSpeed;
}).catch(() => {}).finally(connect);

for (const control of [modelSelect, cwdInput, reasoningSelect, speedSelect]) control.addEventListener("change", () => {
  chrome.storage?.local?.set({
    codexWorkModel: modelSelect.value,
    codexWorkCwd: cwdInput.value,
    codexWorkReasoning: reasoningSelect.value,
    codexWorkSpeed: speedSelect.value,
  }).catch(() => {});
});
