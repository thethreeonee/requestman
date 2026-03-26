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
  InputNumber,
  Modal,
  Popconfirm,
  Select,
  Space,
  Typography,
} from '../../../components';
import { t } from '../../../i18n';
import { Trash2 } from '@/components/animate-ui/icons/trash-2';
import {
  PlusOutlined,
} from '../../../icons';
import { createDefaultCondition, genId, simulateRuleEffect, type SimulateRuleResult } from '../../../rule-utils';
import type { RedirectCondition } from '../../../types';
import ConditionUrlMatchEditor from '../../../components/ConditionUrlMatchEditor';
import TestRuleDrawer from '../../../components/TestRuleDrawer';
import ConditionFilterModal, { isConditionFilterConfigured } from '../../../components/ConditionFilterModal';
import RuleDetailHeader from '../RuleDetailHeader';
import type { RuleDetailProps as Props } from '../types';

export default function RequestDelayRuleDetail({
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
              <Form.Item label={t('延迟（ms）', 'Delay (ms)')} style={{ marginBottom: 0 }}>
                <InputNumber
                  style={{ width: '100%' }}
                  min={0}
                  precision={0}
                  value={c.delayMs}
                  onChange={(value) => updateCondition(c.id, { delayMs: typeof value === 'number' ? value : 0 })}
                  placeholder={t('输入请求延迟时间', 'Enter request delay')}
                />
              </Form.Item>
              <Typography.Text type="secondary">{t('命中该 URL 条件后，请求将延迟指定毫秒数再继续。', 'When this URL condition matches, the request will continue after the specified delay.')}</Typography.Text>
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
