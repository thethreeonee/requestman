import { DEFAULT_GROUP_ID, DEFAULT_GROUP_NAME, DEFAULT_MODIFY_REQUEST_BODY_SCRIPT, DEFAULT_MODIFY_RESPONSE_BODY_SCRIPT } from './constants';
import type { MatchMode, RedirectCondition, RedirectGroup, RedirectRule } from './types';

const RULE_TYPES: RedirectRule['type'][] = [
  'redirect_request',
  'rewrite_string',
  'query_params',
  'modify_request_body',
  'modify_response_body',
  'modify_headers',
  'user_agent',
  'cancel_request',
  'request_delay',
];

export function genId() {
  return typeof crypto !== 'undefined' && 'randomUUID' in crypto
    ? crypto.randomUUID()
    : `${Date.now()}_${Math.random().toString(16).slice(2)}`;
}

export function createDefaultCondition(): RedirectCondition {
  return {
    id: genId(),
    matchTarget: 'url',
    matchMode: 'regex',
    expression: '',
    rewriteFrom: '',
    rewriteTo: '',
    redirectType: 'url',
    redirectTarget: '',
    redirectUrlTarget: '',
    redirectFileTarget: '',
    queryParamModifications: [{ id: genId(), action: 'add', key: '', value: '' }],
    requestHeaderModifications: [],
    responseHeaderModifications: [],
    userAgentType: 'device',
    userAgentPresetKey: 'android_phone',
    userAgentCustomValue: '',
    delayMs: 0,
    requestBodyMode: 'static',
    requestBodyStaticValue: '',
    requestBodyDynamicValue: DEFAULT_MODIFY_REQUEST_BODY_SCRIPT,
    requestBodyValue: '',
    responseBodyMode: 'static',
    responseBodyStaticValue: '',
    responseBodyDynamicValue: DEFAULT_MODIFY_RESPONSE_BODY_SCRIPT,
    responseBodyValue: '',
    filter: {
      pageDomain: '',
      resourceType: 'all',
      requestMethod: 'all',
      requestHeaderKey: '',
      requestHeaderOperator: 'equals',
      requestHeaderValue: '',
    },
  };
}

export function getConditionRedirectTarget(condition: Pick<RedirectCondition, 'redirectType' | 'redirectTarget' | 'redirectUrlTarget' | 'redirectFileTarget'>): string {
  if (condition.redirectType === 'file') {
    return (condition.redirectFileTarget ?? '').trim() || condition.redirectTarget.trim();
  }
  return (condition.redirectUrlTarget ?? '').trim() || condition.redirectTarget.trim();
}

export function normalizeGroups(input: unknown): RedirectGroup[] {
  if (!Array.isArray(input) || input.length === 0) {
    return [{ id: DEFAULT_GROUP_ID, name: DEFAULT_GROUP_NAME, enabled: true }];
  }
  const seen = new Set<string>();
  const groups = input
    .map((it): RedirectGroup | null => {
      if (!it || typeof it !== 'object') return null;
      const obj = it as Record<string, unknown>;
      const rawId = typeof obj.id === 'string' && obj.id.trim() ? obj.id.trim() : genId();
      if (seen.has(rawId)) return null;
      seen.add(rawId);
      return {
        id: rawId,
        name: typeof obj.name === 'string' && obj.name.trim() ? obj.name.trim() : '未命名分组',
        enabled: obj.enabled !== false,
      };
    })
    .filter(Boolean) as RedirectGroup[];

  return groups.length ? groups : [{ id: DEFAULT_GROUP_ID, name: DEFAULT_GROUP_NAME, enabled: true }];
}

