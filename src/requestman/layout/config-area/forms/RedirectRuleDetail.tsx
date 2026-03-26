import React, { useMemo, useRef, useState } from 'react';
import { Input } from '@/components/ui/input';
import {
  InputGroup,
  InputGroupAddon,
  InputGroupButton,
  InputGroupInput,
} from '@/components/ui/input-group';
import { Plus } from '@/components/animate-ui/icons/plus';
import {
  RadioGroup,
  RadioGroupItem,
} from '@/components/animate-ui/components/radix/radio-group';
import { t } from '../../../i18n';
import { createDefaultCondition, genId, simulateRuleEffect, type SimulateRuleResult } from '../../../rule-utils';
import type { RedirectCondition } from '../../../types';
import ConditionUrlMatchEditor from '../../../components/ConditionUrlMatchEditor';
import TestRuleDrawer from '../../../components/TestRuleDrawer';
import ConditionFilterModal, { isConditionFilterConfigured } from '../../../components/ConditionFilterModal';
import ConditionList from '../ConditionList';
import RuleDetailHeader from '../RuleDetailHeader';
import type { RuleDetailProps as Props } from '../types';

const MAX_LOCAL_FILE_SIZE = 1024 * 1024;
const FAKE_PATH_PREFIX = /^C:\\fakepath\\/i;

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
  const getRedirectFileDisplayValue = (condition: RedirectCondition) => {
    if (condition.redirectType !== 'file') return '';
    return (condition.redirectFileSource ?? '').trim().replace(FAKE_PATH_PREFIX, '')
      || (condition.redirectFileName ?? '').trim()
      || (condition.redirectFileTarget ?? '').trim()
      || condition.redirectTarget.trim();
  };

  const currentGroupEnabled = useMemo(() => new Map(groups.map((g) => [g.id, g.enabled])), [groups]);

  const updateCondition = (conditionId: string, patch: Partial<RedirectCondition>) => {
    setWorkingRule((prev) => (prev
      ? { ...prev, conditions: prev.conditions.map((c) => (c.id === conditionId ? { ...c, ...patch } : c)) }
      : prev));
  };

  const updateRedirectTarget = (condition: RedirectCondition, value: string) => {
    if (condition.redirectType === 'file') {
      updateCondition(condition.id, {
        redirectFileTarget: value,
        redirectTarget: value,
        redirectFileName: '',
        redirectFileSource: '',
      });
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
    if (selected.size > MAX_LOCAL_FILE_SIZE) {
      notifyApi.warning(t('本地文件不能超过 1MB', 'Local files must be 1MB or smaller.'));
      event.target.value = '';
      return;
    }
    const source = (selected.path || event.target.value || '').trim().replace(FAKE_PATH_PREFIX, '');
    const reader = new FileReader();
    reader.onload = () => {
      const dataUrl = typeof reader.result === 'string' ? reader.result : '';
      if (!dataUrl) {
        notifyApi.error(t('读取本地文件失败', 'Failed to read the local file.'));
        return;
      }
      updateCondition(condition.id, {
        redirectFileTarget: dataUrl,
        redirectTarget: dataUrl,
        redirectFileName: selected.name,
        redirectFileSource: source || selected.name,
      });
    };
    reader.onerror = () => {
      notifyApi.error(t('读取本地文件失败', 'Failed to read the local file.'));
    };
    reader.readAsDataURL(selected);
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
          <RadioGroup value={c.redirectType} onValueChange={(v) => updateRedirectType(c, v as 'url' | 'file')} className="aui-space">
            {[
              { label: 'URL', value: 'url' },
              { label: t('本地文件', 'Local file'), value: 'file' },
            ].map((opt) => (
              <label key={opt.value} className="flex items-center gap-2">
                <RadioGroupItem value={opt.value} />
                <span>{opt.label}</span>
              </label>
            ))}
          </RadioGroup>
          {c.redirectType === 'file'
            ? <>
              <InputGroup>
                <InputGroupInput
                  value={getRedirectFileDisplayValue(c)}
                  readOnly
                  placeholder={t('请选择要导入并重定向的本地文件', 'Select a local file to import and redirect')}
                />
                <InputGroupAddon align="inline-end">
                  <InputGroupButton variant="ghost" onClick={() => pickFile(c.id)}>
                    <Plus size={14} />
                    {t('选择文件', 'Select file')}
                  </InputGroupButton>
                </InputGroupAddon>
              </InputGroup>
              <input
                ref={(el) => { fileInputRefs.current[c.id] = el; }}
                type="file"
                style={{ display: 'none' }}
                onChange={(e) => onFilePicked(c, e)}
              />
            </>
            : <Input value={getRedirectTarget(c)} onChange={(e) => updateRedirectTarget(c, e.target.value)} placeholder="重定向目标 URL" />}
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
