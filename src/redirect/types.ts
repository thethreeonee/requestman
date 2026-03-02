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
  rewriteFrom: string;
  rewriteTo: string;
  redirectType: 'url' | 'file';
  redirectTarget: string;
  filter: RedirectFilter;
};

export type RedirectRule = {
  id: string;
  name: string;
  type:
    | 'redirect_request'
    | 'rewrite_string'
    | 'query_params'
    | 'modify_request_body'
    | 'modify_response_body'
    | 'modify_headers'
    | 'user_agent'
    | 'cancel_request'
    | 'request_delay';
  enabled: boolean;
  groupId: string;
  conditions: RedirectCondition[];
};

export type RedirectGroup = {
  id: string;
  name: string;
  enabled: boolean;
};
