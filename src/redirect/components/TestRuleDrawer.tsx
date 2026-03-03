import React from 'react';
import { Button, Drawer, Input, Space } from 'antd';
import type { SimulateRuleResult } from '../rule-utils';

type Props = {
  open: boolean;
  testUrl: string;
  testResult: SimulateRuleResult | null;
  onClose: () => void;
  onTest: () => void;
  onTestUrlChange: (value: string) => void;
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
    <Drawer title="测试规则" placement="bottom" open={open} height={260} onClose={onClose}>
      <Space.Compact style={{ width: '100%' }}>
        <Input value={testUrl} onChange={(e) => onTestUrlChange(e.target.value)} placeholder="输入测试URL" />
        <Button onClick={onTest}>测试</Button>
      </Space.Compact>
      <div style={{ marginTop: 12 }}>
        {testResult
          ? testResult.ok
            ? `命中条件：${testResult.matchedCondition.matchTarget}/${testResult.matchedCondition.matchMode}，结果：${testResult.redirectedUrl}`
            : testResult.reason
          : '输入 URL 后点击测试'}
      </div>
    </Drawer>
  );
}
