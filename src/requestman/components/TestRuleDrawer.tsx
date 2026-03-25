import React from 'react';
import { Button, Drawer, Input, Space, Typography } from '../ui';
import type { SimulateRuleResult } from '../rule-utils';
import { t } from '../i18n';

type Props = {
  open: boolean;
  testUrl: string;
  testResult: SimulateRuleResult | null;
  onClose: () => void;
  onTest: () => void;
  onTestUrlChange: (value: string) => void;
};

const resultBlockStyle: React.CSSProperties = {
  marginTop: 12,
  minHeight: 112,
  display: 'flex',
  flexDirection: 'column',
  gap: 10,
};

const rowStyle: React.CSSProperties = {
  padding: '10px 12px',
  borderRadius: 8,
  background: '#fafafa',
  border: '1px solid #f0f0f0',
  lineHeight: 1.6,
};

const valueStyle: React.CSSProperties = {
  marginLeft: 8,
  wordBreak: 'break-all',
  overflowWrap: 'anywhere',
};

export default function TestRuleDrawer({
  open,
  testUrl,
  testResult,
  onClose,
  onTest,
  onTestUrlChange,
}: Props) {
  const matchedConditionIndex = testResult && testResult.ok
    ? testResult.matchedRule.conditions.findIndex((condition) => condition.id === testResult.matchedCondition.id)
    : -1;

  return (
    <Drawer title={t('测试规则', 'Test rule')} placement="bottom" open={open} height={320} onClose={onClose}>
      <Space.Compact style={{ width: '100%' }}>
        <Input
          value={testUrl}
          onChange={(e) => onTestUrlChange(e.target.value)}
          onPressEnter={onTest}
          placeholder={t('输入测试URL', 'Enter URL to test')}
        />
        <Button onClick={onTest}>{t('测试', 'Test')}</Button>
      </Space.Compact>

      <div style={resultBlockStyle}>
        {!testResult && <Typography.Text type="secondary">{t('输入 URL 后点击测试（或按 Enter）', 'Enter URL and click Test (or press Enter).')}</Typography.Text>}

        {testResult && testResult.ok && (
          <>
            <div style={rowStyle}>
              <Typography.Text strong>{t('命中条件配置', 'Matched condition')}</Typography.Text>
              <Typography.Text style={valueStyle}>
                {t('条件', 'Condition')} {matchedConditionIndex >= 0 ? matchedConditionIndex + 1 : '-'}（{testResult.matchedCondition.matchTarget}/{testResult.matchedCondition.matchMode}）
              </Typography.Text>
            </div>
            <div style={rowStyle}>
              <Typography.Text strong>{t('最终结果', 'Final result')}</Typography.Text>
              <Typography.Text style={valueStyle} copyable={{ text: testResult.redirectedUrl }}>
                {testResult.redirectedUrl}
              </Typography.Text>
            </div>
          </>
        )}

        {testResult && !testResult.ok && (
          <div style={rowStyle}>
            <Typography.Text type="secondary">{testResult.reason}</Typography.Text>
          </div>
        )}
      </div>
    </Drawer>
  );
}