export function normalizeRules(input: unknown, groupIds: Set<string>, fallbackGroupId: string): RedirectRule[] {
  if (!Array.isArray(input)) return [];
  const modeSet = new Set<MatchMode>(['equals', 'contains', 'regex', 'wildcard']);
  return input
    .map((it, idx): RedirectRule | null => {
      if (!it || typeof it !== 'object') return null;
      const obj = it as Record<string, unknown>;
      const conditionsInput = Array.isArray(obj.conditions) ? obj.conditions : null;
      const conditions = (conditionsInput ?? [obj])
        .map((cond): RedirectCondition | null => {
          if (!cond || typeof cond !== 'object') return null;
          const c = cond as Record<string, unknown>;
          const filterObj = c.filter && typeof c.filter === 'object' ? (c.filter as Record<string, unknown>) : {};
          const requestBodyMode = c.requestBodyMode === 'dynamic' ? 'dynamic' : 'static';
          const legacyBodyValue = typeof c.requestBodyValue === 'string'
            ? c.requestBodyValue
            : c.requestBodyScript && typeof c.requestBodyScript === 'string'
              ? c.requestBodyScript
              : '';
          const requestBodyStaticValue = typeof c.requestBodyStaticValue === 'string'
            ? c.requestBodyStaticValue
            : requestBodyMode === 'static'
              ? legacyBodyValue
              : '';
          const requestBodyDynamicValue = typeof c.requestBodyDynamicValue === 'string'
            ? c.requestBodyDynamicValue
            : requestBodyMode === 'dynamic' && legacyBodyValue
              ? legacyBodyValue
              : DEFAULT_MODIFY_REQUEST_BODY_SCRIPT;

          const responseBodyMode = c.responseBodyMode === 'dynamic' ? 'dynamic' : 'static';
          const legacyResponseBodyValue = typeof c.responseBodyValue === 'string'
            ? c.responseBodyValue
            : c.responseBodyScript && typeof c.responseBodyScript === 'string'
              ? c.responseBodyScript
              : '';
          const responseBodyStaticValue = typeof c.responseBodyStaticValue === 'string'
            ? c.responseBodyStaticValue
            : responseBodyMode === 'static'
              ? legacyResponseBodyValue
              : '';
          const responseBodyDynamicValue = typeof c.responseBodyDynamicValue === 'string'
            ? c.responseBodyDynamicValue
            : responseBodyMode === 'dynamic' && legacyResponseBodyValue
              ? legacyResponseBodyValue
              : DEFAULT_MODIFY_RESPONSE_BODY_SCRIPT;

          return {
            id: typeof c.id === 'string' && c.id ? c.id : genId(),
            matchTarget: c.matchTarget === 'host' ? 'host' : 'url',
            matchMode: modeSet.has(c.matchMode as MatchMode) ? (c.matchMode as MatchMode) : 'regex',
            expression: typeof c.expression === 'string' ? c.expression : '',
            rewriteFrom: typeof c.rewriteFrom === 'string' ? c.rewriteFrom : '',
            rewriteTo: typeof c.rewriteTo === 'string' ? c.rewriteTo : '',
            redirectType: c.redirectType === 'file' ? 'file' : 'url',
            redirectTarget: typeof c.redirectTarget === 'string'
              ? c.redirectTarget
              : typeof c.redirectUrl === 'string'
                ? c.redirectUrl
                : '',
            redirectUrlTarget: typeof c.redirectUrlTarget === 'string'
              ? c.redirectUrlTarget
              : c.redirectType === 'file'
                ? ''
                : typeof c.redirectTarget === 'string'
                  ? c.redirectTarget
                  : typeof c.redirectUrl === 'string'
                    ? c.redirectUrl
                    : '',
            redirectFileTarget: typeof c.redirectFileTarget === 'string'
              ? c.redirectFileTarget
              : c.redirectType === 'file'
                ? (typeof c.redirectTarget === 'string'
                  ? c.redirectTarget
                  : typeof c.redirectUrl === 'string'
                    ? c.redirectUrl
                    : '')
                : '',
            queryParamModifications: Array.isArray(c.queryParamModifications) && c.queryParamModifications.length > 0
              ? c.queryParamModifications
                .filter((item): item is Record<string, unknown> => !!item && typeof item === 'object')
                .map((item) => ({
                  id: typeof item.id === 'string' && item.id ? item.id : genId(),
                  action: item.action === 'update' || item.action === 'delete' ? item.action : 'add',
                  key: typeof item.key === 'string' ? item.key : '',
                  value: typeof item.value === 'string' ? item.value : '',
                }))
              : [{ id: genId(), action: 'add', key: '', value: '' }],
            requestHeaderModifications: Array.isArray(c.requestHeaderModifications) && c.requestHeaderModifications.length > 0
              ? c.requestHeaderModifications
                .filter((item): item is Record<string, unknown> => !!item && typeof item === 'object')
                .map((item) => ({
                  id: typeof item.id === 'string' && item.id ? item.id : genId(),
                  action: item.action === 'update' || item.action === 'delete' ? item.action : 'add',
                  key: typeof item.key === 'string' ? item.key : '',
                  value: typeof item.value === 'string' ? item.value : '',
                }))
              : [],
            responseHeaderModifications: Array.isArray(c.responseHeaderModifications) && c.responseHeaderModifications.length > 0
              ? c.responseHeaderModifications
                .filter((item): item is Record<string, unknown> => !!item && typeof item === 'object')
                .map((item) => ({
                  id: typeof item.id === 'string' && item.id ? item.id : genId(),
                  action: item.action === 'update' || item.action === 'delete' ? item.action : 'add',
                  key: typeof item.key === 'string' ? item.key : '',
                  value: typeof item.value === 'string' ? item.value : '',
                }))
              : [],
            userAgentType: c.userAgentType === 'browser' || c.userAgentType === 'custom' ? c.userAgentType : 'device',
            userAgentPresetKey: typeof c.userAgentPresetKey === 'string' && c.userAgentPresetKey ? c.userAgentPresetKey : 'android_phone',
            userAgentCustomValue: typeof c.userAgentCustomValue === 'string' ? c.userAgentCustomValue : '',
            delayMs: typeof c.delayMs === 'number' && Number.isFinite(c.delayMs) && c.delayMs >= 0 ? Math.floor(c.delayMs) : 0,
            requestBodyMode,
            requestBodyStaticValue,
            requestBodyDynamicValue,
            requestBodyValue: requestBodyMode === 'dynamic' ? requestBodyDynamicValue : requestBodyStaticValue,
            responseBodyMode,
            responseBodyStaticValue,
            responseBodyDynamicValue,
            responseBodyValue: responseBodyMode === 'dynamic' ? responseBodyDynamicValue : responseBodyStaticValue,
            filter: {
              pageDomain: typeof filterObj.pageDomain === 'string' ? filterObj.pageDomain : '',
              resourceType: typeof filterObj.resourceType === 'string' ? (filterObj.resourceType as RedirectCondition['filter']['resourceType']) : 'all',
              requestMethod: typeof filterObj.requestMethod === 'string' ? (filterObj.requestMethod as RedirectCondition['filter']['requestMethod']) : 'all',
              requestHeaderKey: typeof filterObj.requestHeaderKey === 'string' ? filterObj.requestHeaderKey : '',
              requestHeaderOperator: filterObj.requestHeaderOperator === 'not_equals' || filterObj.requestHeaderOperator === 'contains' ? filterObj.requestHeaderOperator : 'equals',
              requestHeaderValue: typeof filterObj.requestHeaderValue === 'string' ? filterObj.requestHeaderValue : '',
            },
          };
        })
        .filter(Boolean) as RedirectCondition[];

      return {
        id: typeof obj.id === 'string' && obj.id ? obj.id : genId(),
        name: typeof obj.name === 'string' && obj.name.trim() ? obj.name.trim() : `规则 ${idx + 1}`,
        type: RULE_TYPES.includes(obj.type as RedirectRule['type']) ? (obj.type as RedirectRule['type']) : 'redirect_request',
        enabled: obj.enabled !== false,
        groupId: typeof obj.groupId === 'string' && groupIds.has(obj.groupId) ? obj.groupId : fallbackGroupId,
        conditions: conditions.length ? conditions : [createDefaultCondition()],
      };
    })
    .filter(Boolean) as RedirectRule[];
}

