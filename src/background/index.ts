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
