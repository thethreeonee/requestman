import React, { useMemo, useState } from 'react';
import { CaseLower, CaseUpper } from 'lucide-react';
import {
  InputGroup,
  InputGroupAddon,
  InputGroupInput,
} from '@/components/ui/input-group';
import { t } from '../../../i18n';
import { createDefaultCondition, genId, simulateRuleEffect, type SimulateRuleResult } from '../../../rule-utils';
import type { RedirectCondition } from '../../../types';
import ConditionUrlMatchEditor from '../../../components/ConditionUrlMatchEditor';
import TestRuleDrawer from '../../../components/TestRuleDrawer';
import ConditionFilterModal, { isConditionFilterConfigured } from '../../../components/ConditionFilterModal';
import ConditionList from '../ConditionList';
import RuleDetailHeader from '../RuleDetailHeader';
import type { RuleDetailProps as Props } from '../types';

export default function RewriteStringRuleDetail({
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
        <div style={{ display: 'flex', width: '100%', gap: 8 }}>
          <InputGroup style={{ flex: 1, minWidth: 0 }}>
            <InputGroupAddon
              align="inline-start"
              className="flex h-full items-center gap-1.5 self-stretch whitespace-nowrap"
            >
              <span className="inline-flex size-4 items-center justify-center">
                <CaseLower size={16} className="translate-y-px" />
              </span>
              <span className="leading-none">{t('目标', 'Target')}</span>
            </InputGroupAddon>
            <InputGroupInput
              value={c.rewriteFrom}
              onChange={(e) => updateCondition(c.id, { rewriteFrom: e.target.value })}
              placeholder="from"
            />
          </InputGroup>
          <InputGroup style={{ flex: 1, minWidth: 0 }}>
            <InputGroupAddon
              align="inline-start"
              className="flex h-full items-center gap-1.5 self-stretch whitespace-nowrap"
            >
              <span className="inline-flex size-4 items-center justify-center">
                <CaseUpper size={16} className="translate-y-px" />
              </span>
              <span className="leading-none">{t('替换为', 'Replace with')}</span>
            </InputGroupAddon>
            <InputGroupInput
              value={c.rewriteTo}
              onChange={(e) => updateCondition(c.id, { rewriteTo: e.target.value })}
              placeholder="to"
            />
          </InputGroup>
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
