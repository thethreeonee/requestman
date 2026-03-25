import React, { useMemo, useState } from 'react';
import {
  Button,
  Collapse,
  Input,
  Modal,
  Popconfirm,
  Select,
  Space,
  Typography,
} from '../../../components';
import { t } from '../../../i18n';
import {
  DeleteOutlined,
  PlusOutlined,
} from '../../../icons';
import { createDefaultCondition, genId, simulateRuleEffect, type SimulateRuleResult } from '../../../rule-utils';
import type { RedirectCondition } from '../../../types';
import ConditionUrlMatchEditor from '../../../components/ConditionUrlMatchEditor';
import TestRuleDrawer from '../../../components/TestRuleDrawer';
import ConditionFilterModal, { isConditionFilterConfigured } from '../../../components/ConditionFilterModal';
import { getUserAgentByPresetKey, USER_AGENT_PRESETS, type UserAgentType } from '../../../user-agent-presets';
import RuleDetailHeader from '../RuleDetailHeader';
import type { RuleDetailProps as Props } from '../types';

const USER_AGENT_TYPE_OPTIONS = [
  { label: t('设备', 'Device'), value: 'device' },
  { label: t('浏览器', 'Browser'), value: 'browser' },
  { label: t('自定义', 'Custom'), value: 'custom' },
] as const;

const DEVICE_PRESET_GROUP_OPTIONS = Object.entries(USER_AGENT_PRESETS.device).map(([key, group]) => ({
  label: group.label,
  options: group.options.map((option) => ({ label: option.label, value: option.key })),
  key,
}));

const BROWSER_PRESET_GROUP_OPTIONS = Object.entries(USER_AGENT_PRESETS.browser).map(([key, group]) => ({
  label: group.label,
  options: group.options.map((option) => ({ label: option.label, value: option.key })),
  key,
}));

export default function UserAgentRuleDetail({
  groups,
  workingRule,
  originalRule,
  setWorkingRule,
  setRules,
  saveDetailRule,
  setPageToList,
  notifyApi,
}: Props) {
  const [testDrawerOpen, setTestDrawerOpen] = useState(false);
  const [testUrl, setTestUrl] = useState('');
  const [testResult, setTestResult] = useState<SimulateRuleResult | null>(null);
  const [filterModal, setFilterModal] = useState<{ open: boolean; conditionId?: string }>({ open: false });

  const currentGroupEnabled = useMemo(() => new Map(groups.map((g) => [g.id, g.enabled])), [groups]);

  const updateCondition = (conditionId: string, patch: Partial<RedirectCondition>) => {
    setWorkingRule((prev) => (prev
      ? { ...prev, conditions: prev.conditions.map((c) => (c.id === conditionId ? { ...c, ...patch } : c)) }
      : prev));
  };

  const removeCondition = (conditionId: string) => {
    if (workingRule.conditions.length <= 1) {
      notifyApi.warning(t('至少保留一条条件配置', 'Keep at least one condition.'));
      return;
    }
    setWorkingRule({ ...workingRule, conditions: workingRule.conditions.filter((c) => c.id !== conditionId) });
  };


  const activeCondition = workingRule.conditions.find((c) => c.id === filterModal.conditionId);

  const onUserAgentTypeChange = (condition: RedirectCondition, nextType: UserAgentType) => {
    if (nextType === 'custom') {
      updateCondition(condition.id, { userAgentType: 'custom', userAgentPresetKey: '' });
      return;
    }
    const groupedOptions = nextType === 'device' ? DEVICE_PRESET_GROUP_OPTIONS : BROWSER_PRESET_GROUP_OPTIONS;
    const firstPresetKey = groupedOptions[0]?.options[0]?.value ?? '';
    updateCondition(condition.id, {
      userAgentType: nextType,
      userAgentPresetKey: firstPresetKey,
    });
  };

  return <div>
    <RuleDetailHeader
      groups={groups}
      workingRule={workingRule}
      originalRule={originalRule}
      setWorkingRule={setWorkingRule}
      saveDetailRule={saveDetailRule}
      onTest={() => setTestDrawerOpen(true)}
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
            <Space.Compact style={{ width: '100%' }}>
              <Select
                value={c.userAgentType ?? 'device'}
                options={USER_AGENT_TYPE_OPTIONS as never}
                style={{ width: 110 }}
                onChange={(value) => onUserAgentTypeChange(c, value)}
              />
              {c.userAgentType === 'custom' ? <Input
                style={{ flex: 1, minWidth: 0 }}
                placeholder={t('请输入自定义 User-Agent', 'Enter custom User-Agent')}
                value={c.userAgentCustomValue ?? ''}
                onChange={(e) => updateCondition(c.id, { userAgentCustomValue: e.target.value })}
              /> : <Select
                style={{ flex: 1, minWidth: 0 }}
                placeholder={t('请选择 User-Agent', 'Select User-Agent')}
                value={c.userAgentPresetKey}
                options={(c.userAgentType ?? 'device') === 'browser' ? BROWSER_PRESET_GROUP_OPTIONS : DEVICE_PRESET_GROUP_OPTIONS as never}
                onChange={(value) => updateCondition(c.id, { userAgentPresetKey: value })}
              />}
            </Space.Compact>
            <Typography.Text type="secondary" style={{ fontSize: 12 }}>
              {(c.userAgentType ?? 'device') === 'custom'
                ? (c.userAgentCustomValue?.trim() ? `将设置为：${c.userAgentCustomValue.trim()}` : t('请输入自定义 User-Agent', 'Enter custom User-Agent'))
                : (() => {
                  const value = getUserAgentByPresetKey(c.userAgentPresetKey ?? '');
                  return value ? `将设置为：${value}` : t('请选择 User-Agent', 'Select User-Agent');
                })()}
            </Typography.Text>
          </Space>,
        }]}
        style={{ marginBottom: 12 }}
      />
    ))}
    <Button
      variant="outline"
      style={{ marginTop: 12, width: '100%', height: 40, background: 'transparent' }}
      onClick={() => setWorkingRule({ ...workingRule, conditions: [...workingRule.conditions, createDefaultCondition()] })}
    >
      <PlusOutlined />
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
