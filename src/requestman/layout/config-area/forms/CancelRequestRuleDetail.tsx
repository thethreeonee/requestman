import React, { useMemo, useState } from 'react';
import { t } from '../../../i18n';
import { createDefaultCondition, genId, simulateRuleEffect, type SimulateRuleResult } from '../../../rule-utils';
import type { RedirectCondition } from '../../../types';
import ConditionUrlMatchEditor from '../../../components/ConditionUrlMatchEditor';
import TestRuleDrawer from '../../../components/TestRuleDrawer';
import ConditionFilterModal, { isConditionFilterConfigured } from '../../../components/ConditionFilterModal';
import ConditionList from '../ConditionList';
import RuleDetailHeader from '../RuleDetailHeader';
import type { RuleDetailProps as Props } from '../types';

export default function CancelRequestRuleDetail({
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
        <div style={{ display: 'flex', flexDirection: 'column', gap: 8, width: '100%' }}>
          <ConditionUrlMatchEditor
            condition={c}
            filterConfigured={isConditionFilterConfigured(c)}
            onConditionChange={(patch) => updateCondition(c.id, patch)}
            onFilterClick={() => setFilterModal({ open: true, conditionId: c.id })}
          />
          <span style={{ opacity: 0.7 }}>{t('命中该 URL 条件后，将直接取消请求。', 'When this URL condition matches, the request will be cancelled immediately.')}</span>
        </div>
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
