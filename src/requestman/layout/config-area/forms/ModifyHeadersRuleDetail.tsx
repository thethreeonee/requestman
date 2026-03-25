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
  Tooltip,
} from '../../../primitives';
import { t } from '../../../i18n';
import {
  DeleteOutlined,
  PlusOutlined,
} from '../../../icons';
import { createDefaultCondition, genId, simulateRuleEffect, type SimulateRuleResult } from '../../../rule-utils';
import type { HeaderModification, RedirectCondition } from '../../../types';
import ConditionUrlMatchEditor from '../../../components/ConditionUrlMatchEditor';
import RuleDetailToolbar from '../../../components/RuleDetailToolbar';
import RuleNameHeader from '../../../components/RuleNameHeader';
import TestRuleDrawer from '../../../components/TestRuleDrawer';
import ConditionFilterModal, { isConditionFilterConfigured } from '../../../components/ConditionFilterModal';
import type { RuleDetailProps as Props } from '../types';

const HEADER_ACTION_OPTIONS = [
  { label: t('添加', 'Add'), value: 'add' },
  { label: t('修改', 'Update'), value: 'update' },
  { label: t('删除', 'Delete'), value: 'delete' },
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

const HEADER_OPTIONS = COMMON_HEADERS.map((header) => ({
  value: header,
  label: (
    <Tooltip title={header} placement="right">
      <span
        style={{
          display: 'inline-block',
          width: '100%',
          overflow: 'hidden',
          textOverflow: 'ellipsis',
          whiteSpace: 'nowrap',
        }}
      >
        {header}
      </span>
    </Tooltip>
  ),
}));

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
      messageApi.warning(t('至少保留一条条件配置', 'Keep at least one condition.'));
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
            <Input
              placeholder="Header"
              title={modification.key || undefined}
              style={{
                textOverflow: 'ellipsis',
              }}
            />
          </AutoComplete>
          <Input
            placeholder={t('值', 'Value')}
            value={modification.value}
            disabled={modification.action === 'delete'}
            onChange={(e) => updateHeaderModification(condition.id, tabKey, modification.id, { value: e.target.value })}
          />
          <Button danger icon={<DeleteOutlined />} onClick={() => removeHeaderModification(condition.id, tabKey, modification.id)} />
        </Space.Compact>
      ))}
      <Button type="dashed" onClick={() => addHeaderModification(condition.id, tabKey)} icon={<PlusOutlined />}>{t('添加 Header', 'Add header')}</Button>
    </Space>
  );

  return <div>
    <RuleDetailToolbar
      rule={workingRule}
      groups={groups}
      groupId={workingRule.groupId}
      enabled={workingRule.enabled}
      dirty={!!dirty}
      onBack={onBack}
      onEnabledChange={(v) => toggleDetailRuleEnabled(workingRule.id, v)}
      onGroupChange={(v) => setWorkingRule({ ...workingRule, groupId: v })}
      onRename={(name) => setWorkingRule({ ...workingRule, name })}
      onTest={() => setTestDrawerOpen(true)}
      onSave={saveDetailRule}
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
          label: t('请求条件配置', 'Request conditions'),
          extra: (
            <Popconfirm
              title={t('确认删除该条件配置？', 'Delete this condition?')}
              okText={t('删除', 'Delete')}
              cancelText={t('取消', 'Cancel')}
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
                aria-label={t('删除条件', 'Delete condition')}
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
                  label: t('请求 Headers', 'Request headers'),
                  children: renderHeaderTabContent(c, 'requestHeaderModifications'),
                },
                {
                  key: 'responseHeaderModifications',
                  label: t('响应 Headers', 'Response headers'),
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
      {t('添加新条件配置', 'Add condition')}
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
