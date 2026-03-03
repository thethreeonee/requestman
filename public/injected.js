/**
 * 页面主世界脚本注入入口。
 *
 * 约定：只要插件需要向页面注入脚本，都统一放在此文件中，
 * 避免把注入逻辑分散到 background/content 等模块。
 */
(() => {
  const MESSAGE_TYPE = '__REQUESTMAN_DELAY_RULES__';
  const SOURCE = 'requestman-extension';
  let delayRules = [];

  const nativeFetch = window.fetch;
  const nativeXhrOpen = window.XMLHttpRequest && window.XMLHttpRequest.prototype.open;
  const nativeXhrSend = window.XMLHttpRequest && window.XMLHttpRequest.prototype.send;

  function wildcardToRegExpBody(pattern) {
    return pattern.replace(/[|\\{}()[\]^$+?.]/g, '\\$&').replace(/\*/g, '.*');
  }

  function matchesRule(url, rule) {
    const expression = typeof rule.expression === 'string' ? rule.expression : '';
    if (!expression) return false;

    const targetValue = rule.matchTarget === 'host'
      ? (() => {
          try {
            return new URL(url).host;
          } catch {
            return '';
          }
        })()
      : url;

    if (!targetValue) return false;

    try {
      if (rule.matchMode === 'equals') return targetValue === expression;
      if (rule.matchMode === 'contains') return targetValue.includes(expression);
      if (rule.matchMode === 'wildcard') return new RegExp(`^${wildcardToRegExpBody(expression)}$`).test(targetValue);
      return new RegExp(expression).test(targetValue);
    } catch {
      return false;
    }
  }

  function matchFilter(method, resourceType, filter) {
    const normalizedMethod = String(method || 'GET').toLowerCase();
    const normalizedResourceType = String(resourceType || 'xmlhttprequest').toLowerCase();
    const pageDomain = typeof filter?.pageDomain === 'string' ? filter.pageDomain.trim().toLowerCase() : '';
    if (pageDomain && pageDomain !== window.location.hostname.toLowerCase()) return false;

    const filterMethod = typeof filter?.requestMethod === 'string' ? filter.requestMethod.trim().toLowerCase() : '';
    if (filterMethod && filterMethod !== 'all' && filterMethod !== normalizedMethod) return false;

    const filterResourceType = typeof filter?.resourceType === 'string' ? filter.resourceType.trim().toLowerCase() : '';
    if (filterResourceType && filterResourceType !== 'all' && filterResourceType !== normalizedResourceType) return false;

    return true;
  }

  function getDelayMs(url, method, resourceType) {
    let maxDelayMs = 0;
    for (const rule of delayRules) {
      if (!matchFilter(method, resourceType, rule.filter)) continue;
      if (!matchesRule(url, rule)) continue;
      const delayMs = Number.isFinite(rule.delayMs) ? Math.max(0, Math.floor(rule.delayMs)) : 0;
      if (delayMs > maxDelayMs) maxDelayMs = delayMs;
    }
    return maxDelayMs;
  }

  function wait(ms) {
    return new Promise((resolve) => {
      setTimeout(resolve, ms);
    });
  }

  window.addEventListener('message', (event) => {
    const data = event.data;
    if (!data || data.source !== SOURCE || data.type !== MESSAGE_TYPE || !Array.isArray(data.rules)) return;
    delayRules = data.rules;
  });

  if (typeof nativeFetch === 'function') {
    window.fetch = async function requestmanDelayedFetch(input, init) {
      let url = '';
      let method = 'GET';

      if (typeof input === 'string') {
        url = input;
      } else if (input && typeof input === 'object') {
        if ('url' in input && typeof input.url === 'string') {
          url = input.url;
        }
        if ('method' in input && typeof input.method === 'string') {
          method = input.method;
        }
      }
      if (init && typeof init.method === 'string') method = init.method;

      const delayMs = getDelayMs(url, method, 'xmlhttprequest');
      if (delayMs > 0) await wait(delayMs);
      return nativeFetch.call(this, input, init);
    };
  }

  if (nativeXhrOpen && nativeXhrSend) {
    window.XMLHttpRequest.prototype.open = function requestmanDelayedXhrOpen(method, url) {
      this.__requestmanMethod = method;
      this.__requestmanUrl = url;
      return nativeXhrOpen.apply(this, arguments);
    };

    window.XMLHttpRequest.prototype.send = function requestmanDelayedXhrSend(body) {
      const delayMs = getDelayMs(this.__requestmanUrl, this.__requestmanMethod, 'xmlhttprequest');
      if (delayMs <= 0) {
        return nativeXhrSend.call(this, body);
      }
      setTimeout(() => {
        nativeXhrSend.call(this, body);
      }, delayMs);
      return undefined;
    };
  }
})();