export function hasModifyRequestBodyFunction(script: string): boolean {
  const trimmed = script.trim();
  if (!trimmed) return false;

  const declarationPatterns = [
    /\bfunction\s+modifyRequestBody\s*\(/,
    /\b(?:const|let|var)\s+modifyRequestBody\s*=\s*(?:async\s*)?(?:function\s*\(|\()/,
    /\b(?:const|let|var)\s+modifyRequestBody\s*=\s*(?:async\s*)?[A-Za-z_$][\w$]*\s*=>/,
  ];

  return declarationPatterns.some((pattern) => pattern.test(trimmed));
}

export function hasModifyResponseBodyFunction(script: string): boolean {
  const trimmed = script.trim();
  if (!trimmed) return false;

  const declarationPatterns = [
    /\bfunction\s+modifyResponse\s*\(/,
    /\b(?:const|let|var)\s+modifyResponse\s*=\s*(?:async\s*)?(?:function\s*\(|\()/,
    /\b(?:const|let|var)\s+modifyResponse\s*=\s*(?:async\s*)?[A-Za-z_$][\w$]*\s*=>/,
  ];

  return declarationPatterns.some((pattern) => pattern.test(trimmed));
}

function escapeRegex(s: string) { return s.replace(/[|\\{}()[\]^$+?.]/g, '\\$&'); }
function wildcardToRegexBody(pattern: string) { return escapeRegex(pattern).replace(/\*/g, '.*'); }

function buildHostRegex(mode: RedirectCondition['matchMode'], expression: string) {
  if (mode === 'contains') return `^https?://[^/]*${escapeRegex(expression)}[^/]*(?:/|$)`;
  if (mode === 'regex') return `^https?://(?:${expression})(?:/|$)`;
  if (mode === 'wildcard') return `^https?://${wildcardToRegexBody(expression)}(?:/|$)`;
  return `^https?://${escapeRegex(expression)}(?:/|$)`;
}

function buildUrlRegex(mode: RedirectCondition['matchMode'], expression: string) {
  if (mode === 'contains') return `^.*${escapeRegex(expression)}.*$`;
  if (mode === 'wildcard') return `^${wildcardToRegexBody(expression)}$`;
  if (mode === 'regex') return expression;
  return `^${escapeRegex(expression)}$`;
}

function createMatcher(condition: RedirectCondition) {
  const expression = condition.expression.trim();
  if (!expression) return null;
  try {
    const mode = condition.matchMode;
    const regexFilter = condition.matchTarget === 'host'
      ? buildHostRegex(mode, expression)
      : buildUrlRegex(mode, expression);
    return new RegExp(regexFilter);
  } catch {
    return null;
  }
}

function replaceCaptureGroups(template: string, groups: RegExpExecArray) {
  return template.replace(/\$(\d+)/g, (_m, i) => groups[Number(i)] ?? '');
}

export type SimulateRuleResult = {
  ok: true;
  matchedRule: RedirectRule;
  matchedCondition: RedirectCondition;
  redirectedUrl: string;
} | {
  ok: false;
  reason: string;
};

export function simulateRuleEffect(
  inputUrl: string,
  rules: RedirectRule[],
  groupEnabledMap: ReadonlyMap<string, boolean>,
  options?: { includeDisabled?: boolean },
): SimulateRuleResult {
  try {
    new URL(inputUrl);
  } catch {
    return { ok: false, reason: '请输入合法的 URL（需包含协议）' };
  }

  const includeDisabled = !!options?.includeDisabled;

  for (const rule of rules) {
    if (!includeDisabled && (!rule.enabled || groupEnabledMap.get(rule.groupId) === false)) continue;

    for (const condition of rule.conditions) {
      const re = createMatcher(condition);
      if (!re) continue;

      const groups = re.exec(inputUrl);
      if (!groups) continue;

      if (rule.type === 'redirect_request') {
        const redirectTarget = getConditionRedirectTarget(condition);
        if (!redirectTarget) continue;
        return {
          ok: true,
          matchedRule: rule,
          matchedCondition: condition,
          redirectedUrl: replaceCaptureGroups(redirectTarget, groups),
        };
      }

      if (rule.type === 'rewrite_string') {
        const rewriteFrom = condition.rewriteFrom;
        const rewriteTo = condition.rewriteTo;
        if (!rewriteFrom) continue;
        const outputUrl = inputUrl.split(rewriteFrom).join(replaceCaptureGroups(rewriteTo, groups));
        return {
          ok: true,
          matchedRule: rule,
          matchedCondition: condition,
          redirectedUrl: outputUrl,
        };
      }

      if (rule.type === 'query_params') {
        const next = new URL(inputUrl);
        for (const modification of condition.queryParamModifications) {
          const key = modification.key.trim();
          if (!key) continue;
          if (modification.action === 'delete') {
            next.searchParams.delete(key);
            continue;
          }
          if (modification.action === 'add' && next.searchParams.has(key)) continue;
          next.searchParams.set(key, replaceCaptureGroups(modification.value, groups));
        }
        return {
          ok: true,
          matchedRule: rule,
          matchedCondition: condition,
          redirectedUrl: next.toString(),
        };
      }

      return {
        ok: true,
        matchedRule: rule,
        matchedCondition: condition,
        redirectedUrl: inputUrl,
      };
    }
  }

  return { ok: false, reason: '未命中任何启用规则' };
}

export function simulateRedirect(inputUrl: string, rules: RedirectRule[], groupEnabledMap: ReadonlyMap<string, boolean>) {
  return simulateRuleEffect(inputUrl, rules, groupEnabledMap);
}
