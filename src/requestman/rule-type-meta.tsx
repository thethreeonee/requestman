import React from 'react';
import { Binary } from '@/components/animate-ui/icons/binary';
import { Blend } from '@/components/animate-ui/icons/blend';
import { Blocks } from '@/components/animate-ui/icons/blocks';
import { CircleX } from '@/components/animate-ui/icons/circle-x';
import { Compass } from '@/components/animate-ui/icons/compass';
import { CircuitBoard } from '@/components/animate-ui/icons/circuit-board';
import { Gauge } from '@/components/animate-ui/icons/gauge';
import { LayoutDashboard } from '@/components/animate-ui/icons/layout-dashboard';
import { User } from '@/components/animate-ui/icons/user';
import { t } from './i18n';
import type { RedirectRule } from './types';

type RuleType = RedirectRule['type'];
type RuleTypeIconProps = {
  size?: number;
  className?: string;
};
type RuleTypeMeta = {
  label: string;
  Icon: React.ComponentType<RuleTypeIconProps>;
};

const RULE_TYPE_ENTRIES = [
  ['redirect_request', { label: t('重定向请求', 'Redirect Request'), Icon: Compass }],
  ['rewrite_string', { label: t('重写字符串', 'Rewrite String'), Icon: CircuitBoard }],
  ['query_params', { label: t('Query参数', 'Query Params'), Icon: Blocks }],
  ['modify_request_body', { label: t('改写请求体', 'Modify Request Body'), Icon: LayoutDashboard }],
  ['modify_response_body', { label: t('改写响应体', 'Modify Response Body'), Icon: Binary }],
  ['modify_headers', { label: t('修改Headers', 'Modify Headers'), Icon: Blend }],
  ['user_agent', { label: 'User-Agent', Icon: User }],
  ['cancel_request', { label: t('取消请求', 'Cancel Request'), Icon: CircleX }],
  ['request_delay', { label: t('网络请求延迟', 'Request Delay'), Icon: Gauge }],
] as const satisfies readonly [RuleType, RuleTypeMeta][];

export const RULE_TYPE_ORDER = RULE_TYPE_ENTRIES.map(([type]) => type) as RuleType[];

export const RULE_TYPE_META = Object.fromEntries(RULE_TYPE_ENTRIES) as Record<
  RuleType,
  RuleTypeMeta
>;

export const RULE_TYPE_LABEL_MAP = Object.fromEntries(
  RULE_TYPE_ENTRIES.map(([type, meta]) => [type, meta.label]),
) as Record<RuleType, string>;

export function renderRuleTypeIcon(
  type: RuleType,
  props?: RuleTypeIconProps,
) {
  const Icon = RULE_TYPE_META[type].Icon;
  return <Icon size={props?.size ?? 16} className={props?.className} />;
}
