import React, { useMemo, useState } from 'react';
import {
  AutoComplete,
  Button,
  Collapse,
  Input,
  Modal,
  Popconfirm,
  Select,
  Space,
  Tabs,
} from 'antd';
import {
  DeleteOutlined,
  PlusOutlined,
} from '@ant-design/icons';
import { createDefaultCondition, genId, simulateRuleEffect, type SimulateRuleResult } from '../rule-utils';
import type { HeaderModification, RedirectCondition, RedirectGroup, RedirectRule } from '../types';
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

const HEADER_ACTION_OPTIONS = [
  { label: '添加', value: 'add' },
  { label: '修改', value: 'update' },
  { label: '删除', value: 'delete' },
] as const;

const COMMON_HEADERS = [
  'Accept',
  'Accept-Encoding',
  'Accept-Language',
  'Authorization',
  'Cache-Control',
  'Content-Length',
  'Content-Type',
  'Cookie',
  'Host',
  'Origin',
  'Pragma',
  'Referer',
  'Operation-Type',
  'User-Agent',
  'X-Forwarded-For',
  'X-Requested-With',
  'ETag',
  'If-Modified-Since',
  'Last-Modified',
  'Location',
  'Set-Cookie',
  'Access-Control-Allow-Origin',
  'Access-Control-Allow-Headers',
  'Access-Control-Allow-Methods',
  'Access-Control-Expose-Headers',
];

const HEADER_OPTIONS = COMMON_HEADERS.map((header) => ({ value: header }));

export default function ModifyHeadersRuleDetail({
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

  const { enabled: _workingEnabled, ...workingRuleWithoutEnabled } = workingRule;
  const { enabled: _originalEnabled, ...originalRuleWithoutEnabled } = originalRule ?? workingRule;
  const dirty = originalRule && JSON.stringify(workingRuleWithoutEnabled) !== JSON.stringify(originalRuleWithoutEnabled);
  const currentGroupEnabled = useMemo(() => new Map(groups.map((g) => [g.id, g.enabled])), [groups]);

  const updateCondition = (conditionId: string, patch: Partial<RedirectCondition>) => {
    setWorkingRule((prev) => (prev
      ? { ...prev, conditions: prev.conditions.map((c) => (c.id === conditionId ? { ...c, ...patch } : c)) }
      : prev));
  };

  const removeCondition = (conditionId: string) => {
    if (workingRule.conditions.length <= 1) {
      messageApi.warning('至少保留一条条件配置');
      return;
    }
    setWorkingRule({ ...workingRule, conditions: workingRule.conditions.filter((c) => c.id !== conditionId) });
  };


  const updateHeaderModification = (
    conditionId: string,
    tabKey: 'requestHeaderModifications' | 'responseHeaderModifications',
    modificationId: string,
    patch: Partial<HeaderModification>,
  ) => {
    const condition = workingRule.conditions.find((item) => item.id === conditionId);
    if (!condition) return;
    updateCondition(conditionId, {
      [tabKey]: condition[tabKey].map((item) => (item.id === modificationId ? { ...item, ...patch } : item)),
    });
  };

  const addHeaderModification = (
    conditionId: string,
    tabKey: 'requestHeaderModifications' | 'responseHeaderModifications',
  ) => {
    const condition = workingRule.conditions.find((item) => item.id === conditionId);
    if (!condition) return;
    updateCondition(conditionId, {
      [tabKey]: [...condition[tabKey], { id: genId(), action: 'add', key: '', value: '' }],
    });
  };

  const removeHeaderModification = (
    conditionId: string,
    tabKey: 'requestHeaderModifications' | 'responseHeaderModifications',
    modificationId: string,
  ) => {
    const condition = workingRule.conditions.find((item) => item.id === conditionId);
    if (!condition) return;
    updateCondition(conditionId, {
      [tabKey]: condition[tabKey].filter((item) => item.id !== modificationId),
    });
  };

  const activeCondition = workingRule.conditions.find((c) => c.id === filterModal.conditionId);

  const renderHeaderTabContent = (
    condition: RedirectCondition,
    tabKey: 'requestHeaderModifications' | 'responseHeaderModifications',
  ) => (
    <Space direction="vertical" style={{ width: '100%' }}>
      {condition[tabKey].map((modification) => (
        <Space.Compact key={modification.id} style={{ width: '100%' }}>
          <Select
            value={modification.action}
            options={HEADER_ACTION_OPTIONS as never}
            style={{ width: 100 }}
            onChange={(value) => updateHeaderModification(condition.id, tabKey, modification.id, { action: value })}
          />
          <AutoComplete
            style={{ width: 400 }}
            options={HEADER_OPTIONS}
            filterOption={false}
            value={modification.key}
            onChange={(value) => updateHeaderModification(condition.id, tabKey, modification.id, { key: value })}
          >
            <Input placeholder="Header" />
          </AutoComplete>
          <Input
            placeholder="值"
            value={modification.value}
            disabled={modification.action === 'delete'}
            onChange={(e) => updateHeaderModification(condition.id, tabKey, modification.id, { value: e.target.value })}
          />
          <Button danger icon={<DeleteOutlined />} onClick={() => removeHeaderModification(condition.id, tabKey, modification.id)} />
        </Space.Compact>
      ))}
      <Button type="dashed" onClick={() => addHeaderModification(condition.id, tabKey)} icon={<PlusOutlined />}>添加Header</Button>
    </Space>
  );

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
              onCancel={(e) => e?.stopPropagation()}
              onConfirm={(e) => {
                e?.stopPropagation();
                removeCondition(c.id);
              }}
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
            <Tabs
              items={[
                {
                  key: 'requestHeaderModifications',
                  label: '请求Headers',
                  children: renderHeaderTabContent(c, 'requestHeaderModifications'),
                },
                {
                  key: 'responseHeaderModifications',
                  label: '响应Headers',
                  children: renderHeaderTabContent(c, 'responseHeaderModifications'),
                },
              ]}
            />
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
