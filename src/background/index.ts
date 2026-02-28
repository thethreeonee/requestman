export type MatchTarget = 'url' | 'host';
export type MatchMode = 'equals' | 'contains' | 'regex' | 'wildcard';

export type RedirectRule = {
  id?: string;
  enabled?: boolean;
  groupId?: string;
  matchTarget?: MatchTarget;
  matchMode?: MatchMode;
  expression?: string;
  redirectUrl?: string;
};

export type RedirectGroup = {
  id?: string;
  enabled?: boolean;
};

export const REDIRECT_RULES_KEY = 'asap_redirect_rules_v1';
export const REDIRECT_ENABLED_KEY = 'asap_redirect_enabled_v1';
export const REDIRECT_GROUPS_KEY = 'asap_redirect_groups_v1';
export const REDIRECT_RULE_ID_BASE = 10000;
export const REDIRECT_RULE_ID_MAX = 19999;

function escapeRegex(value: string) {
  return value.replace(/[|\\{}()[\]^$+?.]/g, '\\$&');
}

function wildcardToRegexBody(pattern: string) {
  return escapeRegex(pattern).replace(/\*/g, '.*');
}

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

function normalizeRegexSubstitution(redirectUrl: string) {
  return redirectUrl.replace(/\$(\d+)/g, '\\$1');
}

function toDnrRule(
  rule: RedirectRule,
  groupEnabled: ReadonlyMap<string, boolean>,
  index: number,
): chrome.declarativeNetRequest.Rule | null {
  if (!rule.enabled) return null;
  const groupId = typeof rule.groupId === 'string' ? rule.groupId : '';
  if (!groupId || groupEnabled.get(groupId) === false) return null;

  const expression = typeof rule.expression === 'string' ? rule.expression.trim() : '';
  const redirectUrl = typeof rule.redirectUrl === 'string' ? rule.redirectUrl.trim() : '';
  if (!expression || !redirectUrl) return null;

  const id = REDIRECT_RULE_ID_BASE + index;
  if (id > REDIRECT_RULE_ID_MAX) return null;

  const matchTarget: MatchTarget = rule.matchTarget === 'host' ? 'host' : 'url';
  const matchMode: MatchMode =
    rule.matchMode === 'equals' ||
    rule.matchMode === 'contains' ||
    rule.matchMode === 'regex' ||
    rule.matchMode === 'wildcard'
      ? rule.matchMode
      : 'contains';

  const regexFilter =
    matchTarget === 'host'
      ? buildHostRegex(matchMode, expression)
      : buildUrlRegex(matchMode, expression);

  try {
    new RegExp(regexFilter);
  } catch {
    return null;
  }

  const action: chrome.declarativeNetRequest.RuleAction = {
    type: 'redirect',
    redirect:
      matchMode === 'regex'
        ? { regexSubstitution: normalizeRegexSubstitution(redirectUrl) }
        : { url: redirectUrl },
  };

  return {
    id,
    priority: REDIRECT_RULE_ID_MAX - index,
    action,
    condition: {
      regexFilter,
      resourceTypes: ['main_frame', 'sub_frame', 'xmlhttprequest', 'script', 'image', 'font', 'media', 'stylesheet', 'object', 'ping', 'other'],
    },
  };
}

function getManagedRuleIds() {
  const ids: number[] = [];
  for (let id = REDIRECT_RULE_ID_BASE; id <= REDIRECT_RULE_ID_MAX; id += 1) {
    ids.push(id);
  }
  return ids;
}

async function applyRedirectRules(payload: {
  groups?: RedirectGroup[];
  rules?: RedirectRule[];
  enabled?: boolean;
}) {
  const groups = Array.isArray(payload.groups) ? payload.groups : [];
  const rules = Array.isArray(payload.rules) ? payload.rules : [];
  const enabled = payload.enabled !== false;

  const groupEnabled = new Map<string, boolean>();
  for (const group of groups) {
    if (typeof group?.id !== 'string' || !group.id) continue;
    groupEnabled.set(group.id, group.enabled !== false);
  }

  const nextRules: chrome.declarativeNetRequest.Rule[] = [];
  if (enabled) {
    rules.forEach((rule, index) => {
      const dnrRule = toDnrRule(rule, groupEnabled, index);
      if (dnrRule) nextRules.push(dnrRule);
    });
  }

  const removeRuleIds = getManagedRuleIds();
  await chrome.declarativeNetRequest.updateDynamicRules({
    removeRuleIds,
    addRules: nextRules,
  });

  return {
    ok: true,
    activeCount: nextRules.length,
    ignoredCount: Math.max(0, rules.length - nextRules.length),
  };
}


async function restoreRulesFromStorage() {
  const stored = await chrome.storage.local.get([
    REDIRECT_GROUPS_KEY,
    REDIRECT_RULES_KEY,
    REDIRECT_ENABLED_KEY,
  ]);

  await applyRedirectRules({
    groups: stored?.[REDIRECT_GROUPS_KEY],
    rules: stored?.[REDIRECT_RULES_KEY],
    enabled: stored?.[REDIRECT_ENABLED_KEY] !== false,
  });
}

chrome.runtime.onStartup.addListener(() => {
  restoreRulesFromStorage().catch(() => undefined);
});

chrome.runtime.onInstalled.addListener(() => {
  restoreRulesFromStorage().catch(() => undefined);
});

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type !== 'redirectRules/apply') return;

  applyRedirectRules(message)
    .then((result) => sendResponse(result))
    .catch((err: unknown) => {
      sendResponse({
        ok: false,
        error: err instanceof Error ? err.message : String(err),
      });
    });

  return true;
});
