import React, { useMemo, useState } from 'react';
import { Input } from '@/components/ui/input';
import {
  Select,
  SelectContent,
  SelectGroup,
  SelectItem,
  SelectLabel,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import { t } from '../../../i18n';
import { createDefaultCondition, genId, simulateRuleEffect, type SimulateRuleResult } from '../../../rule-utils';
import type { RedirectCondition } from '../../../types';
import ConditionUrlMatchEditor from '../../../components/ConditionUrlMatchEditor';
import TestRuleDrawer from '../../../components/TestRuleDrawer';
import ConditionFilterModal, { isConditionFilterConfigured } from '../../../components/ConditionFilterModal';
import { getUserAgentByPresetKey, USER_AGENT_PRESETS, type UserAgentType } from '../../../user-agent-presets';
import ConditionList from '../ConditionList';
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
  isNewRule,
  setWorkingRule,
  setRules,
  saveDetailRule,
  toggleDetailRuleEnabled,
  duplicateDetailRule,
  deleteDetailRule,
  renameRule,
  moveRuleToGroupById,
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
      isNewRule={isNewRule}
      saveDetailRule={saveDetailRule}
      toggleDetailRuleEnabled={toggleDetailRuleEnabled}
      duplicateDetailRule={duplicateDetailRule}
      deleteDetailRule={deleteDetailRule}
      renameRule={renameRule}
      moveRuleToGroupById={moveRuleToGroupById}
      onTest={() => setTestDrawerOpen(true)}
    />
    <ConditionList
      conditions={workingRule.conditions}
      onAdd={() => {
        const newCondition = createDefaultCondition();
        setWorkingRule({ ...workingRule, conditions: [...workingRule.conditions, newCondition] });
        return newCondition.id;
      }}
      onRemove={removeCondition}
      renderConditionContent={(c) => (
        <ConditionUrlMatchEditor
          condition={c}
          filterConfigured={isConditionFilterConfigured(c)}
          onConditionChange={(patch) => updateCondition(c.id, patch)}
          onFilterClick={() => setFilterModal({ open: true, conditionId: c.id })}
        />
      )}
      renderExecutionContent={(c) => (
        <>
          <div style={{ display: 'flex', gap: 6, width: '100%' }}>
            <Select value={c.userAgentType ?? 'device'} onValueChange={(value) => onUserAgentTypeChange(c, value as UserAgentType)}>
              <SelectTrigger style={{ width: 110 }}>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {USER_AGENT_TYPE_OPTIONS.map((opt) => (
                  <SelectItem key={opt.value} value={opt.value}>{opt.label}</SelectItem>
                ))}
              </SelectContent>
            </Select>
            {c.userAgentType === 'custom' ? <Input
              style={{ flex: 1, minWidth: 0 }}
              placeholder={t('请输入自定义 User-Agent', 'Enter custom User-Agent')}
              value={c.userAgentCustomValue ?? ''}
              onChange={(e) => updateCondition(c.id, { userAgentCustomValue: e.target.value })}
            /> : (
              <Select
                value={c.userAgentPresetKey || undefined}
                onValueChange={(value) => updateCondition(c.id, { userAgentPresetKey: value })}
              >
                <SelectTrigger style={{ flex: 1, minWidth: 0 }}>
                  <SelectValue placeholder={t('请选择 User-Agent', 'Select User-Agent')} />
                </SelectTrigger>
                <SelectContent>
                  {((c.userAgentType ?? 'device') === 'browser' ? BROWSER_PRESET_GROUP_OPTIONS : DEVICE_PRESET_GROUP_OPTIONS).map((group) => (
                    <SelectGroup key={group.key}>
                      <SelectLabel>{group.label}</SelectLabel>
                      {group.options.map((opt) => (
                        <SelectItem key={opt.value} value={opt.value}>{opt.label}</SelectItem>
                      ))}
                    </SelectGroup>
                  ))}
                </SelectContent>
              </Select>
            )}
          </div>
          <span style={{ fontSize: 12, opacity: 0.7 }}>
            {(c.userAgentType ?? 'device') === 'custom'
              ? (c.userAgentCustomValue?.trim() ? `${t('将设置为：', 'Will set to: ')}${c.userAgentCustomValue.trim()}` : t('请输入自定义 User-Agent', 'Enter custom User-Agent'))
              : (() => {
                const value = getUserAgentByPresetKey(c.userAgentPresetKey ?? '');
                return value ? `${t('将设置为：', 'Will set to: ')}${value}` : t('请选择 User-Agent', 'Select User-Agent');
              })()}
          </span>
        </>
      )}
    />
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
