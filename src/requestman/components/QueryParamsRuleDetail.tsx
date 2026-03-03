import React, { useMemo, useState } from 'react';
import {
  Button,
  Collapse,
  Form,
  Input,
  Modal,
  Popconfirm,
  Select,
  Space,
  Typography,
} from 'antd';
import {
  DeleteOutlined,
  EditOutlined,
  PlusOutlined,
} from '@ant-design/icons';
import {
  REQUEST_METHOD_OPTIONS,
  RESOURCE_TYPE_OPTIONS,
} from '../constants';
import { createDefaultCondition, genId, simulateRuleEffect, type SimulateRuleResult } from '../rule-utils';
import type { QueryParamModification, RedirectCondition, RedirectGroup, RedirectRule } from '../types';
import ConditionUrlMatchEditor from './ConditionUrlMatchEditor';
import RuleDetailToolbar from './RuleDetailToolbar';
import TestRuleDrawer from './TestRuleDrawer';

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

const QUERY_ACTION_OPTIONS = [
  { label: '添加', value: 'add' },
  { label: '修改', value: 'update' },
  { label: '删除', value: 'delete' },
] as const;

export default function QueryParamsRuleDetail({
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
    if (workingRule.conditions.length <= 1) return messageApi.warning('至少保留一条条件配置');
    setWorkingRule({ ...workingRule, conditions: workingRule.conditions.filter((c) => c.id !== conditionId) });
  };

  const isFilterConfigured = (condition: RedirectCondition) => !!condition.filter.pageDomain.trim()
    || condition.filter.resourceType !== 'all'
    || condition.filter.requestMethod !== 'all';

  const updateModification = (conditionId: string, modificationId: string, patch: Partial<QueryParamModification>) => {
    const condition = workingRule.conditions.find((item) => item.id === conditionId);
    if (!condition) return;
    updateCondition(conditionId, {
      queryParamModifications: condition.queryParamModifications.map((item) => (item.id === modificationId ? { ...item, ...patch } : item)),
    });
  };

  const addModification = (conditionId: string) => {
    const condition = workingRule.conditions.find((item) => item.id === conditionId);
    if (!condition) return;
    updateCondition(conditionId, {
      queryParamModifications: [...condition.queryParamModifications, { id: genId(), action: 'add', key: '', value: '' }],
    });
  };

  const removeModification = (conditionId: string, modificationId: string) => {
    const condition = workingRule.conditions.find((item) => item.id === conditionId);
    if (!condition) return;
    if (condition.queryParamModifications.length <= 1) return messageApi.warning('至少保留一条修改配置');
    updateCondition(conditionId, {
      queryParamModifications: condition.queryParamModifications.filter((item) => item.id !== modificationId),
    });
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
    <Space align="center" style={{ marginBottom: 16 }}>
      {editRuleName ? <Input value={workingRule.name} onChange={(e) => setWorkingRule({ ...workingRule, name: e.target.value })} onBlur={() => setEditRuleName(false)} onPressEnter={() => setEditRuleName(false)} /> : <Typography.Title level={4} style={{ margin: 0 }}>{workingRule.name}</Typography.Title>}
      <Button type="text" icon={<EditOutlined />} onClick={() => setEditRuleName(true)} />
    </Space>
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
              filterConfigured={isFilterConfigured(c)}
              onConditionChange={(patch) => updateCondition(c.id, patch)}
              onFilterClick={() => setFilterModal({ open: true, conditionId: c.id })}
            />
            {c.queryParamModifications.map((modification) => (
              <Space.Compact key={modification.id} style={{ width: '100%' }}>
                <Select
                  value={modification.action}
                  options={QUERY_ACTION_OPTIONS as never}
                  style={{ width: 100 }}
                  onChange={(value) => updateModification(c.id, modification.id, { action: value })}
                />
                <Input
                  placeholder="参数名"
                  value={modification.key}
                  onChange={(e) => updateModification(c.id, modification.id, { key: e.target.value })}
                />
                <Input
                  placeholder="参数值"
                  value={modification.value}
                  disabled={modification.action === 'delete'}
                  onChange={(e) => updateModification(c.id, modification.id, { value: e.target.value })}
                />
                <Button danger icon={<DeleteOutlined />} onClick={() => removeModification(c.id, modification.id)} />
              </Space.Compact>
            ))}
            <Button type="dashed" onClick={() => addModification(c.id)} icon={<PlusOutlined />}>添加修改</Button>
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
    <Modal open={filterModal.open} title="过滤条件" onCancel={() => setFilterModal({ open: false })} onOk={() => setFilterModal({ open: false })}>
      {activeCondition && <Form layout="vertical">
        <Form.Item label="页面域名"><Input value={activeCondition.filter.pageDomain} onChange={(e) => updateCondition(activeCondition.id, { filter: { ...activeCondition.filter, pageDomain: e.target.value } })} /></Form.Item>
        <Form.Item label="资源类型"><Select value={activeCondition.filter.resourceType} options={RESOURCE_TYPE_OPTIONS as never} onChange={(v) => updateCondition(activeCondition.id, { filter: { ...activeCondition.filter, resourceType: v } })} /></Form.Item>
        <Form.Item label="请求方法"><Select value={activeCondition.filter.requestMethod} options={REQUEST_METHOD_OPTIONS as never} onChange={(v) => updateCondition(activeCondition.id, { filter: { ...activeCondition.filter, requestMethod: v } })} /></Form.Item>
      </Form>}
    </Modal>
  </div>;
}
