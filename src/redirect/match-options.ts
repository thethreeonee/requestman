import type { MatchMode, MatchTarget } from './types';

export const MATCH_TARGET_OPTIONS: { label: string; value: MatchTarget }[] = [
  { label: 'URL', value: 'url' },
  { label: 'Host', value: 'host' },
];

export const MATCH_MODE_OPTIONS: { label: string; value: MatchMode }[] = [
  { label: '等于', value: 'equals' },
  { label: '包含', value: 'contains' },
  { label: '通配符', value: 'wildcard' },
  { label: '正则', value: 'regex' },
];
