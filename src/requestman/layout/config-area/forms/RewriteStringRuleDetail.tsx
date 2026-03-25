import React, { useMemo, useState } from 'react';
import {
  Button,
  Collapse,
  Input,
  Modal,
  Popconfirm,
  Space,
} from '../../../primitives';
import { t } from '../../../i18n';
import {
  DeleteOutlined,
  PlusOutlined,
} from '../../../icons';
import { createDefaultCondition, genId, simulateRuleEffect, type SimulateRuleResult } from '../../../rule-utils';
import type { RedirectCondition } from '../../../types';
import ConditionUrlMatchEditor from '../../../components/ConditionUrlMatchEditor';
import TestRuleDrawer from '../../../components/TestRuleDrawer';
import ConditionFilterModal, { isConditionFilterConfigured } from '../../../components/ConditionFilterModal';
import RuleDetailHeader from '../RuleDetailHeader';
import type { RuleDetailProps as Props } from '../types';

export default function RewriteStringRuleDetail({
  groups,
  workingRule,
  originalRule,
  setWorkingRule,
  setRules,
  saveDetailRule,
  setPageToList,
  messageApi,
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
      messageApi.warning(t('至少保留一条条件配置', 'Keep at least one condition.'));
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
    {workingRule.conditions.map((c) => (
      <Collapse
        key={c.id}
        defaultActiveKey={[c.id]}
        items={[{
          key: c.id,
          label: t('请求条件配置', 'Request conditions'),
          extra: (
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
          ),
          children: <Space direction="vertical" style={{ width: '100%' }}>
            <ConditionUrlMatchEditor
              condition={c}
              filterConfigured={isConditionFilterConfigured(c)}
              onConditionChange={(patch) => updateCondition(c.id, patch)}
              onFilterClick={() => setFilterModal({ open: true, conditionId: c.id })}
            />
            <div style={{ display: 'flex', width: '100%', gap: 8 }}>
              <Space.Compact style={{ flex: 1, minWidth: 0 }}>
                <Space.Addon style={{ flexShrink: 0 }}>{t('目标', 'Target')}</Space.Addon>
                <Input
                  style={{ minWidth: 0 }}
                  value={c.rewriteFrom}
                  onChange={(e) => updateCondition(c.id, { rewriteFrom: e.target.value })}
                  placeholder="from"
                />
              </Space.Compact>
              <Space.Compact style={{ flex: 1, minWidth: 0 }}>
                <Space.Addon style={{ flexShrink: 0 }}>{t('替换为', 'Replace with')}</Space.Addon>
                <Input
                  style={{ minWidth: 0 }}
                  value={c.rewriteTo}
                  onChange={(e) => updateCondition(c.id, { rewriteTo: e.target.value })}
                  placeholder="to"
                />
              </Space.Compact>
            </div>
          </Space>,
        }]}
        style={{ marginBottom: 12 }}
      />
    ))}
    <Button
      type="dashed"
      style={{ marginTop: 12, width: '100%', height: 40, background: 'transparent' }}
      icon={<PlusOutlined />}
      onClick={() => setWorkingRule({ ...workingRule, conditions: [...workingRule.conditions, createDefaultCondition()] })}
    >
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
