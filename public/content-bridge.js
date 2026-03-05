(() => {
  const MESSAGE_TYPE = '__REQUESTMAN_RUNTIME_RULES__';
  const HIT_MESSAGE_TYPE = '__REQUESTMAN_RULE_HIT__';
  const RULES_KEY = 'asap_redirect_rules_v1';
  const GROUPS_KEY = 'asap_redirect_groups_v1';
  const ENABLED_KEY = 'asap_redirect_enabled_v1';
  const TOAST_VISIBLE_MS = 3000;
  const TOAST_ENTER_MS = 180;
  const TOAST_EXIT_MS = 160;
  const RULE_TYPE_ICON_DEFS = {
    redirect_request: { viewBox: '0 0 1024 1024', paths: ['M136 552h63.6c4.4 0 8-3.6 8-8V288.7h528.6v72.6c0 1.9.6 3.7 1.8 5.2a8.3 8.3 0 0011.7 1.4L893 255.4c4.3-5 3.6-10.3 0-13.2L749.7 129.8a8.22 8.22 0 00-5.2-1.8c-4.6 0-8.4 3.8-8.4 8.4V209H199.7c-39.5 0-71.7 32.2-71.7 71.8V544c0 4.4 3.6 8 8 8zm752-80h-63.6c-4.4 0-8 3.6-8 8v255.3H287.8v-72.6c0-1.9-.6-3.7-1.8-5.2a8.3 8.3 0 00-11.7-1.4L131 768.6c-4.3 5-3.6 10.3 0 13.2l143.3 112.4c1.5 1.2 3.3 1.8 5.2 1.8 4.6 0 8.4-3.8 8.4-8.4V815h536.6c39.5 0 71.7-32.2 71.7-71.8V480c-.2-4.4-3.8-8-8.2-8z'] },
    rewrite_string: { viewBox: '64 64 896 896', paths: ['M516 673c0 4.4 3.4 8 7.5 8h185c4.1 0 7.5-3.6 7.5-8v-48c0-4.4-3.4-8-7.5-8h-185c-4.1 0-7.5 3.6-7.5 8v48zm-194.9 6.1l192-161c3.8-3.2 3.8-9.1 0-12.3l-192-160.9A7.95 7.95 0 00308 351v62.7c0 2.4 1 4.6 2.9 6.1L420.7 512l-109.8 92.2a8.1 8.1 0 00-2.9 6.1V673c0 6.8 7.9 10.5 13.1 6.1zM880 112H144c-17.7 0-32 14.3-32 32v736c0 17.7 14.3 32 32 32h736c17.7 0 32-14.3 32-32V144c0-17.7-14.3-32-32-32zm-40 728H184V184h656v656z'] },
    query_params: { viewBox: '64 64 896 896', paths: ['M878.7 336H145.3c-18.4 0-33.3 14.3-33.3 32v464c0 17.7 14.9 32 33.3 32h733.3c18.4 0 33.3-14.3 33.3-32V368c.1-17.7-14.8-32-33.2-32zM360 792H184V632h176v160zm0-224H184V408h176v160zm240 224H424V632h176v160zm0-224H424V408h176v160zm240 224H664V632h176v160zm0-224H664V408h176v160zm64-408H120c-4.4 0-8 3.6-8 8v80c0 4.4 3.6 8 8 8h784c4.4 0 8-3.6 8-8v-80c0-4.4-3.6-8-8-8z'] },
    modify_request_body: { viewBox: '64 64 896 896', paths: ['M688 312v-48c0-4.4-3.6-8-8-8H296c-4.4 0-8 3.6-8 8v48c0 4.4 3.6 8 8 8h384c4.4 0 8-3.6 8-8zm-392 88c-4.4 0-8 3.6-8 8v48c0 4.4 3.6 8 8 8h184c4.4 0 8-3.6 8-8v-48c0-4.4-3.6-8-8-8H296zm144 452H208V148h560v344c0 4.4 3.6 8 8 8h56c4.4 0 8-3.6 8-8V108c0-17.7-14.3-32-32-32H168c-17.7 0-32 14.3-32 32v784c0 17.7 14.3 32 32 32h272c4.4 0 8-3.6 8-8v-56c0-4.4-3.6-8-8-8zm445.7 51.5l-93.3-93.3C814.7 780.7 828 743.9 828 704c0-97.2-78.8-176-176-176s-176 78.8-176 176 78.8 176 176 176c35.8 0 69-10.7 96.8-29l94.7 94.7c1.6 1.6 3.6 2.3 5.6 2.3s4.1-.8 5.6-2.3l31-31a7.9 7.9 0 000-11.2zM652 816c-61.9 0-112-50.1-112-112s50.1-112 112-112 112 50.1 112 112-50.1 112-112 112z'] },
    modify_response_body: { viewBox: '64 64 896 896', paths: ['M688 312v-48c0-4.4-3.6-8-8-8H296c-4.4 0-8 3.6-8 8v48c0 4.4 3.6 8 8 8h384c4.4 0 8-3.6 8-8zm-392 88c-4.4 0-8 3.6-8 8v48c0 4.4 3.6 8 8 8h184c4.4 0 8-3.6 8-8v-48c0-4.4-3.6-8-8-8H296zm376 116c-119.3 0-216 96.7-216 216s96.7 216 216 216 216-96.7 216-216-96.7-216-216-216zm107.5 323.5C750.8 868.2 712.6 884 672 884s-78.8-15.8-107.5-44.5C535.8 810.8 520 772.6 520 732s15.8-78.8 44.5-107.5C593.2 595.8 631.4 580 672 580s78.8 15.8 107.5 44.5C808.2 653.2 824 691.4 824 732s-15.8 78.8-44.5 107.5zM761 656h-44.3c-2.6 0-5 1.2-6.5 3.3l-63.5 87.8-23.1-31.9a7.92 7.92 0 00-6.5-3.3H573c-6.5 0-10.3 7.4-6.5 12.7l73.8 102.1c3.2 4.4 9.7 4.4 12.9 0l114.2-158c3.9-5.3.1-12.7-6.4-12.7zM440 852H208V148h560v344c0 4.4 3.6 8 8 8h56c4.4 0 8-3.6 8-8V108c0-17.7-14.3-32-32-32H168c-17.7 0-32 14.3-32 32v784c0 17.7 14.3 32 32 32h272c4.4 0 8-3.6 8-8v-56c0-4.4-3.6-8-8-8z'] },
    modify_headers: { viewBox: '64 64 896 896', paths: ['M917.7 148.8l-42.4-42.4c-1.6-1.6-3.6-2.3-5.7-2.3s-4.1.8-5.7 2.3l-76.1 76.1a199.27 199.27 0 00-112.1-34.3c-51.2 0-102.4 19.5-141.5 58.6L432.3 308.7a8.03 8.03 0 000 11.3L704 591.7c1.6 1.6 3.6 2.3 5.7 2.3 2 0 4.1-.8 5.7-2.3l101.9-101.9c68.9-69 77-175.7 24.3-253.5l76.1-76.1c3.1-3.2 3.1-8.3 0-11.4zM769.1 441.7l-59.4 59.4-186.8-186.8 59.4-59.4c24.9-24.9 58.1-38.7 93.4-38.7 35.3 0 68.4 13.7 93.4 38.7 24.9 24.9 38.7 58.1 38.7 93.4 0 35.3-13.8 68.4-38.7 93.4zm-190.2 105a8.03 8.03 0 00-11.3 0L501 613.3 410.7 523l66.7-66.7c3.1-3.1 3.1-8.2 0-11.3L441 408.6a8.03 8.03 0 00-11.3 0L363 475.3l-43-43a7.85 7.85 0 00-5.7-2.3c-2 0-4.1.8-5.7 2.3L206.8 534.2c-68.9 69-77 175.7-24.3 253.5l-76.1 76.1a8.03 8.03 0 000 11.3l42.4 42.4c1.6 1.6 3.6 2.3 5.7 2.3s4.1-.8 5.7-2.3l76.1-76.1c33.7 22.9 72.9 34.3 112.1 34.3 51.2 0 102.4-19.5 141.5-58.6l101.9-101.9c3.1-3.1 3.1-8.2 0-11.3l-43-43 66.7-66.7c3.1-3.1 3.1-8.2 0-11.3l-36.6-36.2zM441.7 769.1a131.32 131.32 0 01-93.4 38.7c-35.3 0-68.4-13.7-93.4-38.7a131.32 131.32 0 01-38.7-93.4c0-35.3 13.7-68.4 38.7-93.4l59.4-59.4 186.8 186.8-59.4 59.4z'] },
    user_agent: { viewBox: '64 64 896 896', paths: ['M858.5 763.6a374 374 0 00-80.6-119.5 375.63 375.63 0 00-119.5-80.6c-.4-.2-.8-.3-1.2-.5C719.5 518 760 444.7 760 362c0-137-111-248-248-248S264 225 264 362c0 82.7 40.5 156 102.8 201.1-.4.2-.8.3-1.2.5-44.8 18.9-85 46-119.5 80.6a375.63 375.63 0 00-80.6 119.5A371.7 371.7 0 00136 901.8a8 8 0 008 8.2h60c4.4 0 7.9-3.5 8-7.8 2-77.2 33-149.5 87.8-204.3 56.7-56.7 132-87.9 212.2-87.9s155.5 31.2 212.2 87.9C779 752.7 810 825 812 902.2c.1 4.4 3.6 7.8 8 7.8h60a8 8 0 008-8.2c-1-47.8-10.9-94.3-29.5-138.2zM512 534c-45.9 0-89.1-17.9-121.6-50.4S340 407.9 340 362c0-45.9 17.9-89.1 50.4-121.6S466.1 190 512 190s89.1 17.9 121.6 50.4S684 316.1 684 362c0 45.9-17.9 89.1-50.4 121.6S557.9 534 512 534z'] },
    cancel_request: { viewBox: '64 64 896 896', paths: ['M512 64C264.6 64 64 264.6 64 512s200.6 448 448 448 448-200.6 448-448S759.4 64 512 64zm0 820c-205.4 0-372-166.6-372-372 0-89 31.3-170.8 83.5-234.8l523.3 523.3C682.8 852.7 601 884 512 884zm288.5-137.2L277.2 223.5C341.2 171.3 423 140 512 140c205.4 0 372 166.6 372 372 0 89-31.3 170.8-83.5 234.8z'] },
    request_delay: { viewBox: '64 64 896 896', paths: ['M512 64C264.6 64 64 264.6 64 512s200.6 448 448 448 448-200.6 448-448S759.4 64 512 64zm0 820c-205.4 0-372-166.6-372-372s166.6-372 372-372 372 166.6 372 372-166.6 372-372 372z', 'M686.7 638.6L544.1 535.5V288c0-4.4-3.6-8-8-8H488c-4.4 0-8 3.6-8 8v275.4c0 2.6 1.2 5 3.3 6.5l165.4 120.6c3.6 2.6 8.6 1.8 11.2-1.7l28.6-39c2.6-3.7 1.8-8.7-1.8-11.2z'] },
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
    icon.setAttribute('fill', 'currentColor');
    icon.setAttribute('aria-hidden', 'true');
    for (const pathValue of iconDef.paths) {
      const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
      path.setAttribute('d', pathValue);
      icon.appendChild(path);
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
    container.style.top = '16px';
    container.style.right = '16px';
    container.style.zIndex = '2147483647';
    container.style.minWidth = '375px';
    container.style.maxWidth = '560px';
    container.style.background = 'rgba(20, 20, 24, 0.95)';
    container.style.color = '#f1f5f9';
    container.style.border = '1px solid rgba(148, 163, 184, 0.35)';
    container.style.borderRadius = '12px';
    container.style.boxShadow = '0 12px 32px rgba(0, 0, 0, 0.36)';
    container.style.padding = '8px';
    container.style.boxSizing = 'border-box';
    container.style.fontFamily = "-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif";
    container.style.display = 'none';
    container.style.opacity = '0';
    container.style.transform = 'translateX(12px)';
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
    logo.src = chrome.runtime.getURL('assets/icon.svg');
    logo.alt = 'Requestman';
    logo.style.width = '20px';
    logo.style.height = '20px';

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
    hint.style.marginTop = '12px';

    const list = document.createElement('ul');
    list.style.margin = '0';
    list.style.padding = '0';
    list.style.marginTop = '8px';
    list.style.display = 'grid';
    list.style.rowGap = '8px';
    list.style.fontSize = '14px';

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
      if (hitListNode) hitListNode.innerHTML = '';
      renderedRuleKeys.clear();
      container.style.display = 'block';
      container.style.opacity = '0';
      container.style.transform = 'translateX(12px)';
      requestAnimationFrame(() => {
        container.style.opacity = '1';
        container.style.transform = 'translateX(0)';
      });
      return;
    }

    container.style.opacity = '1';
    container.style.transform = 'translateX(0)';
  }

  function hideHitToast() {
    if (hideToastTimer) {
      clearTimeout(hideToastTimer);
      hideToastTimer = null;
    }
    if (!hitToast) return;

    hitToast.style.opacity = '0';
    hitToast.style.transform = 'translateX(12px)';

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

  window.addEventListener('message', (event) => {
    const data = event.data;
    if (!data || data.source !== 'requestman-extension' || data.type !== HIT_MESSAGE_TYPE) return;
    renderHitRecord(data.payload || {});
  });

  chrome.runtime.onMessage.addListener((message) => {
    if (!message || message.type !== 'requestman:rule-hit') return;
    renderHitRecord(message.payload || {});
  });

  broadcastRules();
})();
