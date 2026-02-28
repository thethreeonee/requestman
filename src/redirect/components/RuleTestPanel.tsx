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
    <div style={{ flex: '0 0 auto', padding: 12, boxSizing: 'border-box', background: '#eef6ff', borderTop: '1px solid #dbeafe' }}>
      <Typography.Title level={5} style={{ margin: '0 0 8px 0' }}>规则测试</Typography.Title>
      <Space direction="vertical" size={8} style={{ width: '100%' }}>
        <Input
          value={testUrl}
          placeholder="输入实际 URL，点击右侧按钮测试匹配"
          onChange={(e) => setTestUrl(e.target.value)}
          onPressEnter={triggerTest}
          addonAfter={<Button size="small" type="link" style={{ paddingInline: 0, height: 22 }} onClick={triggerTest}>测试</Button>}
        />
        {testResult ? (
          testResult.ok ? (
            <Space direction="vertical" size={4}>
              <Typography.Text>
                命中规则：第 {testResult.matchedIndex + 1} 条（
                {testResult.matchedRule.matchTarget}/{testResult.matchedRule.matchMode}）
              </Typography.Text>
              <Typography.Text type="secondary">所属分组：{groupNameMap.get(testResult.matchedRule.groupId) || '未知分组'}</Typography.Text>
              <Typography.Text type="secondary">匹配表达式：{testResult.matchedRule.expression}</Typography.Text>
              <Typography.Text copyable={{ text: testResult.redirectedUrl }}>重定向后：{testResult.redirectedUrl}</Typography.Text>
            </Space>
          ) : (
            <Typography.Text type="secondary">{testResult.reason}</Typography.Text>
          )
        ) : (
          <Typography.Text type="secondary">输入 URL 后点击“测试”</Typography.Text>
        )}
      </Space>
    </div>
  );
}
