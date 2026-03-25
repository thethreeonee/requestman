import React from 'react';
import { Button } from '@/components/animate-ui/components/buttons/button';
import { Input, Space, Typography } from '.';
import type { SimulateRuleResult } from '../rule-utils';
import { t } from '../i18n';
import {
  Sheet,
  SheetContent,
  SheetHeader,
  SheetTitle,
} from '@/components/animate-ui/components/radix/sheet';

type Props = {
  open: boolean;
  testUrl: string;
  testResult: SimulateRuleResult | null;
  onClose: () => void;
  onTest: () => void;
  onTestUrlChange: (value: string) => void;
};

const resultBlockStyle: React.CSSProperties = {
  minHeight: 112,
  display: 'flex',
  flexDirection: 'column',
  gap: 10,
};

const bodyStyle: React.CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
  gap: 12,
  padding: '0 16px 16px',
  overflow: 'auto',
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
  const rowStyle: React.CSSProperties = {
    padding: '10px 12px',
    borderRadius: 8,
    background: 'rgba(127, 127, 127, 0.08)',
    border: '1px solid rgba(127, 127, 127, 0.16)',
    lineHeight: 1.6,
  };
  const matchedConditionIndex = testResult && testResult.ok
    ? testResult.matchedRule.conditions.findIndex((condition) => condition.id === testResult.matchedCondition.id)
    : -1;

  return (
    <Sheet open={open} onOpenChange={(nextOpen) => { if (!nextOpen) onClose(); }}>
      <SheetContent side="right" showCloseButton className="w-[420px] max-w-[100vw] overflow-hidden p-0">
        <SheetHeader style={{ paddingBottom: 12 }}>
          <SheetTitle>{t('测试规则', 'Test rule')}</SheetTitle>
        </SheetHeader>

        <div style={bodyStyle}>
          <Space.Compact style={{ width: '100%' }}>
            <Input
              value={testUrl}
              onChange={(e) => onTestUrlChange(e.target.value)}
              onPressEnter={onTest}
              placeholder={t('输入测试URL', 'Enter URL to test')}
            />
            <Button variant="outline" onClick={onTest}>{t('测试', 'Test')}</Button>
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
        </div>
      </SheetContent>
    </Sheet>
  );
}
