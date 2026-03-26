(() => {
  const MESSAGE_TYPE = '__REQUESTMAN_RUNTIME_RULES__';
  const RULES_KEY = 'asap_redirect_rules_v1';
  const GROUPS_KEY = 'asap_redirect_groups_v1';
  const ENABLED_KEY = 'asap_redirect_enabled_v1';
  function logRuleHit(record) {
    const ruleType = typeof record?.ruleType === 'string' ? record.ruleType : 'redirect_request';
    const ruleName = typeof record?.ruleName === 'string' ? record.ruleName.trim() : '';
    if (!ruleName) return;
    console.log(`[🔀 REQUESTMAN] 🧭 Rule hit: ${ruleType} ::: ${ruleName}`);
  }

  function isGroupEnabled(groupEnabled, groupId) {
    if (!groupId) return true;
    return groupEnabled.get(groupId) !== false;
  }

  function getGroupEnabledMap(groups) {
    const groupEnabled = new Map();
    for (const group of groups) {
      if (group && typeof group.id === 'string' && group.id) {
        groupEnabled.set(group.id, group.enabled !== false);
      }
    }
    return groupEnabled;
  }

  function getActiveDelayConditions(rules, groupEnabled) {
    const conditions = [];
    for (const rule of rules) {
      if (!rule || rule.type !== 'request_delay' || rule.enabled === false) continue;
      if (!isGroupEnabled(groupEnabled, typeof rule.groupId === 'string' ? rule.groupId : '')) continue;

      const list = Array.isArray(rule.conditions) ? rule.conditions : [];
      for (const condition of list) {
        if (!condition || typeof condition.expression !== 'string' || !condition.expression.trim()) continue;
        const delayMs = Number.isFinite(condition.delayMs) ? Math.max(0, Math.floor(condition.delayMs)) : 0;
        if (!delayMs) continue;
        conditions.push({
          ruleName: typeof rule.name === 'string' ? rule.name : '',
          ruleId: typeof rule.id === 'string' ? rule.id : '',
          ruleType: 'request_delay',
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

  function getActiveModifyRequestBodyConditions(rules, groupEnabled) {
    const conditions = [];
    for (const rule of rules) {
      if (!rule || rule.type !== 'modify_request_body' || rule.enabled === false) continue;
      if (!isGroupEnabled(groupEnabled, typeof rule.groupId === 'string' ? rule.groupId : '')) continue;

      const list = Array.isArray(rule.conditions) ? rule.conditions : [];
      for (const condition of list) {
        if (!condition || typeof condition.expression !== 'string' || !condition.expression.trim()) continue;
        const requestBodyMode = condition.requestBodyMode === 'dynamic' ? 'dynamic' : 'static';
        const requestBodyStaticValue = typeof condition.requestBodyStaticValue === 'string'
          ? condition.requestBodyStaticValue
          : requestBodyMode === 'static' && typeof condition.requestBodyValue === 'string'
            ? condition.requestBodyValue
            : '';
        const requestBodyDynamicValue = typeof condition.requestBodyDynamicValue === 'string'
          ? condition.requestBodyDynamicValue
          : requestBodyMode === 'dynamic' && typeof condition.requestBodyValue === 'string'
            ? condition.requestBodyValue
            : typeof condition.requestBodyScript === 'string'
              ? condition.requestBodyScript
              : '';
        const requestBodyValue = requestBodyMode === 'dynamic' ? requestBodyDynamicValue : requestBodyStaticValue;
        if (!requestBodyValue.trim()) continue;
        conditions.push({
          ruleName: typeof rule.name === 'string' ? rule.name : '',
          ruleId: typeof rule.id === 'string' ? rule.id : '',
          ruleType: 'modify_request_body',
          expression: condition.expression.trim(),
          matchTarget: condition.matchTarget === 'host' ? 'host' : 'url',
          matchMode: ['equals', 'contains', 'regex', 'wildcard'].includes(condition.matchMode) ? condition.matchMode : 'regex',
          requestBodyMode,
          requestBodyValue,
          filter: condition.filter && typeof condition.filter === 'object' ? condition.filter : {},
        });
      }
    }
    return conditions;
  }


  function getActiveModifyResponseBodyConditions(rules, groupEnabled) {
    const conditions = [];
    for (const rule of rules) {
      if (!rule || rule.type !== 'modify_response_body' || rule.enabled === false) continue;
      if (!isGroupEnabled(groupEnabled, typeof rule.groupId === 'string' ? rule.groupId : '')) continue;

      const list = Array.isArray(rule.conditions) ? rule.conditions : [];
      for (const condition of list) {
        if (!condition || typeof condition.expression !== 'string' || !condition.expression.trim()) continue;
        const responseBodyMode = condition.responseBodyMode === 'dynamic' ? 'dynamic' : 'static';
        const responseBodyStaticValue = typeof condition.responseBodyStaticValue === 'string'
          ? condition.responseBodyStaticValue
          : responseBodyMode === 'static' && typeof condition.responseBodyValue === 'string'
            ? condition.responseBodyValue
            : '';
        const responseBodyDynamicValue = typeof condition.responseBodyDynamicValue === 'string'
          ? condition.responseBodyDynamicValue
          : responseBodyMode === 'dynamic' && typeof condition.responseBodyValue === 'string'
            ? condition.responseBodyValue
            : typeof condition.responseBodyScript === 'string'
              ? condition.responseBodyScript
              : '';
        const responseBodyValue = responseBodyMode === 'dynamic' ? responseBodyDynamicValue : responseBodyStaticValue;
        if (!responseBodyValue.trim()) continue;
        conditions.push({
          ruleName: typeof rule.name === 'string' ? rule.name : '',
          ruleId: typeof rule.id === 'string' ? rule.id : '',
          ruleType: 'modify_response_body',
          expression: condition.expression.trim(),
          matchTarget: condition.matchTarget === 'host' ? 'host' : 'url',
          matchMode: ['equals', 'contains', 'regex', 'wildcard'].includes(condition.matchMode) ? condition.matchMode : 'regex',
          responseBodyMode,
          responseBodyValue,
          filter: condition.filter && typeof condition.filter === 'object' ? condition.filter : {},
        });
      }
    }
    return conditions;
  }

  function broadcastRules() {
    chrome.storage.local.get([RULES_KEY, GROUPS_KEY, ENABLED_KEY], (payload) => {
      const redirectEnabled = payload?.[ENABLED_KEY] !== false;
      const groups = Array.isArray(payload?.[GROUPS_KEY]) ? payload[GROUPS_KEY] : [];
      const rules = Array.isArray(payload?.[RULES_KEY]) ? payload[RULES_KEY] : [];
      const groupEnabled = getGroupEnabledMap(groups);

      window.postMessage({
        source: 'requestman-extension',
        type: MESSAGE_TYPE,
        delayRules: redirectEnabled ? getActiveDelayConditions(rules, groupEnabled) : [],
        modifyRequestBodyRules: redirectEnabled ? getActiveModifyRequestBodyConditions(rules, groupEnabled) : [],
        modifyResponseBodyRules: redirectEnabled ? getActiveModifyResponseBodyConditions(rules, groupEnabled) : [],
      }, '*');
    });
  }

  chrome.storage.onChanged.addListener((changes, areaName) => {
    if (areaName !== 'local') return;
    if (!(RULES_KEY in changes) && !(GROUPS_KEY in changes) && !(ENABLED_KEY in changes)) return;
    broadcastRules();
  });

  chrome.runtime.onMessage.addListener((message) => {
    if (!message || message.type !== 'requestman:rule-hit') return;
    logRuleHit(message.payload || {});
  });

  broadcastRules();
})();
