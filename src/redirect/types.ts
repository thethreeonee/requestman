export type MatchTarget = 'url' | 'host';
export type MatchMode = 'equals' | 'contains' | 'regex' | 'wildcard';
export type ResourceTypeFilter =
  | 'all'
  | 'xmlhttprequest'
  | 'script'
  | 'stylesheet'
  | 'image'
  | 'media'
  | 'font'
  | 'websocket'
  | 'main_frame'
  | 'sub_frame';

export type RequestMethodFilter =
  | 'all'
  | 'get'
  | 'post'
  | 'put'
  | 'patch'
  | 'delete'
  | 'head'
  | 'options';

export type RedirectFilter = {
  pageDomain: string;
  resourceType: ResourceTypeFilter;
  requestMethod: RequestMethodFilter;
};

export type RedirectCondition = {
  id: string;
  matchTarget: MatchTarget;
  matchMode: MatchMode;
  expression: string;
  redirectType: 'url' | 'file';
  redirectTarget: string;
  filter: RedirectFilter;
};

export type RedirectRule = {
  id: string;
  name: string;
  type: 'redirect_request';
  enabled: boolean;
  groupId: string;
  conditions: RedirectCondition[];
};

export type RedirectGroup = {
  id: string;
  name: string;
  enabled: boolean;
};
