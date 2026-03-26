(() => {
  const MESSAGE_TYPE = '__REQUESTMAN_RUNTIME_RULES__';
  const HIT_MESSAGE_TYPE = '__REQUESTMAN_RULE_HIT__';
  const RULES_KEY = 'asap_redirect_rules_v1';
  const GROUPS_KEY = 'asap_redirect_groups_v1';
  const ENABLED_KEY = 'asap_redirect_enabled_v1';
  const TOAST_VISIBLE_MS = 2000;
  const TOAST_ENTER_MS = 180;
  const TOAST_EXIT_MS = 160;
  const RULE_TYPE_ICON_DEFS = {
    redirect_request: {
      viewBox: '0 0 24 24',
      elements: [
        ['circle', { cx: '6', cy: '19', r: '3' }],
        ['path', { d: 'M9 19h8.5a3.5 3.5 0 0 0 0-7h-11a3.5 3.5 0 0 1 0-7H15' }],
        ['circle', { cx: '18', cy: '5', r: '3' }],
      ],
    },
    rewrite_string: {
      viewBox: '0 0 24 24',
      elements: [
        ['rect', { width: '18', height: '18', x: '3', y: '3', rx: '2' }],
        ['path', { d: 'M11 9h4a2 2 0 0 0 2-2V3' }],
        ['circle', { cx: '9', cy: '9', r: '2' }],
        ['path', { d: 'M7 21v-4a2 2 0 0 1 2-2h4' }],
        ['circle', { cx: '15', cy: '15', r: '2' }],
      ],
    },
    query_params: {
      viewBox: '0 0 24 24',
      elements: [
        ['path', { d: 'M20.341 6.484A10 10 0 0 1 10.266 21.85' }],
        ['path', { d: 'M3.659 17.516A10 10 0 0 1 13.74 2.152' }],
        ['circle', { cx: '12', cy: '12', r: '3' }],
        ['circle', { cx: '19', cy: '5', r: '2' }],
        ['circle', { cx: '5', cy: '19', r: '2' }],
      ],
    },
    modify_request_body: {
      viewBox: '0 0 24 24',
      elements: [
        ['rect', { width: '7', height: '9', x: '3', y: '3', rx: '1' }],
        ['rect', { width: '7', height: '5', x: '14', y: '3', rx: '1' }],
        ['rect', { width: '7', height: '9', x: '14', y: '12', rx: '1' }],
        ['rect', { width: '7', height: '5', x: '3', y: '16', rx: '1' }],
      ],
    },
    modify_response_body: {
      viewBox: '0 0 24 24',
      elements: [
        ['rect', { x: '14', y: '14', width: '4', height: '6', rx: '2' }],
        ['rect', { x: '6', y: '4', width: '4', height: '6', rx: '2' }],
        ['path', { d: 'M6 20h4' }],
        ['path', { d: 'M14 10h4' }],
        ['path', { d: 'M6 14h2v6' }],
        ['path', { d: 'M14 4h2v6' }],
      ],
    },
    modify_headers: {
      viewBox: '0 0 24 24',
      elements: [
        ['circle', { cx: '9', cy: '9', r: '7' }],
        ['circle', { cx: '15', cy: '15', r: '7' }],
      ],
    },
    user_agent: {
      viewBox: '0 0 24 24',
      elements: [
        ['path', { d: 'M19 21v-2a4 4 0 0 0-4-4H9a4 4 0 0 0-4 4v2' }],
        ['circle', { cx: '12', cy: '7', r: '4' }],
      ],
    },
    cancel_request: {
      viewBox: '0 0 24 24',
      elements: [
        ['circle', { cx: '12', cy: '12', r: '10' }],
        ['path', { d: 'm15 9-6 6' }],
        ['path', { d: 'm9 9 6 6' }],
      ],
    },
    request_delay: {
      viewBox: '0 0 24 24',
      elements: [
        ['path', { d: 'm12 14 4-4' }],
        ['path', { d: 'M3.34 19a10 10 0 1 1 17.32 0' }],
      ],
    },
  };

  let hitToast = null;
  let hitListNode = null;
  let hideToastTimer = null;
  let hideAnimationTimer = null;
  const renderedRuleKeys = new Set();

  function createRuleTypeIcon(ruleType) {
    const iconDef = RULE_TYPE_ICON_DEFS[ruleType] || RULE_TYPE_ICON_DEFS.redirect_request;
    const icon = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    icon.setAttribute('viewBox', iconDef.viewBox);
    icon.setAttribute('width', '14');
    icon.setAttribute('height', '14');
    icon.setAttribute('fill', 'none');
    icon.setAttribute('stroke', 'currentColor');
    icon.setAttribute('stroke-width', '2');
    icon.setAttribute('stroke-linecap', 'round');
    icon.setAttribute('stroke-linejoin', 'round');
    icon.setAttribute('aria-hidden', 'true');
    for (const [tagName, attrs] of iconDef.elements) {
      const element = document.createElementNS('http://www.w3.org/2000/svg', tagName);
      for (const [name, value] of Object.entries(attrs)) {
        element.setAttribute(name, value);
      }
      icon.appendChild(element);
    }
    return icon;
  }

  function ensureHitToast() {
    if (hitToast && hitListNode && document.documentElement.contains(hitToast)) {
      return { container: hitToast, list: hitListNode };
    }

    const container = document.createElement('div');
    container.id = '__requestman-hit-toast';
    container.style.position = 'fixed';
    container.style.top = '20px';
    container.style.left = '50%';
    container.style.transform = 'translateX(-50%)';
    container.style.zIndex = '2147483647';
    container.style.minWidth = '375px';
    container.style.maxWidth = '560px';
    container.style.background = 'rgba(20, 20, 24, 0.82)';
    container.style.backdropFilter = 'blur(12px)';
    container.style.webkitBackdropFilter = 'blur(12px)';
    container.style.color = '#f1f5f9';
    container.style.border = '1px solid rgba(148, 163, 184, 0.35)';
    container.style.borderRadius = '12px';
    container.style.boxShadow = [
      '0 0 0 0.5px rgba(0, 0, 0, 0.18)',
      '0 2px 4px rgba(0, 0, 0, 0.12)',
      '0 8px 16px rgba(0, 0, 0, 0.10)',
      '0 24px 48px rgba(0, 0, 0, 0.18)',
      '0 48px 80px rgba(0, 0, 0, 0.14)',
    ].join(', ');
    container.style.padding = '12px';
    container.style.boxSizing = 'border-box';
    container.style.fontFamily = "-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif";
    container.style.setProperty('text-align', 'left', 'important');
    container.style.display = 'none';
    container.style.opacity = '0';
    container.style.transition = `opacity ${TOAST_ENTER_MS}ms ease, transform ${TOAST_ENTER_MS}ms ease`;

    const header = document.createElement('div');
    header.style.display = 'flex';
    header.style.alignItems = 'center';
    header.style.justifyContent = 'space-between';
    header.style.height = '20px';

    const headerLeft = document.createElement('div');
    headerLeft.style.display = 'inline-flex';
    headerLeft.style.alignItems = 'center';
    headerLeft.style.gap = '8px';
    headerLeft.style.height = '20px';

    const logo = document.createElement('img');
    logo.src = chrome.runtime.getURL('assets/icon-hit-128.png');
    logo.alt = 'Requestman';
    logo.style.width = '16px';
    logo.style.height = '16px';

    const title = document.createElement('strong');
    title.textContent = 'Requestman';
    title.style.fontSize = '10px';
    title.style.lineHeight = '20px';
    title.style.letterSpacing = '0.2px';

    headerLeft.appendChild(logo);
    headerLeft.appendChild(title);

    const close = document.createElement('button');
    close.type = 'button';
    close.textContent = '✕';
    close.style.cursor = 'pointer';
    close.style.border = '0';
    close.style.background = 'transparent';
    close.style.color = '#e2e8f0';
    close.style.fontSize = '16px';
    close.style.lineHeight = '16px';
    close.style.padding = '0';
    close.style.width = '16px';
    close.style.height = '16px';
    close.style.display = 'inline-flex';
    close.style.alignItems = 'center';
    close.style.justifyContent = 'center';
    close.setAttribute('aria-label', '关闭');
    close.addEventListener('click', () => hideHitToast());

    header.appendChild(headerLeft);
    header.appendChild(close);

    const hint = document.createElement('div');
    hint.textContent = '以下规则已在当前页生效';
    hint.style.fontSize = '12px';
    hint.style.lineHeight = '16px';
    hint.style.marginTop = '16px';
    hint.style.setProperty('text-align', 'left', 'important');

    const list = document.createElement('ul');
    list.style.margin = '0';
    list.style.padding = '0';
    list.style.marginTop = '8px';
    list.style.display = 'grid';
    list.style.rowGap = '8px';
    list.style.fontSize = '14px';
    list.style.setProperty('text-align', 'left', 'important');

    container.appendChild(header);
    container.appendChild(hint);
    container.appendChild(list);
    (document.body || document.documentElement).appendChild(container);
    hitToast = container;
    hitListNode = list;

    return { container, list };
  }

  function showHitToast(container) {
    if (hideAnimationTimer) {
      clearTimeout(hideAnimationTimer);
      hideAnimationTimer = null;
    }

    if (container.style.display !== 'block') {
      container.style.display = 'block';
      container.style.opacity = '0';
      container.style.transform = 'translateX(-50%) translateY(-8px)';
      requestAnimationFrame(() => {
        container.style.opacity = '1';
        container.style.transform = 'translateX(-50%) translateY(0)';
      });
      return;
    }

    container.style.opacity = '1';
    container.style.transform = 'translateX(-50%) translateY(0)';
  }

  function hideHitToast() {
    if (hideToastTimer) {
      clearTimeout(hideToastTimer);
      hideToastTimer = null;
    }
    if (!hitToast) return;

    hitToast.style.opacity = '0';
    hitToast.style.transform = 'translateX(-50%) translateY(-8px)';

    if (hideAnimationTimer) clearTimeout(hideAnimationTimer);
    hideAnimationTimer = setTimeout(() => {
      if (!hitToast) return;
      hitToast.style.display = 'none';
      if (hitListNode) hitListNode.innerHTML = '';
      renderedRuleKeys.clear();
      hideAnimationTimer = null;
    }, TOAST_EXIT_MS);
  }

  function renderHitRecord(record) {
    const { container, list } = ensureHitToast();
    const ruleType = typeof record.ruleType === 'string' && record.ruleType ? record.ruleType : 'redirect_request';
    const ruleName = typeof record.ruleName === 'string' ? record.ruleName.trim() : '';
    if (!ruleName) return;
    const ruleId = typeof record.ruleId === 'string' ? record.ruleId.trim() : '';
    const dedupeKey = `${ruleType}::${ruleId || ruleName}`;

    if (renderedRuleKeys.has(dedupeKey)) {
      showHitToast(container);
      if (hideToastTimer) clearTimeout(hideToastTimer);
      hideToastTimer = setTimeout(() => {
        hideHitToast();
      }, TOAST_VISIBLE_MS);
      return;
    }
    renderedRuleKeys.add(dedupeKey);
    const item = document.createElement('li');
    item.style.listStyle = 'none';
    item.style.background = 'rgba(148, 163, 184, 0.08)';
    item.style.borderRadius = '8px';
    item.style.padding = '12px';
    item.style.display = 'flex';
    item.style.alignItems = 'center';
    item.style.gap = '8px';
    const icon = createRuleTypeIcon(ruleType);
    const nameNode = document.createElement('span');
    nameNode.style.fontSize = '14px';
    nameNode.style.lineHeight = '16px';
    nameNode.textContent = ruleName;
    item.appendChild(icon);
    item.appendChild(nameNode);
    list.appendChild(item);
    showHitToast(container);

    if (hideToastTimer) clearTimeout(hideToastTimer);
    hideToastTimer = setTimeout(() => {
      hideHitToast();
    }, TOAST_VISIBLE_MS);
  }

  function notifyContentReady() {
    chrome.runtime.sendMessage({ type: 'requestman:content-ready' }, () => {
      void chrome.runtime.lastError;
    });
  }

  const RULE_TYPE_LABEL_MAP = {
    redirect_request: 'Redirect Request',
    rewrite_string: 'Rewrite String',
    query_params: 'Query Params',
    modify_request_body: 'Modify Request Body',
    modify_response_body: 'Modify Response Body',
    modify_headers: 'Modify Headers',
    user_agent: 'User Agent',
    cancel_request: 'Cancel Request',
    request_delay: 'Request Delay',
  };

  function toRuleTypeLabel(ruleType) {
    if (typeof ruleType !== 'string') return 'Redirect Request';
    return RULE_TYPE_LABEL_MAP[ruleType] || ruleType;
  }

  function logRuleHit(record) {
    const ruleType = typeof record?.ruleType === 'string' ? record.ruleType : 'redirect_request';
    const ruleTypeLabel = toRuleTypeLabel(ruleType);
    const ruleName = typeof record?.ruleName === 'string' ? record.ruleName.trim() : '';
    const matchedUrl = typeof record?.url === 'string' ? record.url : '';
    if (!ruleName) return;
    const title = `[🔀 REQUESTMAN] 🧭 Rule hit ::: ${ruleTypeLabel} / ${ruleName}`;
    if (typeof console.groupCollapsed === 'function' && typeof console.groupEnd === 'function') {
      console.groupCollapsed(title);
      console.log({ rule: ruleTypeLabel, ruleName, matchedUrl });
      console.groupEnd();
      return;
    }
    console.log(title, { rule: ruleTypeLabel, ruleName, matchedUrl });
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

  function forwardInjectedHit(record) {
    const ruleName = typeof record.ruleName === 'string' ? record.ruleName.trim() : '';
    if (!ruleName) return;
    chrome.runtime.sendMessage({
      type: 'requestman:add-injected-hit',
      payload: { ruleName, ruleType: typeof record.ruleType === 'string' ? record.ruleType : 'redirect_request', url: typeof record.url === 'string' ? record.url : '' },
    }, () => { void chrome.runtime.lastError; });
  }

  window.addEventListener('message', (event) => {
    const data = event.data;
    if (!data || data.source !== 'requestman-extension' || data.type !== HIT_MESSAGE_TYPE) return;
    const payload = data.payload || {};
    logRuleHit(payload);
    renderHitRecord(payload);
    forwardInjectedHit(payload);
  });

  chrome.runtime.onMessage.addListener((message) => {
    if (!message || message.type !== 'requestman:rule-hit') return;
    logRuleHit(message.payload || {});
    renderHitRecord(message.payload || {});
  });

  broadcastRules();
  ensureHitToast();
  notifyContentReady();
  window.addEventListener('pageshow', () => {
    notifyContentReady();
  });
})();
