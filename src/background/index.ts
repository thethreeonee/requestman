import { getUserAgentByPresetKey } from '../requestman/user-agent-presets';
export type MatchTarget = 'url' | 'host';
export type MatchMode = 'equals' | 'contains' | 'regex' | 'wildcard';

type RedirectFilter = {
  pageDomain?: string;
  resourceType?: string;
  requestMethod?: string;
  requestHeaderKey?: string;
  requestHeaderOperator?: 'equals' | 'not_equals' | 'contains';
  requestHeaderValue?: string;
};

type RedirectCondition = {
  id?: string;
  matchTarget?: MatchTarget;
  matchMode?: MatchMode;
  expression?: string;
  redirectType?: 'url' | 'file';
  redirectTarget?: string;
  redirectUrlTarget?: string;
  redirectFileTarget?: string;
  rewriteFrom?: string;
  rewriteTo?: string;
  queryParamModifications?: Array<{
    action?: 'add' | 'update' | 'delete';
    key?: string;
    value?: string;
  }>;
  requestHeaderModifications?: Array<{
    action?: 'add' | 'update' | 'delete';
    key?: string;
    value?: string;
  }>;
  responseHeaderModifications?: Array<{
    action?: 'add' | 'update' | 'delete';
    key?: string;
    value?: string;
  }>;
  userAgentType?: 'device' | 'browser' | 'custom';
  userAgentPresetKey?: string;
  userAgentCustomValue?: string;
  delayMs?: number;
  requestBodyMode?: 'static' | 'dynamic';
  requestBodyValue?: string;
  filter?: RedirectFilter;
};

export type RedirectRule = {
  id?: string;
  name?: string;
  type?: 'redirect_request' | 'rewrite_string' | 'query_params' | 'modify_request_body' | 'modify_response_body' | 'modify_headers' | 'user_agent' | 'cancel_request' | 'request_delay';
  enabled?: boolean;
  groupId?: string;
  conditions?: RedirectCondition[];
  expression?: string;
  redirectUrl?: string;
  matchTarget?: MatchTarget;
  matchMode?: MatchMode;
};

export type RedirectGroup = { id?: string; enabled?: boolean };

export const REDIRECT_RULES_KEY = 'asap_redirect_rules_v1';
export const REDIRECT_ENABLED_KEY = 'asap_redirect_enabled_v1';
export const REDIRECT_GROUPS_KEY = 'asap_redirect_groups_v1';
export const REDIRECT_RULE_ID_BASE = 10000;
export const REDIRECT_RULE_ID_MAX = 19999;
const managedRuleMeta = new Map<number, { ruleName: string; ruleType: string }>();
let ruleCachesReady = false;
let ruleCachesPromise: Promise<void> | null = null;
const REQUESTMAN_PANEL_URL = chrome.runtime.getURL('requestman/index.html');

chrome.action.onClicked.addListener(() => {
  chrome.tabs.create({ url: REQUESTMAN_PANEL_URL });
});

function escapeRegex(value: string) { return value.replace(/[|\\{}()[\]^$+?.]/g, '\\$&'); }
function wildcardToRegexBody(pattern: string) { return escapeRegex(pattern).replace(/\*/g, '.*'); }
function escapeHeaderPattern(value: string) { return value.replace(/[?*\\]/g, '\\$&'); }
function buildHostRegex(mode: MatchMode, expression: string) {
  if (mode === 'contains') return `^https?://[^/]*${escapeRegex(expression)}[^/]*(?:/|$)`;
  if (mode === 'regex') return `^https?://(?:${expression})(?:/|$)`;
  if (mode === 'wildcard') return `^https?://${wildcardToRegexBody(expression)}(?:/|$)`;
  return `^https?://${escapeRegex(expression)}(?:/|$)`;
}
function buildUrlRegex(mode: MatchMode, expression: string) {
  if (mode === 'contains') return `^.*${escapeRegex(expression)}.*$`;
  if (mode === 'wildcard') return `^${wildcardToRegexBody(expression)}$`;
  if (mode === 'regex') return expression;
  return `^${escapeRegex(expression)}$`;
}
function normalizeRegexSubstitution(value: string) { return value.replace(/\$(\d+)/g, '\\$1'); }
function escapeRegexReplacement(value: string) { return value.replace(/\\/g, '\\\\').replace(/\$/g, '$$$$'); }

