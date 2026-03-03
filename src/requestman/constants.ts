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

export const REQUEST_HEADER_FILTER_OPERATOR_OPTIONS = [
  { label: '等于', value: 'equals' },
  { label: '不等于', value: 'not_equals' },
  { label: '包含', value: 'contains' },
] as const;

export const COMMON_HEADER_OPTIONS = [
  'Accept',
  'Accept-Encoding',
  'Accept-Language',
  'Authorization',
  'Cache-Control',
  'Content-Length',
  'Content-Type',
  'Cookie',
  'Host',
  'Origin',
  'Pragma',
  'Referer',
  'User-Agent',
  'X-Forwarded-For',
  'X-Requested-With',
  'ETag',
  'If-Modified-Since',
  'Last-Modified',
  'Location',
  'Set-Cookie',
  'Access-Control-Allow-Origin',
  'Access-Control-Allow-Headers',
  'Access-Control-Allow-Methods',
  'Access-Control-Expose-Headers',
].map((header) => ({ value: header }));

export const DEFAULT_MODIFY_REQUEST_BODY_SCRIPT = `function modifyRequestBody(args) {
  const { method, url, body, bodyAsJson } = args;
  // Change request body below depending upon request attributes received in args
  
  return body;
}`;

export const DEFAULT_MODIFY_RESPONSE_BODY_SCRIPT = `function modifyResponse(args) {
  const { method, url, status, statusText, body, bodyAsJson } = args;
  // Change response body below depending upon request/response attributes received in args

  return body;
}`;
