import React, { useMemo, useState } from 'react';
import { Button } from '@/components/animate-ui/components/buttons/button';
import {
  Input,
  Modal,
  Select,
  Space,
} from '../../../components';
import { t } from '../../../i18n';
import {
  DeleteOutlined,
  PlusOutlined,
} from '../../../icons';
import { createDefaultCondition, genId, simulateRuleEffect, type SimulateRuleResult } from '../../../rule-utils';
import type { QueryParamModification, RedirectCondition } from '../../../types';
import ConditionUrlMatchEditor from '../../../components/ConditionUrlMatchEditor';
import TestRuleDrawer from '../../../components/TestRuleDrawer';
import ConditionFilterModal, { isConditionFilterConfigured } from '../../../components/ConditionFilterModal';
import ConditionList from '../ConditionList';
import RuleDetailHeader from '../RuleDetailHeader';
import type { RuleDetailProps as Props } from '../types';

const QUERY_ACTION_OPTIONS = [
  { label: t('添加', 'Add'), value: 'add' },
  { label: t('修改', 'Update'), value: 'update' },
  { label: t('删除', 'Delete'), value: 'delete' },
] as const;

export default function QueryParamsRuleDetail({
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
    if (condition.queryParamModifications.length <= 1) return notifyApi.warning(t('至少保留一条修改配置', 'Keep at least one modification.'));
    updateCondition(conditionId, {
      queryParamModifications: condition.queryParamModifications.filter((item) => item.id !== modificationId),
    });
  };

  const activeCondition = workingRule.conditions.find((c) => c.id === filterModal.conditionId);

  return <div>
    <RuleDetailHeader
      groups={groups}
      workingRule={workingRule}
      originalRule={originalRule}
      setWorkingRule={setWorkingRule}
      saveDetailRule={saveDetailRule}
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
      renderContent={(c) => (
        <Space direction="vertical" style={{ width: '100%' }}>
          <ConditionUrlMatchEditor
            condition={c}
            filterConfigured={isConditionFilterConfigured(c)}
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
                placeholder={t('参数名', 'Parameter key')}
                value={modification.key}
                onChange={(e) => updateModification(c.id, modification.id, { key: e.target.value })}
              />
              <Input
                placeholder={t('参数值', 'Parameter value')}
                value={modification.value}
                disabled={modification.action === 'delete'}
                onChange={(e) => updateModification(c.id, modification.id, { value: e.target.value })}
              />
              <Button variant="destructive" size="icon" onClick={() => removeModification(c.id, modification.id)}>
                <DeleteOutlined />
              </Button>
            </Space.Compact>
          ))}
          <Button variant="outline" onClick={() => addModification(c.id)}><PlusOutlined />{t('添加修改', 'Add modification')}</Button>
        </Space>
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
