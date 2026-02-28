import { DEFAULT_GROUP_ID, DEFAULT_GROUP_NAME } from './constants';
import type { MatchMode, RedirectGroup, RedirectRule } from './types';

export function genId() {
  return typeof crypto !== 'undefined' && 'randomUUID' in crypto
    ? crypto.randomUUID()
    : `${Date.now()}_${Math.random().toString(16).slice(2)}`;
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
      const name = typeof obj.name === 'string' ? obj.name.trim() : '';
      return {
        id: rawId,
        name: name || '未命名分组',
        enabled: obj.enabled !== false,
      };
    })
    .filter(Boolean) as RedirectGroup[];

  if (groups.length > 0) return groups;
  return [{ id: DEFAULT_GROUP_ID, name: DEFAULT_GROUP_NAME, enabled: true }];
}

export function normalizeRules(
  input: unknown,
  groupIds: Set<string>,
  fallbackGroupId: string,
): RedirectRule[] {
  if (!Array.isArray(input)) return [];
  return input
    .map((it): RedirectRule | null => {
      if (!it || typeof it !== 'object') return null;
      const obj = it as Record<string, unknown>;
      const matchTarget = obj.matchTarget === 'host' ? 'host' : 'url';
      const modeSet = new Set<MatchMode>(['equals', 'contains', 'regex', 'wildcard']);
      const matchMode = modeSet.has(obj.matchMode as MatchMode)
        ? (obj.matchMode as MatchMode)
        : 'contains';
      return {
        id: typeof obj.id === 'string' && obj.id ? obj.id : genId(),
        enabled: obj.enabled !== false,
        groupId:
          typeof obj.groupId === 'string' && groupIds.has(obj.groupId)
            ? obj.groupId
            : fallbackGroupId,
        matchTarget,
        matchMode,
        expression: typeof obj.expression === 'string' ? obj.expression : '',
        redirectUrl: typeof obj.redirectUrl === 'string' ? obj.redirectUrl : '',
      };
    })
    .filter(Boolean) as RedirectRule[];
}

function escapeRegex(s: string) {
  return s.replace(/[|\\{}()[\]^$+?.]/g, '\\$&');
}

function wildcardToRegexBody(pattern: string) {
  return escapeRegex(pattern).replace(/\*/g, '.*');
}

function parseUrl(raw: string) {
  try {
    return new URL(raw);
  } catch {
    try {
      return new URL(raw, 'http://localhost');
    } catch {
      return null;
    }
  }
}

function buildHostRegex(mode: MatchMode, expression: string) {
  if (mode === 'contains') return `^https?://[^/]*${escapeRegex(expression)}[^/]*(?:/|$)`;
  if (mode === 'regex') return `^https?://(?:${expression})(?:/|$)`;
  if (mode === 'wildcard') return `^https?://${wildcardToRegexBody(expression)}(?:/|$)`;
  return `^https?://${escapeRegex(expression)}(?:/|$)`;
}

function replaceByGroups(redirectUrl: string, groups: RegExpExecArray | null) {
  return redirectUrl.replace(/\$(\d+)/g, (_m, idx) => groups?.[Number(idx)] ?? '');
}

export function isRuleEffectivelyEnabled(
  rule: RedirectRule,
  groupEnabledMap: ReadonlyMap<string, boolean>,
) {
  return rule.enabled && groupEnabledMap.get(rule.groupId) !== false;
}

export function simulateRedirect(
  inputUrl: string,
  rules: RedirectRule[],
  groupEnabledMap: ReadonlyMap<string, boolean>,
) {
  const parsed = parseUrl(inputUrl);
  if (!parsed) {
    return { ok: false as const, reason: 'URL 格式无效' };
  }

  const fullUrl = parsed.toString();
  const host = parsed.host;

  for (let i = 0; i < rules.length; i += 1) {
    const rule = rules[i];
    if (!isRuleEffectivelyEnabled(rule, groupEnabledMap)) continue;
    const expression = rule.expression.trim();
    const redirectUrl = rule.redirectUrl.trim();
    if (!expression || !redirectUrl) continue;

    if (rule.matchTarget === 'url') {
      if (rule.matchMode === 'equals' && fullUrl !== expression) continue;
      if (rule.matchMode === 'contains' && !fullUrl.includes(expression)) continue;
      if (rule.matchMode === 'wildcard') {
        let re: RegExp;
        try {
          re = new RegExp(`^${wildcardToRegexBody(expression)}$`);
        } catch {
          continue;
        }
        if (!re.test(fullUrl)) continue;
      }
      if (rule.matchMode === 'regex') {
        let re: RegExp;
        try {
          re = new RegExp(expression);
        } catch {
          continue;
        }
        const groups = re.exec(fullUrl);
        if (!groups) continue;
        return {
          ok: true as const,
          matchedIndex: i,
          matchedRule: rule,
          redirectedUrl: /\$\d+/.test(redirectUrl)
            ? replaceByGroups(redirectUrl, groups)
            : redirectUrl,
        };
      }

      return {
        ok: true as const,
        matchedIndex: i,
        matchedRule: rule,
        redirectedUrl: redirectUrl,
      };
    }

    if (rule.matchMode === 'equals' && host !== expression) continue;
    if (rule.matchMode === 'contains' && !host.includes(expression)) continue;

    const hostRegexPattern = buildHostRegex(rule.matchMode, expression);
    if (rule.matchMode === 'wildcard' || rule.matchMode === 'regex') {
      let re: RegExp;
      try {
        re = new RegExp(hostRegexPattern);
      } catch {
        continue;
      }
      const groups = re.exec(fullUrl);
      if (!groups) continue;
      return {
        ok: true as const,
        matchedIndex: i,
        matchedRule: rule,
        redirectedUrl:
          rule.matchMode === 'regex' && /\$\d+/.test(redirectUrl)
            ? replaceByGroups(redirectUrl, groups)
            : redirectUrl,
      };
    }

    return {
      ok: true as const,
      matchedIndex: i,
      matchedRule: rule,
      redirectedUrl: redirectUrl,
    };
  }

  return { ok: false as const, reason: '未命中任何启用规则' };
}
