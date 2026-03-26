import React, { useMemo, useRef, useState } from 'react';
import { Button } from '@/components/animate-ui/components/buttons/button';
import {
  Input,
  Modal,
  Radio,
} from '../../../components';
import { t } from '../../../i18n';
import {
  FileOutlined,
} from '../../../icons';
import { createDefaultCondition, genId, simulateRuleEffect, type SimulateRuleResult } from '../../../rule-utils';
import type { RedirectCondition } from '../../../types';
import ConditionUrlMatchEditor from '../../../components/ConditionUrlMatchEditor';
import TestRuleDrawer from '../../../components/TestRuleDrawer';
import ConditionFilterModal, { isConditionFilterConfigured } from '../../../components/ConditionFilterModal';
import ConditionList from '../ConditionList';
import RuleDetailHeader from '../RuleDetailHeader';
import type { RuleDetailProps as Props } from '../types';

export default function RedirectRuleDetail({
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
  const fileInputRefs = useRef<Record<string, HTMLInputElement | null>>({});

  const getRedirectTarget = (condition: RedirectCondition) => (condition.redirectType === 'file'
    ? condition.redirectFileTarget ?? condition.redirectTarget
    : condition.redirectUrlTarget ?? condition.redirectTarget);

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
          <Radio.Group value={c.redirectType} onChange={(e) => updateRedirectType(c, e.target.value as 'url' | 'file')}><Radio value="url">URL</Radio><Radio value="file">{t('本地文件', 'Local file')}</Radio></Radio.Group>
          {c.redirectType === 'file'
            ? <>
              <div style={{ display: 'flex', gap: 6, width: '100%' }}>
                <Input
                  value={getRedirectTarget(c)}
                  onChange={(e) => updateRedirectTarget(c, e.target.value)}
                  placeholder={t('请输入本地文件绝对路径', 'Enter absolute local file path')}
                />
                <Button variant="outline" onClick={() => pickFile(c.id)}><FileOutlined />{t('选择文件', 'Select file')}</Button>
              </div>
              <input
                ref={(el) => { fileInputRefs.current[c.id] = el; }}
                type="file"
                style={{ display: 'none' }}
                onChange={(e) => onFilePicked(c, e)}
              />
            </>
            : <Input value={getRedirectTarget(c)} onChange={(e) => updateRedirectTarget(c, e.target.value)} placeholder="重定向目标 URL" />}
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
