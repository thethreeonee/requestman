import React, { useMemo, useState } from 'react';
import { Button, Drawer, Input, Modal, Space, Typography } from 'antd';
import { genId, simulateRuleEffect, type SimulateRuleResult } from '../rule-utils';
import type { RedirectGroup, RedirectRule } from '../types';
import RuleDetailToolbar from './RuleDetailToolbar';

type Props = {
  groups: RedirectGroup[];
  workingRule: RedirectRule;
  originalRule: RedirectRule | null;
  setWorkingRule: React.Dispatch<React.SetStateAction<RedirectRule | null>>;
  setRules: React.Dispatch<React.SetStateAction<RedirectRule[]>>;
  onBack: () => void;
  saveDetailRule: () => void;
  toggleDetailRuleEnabled: (ruleId: string, enabled: boolean) => void;
  setPageToList: () => void;
  title: string;
};

export default function RuleDetailPlaceholder({
  groups,
  workingRule,
  originalRule,
  setWorkingRule,
  setRules,
  onBack,
  saveDetailRule,
  toggleDetailRuleEnabled,
  setPageToList,
  title,
}: Props) {
  const [testDrawerOpen, setTestDrawerOpen] = useState(false);
  const [testUrl, setTestUrl] = useState('');
  const [testResult, setTestResult] = useState<SimulateRuleResult | null>(null);

  const { enabled: _workingEnabled, ...workingRuleWithoutEnabled } = workingRule;
  const { enabled: _originalEnabled, ...originalRuleWithoutEnabled } = originalRule ?? workingRule;
  const dirty = originalRule && JSON.stringify(workingRuleWithoutEnabled) !== JSON.stringify(originalRuleWithoutEnabled);
  const currentGroupEnabled = useMemo(() => new Map(groups.map((g) => [g.id, g.enabled])), [groups]);

  return <div>
    <RuleDetailToolbar
      groups={groups}
      groupId={workingRule.groupId}
      enabled={workingRule.enabled}
      dirty={!!dirty}
      onBack={onBack}
      onEnabledChange={(v) => toggleDetailRuleEnabled(workingRule.id, v)}
      onGroupChange={(v) => setWorkingRule({ ...workingRule, groupId: v })}
      onTest={() => setTestDrawerOpen(true)}
      onSave={saveDetailRule}
      menuItems={[
        { key: 'copy', label: '复制', onClick: () => setWorkingRule({ ...workingRule, id: genId(), name: `${workingRule.name} 副本` }) },
        { key: 'delete', label: '删除', danger: true, onClick: () => Modal.confirm({ title: '确认删除规则？', okButtonProps: { danger: true }, onOk: () => { setRules((prev) => prev.filter((r) => r.id !== workingRule.id)); setPageToList(); } }) },
      ]}
    />
    <Typography.Title level={4}>{title}</Typography.Title>
    <Drawer title="测试规则" placement="bottom" open={testDrawerOpen} height={260} onClose={() => setTestDrawerOpen(false)}>
      <Space.Compact style={{ width: '100%' }}>
        <Input value={testUrl} onChange={(e) => setTestUrl(e.target.value)} placeholder="输入测试URL" />
        <Button onClick={() => setTestResult(simulateRuleEffect(testUrl, [workingRule], currentGroupEnabled))}>测试</Button>
      </Space.Compact>
      <div style={{ marginTop: 12 }}>
        {testResult ? (
          testResult.ok
            ? `命中条件：${testResult.matchedCondition.matchTarget}/${testResult.matchedCondition.matchMode}，结果：${testResult.redirectedUrl}`
            : testResult.reason
        ) : '输入 URL 后点击测试'}
      </div>
    </Drawer>
  </div>;
}
