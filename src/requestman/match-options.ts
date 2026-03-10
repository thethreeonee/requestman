import type { MatchMode, MatchTarget } from './types';
import { t } from './i18n';

export const MATCH_TARGET_OPTIONS: { label: string; value: MatchTarget }[] = [
  { label: 'URL', value: 'url' },
  { label: 'Host', value: 'host' },
];

export const MATCH_MODE_OPTIONS: { label: string; value: MatchMode }[] = [
  { label: t('等于', 'Equals'), value: 'equals' },
  { label: t('包含', 'Contains'), value: 'contains' },
  { label: t('通配符', 'Wildcard'), value: 'wildcard' },
  { label: t('正则', 'Regex'), value: 'regex' },
];
