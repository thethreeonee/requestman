import { STORAGE_KEY, defaultConfig, normalizeConfig } from './config.js';
import { buildDynamicRules } from './rules.js';

export function setupRedirectBackground() {
  chrome.runtime.onInstalled.addListener(async () => {
    const data = await chrome.storage.local.get(STORAGE_KEY);
    if (!data[STORAGE_KEY]) {
      await chrome.storage.local.set({ [STORAGE_KEY]: defaultConfig });
    }
    await syncDynamicRules();
  });

  chrome.runtime.onStartup.addListener(async () => {
    await syncDynamicRules();
  });

  chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
    if (message?.type === 'redirect:getConfig') {
      chrome.storage.local
        .get(STORAGE_KEY)
        .then((data) => sendResponse({ ok: true, config: data[STORAGE_KEY] || defaultConfig }))
        .catch((error) => sendResponse({ ok: false, error: String(error) }));
      return true;
    }

    if (message?.type === 'redirect:saveConfig') {
      const config = normalizeConfig(message.config);
      chrome.storage.local
        .set({ [STORAGE_KEY]: config })
        .then(syncDynamicRules)
        .then(() => sendResponse({ ok: true }))
        .catch((error) => sendResponse({ ok: false, error: String(error) }));
      return true;
    }

    return false;
  });
}

async function syncDynamicRules() {
  const current = await chrome.declarativeNetRequest.getDynamicRules();
  const removeRuleIds = current.map((rule) => rule.id);

  const data = await chrome.storage.local.get(STORAGE_KEY);
  const config = normalizeConfig(data[STORAGE_KEY] || defaultConfig);
  const addRules = buildDynamicRules(config);

  await chrome.declarativeNetRequest.updateDynamicRules({
    removeRuleIds,
    addRules
  });
}
