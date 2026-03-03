(() => {
  const MESSAGE_TYPE = '__REQUESTMAN_DELAY_RULES__';
  const RULES_KEY = 'asap_redirect_rules_v1';
  const GROUPS_KEY = 'asap_redirect_groups_v1';
  const ENABLED_KEY = 'asap_redirect_enabled_v1';

  function getActiveDelayConditions(payload) {
    const redirectEnabled = payload?.[ENABLED_KEY] !== false;
    if (!redirectEnabled) return [];

    const groups = Array.isArray(payload?.[GROUPS_KEY]) ? payload[GROUPS_KEY] : [];
    const groupEnabled = new Map();
    for (const group of groups) {
      if (group && typeof group.id === 'string' && group.id) {
        groupEnabled.set(group.id, group.enabled !== false);
      }
    }

    const rules = Array.isArray(payload?.[RULES_KEY]) ? payload[RULES_KEY] : [];
    const conditions = [];
    for (const rule of rules) {
      if (!rule || rule.type !== 'request_delay' || rule.enabled === false) continue;
      const groupId = typeof rule.groupId === 'string' ? rule.groupId : '';
      if (groupId && groupEnabled.get(groupId) === false) continue;

      const list = Array.isArray(rule.conditions) ? rule.conditions : [];
      for (const condition of list) {
        if (!condition || typeof condition.expression !== 'string' || !condition.expression.trim()) continue;
        const delayMs = Number.isFinite(condition.delayMs) ? Math.max(0, Math.floor(condition.delayMs)) : 0;
        if (!delayMs) continue;
        conditions.push({
          expression: condition.expression.trim(),
          matchTarget: condition.matchTarget === 'host' ? 'host' : 'url',
          matchMode: ['equals', 'contains', 'regex', 'wildcard'].includes(condition.matchMode) ? condition.matchMode : 'regex',
          delayMs,
          filter: condition.filter && typeof condition.filter === 'object' ? condition.filter : {},
        });
      }
    }
    return conditions;
  }

  function broadcastRules() {
    chrome.storage.local.get([RULES_KEY, GROUPS_KEY, ENABLED_KEY], (payload) => {
      window.postMessage({ source: 'requestman-extension', type: MESSAGE_TYPE, rules: getActiveDelayConditions(payload) }, '*');
    });
  }

  chrome.storage.onChanged.addListener((changes, areaName) => {
    if (areaName !== 'local') return;
    if (!(RULES_KEY in changes) && !(GROUPS_KEY in changes) && !(ENABLED_KEY in changes)) return;
    broadcastRules();
  });

  broadcastRules();
})();
