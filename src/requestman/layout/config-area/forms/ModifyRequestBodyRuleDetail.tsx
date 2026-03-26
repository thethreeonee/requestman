import React, { useMemo, useState } from 'react';
import {
  Accordion,
  AccordionContent,
  AccordionItem,
  AccordionTrigger,
} from '@/components/animate-ui/components/radix/accordion';
import {
  Button,
  Form,
  Modal,
  Popconfirm,
  Radio,
  Select,
  Space,
} from '../../../components';
import { t } from '../../../i18n';
import {
  DeleteOutlined,
  PlusOutlined,
} from '../../../icons';
import {
  createDefaultCondition,
  genId,
  hasModifyRequestBodyFunction,
  simulateRuleEffect,
  type SimulateRuleResult,
} from '../../../rule-utils';
import CodeMirror from '@uiw/react-codemirror';
import { json } from '@codemirror/lang-json';
import { javascript } from '@codemirror/lang-javascript';
import type { RedirectCondition, RequestBodyModifyMode } from '../../../types';
import ConditionUrlMatchEditor from '../../../components/ConditionUrlMatchEditor';
import TestRuleDrawer from '../../../components/TestRuleDrawer';
import ConditionFilterModal, { isConditionFilterConfigured } from '../../../components/ConditionFilterModal';
import RuleDetailHeader from '../RuleDetailHeader';
import type { RuleDetailProps as Props } from '../types';

function validateDynamicScript(code: string): string | null {
  if (!hasModifyRequestBodyFunction(code)) return t('需定义 modifyRequestBody(args) 方法', 'Define modifyRequestBody(args).');
  return null;
}

function CodeEditor({ value, onChange, mode }: { value: string; onChange: (value: string) => void; mode: RequestBodyModifyMode }) {
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

export default function ModifyRequestBodyRuleDetail({
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
  const [openConditions, setOpenConditions] = useState<string[]>(() => workingRule.conditions.map((c) => c.id));

  const currentGroupEnabled = useMemo(() => new Map(groups.map((g) => [g.id, g.enabled])), [groups]);

  const updateCondition = (conditionId: string, patch: Partial<RedirectCondition>) => {
    setWorkingRule((prev) => (prev
      ? { ...prev, conditions: prev.conditions.map((c) => (c.id === conditionId ? { ...c, ...patch } : c)) }
      : prev));
  };

  const updateConditionMode = (conditionId: string, mode: RequestBodyModifyMode) => {
    const condition = workingRule.conditions.find((item) => item.id === conditionId);
    if (!condition) return;
    const nextValue = mode === 'dynamic' ? condition.requestBodyDynamicValue : condition.requestBodyStaticValue;
    updateCondition(conditionId, { requestBodyMode: mode, requestBodyValue: nextValue });
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
    <Accordion type="multiple" value={openConditions} onValueChange={setOpenConditions}>
      {workingRule.conditions.map((c) => {
        const dynamicScriptError = c.requestBodyMode === 'dynamic' ? validateDynamicScript(c.requestBodyDynamicValue) : null;
        return (
          <AccordionItem key={c.id} value={c.id} className="mb-3 border rounded-lg overflow-hidden">
            <AccordionTrigger className="px-4 hover:no-underline">
              <div style={{ display: 'flex', flex: 1, alignItems: 'center', justifyContent: 'space-between' }}>
                <span>{t('请求条件配置', 'Request conditions')}</span>
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
              </div>
            </AccordionTrigger>
            <AccordionContent className="px-4">
              <Space direction="vertical" style={{ width: '100%' }}>
                <ConditionUrlMatchEditor
                  condition={c}
                  filterConfigured={isConditionFilterConfigured(c)}
                  onConditionChange={(patch) => updateCondition(c.id, patch)}
                  onFilterClick={() => setFilterModal({ open: true, conditionId: c.id })}
                />
                <Form.Item label={t('修改方式', 'Modify mode')} style={{ marginBottom: 8 }}>
                  <Radio.Group
                    value={c.requestBodyMode}
                    onChange={(e) => updateConditionMode(c.id, e.target.value)}
                    options={[
                      { label: t('静态数据', 'Static'), value: 'static' },
                      { label: t('动态（JavaScript）', 'Dynamic (JavaScript)'), value: 'dynamic' },
                    ]}
                  />
                </Form.Item>
                <Form.Item
                  label={c.requestBodyMode === 'dynamic' ? t('JavaScript 代码', 'JavaScript code') : t('替换后的请求体', 'Replaced request body')}
                  validateStatus={dynamicScriptError ? 'error' : ''}
                  help={dynamicScriptError ?? (c.requestBodyMode === 'dynamic' ? t('需定义 modifyRequestBody(args) 并返回最终请求体', 'Define modifyRequestBody(args) and return the final request body.') : t('命中后会直接替换原始请求 body', 'Will directly replace the original request body when matched.'))}
                  layout="vertical"
                  style={{ marginBottom: 0 }}
                >
                  <CodeEditor
                    mode={c.requestBodyMode}
                    value={c.requestBodyMode === 'dynamic' ? c.requestBodyDynamicValue : c.requestBodyStaticValue}
                    onChange={(value) => updateCondition(c.id, c.requestBodyMode === 'dynamic'
                      ? { requestBodyDynamicValue: value, requestBodyValue: value }
                      : { requestBodyStaticValue: value, requestBodyValue: value })}
                  />
                </Form.Item>
              </Space>
            </AccordionContent>
          </AccordionItem>
        );
      })}
    </Accordion>
    <Button
      variant="outline"
      style={{ marginTop: 12, width: '100%', height: 40, background: 'transparent' }}
      onClick={() => {
        const newCondition = createDefaultCondition();
        setWorkingRule({ ...workingRule, conditions: [...workingRule.conditions, newCondition] });
        setOpenConditions((prev) => [...prev, newCondition.id]);
      }}
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
