export type MatchTarget = 'url' | 'host';
export type MatchMode = 'equals' | 'contains' | 'regex' | 'wildcard';

type RedirectFilter = {
  pageDomain?: string;
  resourceType?: string;
  requestMethod?: string;
};

type RedirectCondition = {
  id?: string;
  matchTarget?: MatchTarget;
  matchMode?: MatchMode;
  expression?: string;
  redirectType?: 'url' | 'file';
  redirectTarget?: string;
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
  filter?: RedirectFilter;
};

export type RedirectRule = {
  id?: string;
  type?: 'redirect_request' | 'rewrite_string' | 'query_params' | 'modify_headers';
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

function escapeRegex(value: string) { return value.replace(/[|\\{}()[\]^$+?.]/g, '\\$&'); }
function wildcardToRegexBody(pattern: string) { return escapeRegex(pattern).replace(/\*/g, '.*'); }
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

function toOneRule(condition: RedirectCondition, index: number): chrome.declarativeNetRequest.Rule | null {
  const expression = typeof condition.expression === 'string' ? condition.expression.trim() : '';
  const redirectTarget = typeof condition.redirectTarget === 'string'
    ? condition.redirectTarget.trim()
    : typeof (condition as { redirectUrl?: string }).redirectUrl === 'string'
      ? ((condition as { redirectUrl?: string }).redirectUrl as string).trim()
      : '';
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

  const conditionRule: chrome.declarativeNetRequest.RuleCondition = { regexFilter, resourceTypes: ['main_frame', 'sub_frame', 'xmlhttprequest', 'script', 'image', 'font', 'media', 'stylesheet', 'object', 'ping', 'other'] };
  const filter = condition.filter ?? {};
  if (typeof filter.pageDomain === 'string' && filter.pageDomain.trim()) conditionRule.initiatorDomains = [filter.pageDomain.trim()];
  if (typeof filter.resourceType === 'string' && filter.resourceType !== 'all') conditionRule.resourceTypes = [filter.resourceType as chrome.declarativeNetRequest.ResourceType];
  if (typeof filter.requestMethod === 'string' && filter.requestMethod !== 'all') conditionRule.requestMethods = [filter.requestMethod.toUpperCase() as chrome.declarativeNetRequest.RequestMethod];

  return { id, priority: REDIRECT_RULE_ID_MAX - index, action, condition: conditionRule };
}

function toRewriteRule(condition: RedirectCondition, index: number): chrome.declarativeNetRequest.Rule | null {
  const expression = typeof condition.expression === 'string' ? condition.expression.trim() : '';
  const from = typeof condition.rewriteFrom === 'string' ? condition.rewriteFrom : '';
  const to = typeof condition.rewriteTo === 'string' ? condition.rewriteTo : '';
  if (!expression || !from) return null;
  const id = REDIRECT_RULE_ID_BASE + index;
  if (id > REDIRECT_RULE_ID_MAX) return null;

  const matchTarget: MatchTarget = condition.matchTarget === 'host' ? 'host' : 'url';
  const matchMode: MatchMode = ['equals', 'contains', 'regex', 'wildcard'].includes(condition.matchMode ?? '') ? (condition.matchMode as MatchMode) : 'regex';
  const conditionBody = matchTarget === 'host'
    ? buildHostRegex(matchMode, expression).replace(/^\^/, '').replace(/\$$/, '')
    : buildUrlRegex(matchMode, expression).replace(/^\^/, '').replace(/\$$/, '');
  const fromBody = matchMode === 'regex' ? from : escapeRegex(from);
  // Regex matching mode often already embeds `rewriteFrom` inside `expression`.
  // Avoid appending conditionBody before rewriteFrom, or we may require the token twice.
  const regexFilter = matchMode === 'regex'
    ? `^(.*)${fromBody}(.*)$`
    : `^(.*${conditionBody}.*)${fromBody}(.*)$`;
  try { new RegExp(regexFilter); } catch { return null; }

  const action: chrome.declarativeNetRequest.RuleAction = {
    type: 'redirect',
    redirect: { regexSubstitution: `\\1${normalizeRegexSubstitution(escapeRegexReplacement(to))}\\2` },
  };

  const conditionRule: chrome.declarativeNetRequest.RuleCondition = { regexFilter, resourceTypes: ['main_frame', 'sub_frame', 'xmlhttprequest', 'script', 'image', 'font', 'media', 'stylesheet', 'object', 'ping', 'other'] };
  const filter = condition.filter ?? {};
  if (typeof filter.pageDomain === 'string' && filter.pageDomain.trim()) conditionRule.initiatorDomains = [filter.pageDomain.trim()];
  if (typeof filter.resourceType === 'string' && filter.resourceType !== 'all') conditionRule.resourceTypes = [filter.resourceType as chrome.declarativeNetRequest.ResourceType];
  if (typeof filter.requestMethod === 'string' && filter.requestMethod !== 'all') conditionRule.requestMethods = [filter.requestMethod.toUpperCase() as chrome.declarativeNetRequest.RequestMethod];

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

  const conditionRule: chrome.declarativeNetRequest.RuleCondition = { regexFilter, resourceTypes: ['main_frame', 'sub_frame', 'xmlhttprequest', 'script', 'image', 'font', 'media', 'stylesheet', 'object', 'ping', 'other'] };
  const filter = condition.filter ?? {};
  if (typeof filter.pageDomain === 'string' && filter.pageDomain.trim()) conditionRule.initiatorDomains = [filter.pageDomain.trim()];
  if (typeof filter.resourceType === 'string' && filter.resourceType !== 'all') conditionRule.resourceTypes = [filter.resourceType as chrome.declarativeNetRequest.ResourceType];
  if (typeof filter.requestMethod === 'string' && filter.requestMethod !== 'all') conditionRule.requestMethods = [filter.requestMethod.toUpperCase() as chrome.declarativeNetRequest.RequestMethod];

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

  const mapHeaders = (modifications: RedirectCondition['requestHeaderModifications']) => (Array.isArray(modifications) ? modifications : [])
    .filter((mod) => typeof mod?.key === 'string' && mod.key.trim())
    .map((mod) => ({
      header: (mod.key as string).trim(),
      operation: mod.action === 'delete' ? 'remove' : mod.action === 'update' ? 'set' : 'append',
      ...(mod.action === 'delete' ? {} : { value: typeof mod.value === 'string' ? mod.value : '' }),
    }));

  const requestHeaders = mapHeaders(condition.requestHeaderModifications);
  const responseHeaders = mapHeaders(condition.responseHeaderModifications);
  if (!requestHeaders.length && !responseHeaders.length) return null;

  const action: chrome.declarativeNetRequest.RuleAction = {
    type: 'modifyHeaders',
    ...(requestHeaders.length ? { requestHeaders } : {}),
    ...(responseHeaders.length ? { responseHeaders } : {}),
  };

  const conditionRule: chrome.declarativeNetRequest.RuleCondition = { regexFilter, resourceTypes: ['main_frame', 'sub_frame', 'xmlhttprequest', 'script', 'image', 'font', 'media', 'stylesheet', 'object', 'ping', 'other'] };
  const filter = condition.filter ?? {};
  if (typeof filter.pageDomain === 'string' && filter.pageDomain.trim()) conditionRule.initiatorDomains = [filter.pageDomain.trim()];
  if (typeof filter.resourceType === 'string' && filter.resourceType !== 'all') conditionRule.resourceTypes = [filter.resourceType as chrome.declarativeNetRequest.ResourceType];
  if (typeof filter.requestMethod === 'string' && filter.requestMethod !== 'all') conditionRule.requestMethods = [filter.requestMethod.toUpperCase() as chrome.declarativeNetRequest.RequestMethod];

  return { id, priority: REDIRECT_RULE_ID_MAX - index, action, condition: conditionRule };
}

function getManagedRuleIds() { return Array.from({ length: REDIRECT_RULE_ID_MAX - REDIRECT_RULE_ID_BASE + 1 }, (_, i) => REDIRECT_RULE_ID_BASE + i); }

async function applyRedirectRules(payload: { groups?: RedirectGroup[]; rules?: RedirectRule[]; enabled?: boolean; }) {
  const groups = Array.isArray(payload.groups) ? payload.groups : [];
  const rules = Array.isArray(payload.rules) ? payload.rules : [];
  const enabled = payload.enabled !== false;
  const groupEnabled = new Map<string, boolean>();
  for (const group of groups) if (typeof group?.id === 'string' && group.id) groupEnabled.set(group.id, group.enabled !== false);

  const nextRules: chrome.declarativeNetRequest.Rule[] = [];
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
              : toOneRule(c, index);
        index += 1;
        if (dnr) nextRules.push(dnr);
      }
    }
  }

  await chrome.declarativeNetRequest.updateDynamicRules({ removeRuleIds: getManagedRuleIds(), addRules: nextRules });
  return { ok: true, activeCount: nextRules.length };
}

async function restoreRulesFromStorage() {
  const stored = await chrome.storage.local.get([REDIRECT_GROUPS_KEY, REDIRECT_RULES_KEY, REDIRECT_ENABLED_KEY]);
  await applyRedirectRules({ groups: stored?.[REDIRECT_GROUPS_KEY], rules: stored?.[REDIRECT_RULES_KEY], enabled: stored?.[REDIRECT_ENABLED_KEY] !== false });
}

chrome.runtime.onStartup.addListener(() => { restoreRulesFromStorage().catch(() => undefined); });
chrome.runtime.onInstalled.addListener(() => { restoreRulesFromStorage().catch(() => undefined); });
chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type !== 'redirectRules/apply') return;
  applyRedirectRules(message).then((result) => sendResponse(result)).catch((err: unknown) => sendResponse({ ok: false, error: err instanceof Error ? err.message : String(err) }));
  return true;
});
