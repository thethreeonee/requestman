import React, { useMemo, useState } from 'react';
import {
  Form,
  Modal,
  Radio,
  Select,
} from '../../../components';
import { t } from '../../../i18n';
import {
  createDefaultCondition,
  genId,
  hasModifyResponseBodyFunction,
  simulateRuleEffect,
  type SimulateRuleResult,
} from '../../../rule-utils';
import CodeMirror from '@uiw/react-codemirror';
import { json } from '@codemirror/lang-json';
import { javascript } from '@codemirror/lang-javascript';
import type { RedirectCondition, ResponseBodyModifyMode } from '../../../types';
import ConditionUrlMatchEditor from '../../../components/ConditionUrlMatchEditor';
import TestRuleDrawer from '../../../components/TestRuleDrawer';
import ConditionFilterModal, { isConditionFilterConfigured } from '../../../components/ConditionFilterModal';
import ConditionList from '../ConditionList';
import RuleDetailHeader from '../RuleDetailHeader';
import type { RuleDetailProps as Props } from '../types';

function validateDynamicScript(code: string): string | null {
  if (!hasModifyResponseBodyFunction(code)) return t('需定义 modifyResponse(args) 方法', 'Define modifyResponse(args).');
  return null;
}

function CodeEditor({ value, onChange, mode }: { value: string; onChange: (value: string) => void; mode: ResponseBodyModifyMode }) {
  const extensions = useMemo(() => (mode === 'dynamic' ? [javascript()] : [json()]), [mode]);

  return (
    <CodeMirror
      value={value}
      onChange={onChange}
      extensions={extensions}
      height="220px"
      basicSetup={{
        lineNumbers: true,
        foldGutter: true,
        highlightActiveLine: true,
      }}
      className="requestman-body-editor"
    />
  );
}

export default function ModifyResponseBodyRuleDetail({
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

  const updateConditionMode = (conditionId: string, mode: ResponseBodyModifyMode) => {
    const condition = workingRule.conditions.find((item) => item.id === conditionId);
    if (!condition) return;
    const nextValue = mode === 'dynamic' ? condition.responseBodyDynamicValue : condition.responseBodyStaticValue;
    updateCondition(conditionId, { responseBodyMode: mode, responseBodyValue: nextValue });
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
      renderContent={(c) => {
        const dynamicScriptError = c.responseBodyMode === 'dynamic' ? validateDynamicScript(c.responseBodyDynamicValue) : null;
        return (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 8, width: '100%' }}>
            <ConditionUrlMatchEditor
              condition={c}
              filterConfigured={isConditionFilterConfigured(c)}
              onConditionChange={(patch) => updateCondition(c.id, patch)}
              onFilterClick={() => setFilterModal({ open: true, conditionId: c.id })}
            />
            <Form.Item label={t('修改方式', 'Modify mode')} style={{ marginBottom: 8 }}>
              <Radio.Group
                value={c.responseBodyMode}
                onChange={(e) => updateConditionMode(c.id, e.target.value)}
                options={[
                  { label: t('静态数据', 'Static'), value: 'static' },
                  { label: t('动态（JavaScript）', 'Dynamic (JavaScript)'), value: 'dynamic' },
                ]}
              />
            </Form.Item>
            <Form.Item
              label={c.responseBodyMode === 'dynamic' ? t('JavaScript 代码', 'JavaScript code') : t('替换后的响应体', 'Replaced response body')}
              validateStatus={dynamicScriptError ? 'error' : ''}
              help={dynamicScriptError ?? (c.responseBodyMode === 'dynamic' ? t('需定义 modifyResponse(args) 并返回最终响应体', 'Define modifyResponse(args) and return the final response body.') : t('命中后会直接替换原始响应 body', 'Will directly replace the original response body when matched.'))}
              layout="vertical"
              style={{ marginBottom: 0 }}
            >
              <CodeEditor
                mode={c.responseBodyMode}
                value={c.responseBodyMode === 'dynamic' ? c.responseBodyDynamicValue : c.responseBodyStaticValue}
                onChange={(value) => updateCondition(c.id, c.responseBodyMode === 'dynamic'
                  ? { responseBodyDynamicValue: value, responseBodyValue: value }
                  : { responseBodyStaticValue: value, responseBodyValue: value })}
              />
            </Form.Item>
          </div>
        );
      }}
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
