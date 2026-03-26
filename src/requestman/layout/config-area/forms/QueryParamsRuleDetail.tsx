import React, { useMemo, useState } from 'react';
import { Button } from '@/components/animate-ui/components/buttons/button';
import {
  Accordion,
  AccordionContent,
  AccordionItem,
  AccordionTrigger,
} from '@/components/animate-ui/components/radix/accordion';
import {
  Input,
  Modal,
  Popconfirm,
  Select,
  Space,
} from '../../../components';
import { Trash2 } from '@/components/animate-ui/icons/trash-2';
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
  const [openConditions, setOpenConditions] = useState<string[]>(() => workingRule.conditions.map((c) => c.id));

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
    <Accordion type="multiple" value={openConditions} onValueChange={setOpenConditions}>
      {workingRule.conditions.map((c) => (
        <AccordionItem key={c.id} value={c.id} className="mb-3 border rounded-lg">
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
                  <Trash2 size={14} />
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
          </AccordionContent>
        </AccordionItem>
      ))}
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
