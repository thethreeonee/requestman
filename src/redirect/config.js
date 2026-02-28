export const STORAGE_KEY = 'redirectConfigV1';

export const defaultConfig = {
  groups: []
};

export function uid(prefix) {
  return `${prefix}-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
}

export function createGroup(count = 0) {
  return {
    id: uid('group'),
    name: `规则组 ${count + 1}`,
    enabled: true,
    rules: []
  };
}

export function createRule() {
  return {
    id: uid('rule'),
    enabled: true,
    scope: 'url',
    matchType: 'contains',
    pattern: '',
    redirectTo: ''
  };
}

export function normalizeConfig(input) {
  if (!input || !Array.isArray(input.groups)) {
    return { ...defaultConfig };
  }

  const groups = input.groups.map((group, gi) => ({
    id: String(group.id || `group-${Date.now()}-${gi}`),
    name: String(group.name || `规则组 ${gi + 1}`),
    enabled: Boolean(group.enabled),
    rules: Array.isArray(group.rules)
      ? group.rules.map((rule, ri) => ({
          id: String(rule.id || `rule-${Date.now()}-${gi}-${ri}`),
          enabled: Boolean(rule.enabled),
          scope: rule.scope === 'host' ? 'host' : 'url',
          matchType: ['contains', 'equals', 'regex', 'wildcard'].includes(rule.matchType)
            ? rule.matchType
            : 'contains',
          pattern: String(rule.pattern || ''),
          redirectTo: String(rule.redirectTo || '')
        }))
      : []
  }));

  return { groups };
}
