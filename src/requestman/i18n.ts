export type Locale = 'zh' | 'en';

const getLocale = (): Locale => {
  const language = (typeof navigator !== 'undefined' ? navigator.language : 'en').toLowerCase();
  return language.startsWith('zh') ? 'zh' : 'en';
};

export const locale: Locale = getLocale();

export const t = (zh: string, en: string): string => (locale === 'zh' ? zh : en);
