import { t } from './i18n';
export type UserAgentType = 'device' | 'browser' | 'custom';

export const USER_AGENT_PRESETS = {
  device: {
    android: {
      label: t('安卓', 'Android'),
      options: [
        { key: 'android_phone', label: t('安卓手机', 'Android phone'), ua: 'Mozilla/5.0 (Linux; Android 14; Pixel 8 Build/UQ1A.240205.002) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36' },
        { key: 'android_tablet', label: t('安卓平板', 'Android tablet'), ua: 'Mozilla/5.0 (Linux; Android 13; SM-X706B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36' },
      ],
    },
    apple: {
      label: t('苹果', 'Apple'),
      options: [
        { key: 'iphone', label: 'iPhone', ua: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1' },
        { key: 'ipad', label: 'iPad', ua: 'Mozilla/5.0 (iPad; CPU OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1' },
      ],
    },
    windows: {
      label: 'Windows',
      options: [
        { key: 'windows_phone', label: 'Windows Phone', ua: 'Mozilla/5.0 (Windows Phone 10.0; Android 6.0.1; Microsoft; RM-1152) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/52.0.2743.116 Mobile Safari/537.36 Edge/15.15254' },
        { key: 'windows_tablet', label: t('Windows 平板', 'Windows tablet'), ua: 'Mozilla/5.0 (Windows NT 10.0; ARM; Tablet PC) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36' },
      ],
    },
    other: {
      label: t('其他', 'Other'),
      options: [
        { key: 'symbian_phone', label: t('Symbian 手机', 'Symbian phone'), ua: 'Mozilla/5.0 (SymbianOS/9.4; Series60/5.0 Nokia5800d-1/52.0.007; Profile/MIDP-2.1 Configuration/CLDC-1.1 ) AppleWebKit/525 (KHTML, like Gecko) BrowserNG/7.2.6.9 3gpp-gba' },
      ],
    },
  },
  browser: {
    chrome: {
      label: 'Chrome',
      options: [
        { key: 'chrome_windows', label: 'Chrome on Windows', ua: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36' },
        { key: 'chrome_macos', label: 'Chrome on macOS', ua: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 14_4) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36' },
        { key: 'chrome_linux', label: 'Chrome on Linux', ua: 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36' },
      ],
    },
    firefox: {
      label: 'Firefox',
      options: [
        { key: 'firefox_windows', label: 'Firefox on Windows', ua: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:125.0) Gecko/20100101 Firefox/125.0' },
        { key: 'firefox_macos', label: 'Firefox on macOS', ua: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 14.4; rv:125.0) Gecko/20100101 Firefox/125.0' },
        { key: 'firefox_linux', label: 'Firefox on Linux', ua: 'Mozilla/5.0 (X11; Linux x86_64; rv:125.0) Gecko/20100101 Firefox/125.0' },
      ],
    },
    safari: {
      label: 'Safari',
      options: [
        { key: 'safari_macos', label: 'Safari', ua: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 14_4) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15' },
      ],
    },
    microsoft: {
      label: 'Microsoft',
      options: [
        { key: 'ie11', label: 'Microsoft Internet Explorer 11', ua: 'Mozilla/5.0 (Windows NT 6.1; Trident/7.0; rv:11.0) like Gecko' },
        { key: 'edge', label: 'Microsoft Edge', ua: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36 Edg/124.0.0.0' },
      ],
    },
    opera: {
      label: 'Opera',
      options: [
        { key: 'opera', label: 'Opera', ua: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36 OPR/109.0.0.0' },
      ],
    },
  },
} as const;

const allOptions = [
  ...Object.values(USER_AGENT_PRESETS.device).flatMap((group) => group.options),
  ...Object.values(USER_AGENT_PRESETS.browser).flatMap((group) => group.options),
];

const presetMap = new Map(allOptions.map((option) => [option.key, option.ua]));

export function getUserAgentByPresetKey(presetKey: string) {
  return presetMap.get(presetKey) ?? '';
}
