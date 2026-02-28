export type MatchTarget = 'url' | 'host';
export type MatchMode = 'equals' | 'contains' | 'regex' | 'wildcard';

export type RedirectRule = {
  id: string;
  enabled: boolean;
  groupId: string;
  matchTarget: MatchTarget;
  matchMode: MatchMode;
  expression: string;
  redirectUrl: string;
};

export type RedirectGroup = {
  id: string;
  name: string;
  enabled: boolean;
};

export type RuleDraft = {
  expression?: string;
  redirectUrl?: string;
};

export type RuleDragData = {
  type: 'rule';
  groupId: string;
};

export type GroupDropData = {
  type: 'group';
  groupId: string;
};

export type DragData = RuleDragData | GroupDropData;
