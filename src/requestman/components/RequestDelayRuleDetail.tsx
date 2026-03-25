import React, { useMemo, useState } from 'react';
import {
  Button,
  Collapse,
  Form,
  InputNumber,
  Modal,
  Popconfirm,
  Select,
  Space,
  Typography,
} from '../ui';
import { t } from '../i18n';
import {
  DeleteOutlined,
  PlusOutlined,
} from '../ui/icons';
import { createDefaultCondition, genId, simulateRuleEffect, type SimulateRuleResult } from '../rule-utils';
import type { RedirectCondition, RedirectGroup, RedirectRule } from '../types';
import ConditionUrlMatchEditor from './ConditionUrlMatchEditor';
import RuleDetailToolbar from './RuleDetailToolbar';
import RuleNameHeader from './RuleNameHeader';
import TestRuleDrawer from './TestRuleDrawer';
import ConditionFilterModal, { isConditionFilterConfigured } from './ConditionFilterModal';

type Props = {
  groups: RedirectGroup[];
  workingRule: RedirectRule;
  originalRule: RedirectRule | null;
  setWorkingRule: React.Dispatch<React.SetStateAction<RedirectRule | null>>;
  setRules: React.Dispatch<React.SetStateAction<RedirectRule[]>>;
  onBack: () => void;
  saveDetailRule: () => void;
  toggleDetailRuleEnabled: (ruleId: string, enabled: boolean) => void;
  setPageToList: () => void;
  messageApi: { warning: (content: string) => void };
};

export default function RequestDelayRuleDetail({
  groups,
  workingRule,
  originalRule,
  setWorkingRule,
  setRules,
  onBack,
  saveDetailRule,
  toggleDetailRuleEnabled,
  setPageToList,
  messageApi,
}: Props) {
  const [editRuleName, setEditRuleName] = useState(false);
  const [testDrawerOpen, setTestDrawerOpen] = useState(false);
  const [testUrl, setTestUrl] = useState('');
  const [testResult, setTestResult] = useState<SimulateRuleResult | null>(null);
  const [filterModal, setFilterModal] = useState<{ open: boolean; conditionId?: string }>({ open: false });

  const { enabled: _workingEnabled, ...workingRuleWithoutEnabled } = workingRule;
  const { enabled: _originalEnabled, ...originalRuleWithoutEnabled } = originalRule ?? workingRule;
  const dirty = originalRule && JSON.stringify(workingRuleWithoutEnabled) !== JSON.stringify(originalRuleWithoutEnabled);
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
    <RuleDetailToolbar
      groups={groups}
      groupId={workingRule.groupId}
      enabled={workingRule.enabled}
      dirty={!!dirty}
      onBack={onBack}
      onEnabledChange={(v) => toggleDetailRuleEnabled(workingRule.id, v)}
      onGroupChange={(v) => setWorkingRule({ ...workingRule, groupId: v })}
      onTest={() => setTestDrawerOpen(true)}
      onSave={saveDetailRule}
      menuItems={[
        { key: 'copy', label: t('复制', 'Duplicate'), onClick: () => setWorkingRule({ ...workingRule, id: genId(), name: `${workingRule.name} ${t('副本', 'Copy')}` }) },
        { key: 'delete', label: t('删除', 'Delete'), danger: true, onClick: () => Modal.confirm({ title: t('确认删除规则？', 'Delete this rule?'), okButtonProps: { danger: true }, onOk: () => { setRules((prev) => prev.filter((r) => r.id !== workingRule.id)); setPageToList(); } }) },
      ]}
    />
    <RuleNameHeader
      rule={workingRule}
      editRuleName={editRuleName}
      setEditRuleName={setEditRuleName}
      setWorkingRule={setWorkingRule}
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
