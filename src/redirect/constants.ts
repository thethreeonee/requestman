export const REDIRECT_RULES_KEY = 'asap_redirect_rules_v1';
export const REDIRECT_ENABLED_KEY = 'asap_redirect_enabled_v1';
export const REDIRECT_GROUPS_KEY = 'asap_redirect_groups_v1';

export const DEFAULT_GROUP_ID = '__default__';
export const DEFAULT_GROUP_NAME = '默认分组';

export const MATCH_TARGET_OPTIONS = [
  { label: 'URL', value: 'url' },
  { label: 'Host', value: 'host' },
] as const;

export const MATCH_MODE_OPTIONS = [
  { label: '等于', value: 'equals' },
  { label: '包含', value: 'contains' },
  { label: '正则', value: 'regex' },
  { label: '通配', value: 'wildcard' },
] as const;
