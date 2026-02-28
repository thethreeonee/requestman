const STORAGE_KEY = 'redirectConfigV1';
const RULE_ID_BASE = 10_000;

const defaultConfig = {
  groups: []
};

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

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (msg?.type === 'redirect:getConfig') {
    chrome.storage.local
      .get(STORAGE_KEY)
      .then((data) => sendResponse({ ok: true, config: data[STORAGE_KEY] || defaultConfig }))
      .catch((err) => sendResponse({ ok: false, error: String(err) }));
    return true;
  }

  if (msg?.type === 'redirect:saveConfig') {
    const config = normalizeConfig(msg.config);
    chrome.storage.local
      .set({ [STORAGE_KEY]: config })
      .then(syncDynamicRules)
      .then(() => sendResponse({ ok: true }))
      .catch((err) => sendResponse({ ok: false, error: String(err) }));
    return true;
  }

  return false;
});

function normalizeConfig(input) {
  if (!input || !Array.isArray(input.groups)) {
    return { ...defaultConfig };
  }

  const groups = input.groups.map((group, gi) => ({
    id: String(group.id || `group-${Date.now()}-${gi}`),
    name: String(group.name || `规则组 ${gi + 1}`),
    enabled: Boolean(group.enabled),
    rules: Array.isArray(group.rules)
      ? group.rules.map((rule, ri) => ({
          id: String(rule.id || `rule-${Date.now()}-${gi}-${ri}`),
          enabled: Boolean(rule.enabled),
          scope: rule.scope === 'host' ? 'host' : 'url',
          matchType: ['contains', 'equals', 'regex', 'wildcard'].includes(rule.matchType)
            ? rule.matchType
            : 'contains',
          pattern: String(rule.pattern || ''),
          redirectTo: String(rule.redirectTo || '')
        }))
      : []
  }));

  return { groups };
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

function buildDynamicRules(config) {
  const rules = [];
  let nextId = RULE_ID_BASE;
  let priority = 1_000;

  for (const group of config.groups) {
    for (const rule of group.rules) {
      if (!group.enabled || !rule.enabled) {
        continue;
      }
      if (!rule.pattern || !rule.redirectTo) {
        continue;
      }

      const condition = buildCondition(rule);
      if (!condition) {
        continue;
      }

      const action = buildAction(rule);
      if (!action) {
        continue;
      }

      rules.push({
        id: nextId++,
        priority: priority--,
        action,
        condition: {
          ...condition,
          resourceTypes: ['main_frame', 'sub_frame', 'xmlhttprequest', 'script', 'image', 'font', 'stylesheet', 'media', 'object', 'ping', 'other']
        }
      });
    }
  }

  return rules;
}

function buildAction(rule) {
  if (rule.matchType === 'regex') {
    return {
      type: 'redirect',
      redirect: {
        regexSubstitution: rule.redirectTo
      }
    };
  }

  return {
    type: 'redirect',
    redirect: {
      url: rule.redirectTo
    }
  };
}

function buildCondition(rule) {
  const { scope, matchType, pattern } = rule;

  if (matchType === 'regex') {
    const source = scope === 'host' ? `^https?:\\/\\/(${pattern})(:\\d+)?(?:\\/|$)` : pattern;
    return { regexFilter: source };
  }

  if (matchType === 'wildcard') {
    const escaped = escapeForRegex(pattern).replace(/\\\*/g, '.*');
    const regex = scope === 'host'
      ? `^https?:\\/\\/${escaped}(?::\\d+)?(?:\\/|$)`
      : `^${escaped}$`;
    return { regexFilter: regex };
  }

  if (matchType === 'equals') {
    const regex = scope === 'host'
      ? `^https?:\\/\\/${escapeForRegex(pattern)}(?::\\d+)?(?:\\/|$)`
      : `^${escapeForRegex(pattern)}$`;
    return { regexFilter: regex };
  }

  if (matchType === 'contains') {
    const regex = scope === 'host'
      ? `^https?:\\/\\/[^/]*${escapeForRegex(pattern)}[^/]*(?::\\d+)?(?:\\/|$)`
      : escapeForRegex(pattern);
    return { regexFilter: regex };
  }

  return null;
}

function escapeForRegex(text) {
  return text.replace(/[.*+?^${}()|[\\]\\]/g, '\\$&');
}
