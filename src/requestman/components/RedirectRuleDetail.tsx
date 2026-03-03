import React, { useMemo, useRef, useState } from 'react';
import {
  Button,
  Collapse,
  Input,
  Modal,
  Popconfirm,
  Radio,
  Space,
} from 'antd';
import {
  DeleteOutlined,
  FileOutlined,
  PlusOutlined,
} from '@ant-design/icons';
import { createDefaultCondition, genId, simulateRuleEffect, type SimulateRuleResult } from '../rule-utils';
import type { RedirectCondition, RedirectGroup, RedirectRule } from '../types';
import ConditionUrlMatchEditor from './ConditionUrlMatchEditor';
import RuleDetailToolbar from './RuleDetailToolbar';
import RuleNameHeader from './RuleNameHeader';
import TestRuleDrawer from './TestRuleDrawer';
import ConditionFilterModal, { isConditionFilterConfigured } from './ConditionFilterModal';

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
  messageApi: { warning: (content: string) => void };
};

export default function RedirectRuleDetail({
  groups,
  workingRule,
  originalRule,
  setWorkingRule,
  setRules,
  onBack,
  saveDetailRule,
  toggleDetailRuleEnabled,
  setPageToList,
  messageApi,
}: Props) {
  const [editRuleName, setEditRuleName] = useState(false);
  const [testDrawerOpen, setTestDrawerOpen] = useState(false);
  const [testUrl, setTestUrl] = useState('');
  const [testResult, setTestResult] = useState<SimulateRuleResult | null>(null);
  const [filterModal, setFilterModal] = useState<{ open: boolean; conditionId?: string }>({ open: false });
  const fileInputRefs = useRef<Record<string, HTMLInputElement | null>>({});

  const getRedirectTarget = (condition: RedirectCondition) => (condition.redirectType === 'file'
    ? condition.redirectFileTarget ?? condition.redirectTarget
    : condition.redirectUrlTarget ?? condition.redirectTarget);

  const { enabled: _workingEnabled, ...workingRuleWithoutEnabled } = workingRule;
  const { enabled: _originalEnabled, ...originalRuleWithoutEnabled } = originalRule ?? workingRule;
  const dirty = originalRule && JSON.stringify(workingRuleWithoutEnabled) !== JSON.stringify(originalRuleWithoutEnabled);
  const currentGroupEnabled = useMemo(() => new Map(groups.map((g) => [g.id, g.enabled])), [groups]);

  const updateCondition = (conditionId: string, patch: Partial<RedirectCondition>) => {
    setWorkingRule((prev) => (prev
      ? { ...prev, conditions: prev.conditions.map((c) => (c.id === conditionId ? { ...c, ...patch } : c)) }
      : prev));
  };

  const updateRedirectTarget = (condition: RedirectCondition, value: string) => {
    if (condition.redirectType === 'file') {
      updateCondition(condition.id, { redirectFileTarget: value, redirectTarget: value });
      return;
    }
    updateCondition(condition.id, { redirectUrlTarget: value, redirectTarget: value });
  };

  const updateRedirectType = (condition: RedirectCondition, type: 'url' | 'file') => {
    const nextTarget = type === 'file'
      ? (condition.redirectFileTarget ?? '')
      : (condition.redirectUrlTarget ?? '');
    updateCondition(condition.id, { redirectType: type, redirectTarget: nextTarget });
  };

  const pickFile = (conditionId: string) => {
    const input = fileInputRefs.current[conditionId];
    input?.click();
  };

  const onFilePicked = (condition: RedirectCondition, event: React.ChangeEvent<HTMLInputElement>) => {
    const selected = event.target.files?.[0] as (File & { path?: string }) | undefined;
    if (!selected) return;
    const nativePath = selected.path
      || event.target.value
      || '';
    const fullPath = nativePath.replace(/^C:\\fakepath\\/i, '').trim();
    updateCondition(condition.id, { redirectFileTarget: fullPath, redirectTarget: fullPath });
    event.target.value = '';
  };

  const removeCondition = (conditionId: string) => {
    if (workingRule.conditions.length <= 1) return messageApi.warning('至少保留一条条件配置');
    setWorkingRule({ ...workingRule, conditions: workingRule.conditions.filter((c) => c.id !== conditionId) });
  };


  const activeCondition = workingRule.conditions.find((c) => c.id === filterModal.conditionId);

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
    <RuleNameHeader
      rule={workingRule}
      editRuleName={editRuleName}
      setEditRuleName={setEditRuleName}
      setWorkingRule={setWorkingRule}
    />
    {workingRule.conditions.map((c) => (
      <Collapse
        key={c.id}
        defaultActiveKey={[c.id]}
        items={[{
          key: c.id,
          label: '请求条件配置',
          extra: (
            <Popconfirm
              title="确认删除该条件配置？"
              okText="删除"
              cancelText="取消"
              okButtonProps={{ danger: true, type: 'primary' }}
              onConfirm={() => removeCondition(c.id)}
            >
              <span
                role="button"
                tabIndex={0}
                aria-label="删除条件"
                onMouseDown={(e) => e.stopPropagation()}
                onPointerDown={(e) => e.stopPropagation()}
                onClick={(e) => e.stopPropagation()}
                onKeyDown={(e) => {
                  if (e.key === 'Enter' || e.key === ' ') {
                    e.preventDefault();
                    e.stopPropagation();
                  }
                }}
                style={{ color: '#ff4d4f', cursor: 'pointer', padding: '0 4px' }}
              >
                <DeleteOutlined />
              </span>
            </Popconfirm>
          ),
          children: <Space direction="vertical" style={{ width: '100%' }}>
            <ConditionUrlMatchEditor
              condition={c}
              filterConfigured={isConditionFilterConfigured(c)}
              onConditionChange={(patch) => updateCondition(c.id, patch)}
              onFilterClick={() => setFilterModal({ open: true, conditionId: c.id })}
            />
            <Radio.Group value={c.redirectType} onChange={(e) => updateRedirectType(c, e.target.value as 'url' | 'file')}><Radio value="url">URL</Radio><Radio value="file">本地文件</Radio></Radio.Group>
            {c.redirectType === 'file'
              ? <>
                <Space.Compact style={{ width: '100%' }}>
                  <Input
                    value={getRedirectTarget(c)}
                    onChange={(e) => updateRedirectTarget(c, e.target.value)}
                    placeholder="请输入本地文件绝对路径"
                  />
                  <Button icon={<FileOutlined />} onClick={() => pickFile(c.id)}>选择文件</Button>
                </Space.Compact>
                <input
                  ref={(el) => { fileInputRefs.current[c.id] = el; }}
                  type="file"
                  style={{ display: 'none' }}
                  onChange={(e) => onFilePicked(c, e)}
                />
              </>
              : <Input value={getRedirectTarget(c)} onChange={(e) => updateRedirectTarget(c, e.target.value)} placeholder="重定向目标 URL" />}
          </Space>,
        }]}
        style={{ marginBottom: 12 }}
      />
    ))}
    <Button
      type="dashed"
      style={{ marginTop: 12, width: '100%', height: 40, background: 'transparent' }}
      icon={<PlusOutlined />}
      onClick={() => setWorkingRule({ ...workingRule, conditions: [...workingRule.conditions, createDefaultCondition()] })}
    >
      添加新条件配置
    </Button>
    <TestRuleDrawer
      open={testDrawerOpen}
      testUrl={testUrl}
      testResult={testResult}
      onClose={() => setTestDrawerOpen(false)}
      onTest={() => setTestResult(simulateRuleEffect(testUrl, [workingRule], currentGroupEnabled, { includeDisabled: true }))}
      onTestUrlChange={setTestUrl}
    />
    <ConditionFilterModal
      open={filterModal.open}
      condition={activeCondition}
      onClose={() => setFilterModal({ open: false })}
      onConditionChange={updateCondition}
    />
  </div>;
}
