import { DEFAULT_GROUP_ID, DEFAULT_GROUP_NAME } from './constants';
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
    redirectType: 'url',
    redirectTarget: '',
    filter: {
      pageDomain: '',
      resourceType: 'all',
      requestMethod: 'all',
    },
  };
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
          return {
            id: typeof c.id === 'string' && c.id ? c.id : genId(),
            matchTarget: c.matchTarget === 'host' ? 'host' : 'url',
            matchMode: modeSet.has(c.matchMode as MatchMode) ? (c.matchMode as MatchMode) : 'regex',
            expression: typeof c.expression === 'string' ? c.expression : '',
            redirectType: c.redirectType === 'file' ? 'file' : 'url',
            redirectTarget: typeof c.redirectTarget === 'string'
              ? c.redirectTarget
              : typeof c.redirectUrl === 'string'
                ? c.redirectUrl
                : '',
            filter: {
              pageDomain: typeof filterObj.pageDomain === 'string' ? filterObj.pageDomain : '',
              resourceType: typeof filterObj.resourceType === 'string' ? (filterObj.resourceType as RedirectCondition['filter']['resourceType']) : 'all',
              requestMethod: typeof filterObj.requestMethod === 'string' ? (filterObj.requestMethod as RedirectCondition['filter']['requestMethod']) : 'all',
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

function escapeRegex(s: string) { return s.replace(/[|\\{}()[\]^$+?.]/g, '\\$&'); }
function wildcardToRegexBody(pattern: string) { return escapeRegex(pattern).replace(/\*/g, '.*'); }

export function simulateRedirect(inputUrl: string, rules: RedirectRule[], groupEnabledMap: ReadonlyMap<string, boolean>) {
  for (const rule of rules) {
    if (!rule.enabled || groupEnabledMap.get(rule.groupId) === false) continue;
    for (const c of rule.conditions) {
      const expression = c.expression.trim();
      const redirectTarget = c.redirectTarget.trim();
      if (!expression || !redirectTarget) continue;
      let re: RegExp;
      try {
        if (c.matchMode === 'contains') re = new RegExp(escapeRegex(expression));
        else if (c.matchMode === 'equals') re = new RegExp(`^${escapeRegex(expression)}$`);
        else if (c.matchMode === 'wildcard') re = new RegExp(`^${wildcardToRegexBody(expression)}$`);
        else re = new RegExp(expression);
      } catch { continue; }
      const target = c.matchTarget === 'host' ? (new URL(inputUrl)).host : inputUrl;
      const groups = re.exec(target);
      if (!groups) continue;
      return { ok: true as const, matchedRule: rule, redirectedUrl: redirectTarget.replace(/\$(\d+)/g, (_m, i) => groups[Number(i)] ?? '') };
    }
  }
  return { ok: false as const, reason: '未命中任何启用规则' };
}
