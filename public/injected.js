/**
 * 页面主世界脚本注入入口。
 *
 * 约定：只要插件需要向页面注入脚本，都统一放在此文件中，
 * 避免把注入逻辑分散到 background/content 等模块。
 */
(() => {
  const MESSAGE_TYPE = '__REQUESTMAN_RUNTIME_RULES__';
  const HIT_MESSAGE_TYPE = '__REQUESTMAN_RULE_HIT__';
  const SOURCE = 'requestman-extension';
  let delayRules = [];
  let modifyRequestBodyRules = [];
  let modifyResponseBodyRules = [];

  const nativeFetch = window.fetch;
  const nativeXhrOpen = window.XMLHttpRequest && window.XMLHttpRequest.prototype.open;
  const nativeXhrSend = window.XMLHttpRequest && window.XMLHttpRequest.prototype.send;

  function wildcardToRegExpBody(pattern) {
    return pattern.replace(/[|\\{}()[\]^$+?.]/g, '\\$&').replace(/\*/g, '.*');
  }

  function toAbsoluteUrl(rawUrl) {
    if (typeof rawUrl !== 'string' || !rawUrl) return '';
    try {
      return new URL(rawUrl, window.location.href).href;
    } catch {
      return rawUrl;
    }
  }

  function matchesRule(url, rule) {
    const expression = typeof rule.expression === 'string' ? rule.expression : '';
    if (!expression) return false;

    const normalizedUrl = toAbsoluteUrl(url);

    const targetValue = rule.matchTarget === 'host'
      ? (() => {
          try {
            return new URL(normalizedUrl).host;
          } catch {
            return '';
          }
        })()
      : normalizedUrl;

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

  function normalizeHeaderMap(headersLike) {
    const normalizedHeaders = new Map();
    if (!headersLike) return normalizedHeaders;

    const appendHeader = (key, value) => {
      const normalizedKey = String(key || '').trim().toLowerCase();
      if (!normalizedKey) return;
      const normalizedValue = String(value ?? '');
      if (normalizedHeaders.has(normalizedKey)) {
        normalizedHeaders.set(normalizedKey, `${normalizedHeaders.get(normalizedKey)}, ${normalizedValue}`);
      } else {
        normalizedHeaders.set(normalizedKey, normalizedValue);
      }
    };

    try {
      if (typeof Headers !== 'undefined' && headersLike instanceof Headers) {
        headersLike.forEach((value, key) => appendHeader(key, value));
        return normalizedHeaders;
      }

      if (Array.isArray(headersLike)) {
        for (const item of headersLike) {
          if (Array.isArray(item) && item.length >= 2) appendHeader(item[0], item[1]);
        }
        return normalizedHeaders;
      }

      if (typeof headersLike.forEach === 'function') {
        headersLike.forEach((value, key) => appendHeader(key, value));
        return normalizedHeaders;
      }

      if (typeof headersLike === 'object') {
        for (const [key, value] of Object.entries(headersLike)) appendHeader(key, value);
      }
    } catch {
      return normalizedHeaders;
    }

    return normalizedHeaders;
  }

  function matchHeaderFilter(filter, headersLike) {
    const requestHeaderKey = typeof filter?.requestHeaderKey === 'string' ? filter.requestHeaderKey.trim().toLowerCase() : '';
    const requestHeaderValue = typeof filter?.requestHeaderValue === 'string' ? filter.requestHeaderValue : '';
    if (!requestHeaderKey || !requestHeaderValue) return true;

    const requestHeaderOperator = filter?.requestHeaderOperator;
    const headers = normalizeHeaderMap(headersLike);
    const actualValue = headers.get(requestHeaderKey) || '';

    if (requestHeaderOperator === 'contains') return actualValue.includes(requestHeaderValue);
    if (requestHeaderOperator === 'not_equals') return actualValue !== requestHeaderValue;
    return actualValue === requestHeaderValue;
  }

  function shouldApplyRule(url, method, resourceType, headers, rule) {
    if (!matchFilter(method, resourceType, rule.filter)) return false;
    if (!matchHeaderFilter(rule.filter, headers)) return false;
    if (!matchesRule(url, rule)) return false;
    return true;
  }

  function reportRuleHit(rule) {
    window.postMessage({
      source: SOURCE,
      type: HIT_MESSAGE_TYPE,
      payload: {
        ruleName: typeof rule?.ruleName === 'string' ? rule.ruleName : '',
        ruleType: typeof rule?.ruleType === 'string' ? rule.ruleType : 'redirect_request',
      },
    }, '*');
  }

  function getDelayMs(url, method, resourceType, headers) {
    let maxDelayMs = 0;
    for (const rule of delayRules) {
      if (!shouldApplyRule(url, method, resourceType, headers, rule)) continue;
      reportRuleHit(rule);
      const delayMs = Number.isFinite(rule.delayMs) ? Math.max(0, Math.floor(rule.delayMs)) : 0;
      if (delayMs > maxDelayMs) maxDelayMs = delayMs;
    }
    return maxDelayMs;
  }

  function parseBodyAsJson(body) {
    if (!body || typeof body !== 'string') return null;
    try {
      return JSON.parse(body);
    } catch {
      return null;
    }
  }

  function normalizeBodyResult(result, fallbackBody) {
    if (result === undefined) return fallbackBody;
    if (result === null) return '';
    if (typeof result === 'string') return result;
    if (typeof result === 'object') return result;
    return String(result);
  }

  function toBodyValue(bodyResult) {
    if (typeof bodyResult === 'string') return bodyResult;
    if (bodyResult && typeof bodyResult === 'object') {
      try {
        return JSON.stringify(bodyResult);
      } catch {
        return String(bodyResult);
      }
    }
    return String(bodyResult ?? '');
  }

  function runDynamicBodyScript(script, args, fallbackBody, functionName) {
    try {
      const dynamicModifier = new Function(`${script}\nreturn typeof ${functionName} === 'function' ? ${functionName} : null;`)();
      if (typeof dynamicModifier !== 'function') return fallbackBody;
      const result = dynamicModifier(args);
      return normalizeBodyResult(result, fallbackBody);
    } catch {
      return fallbackBody;
    }
  }

  function resolveRequestBody(url, method, resourceType, headers, body) {
    if (typeof body !== 'string') return body;
    let nextBody = body;

    for (const rule of modifyRequestBodyRules) {
      if (!shouldApplyRule(url, method, resourceType, headers, rule)) continue;
      reportRuleHit(rule);

      if (rule.requestBodyMode === 'dynamic') {
        nextBody = runDynamicBodyScript(rule.requestBodyValue, {
          method: String(method || 'GET').toUpperCase(),
          url,
          body: nextBody,
          bodyAsJson: parseBodyAsJson(nextBody),
        }, nextBody, 'modifyRequestBody');
      } else {
        nextBody = rule.requestBodyValue;
      }
    }

    return nextBody;
  }

  function hasMatchedResponseRule(url, method, resourceType, headers) {
    for (const rule of modifyResponseBodyRules) {
      if (!shouldApplyRule(url, method, resourceType, headers, rule)) continue;
      reportRuleHit(rule);
      return true;
    }
    return false;
  }

  function resolveResponseBody(url, method, resourceType, headers, responseMeta, body) {
    if (typeof body !== 'string') return body;
    let nextBody = body;

    for (const rule of modifyResponseBodyRules) {
      if (!shouldApplyRule(url, method, resourceType, headers, rule)) continue;

      if (rule.responseBodyMode === 'dynamic') {
        nextBody = runDynamicBodyScript(rule.responseBodyValue, {
          method: String(method || 'GET').toUpperCase(),
          url,
          status: responseMeta.status,
          statusText: responseMeta.statusText,
          headers: responseMeta.headers,
          body: nextBody,
          bodyAsJson: parseBodyAsJson(nextBody),
        }, nextBody, 'modifyResponse');
      } else {
        nextBody = rule.responseBodyValue;
      }
    }

    return nextBody;
  }

  function wait(ms) {
    return new Promise((resolve) => {
      setTimeout(resolve, ms);
    });
  }

  window.addEventListener('message', (event) => {
    const data = event.data;
    if (!data || data.source !== SOURCE || data.type !== MESSAGE_TYPE) return;
    delayRules = Array.isArray(data.delayRules) ? data.delayRules : [];
    modifyRequestBodyRules = Array.isArray(data.modifyRequestBodyRules) ? data.modifyRequestBodyRules : [];
    modifyResponseBodyRules = Array.isArray(data.modifyResponseBodyRules) ? data.modifyResponseBodyRules : [];
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

      url = toAbsoluteUrl(url);
      const requestHeaders = init?.headers
        || (typeof Request !== 'undefined' && input instanceof Request ? input.headers : undefined);

      const delayMs = getDelayMs(url, method, 'xmlhttprequest', requestHeaders);
      if (delayMs > 0) await wait(delayMs);

      let body = null;
      if (typeof init?.body === 'string') {
        body = init.body;
      } else if (typeof Request !== 'undefined' && input instanceof Request && !init?.body) {
        body = await input.clone().text();
      }

      let nextInput = input;
      let nextInit = init;
      if (typeof body === 'string') {
        const nextBody = resolveRequestBody(url, method, 'xmlhttprequest', requestHeaders, body);
        const nextBodyValue = toBodyValue(nextBody);
        if (nextBodyValue !== body) {
          nextInit = { ...(init || {}), body: nextBodyValue, method };
        }
      }

      const response = await nativeFetch.call(this, nextInput, nextInit);
      if (!hasMatchedResponseRule(url, method, 'xmlhttprequest', requestHeaders)) return response;

      try {
        const originalBody = await response.clone().text();
        const nextBody = toBodyValue(resolveResponseBody(url, method, 'xmlhttprequest', requestHeaders, {
          status: response.status,
          statusText: response.statusText,
          headers: Object.fromEntries(response.headers.entries()),
        }, originalBody));
        if (nextBody === originalBody) return response;

        return new Response(nextBody, {
          status: response.status,
          statusText: response.statusText,
          headers: new Headers(response.headers),
        });
      } catch {
        return response;
      }
    };
  }

  if (nativeXhrOpen && nativeXhrSend) {
    const nativeXhrSetRequestHeader = window.XMLHttpRequest.prototype.setRequestHeader;

    window.XMLHttpRequest.prototype.open = function requestmanDelayedXhrOpen(method, url) {
      this.__requestmanMethod = method;
      this.__requestmanUrl = url;
      this.__requestmanHeaders = {};
      return nativeXhrOpen.apply(this, arguments);
    };

    if (nativeXhrSetRequestHeader) {
      window.XMLHttpRequest.prototype.setRequestHeader = function requestmanSetRequestHeader(key, value) {
        const normalizedKey = String(key || '').trim().toLowerCase();
        if (normalizedKey) {
          const existingValue = this.__requestmanHeaders?.[normalizedKey];
          const nextValue = String(value ?? '');
          this.__requestmanHeaders = this.__requestmanHeaders || {};
          this.__requestmanHeaders[normalizedKey] = existingValue ? `${existingValue}, ${nextValue}` : nextValue;
        }
        return nativeXhrSetRequestHeader.apply(this, arguments);
      };
    }

    window.XMLHttpRequest.prototype.send = function requestmanDelayedXhrSend(body) {
      const method = this.__requestmanMethod;
      const url = toAbsoluteUrl(this.__requestmanUrl);
      const requestHeaders = this.__requestmanHeaders || {};
      const delayMs = getDelayMs(url, method, 'xmlhttprequest', requestHeaders);
      const requestBody = typeof body === 'string'
        ? toBodyValue(resolveRequestBody(url, method, 'xmlhttprequest', requestHeaders, body))
        : body;

      if (hasMatchedResponseRule(url, method, 'xmlhttprequest', requestHeaders)) {
        this.addEventListener('readystatechange', () => {
          if (this.readyState !== 4) return;
          if (this.responseType && this.responseType !== 'text' && this.responseType !== 'json') return;

          try {
            const originalBody = this.responseType === 'json'
              ? JSON.stringify(this.response)
              : this.responseText;
            const nextBody = toBodyValue(resolveResponseBody(url, method, 'xmlhttprequest', requestHeaders, {
              status: this.status,
              statusText: this.statusText,
              headers: {},
            }, originalBody));
            if (nextBody === originalBody) return;

            Object.defineProperty(this, 'responseText', { configurable: true, get: () => nextBody });
            if (!this.responseType || this.responseType === 'text') {
              Object.defineProperty(this, 'response', { configurable: true, get: () => nextBody });
            } else if (this.responseType === 'json') {
              Object.defineProperty(this, 'response', {
                configurable: true,
                get: () => {
                  try {
                    return JSON.parse(nextBody);
                  } catch {
                    return null;
                  }
                },
              });
            }
          } catch {
            // ignore
          }
        });
      }

      if (delayMs <= 0) {
        return nativeXhrSend.call(this, requestBody);
      }
      setTimeout(() => {
        nativeXhrSend.call(this, requestBody);
      }, delayMs);
      return undefined;
    };
  }
})();
