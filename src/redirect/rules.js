const RULE_ID_BASE = 10_000;

export function buildDynamicRules(config) {
  const rules = [];
  let nextId = RULE_ID_BASE;
  let priority = 1_000;

  for (const group of config.groups) {
    for (const rule of group.rules) {
      if (!group.enabled || !rule.enabled) {
        continue;
      }
      if (!rule.pattern || !rule.redirectTo) {
        continue;
      }

      const condition = buildCondition(rule);
      if (!condition) {
        continue;
      }

      const action = buildAction(rule);
      if (!action) {
        continue;
      }

      rules.push({
        id: nextId++,
        priority: priority--,
        action,
        condition: {
          ...condition,
          resourceTypes: ['main_frame', 'sub_frame', 'xmlhttprequest', 'script', 'image', 'font', 'stylesheet', 'media', 'object', 'ping', 'other']
        }
      });
    }
  }

  return rules;
}

function buildAction(rule) {
  if (rule.matchType === 'regex') {
    return {
      type: 'redirect',
      redirect: {
        regexSubstitution: rule.redirectTo
      }
    };
  }

  return {
    type: 'redirect',
    redirect: {
      url: rule.redirectTo
    }
  };
}

function buildCondition(rule) {
  const { scope, matchType, pattern } = rule;

  if (matchType === 'regex') {
    const source = scope === 'host' ? `^https?:\\/\\/(${pattern})(:\\d+)?(?:\\/|$)` : pattern;
    return { regexFilter: source };
  }

  if (matchType === 'wildcard') {
    const escaped = escapeForRegex(pattern).replace(/\\\*/g, '.*');
    const regex = scope === 'host'
      ? `^https?:\\/\\/${escaped}(?::\\d+)?(?:\\/|$)`
      : `^${escaped}$`;
    return { regexFilter: regex };
  }

  if (matchType === 'equals') {
    const regex = scope === 'host'
      ? `^https?:\\/\\/${escapeForRegex(pattern)}(?::\\d+)?(?:\\/|$)`
      : `^${escapeForRegex(pattern)}$`;
    return { regexFilter: regex };
  }

  if (matchType === 'contains') {
    const regex = scope === 'host'
      ? `^https?:\\/\\/[^/]*${escapeForRegex(pattern)}[^/]*(?::\\d+)?(?:\\/|$)`
      : escapeForRegex(pattern);
    return { regexFilter: regex };
  }

  return null;
}

function escapeForRegex(text) {
  return text.replace(/[.*+?^${}()|[\\]\\]/g, '\\$&');
}
