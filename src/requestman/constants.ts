export const REDIRECT_RULES_KEY = 'asap_redirect_rules_v1';
export const REDIRECT_ENABLED_KEY = 'asap_redirect_enabled_v1';
export const REDIRECT_GROUPS_KEY = 'asap_redirect_groups_v1';

export const DEFAULT_GROUP_ID = '__default__';
export const DEFAULT_GROUP_NAME = '默认分组';

export const MATCH_TARGET_OPTIONS = [
  { label: 'URL', value: 'url' },
  { label: 'HOST', value: 'host' },
] as const;

export const MATCH_MODE_OPTIONS = [
  { label: '包含', value: 'contains' },
  { label: '等于', value: 'equals' },
  { label: '正则', value: 'regex' },
  { label: '通配符', value: 'wildcard' },
] as const;

export const RESOURCE_TYPE_OPTIONS = [
  { label: '所有', value: 'all' },
  { label: 'XHR', value: 'xmlhttprequest' },
  { label: 'JS', value: 'script' },
  { label: 'CSS', value: 'stylesheet' },
  { label: 'Image', value: 'image' },
  { label: 'Media', value: 'media' },
  { label: 'Font', value: 'font' },
  { label: 'Web Socket', value: 'websocket' },
  { label: 'Main Document', value: 'main_frame' },
  { label: 'iFrame Document', value: 'sub_frame' },
] as const;

export const REQUEST_METHOD_OPTIONS = [
  { label: '所有', value: 'all' },
  { label: 'GET', value: 'get' },
  { label: 'POST', value: 'post' },
  { label: 'PUT', value: 'put' },
  { label: 'PATCH', value: 'patch' },
  { label: 'DELETE', value: 'delete' },
  { label: 'HEAD', value: 'head' },
  { label: 'OPTIONS', value: 'options' },
] as const;
