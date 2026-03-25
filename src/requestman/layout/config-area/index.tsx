import React, { Suspense, lazy } from 'react';
import { Typography } from '../../components';
import { t } from '../../i18n';
import type { RedirectRule } from '../../types';
import type { RuleDetailProps } from './types';

const RedirectRuleDetail = lazy(() => import('./forms/RedirectRuleDetail'));
const RewriteStringRuleDetail = lazy(() => import('./forms/RewriteStringRuleDetail'));
const QueryParamsRuleDetail = lazy(() => import('./forms/QueryParamsRuleDetail'));
const ModifyRequestBodyRuleDetail = lazy(() => import('./forms/ModifyRequestBodyRuleDetail'));
const ModifyResponseBodyRuleDetail = lazy(() => import('./forms/ModifyResponseBodyRuleDetail'));
const ModifyHeadersRuleDetail = lazy(() => import('./forms/ModifyHeadersRuleDetail'));
const UserAgentRuleDetail = lazy(() => import('./forms/UserAgentRuleDetail'));
const CancelRequestRuleDetail = lazy(() => import('./forms/CancelRequestRuleDetail'));
const RequestDelayRuleDetail = lazy(() => import('./forms/RequestDelayRuleDetail'));

type Props = {
  currentRule: RedirectRule | null;
  detailProps: RuleDetailProps | null;
};

function renderRuleEditor(currentRule: RedirectRule, detailProps: RuleDetailProps) {
  if (currentRule.type === 'redirect_request') return <RedirectRuleDetail {...detailProps} />;
  if (currentRule.type === 'rewrite_string') return <RewriteStringRuleDetail {...detailProps} />;
  if (currentRule.type === 'query_params') return <QueryParamsRuleDetail {...detailProps} />;
  if (currentRule.type === 'modify_request_body') return <ModifyRequestBodyRuleDetail {...detailProps} />;
  if (currentRule.type === 'modify_response_body') return <ModifyResponseBodyRuleDetail {...detailProps} />;
  if (currentRule.type === 'modify_headers') return <ModifyHeadersRuleDetail {...detailProps} />;
  if (currentRule.type === 'user_agent') return <UserAgentRuleDetail {...detailProps} />;
  if (currentRule.type === 'cancel_request') return <CancelRequestRuleDetail {...detailProps} />;
  return <RequestDelayRuleDetail {...detailProps} />;
}

export default function ConfigArea({ currentRule, detailProps }: Props) {
  return (
    <main className="main-editor">
      <Suspense fallback={<div style={{ padding: 16 }}>{t('加载中...', 'Loading...')}</div>}>
        {currentRule && detailProps
          ? renderRuleEditor(currentRule, detailProps)
          : (
            <div className="editor-placeholder">
              <Typography.Title level={4} style={{ marginTop: 0 }}>{t('选择一条规则开始编辑', 'Select a rule to start editing')}</Typography.Title>
              <Typography.Text type="secondary">{t('左侧规则列表选择规则后，可在此处编辑。', 'Select a rule from the sidebar to edit it here.')}</Typography.Text>
            </div>
          )}
      </Suspense>
    </main>
  );
}
