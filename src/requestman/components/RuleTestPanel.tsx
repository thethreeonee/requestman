import React from 'react';
import { Button, Input, Space, Typography } from 'antd';
import type { simulateRedirect } from '../rule-utils';

type TestResult = ReturnType<typeof simulateRedirect> | null;

type Props = {
  testUrl: string;
  setTestUrl: (value: string) => void;
  triggerTest: () => void;
  testResult: TestResult;
  groupNameMap: ReadonlyMap<string, string>;
};

export default function RuleTestPanel({ testUrl, setTestUrl, triggerTest, testResult, groupNameMap }: Props) {
  return (
    <div className="redirect-test-panel">
      <Typography.Title level={5} style={{ margin: '0 0 8px 0' }}>Test URL</Typography.Title>
      <Space direction="vertical" size={8} style={{ width: '100%' }}>
        <Input
          value={testUrl}
          placeholder="Paste a URL and run it against your active rules"
          onChange={(e) => setTestUrl(e.target.value)}
          onPressEnter={triggerTest}
          addonAfter={<Button size="small" type="link" style={{ paddingInline: 0, height: 22 }} onClick={triggerTest}>Test</Button>}
        />
        {testResult ? (
          testResult.ok ? (
            <Space direction="vertical" size={4}>
              <Typography.Text>
                Matched rule #{testResult.matchedIndex + 1} (
                {testResult.matchedRule.matchTarget}/{testResult.matchedRule.matchMode}）
              </Typography.Text>
              <Typography.Text type="secondary">Group: {groupNameMap.get(testResult.matchedRule.groupId) || 'Unknown group'}</Typography.Text>
              <Typography.Text type="secondary">Source Condition: {testResult.matchedRule.expression}</Typography.Text>
              <Typography.Text copyable={{ text: testResult.redirectedUrl }}>Destination URL: {testResult.redirectedUrl}</Typography.Text>
            </Space>
          ) : (
            <Typography.Text type="secondary">{testResult.reason}</Typography.Text>
          )
        ) : (
          <Typography.Text type="secondary">Enter a URL and click Test.</Typography.Text>
        )}
      </Space>
    </div>
  );
}
