import React from 'react';
import { Button, Drawer, Input, Space, Typography } from 'antd';
import type { SimulateRuleResult } from '../rule-utils';

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
  return (
    <Drawer title="测试规则" placement="bottom" open={open} height={320} onClose={onClose}>
      <Space.Compact style={{ width: '100%' }}>
        <Input
          value={testUrl}
          onChange={(e) => onTestUrlChange(e.target.value)}
          onPressEnter={onTest}
          placeholder="输入测试URL"
        />
        <Button onClick={onTest}>测试</Button>
      </Space.Compact>

      <div style={resultBlockStyle}>
        {!testResult && <Typography.Text type="secondary">输入 URL 后点击测试（或按 Enter）</Typography.Text>}

        {testResult && testResult.ok && (
          <>
            <div style={rowStyle}>
              <Typography.Text strong>命中规则</Typography.Text>
              <Typography.Text style={valueStyle}>
                {testResult.matchedRule.name}（{testResult.matchedCondition.matchTarget}/{testResult.matchedCondition.matchMode}）
              </Typography.Text>
            </div>
            <div style={rowStyle}>
              <Typography.Text strong>最终结果</Typography.Text>
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