const ALL_RESOURCE_TYPES: chrome.declarativeNetRequest.ResourceType[] = ['main_frame', 'sub_frame', 'xmlhttprequest', 'script', 'image', 'font', 'media', 'stylesheet', 'object', 'ping', 'other'];
const VALID_RESOURCE_TYPES = new Set<string>([...ALL_RESOURCE_TYPES, 'websocket', 'webtransport', 'csp_report']);
const VALID_REQUEST_METHODS = new Set<string>(['connect', 'delete', 'get', 'head', 'options', 'patch', 'post', 'put']);

function normalizeDomainFilter(value: string): string {
  const raw = value.trim();
  if (!raw) return '';
  const withProtocol = /^https?:\/\//i.test(raw) ? raw : `https://${raw}`;
  try {
    return new URL(withProtocol).hostname;
  } catch {
    return raw.replace(/^https?:\/\//i, '').split('/')[0].split(':')[0].trim();
  }
}

function applyConditionFilters(conditionRule: chrome.declarativeNetRequest.RuleCondition, filter?: RedirectFilter) {
  const pageDomain = typeof filter?.pageDomain === 'string' ? normalizeDomainFilter(filter.pageDomain) : '';
  if (pageDomain) conditionRule.initiatorDomains = [pageDomain];

  const resourceType = typeof filter?.resourceType === 'string' ? filter.resourceType.trim().toLowerCase() : '';
  if (resourceType && resourceType !== 'all' && VALID_RESOURCE_TYPES.has(resourceType)) {
    conditionRule.resourceTypes = [resourceType as chrome.declarativeNetRequest.ResourceType];
  }

  const requestMethod = typeof filter?.requestMethod === 'string' ? filter.requestMethod.trim().toLowerCase() : '';
  if (requestMethod && requestMethod !== 'all' && VALID_REQUEST_METHODS.has(requestMethod)) {
    conditionRule.requestMethods = [requestMethod as chrome.declarativeNetRequest.RequestMethod];
  }

  const requestHeaderKey = typeof filter?.requestHeaderKey === 'string' ? filter.requestHeaderKey.trim().toLowerCase() : '';
  const requestHeaderValue = typeof filter?.requestHeaderValue === 'string' ? filter.requestHeaderValue.trim() : '';
  const requestHeaderOperator = filter?.requestHeaderOperator;
  if (requestHeaderKey && requestHeaderValue) {
    const headerFilter: chrome.declarativeNetRequest.HeaderInfo = {
      header: requestHeaderKey,
      ...(requestHeaderOperator === 'contains'
        ? { values: [`*${escapeHeaderPattern(requestHeaderValue)}*`] }
        : requestHeaderOperator === 'not_equals'
          ? { excludedValues: [escapeHeaderPattern(requestHeaderValue)] }
          : { values: [escapeHeaderPattern(requestHeaderValue)] }),
    };
    conditionRule.requestHeaders = [headerFilter];
  }
}

function toOneRule(condition: RedirectCondition, index: number): chrome.declarativeNetRequest.Rule | null {
  const expression = typeof condition.expression === 'string' ? condition.expression.trim() : '';
  const redirectTarget = condition.redirectType === 'file'
    ? (typeof condition.redirectFileTarget === 'string' && condition.redirectFileTarget.trim()
      ? condition.redirectFileTarget.trim()
      : typeof condition.redirectTarget === 'string'
        ? condition.redirectTarget.trim()
        : '')
    : (typeof condition.redirectUrlTarget === 'string' && condition.redirectUrlTarget.trim()
      ? condition.redirectUrlTarget.trim()
      : typeof condition.redirectTarget === 'string'
        ? condition.redirectTarget.trim()
        : typeof (condition as { redirectUrl?: string }).redirectUrl === 'string'
          ? ((condition as { redirectUrl?: string }).redirectUrl as string).trim()
          : '');
  if (!expression || !redirectTarget) return null;
  const id = REDIRECT_RULE_ID_BASE + index;
  if (id > REDIRECT_RULE_ID_MAX) return null;
  const matchTarget: MatchTarget = condition.matchTarget === 'host' ? 'host' : 'url';
  const matchMode: MatchMode = ['equals', 'contains', 'regex', 'wildcard'].includes(condition.matchMode ?? '') ? (condition.matchMode as MatchMode) : 'regex';
  const regexFilter = matchTarget === 'host' ? buildHostRegex(matchMode, expression) : buildUrlRegex(matchMode, expression);
  try { new RegExp(regexFilter); } catch { return null; }

  const action: chrome.declarativeNetRequest.RuleAction = {
    type: 'redirect',
    redirect: matchMode === 'regex' ? { regexSubstitution: normalizeRegexSubstitution(redirectTarget) } : { url: redirectTarget },
  };

  const conditionRule: chrome.declarativeNetRequest.RuleCondition = { regexFilter, resourceTypes: ALL_RESOURCE_TYPES };
  applyConditionFilters(conditionRule, condition.filter);

  return { id, priority: REDIRECT_RULE_ID_MAX - index, action, condition: conditionRule };
}

function makeRegexNonCapturing(expression: string): string {
  return expression.replace(/(^|[^\\])\((?!\?)/g, '$1(?:');
}

function buildRewriteUrlRegex(mode: MatchMode, expression: string, rewriteFrom: string): string {
  const escapedFrom = escapeRegex(rewriteFrom);
  if (mode === 'contains') return `^(.*${escapeRegex(expression)}.*?)${escapedFrom}(.*)$`;
  if (mode === 'wildcard') return `^(${wildcardToRegexBody(expression)}.*?)${escapedFrom}(.*)$`;
  if (mode === 'equals') {
    const idx = expression.indexOf(rewriteFrom);
    if (idx === -1) return '^\\b$';
    return `^(${escapeRegex(expression.slice(0, idx))})${escapedFrom}(${escapeRegex(expression.slice(idx + rewriteFrom.length))})$`;
  }
  // regex: split expression at rewriteFrom to create capture groups around it.
  // Avoids lookaheads which are not supported by RE2 (Chrome DNR regex engine).
  // Normalize user's capture groups to non-capturing so substitution group indexes remain stable.
  const ncExpression = makeRegexNonCapturing(expression);
  const fromIdx = ncExpression.indexOf(rewriteFrom);
  if (fromIdx !== -1) {
    const prefix = ncExpression.slice(0, fromIdx);
    const suffix = ncExpression.slice(fromIdx + rewriteFrom.length);
    const cleanPrefix = prefix.replace(/^\^/, '');
    const cleanSuffix = suffix.replace(/\$$/, '');
    return `^(${cleanPrefix})${escapedFrom}(${cleanSuffix})$`;
  }
  // Fallback: rewriteFrom not found literally in expression, match any URL containing it.
  return `^(.*)${escapedFrom}(.*)$`;
}

function buildRewriteHostRegex(mode: MatchMode, expression: string, rewriteFrom: string): string {
  const escapedFrom = escapeRegex(rewriteFrom);
  if (mode === 'contains') return `^(https?://[^/]*${escapeRegex(expression)}[^/]*(?:/|$).*?)${escapedFrom}(.*)$`;
  if (mode === 'wildcard') return `^(https?://${wildcardToRegexBody(expression)}(?:/|$).*?)${escapedFrom}(.*)$`;
  if (mode === 'regex') return `^(https?://(?:${expression})(?:/|$).*?)${escapedFrom}(.*)$`;
  return `^(https?://${escapeRegex(expression)}(?:/|$).*?)${escapedFrom}(.*)$`;
}

function toRewriteRule(condition: RedirectCondition, index: number): chrome.declarativeNetRequest.Rule | null {
  const expression = typeof condition.expression === 'string' ? condition.expression.trim() : '';
  const rewriteFrom = typeof condition.rewriteFrom === 'string' ? condition.rewriteFrom : '';
  const rewriteTo = typeof condition.rewriteTo === 'string' ? condition.rewriteTo : '';
  if (!expression || !rewriteFrom) return null;
  const id = REDIRECT_RULE_ID_BASE + index;
  if (id > REDIRECT_RULE_ID_MAX) return null;

  const matchTarget: MatchTarget = condition.matchTarget === 'host' ? 'host' : 'url';
  const matchMode: MatchMode = ['equals', 'contains', 'regex', 'wildcard'].includes(condition.matchMode ?? '') ? (condition.matchMode as MatchMode) : 'regex';
  const regexFilter = matchTarget === 'host'
    ? buildRewriteHostRegex(matchMode, expression, rewriteFrom)
    : buildRewriteUrlRegex(matchMode, expression, rewriteFrom);
  try { new RegExp(regexFilter); } catch { return null; }

  // In Chrome DNR regexSubstitution, only \ needs escaping; \N refers to capture groups.
  // rewrite_string regexFilter variants all capture before/after rewriteFrom in group 1/2.
  const escapedTo = rewriteTo.replace(/\\/g, '\\\\');
  const regexSubstitution = `\\1${escapedTo}\\2`;
  const action: chrome.declarativeNetRequest.RuleAction = {
    type: 'redirect',
    redirect: { regexSubstitution },
  };

  const conditionRule: chrome.declarativeNetRequest.RuleCondition = { regexFilter, resourceTypes: ALL_RESOURCE_TYPES };
  applyConditionFilters(conditionRule, condition.filter);

  return { id, priority: REDIRECT_RULE_ID_MAX - index, action, condition: conditionRule };
}

function toQueryParamsRule(condition: RedirectCondition, index: number): chrome.declarativeNetRequest.Rule | null {
  const expression = typeof condition.expression === 'string' ? condition.expression.trim() : '';
  if (!expression) return null;
  const id = REDIRECT_RULE_ID_BASE + index;
  if (id > REDIRECT_RULE_ID_MAX) return null;

  const matchTarget: MatchTarget = condition.matchTarget === 'host' ? 'host' : 'url';
  const matchMode: MatchMode = ['equals', 'contains', 'regex', 'wildcard'].includes(condition.matchMode ?? '') ? (condition.matchMode as MatchMode) : 'regex';
  const regexFilter = matchTarget === 'host' ? buildHostRegex(matchMode, expression) : buildUrlRegex(matchMode, expression);
  try { new RegExp(regexFilter); } catch { return null; }

  const modifications = Array.isArray(condition.queryParamModifications) ? condition.queryParamModifications : [];
  const addOrReplaceParams = modifications
    .filter((mod) => (mod.action === 'add' || mod.action === 'update') && typeof mod.key === 'string' && mod.key.trim())
    .map((mod) => ({
      key: (mod.key as string).trim(),
      value: typeof mod.value === 'string' ? mod.value : '',
      ...(mod.action === 'update' ? { replaceOnly: true } : {}),
    }));
  const removeParams = modifications
    .filter((mod) => mod.action === 'delete' && typeof mod.key === 'string' && mod.key.trim())
    .map((mod) => (mod.key as string).trim());
  if (addOrReplaceParams.length === 0 && removeParams.length === 0) return null;

  const action: chrome.declarativeNetRequest.RuleAction = {
    type: 'redirect',
    redirect: {
      transform: {
        queryTransform: {
          ...(addOrReplaceParams.length ? { addOrReplaceParams } : {}),
          ...(removeParams.length ? { removeParams } : {}),
        },
      },
    },
  };

  const conditionRule: chrome.declarativeNetRequest.RuleCondition = { regexFilter, resourceTypes: ALL_RESOURCE_TYPES };
  applyConditionFilters(conditionRule, condition.filter);

  return { id, priority: REDIRECT_RULE_ID_MAX - index, action, condition: conditionRule };
}



function toUserAgentRule(condition: RedirectCondition, index: number): chrome.declarativeNetRequest.Rule | null {
  const expression = typeof condition.expression === 'string' ? condition.expression.trim() : '';
  if (!expression) return null;
  const id = REDIRECT_RULE_ID_BASE + index;
  if (id > REDIRECT_RULE_ID_MAX) return null;

  const matchTarget: MatchTarget = condition.matchTarget === 'host' ? 'host' : 'url';
  const matchMode: MatchMode = ['equals', 'contains', 'regex', 'wildcard'].includes(condition.matchMode ?? '') ? (condition.matchMode as MatchMode) : 'regex';
  const regexFilter = matchTarget === 'host' ? buildHostRegex(matchMode, expression) : buildUrlRegex(matchMode, expression);
  try { new RegExp(regexFilter); } catch { return null; }

  const uaType = condition.userAgentType === 'browser' || condition.userAgentType === 'custom' ? condition.userAgentType : 'device';
  const userAgentValue = uaType === 'custom'
    ? (typeof condition.userAgentCustomValue === 'string' ? condition.userAgentCustomValue.trim() : '')
    : getUserAgentByPresetKey(typeof condition.userAgentPresetKey === 'string' ? condition.userAgentPresetKey : '');
  if (!userAgentValue) return null;

  const action: chrome.declarativeNetRequest.RuleAction = {
    type: 'modifyHeaders',
    requestHeaders: [{
      header: 'User-Agent',
      operation: 'set',
      value: userAgentValue,
    }],
  };

  const conditionRule: chrome.declarativeNetRequest.RuleCondition = { regexFilter, resourceTypes: ['main_frame', 'sub_frame', 'xmlhttprequest', 'script', 'image', 'font', 'media', 'stylesheet', 'object', 'ping', 'other'] };
  applyConditionFilters(conditionRule, condition.filter);

  return { id, priority: REDIRECT_RULE_ID_MAX - index, action, condition: conditionRule };
}

function toModifyHeadersRule(condition: RedirectCondition, index: number): chrome.declarativeNetRequest.Rule | null {
  const expression = typeof condition.expression === 'string' ? condition.expression.trim() : '';
  if (!expression) return null;
  const id = REDIRECT_RULE_ID_BASE + index;
  if (id > REDIRECT_RULE_ID_MAX) return null;

  const matchTarget: MatchTarget = condition.matchTarget === 'host' ? 'host' : 'url';
  const matchMode: MatchMode = ['equals', 'contains', 'regex', 'wildcard'].includes(condition.matchMode ?? '') ? (condition.matchMode as MatchMode) : 'regex';
  const regexFilter = matchTarget === 'host' ? buildHostRegex(matchMode, expression) : buildUrlRegex(matchMode, expression);
  try { new RegExp(regexFilter); } catch { return null; }

  const mapHeaders = (
    modifications: RedirectCondition['requestHeaderModifications'],
    target: 'request' | 'response',
  ) => (Array.isArray(modifications) ? modifications : [])
    .filter((mod) => typeof mod?.key === 'string' && mod.key.trim())
    .map((mod) => ({
      header: (mod.key as string).trim(),
      operation: mod.action === 'delete'
        ? 'remove'
        : mod.action === 'update'
          ? 'set'
          : target === 'request'
            ? 'set'
            : 'append',
      ...(mod.action === 'delete' ? {} : { value: typeof mod.value === 'string' ? mod.value : '' }),
    }));

  const requestHeaders = mapHeaders(condition.requestHeaderModifications, 'request');
  const responseHeaders = mapHeaders(condition.responseHeaderModifications, 'response');
  if (!requestHeaders.length && !responseHeaders.length) return null;

  const action: chrome.declarativeNetRequest.RuleAction = {
    type: 'modifyHeaders',
    ...(requestHeaders.length ? { requestHeaders } : {}),
    ...(responseHeaders.length ? { responseHeaders } : {}),
  };

  const conditionRule: chrome.declarativeNetRequest.RuleCondition = { regexFilter, resourceTypes: ALL_RESOURCE_TYPES };
  applyConditionFilters(conditionRule, condition.filter);

  return { id, priority: REDIRECT_RULE_ID_MAX - index, action, condition: conditionRule };
}


function toCancelRequestRule(condition: RedirectCondition, index: number): chrome.declarativeNetRequest.Rule | null {
  const expression = typeof condition.expression === 'string' ? condition.expression.trim() : '';
  if (!expression) return null;
  const id = REDIRECT_RULE_ID_BASE + index;
  if (id > REDIRECT_RULE_ID_MAX) return null;

  const matchTarget: MatchTarget = condition.matchTarget === 'host' ? 'host' : 'url';
  const matchMode: MatchMode = ['equals', 'contains', 'regex', 'wildcard'].includes(condition.matchMode ?? '') ? (condition.matchMode as MatchMode) : 'regex';
  const regexFilter = matchTarget === 'host' ? buildHostRegex(matchMode, expression) : buildUrlRegex(matchMode, expression);
  try { new RegExp(regexFilter); } catch { return null; }

  const action: chrome.declarativeNetRequest.RuleAction = {
    type: 'block',
  };

  const conditionRule: chrome.declarativeNetRequest.RuleCondition = { regexFilter, resourceTypes: ALL_RESOURCE_TYPES };
  applyConditionFilters(conditionRule, condition.filter);

  return { id, priority: REDIRECT_RULE_ID_MAX - index, action, condition: conditionRule };
}

function getManagedRuleIds() { return Array.from({ length: REDIRECT_RULE_ID_MAX - REDIRECT_RULE_ID_BASE + 1 }, (_, i) => REDIRECT_RULE_ID_BASE + i); }
const normalizeNumericId = (value: unknown) => {
  if (typeof value === 'number' && Number.isInteger(value)) return value;
  if (typeof value === 'string' && /^\d+$/.test(value)) return Number(value);
  return null;
};

function notifyMatchedRule(tabId: number, ruleId: number) {
  const meta = managedRuleMeta.get(ruleId);
  if (!meta || !meta.ruleName.trim()) return;
  chrome.tabs.sendMessage(tabId, { type: 'requestman:rule-hit', payload: meta }, () => {
    void chrome.runtime.lastError;
  });
}

async function applyRedirectRules(payload: { groups?: RedirectGroup[]; rules?: RedirectRule[]; enabled?: boolean; }) {
  const groups = Array.isArray(payload.groups) ? payload.groups : [];
  const rules = Array.isArray(payload.rules) ? payload.rules : [];
  const enabled = payload.enabled !== false;
  const groupEnabled = new Map<string, boolean>();
  for (const group of groups) if (typeof group?.id === 'string' && group.id) groupEnabled.set(group.id, group.enabled !== false);

  const nextRules: chrome.declarativeNetRequest.Rule[] = [];
  managedRuleMeta.clear();
  if (enabled) {
    let index = 0;
    for (const rule of rules) {
      if (rule.enabled === false) continue;
      const groupId = typeof rule.groupId === 'string' ? rule.groupId : '';
      if (!groupId || groupEnabled.get(groupId) === false) continue;
      const conditions = Array.isArray(rule.conditions) && rule.conditions.length
        ? rule.conditions
        : [{ expression: rule.expression, redirectTarget: rule.redirectUrl, matchMode: rule.matchMode, matchTarget: rule.matchTarget }];
      for (const c of conditions) {
        const dnr = rule.type === 'rewrite_string'
          ? toRewriteRule(c, index)
          : rule.type === 'query_params'
            ? toQueryParamsRule(c, index)
            : rule.type === 'modify_headers'
              ? toModifyHeadersRule(c, index)
              : rule.type === 'user_agent'
                ? toUserAgentRule(c, index)
                : rule.type === 'cancel_request'
                  ? toCancelRequestRule(c, index)
                  : rule.type === 'request_delay'
                    ? null
                    : toOneRule(c, index);
        index += 1;
        if (dnr) {
          nextRules.push(dnr);
          managedRuleMeta.set(dnr.id, {
            ruleName: typeof rule.name === 'string' ? rule.name : '',
            ruleType: typeof rule.type === 'string' ? rule.type : 'redirect_request',
          });
        }
      }
    }
  }

  await chrome.declarativeNetRequest.updateDynamicRules({ removeRuleIds: getManagedRuleIds(), addRules: nextRules });
  ruleCachesReady = true;
  return { ok: true, activeCount: nextRules.length };
}

async function restoreRulesFromStorage() {
  const stored = await chrome.storage.local.get([REDIRECT_GROUPS_KEY, REDIRECT_RULES_KEY, REDIRECT_ENABLED_KEY]);
  await applyRedirectRules({ groups: stored?.[REDIRECT_GROUPS_KEY], rules: stored?.[REDIRECT_RULES_KEY], enabled: stored?.[REDIRECT_ENABLED_KEY] !== false });
}

async function ensureRuleCachesReady() {
  if (ruleCachesReady) return;
  if (!ruleCachesPromise) {
    ruleCachesPromise = restoreRulesFromStorage()
      .then(() => {
        ruleCachesReady = true;
      })
      .catch(() => {
        ruleCachesReady = false;
      })
      .finally(() => {
        ruleCachesPromise = null;
      });
  }
  await ruleCachesPromise;
}

chrome.runtime.onStartup.addListener(() => { void ensureRuleCachesReady(); });
chrome.runtime.onInstalled.addListener(() => { void ensureRuleCachesReady(); });
chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type !== 'redirectRules/apply') return;
  applyRedirectRules(message).then((result) => sendResponse(result)).catch((err: unknown) => sendResponse({ ok: false, error: err instanceof Error ? err.message : String(err) }));
  return true;
});

if (chrome.declarativeNetRequest.onRuleMatchedDebug) {
  chrome.declarativeNetRequest.onRuleMatchedDebug.addListener((info) => {
    const tabId = normalizeNumericId(info.request?.tabId);
    const ruleId = normalizeNumericId(info.rule?.ruleId);
    if (tabId === null || tabId < 0 || ruleId === null) return;
    notifyMatchedRule(tabId, ruleId);
  });
}

void ensureRuleCachesReady();
