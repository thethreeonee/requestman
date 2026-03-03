import React, { useMemo, useState } from 'react';
import {
  Button,
  Collapse,
  Form,
  Input,
  Modal,
  Popconfirm,
  Radio,
  Select,
  Space,
  Typography,
} from 'antd';
import {
  DeleteOutlined,
  EditOutlined,
  PlusOutlined,
} from '@ant-design/icons';
import {
  REQUEST_METHOD_OPTIONS,
  RESOURCE_TYPE_OPTIONS,
} from '../constants';
import {
  createDefaultCondition,
  genId,
  hasModifyRequestBodyFunction,
  simulateRuleEffect,
  type SimulateRuleResult,
} from '../rule-utils';
import CodeMirror from '@uiw/react-codemirror';
import { json } from '@codemirror/lang-json';
import { javascript } from '@codemirror/lang-javascript';
import type { RedirectCondition, RedirectGroup, RedirectRule, RequestBodyModifyMode } from '../types';
import ConditionUrlMatchEditor from './ConditionUrlMatchEditor';
import RuleDetailToolbar from './RuleDetailToolbar';
import TestRuleDrawer from './TestRuleDrawer';

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

function validateDynamicScript(code: string): string | null {
  if (!hasModifyRequestBodyFunction(code)) return '需定义 modifyRequestBody(args) 方法';
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

  const updateConditionMode = (conditionId: string, mode: RequestBodyModifyMode) => {
    const condition = workingRule.conditions.find((item) => item.id === conditionId);
    if (!condition) return;
    const nextValue = mode === 'dynamic' ? condition.requestBodyDynamicValue : condition.requestBodyStaticValue;
    updateCondition(conditionId, { requestBodyMode: mode, requestBodyValue: nextValue });
  };

  const removeCondition = (conditionId: string) => {
    if (workingRule.conditions.length <= 1) return messageApi.warning('至少保留一条条件配置');
    setWorkingRule({ ...workingRule, conditions: workingRule.conditions.filter((c) => c.id !== conditionId) });
  };

  const isFilterConfigured = (condition: RedirectCondition) => !!condition.filter.pageDomain.trim()
    || condition.filter.resourceType !== 'all'
    || condition.filter.requestMethod !== 'all';

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
        { key: 'copy', label: '复制', onClick: () => setWorkingRule({ ...workingRule, id: genId(), name: `${workingRule.name} 副本` }) },
        { key: 'delete', label: '删除', danger: true, onClick: () => Modal.confirm({ title: '确认删除规则？', okButtonProps: { danger: true }, onOk: () => { setRules((prev) => prev.filter((r) => r.id !== workingRule.id)); setPageToList(); } }) },
      ]}
    />
    <Space align="center" style={{ marginBottom: 16 }}>
      {editRuleName ? <Input value={workingRule.name} onChange={(e) => setWorkingRule({ ...workingRule, name: e.target.value })} onBlur={() => setEditRuleName(false)} onPressEnter={() => setEditRuleName(false)} /> : <Typography.Title level={4} style={{ margin: 0 }}>{workingRule.name}</Typography.Title>}
      <Button type="text" icon={<EditOutlined />} onClick={() => setEditRuleName(true)} />
    </Space>
    {workingRule.conditions.map((c) => {
      const dynamicScriptError = c.requestBodyMode === 'dynamic' ? validateDynamicScript(c.requestBodyDynamicValue) : null;
      return <Collapse
        key={c.id}
        defaultActiveKey={[c.id]}
        items={[{
          key: c.id,
          label: '请求条件配置',
          extra: (
            <Popconfirm
              title="确认删除该条件配置？"
              okText="删除"
              cancelText="取消"
              okButtonProps={{ danger: true, type: 'primary' }}
              onConfirm={() => removeCondition(c.id)}
            >
              <span
                role="button"
                tabIndex={0}
                aria-label="删除条件"
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
              filterConfigured={isFilterConfigured(c)}
              onConditionChange={(patch) => updateCondition(c.id, patch)}
              onFilterClick={() => setFilterModal({ open: true, conditionId: c.id })}
            />
            <Form.Item label="修改方式" style={{ marginBottom: 8 }}>
              <Radio.Group
                value={c.requestBodyMode}
                onChange={(e) => updateConditionMode(c.id, e.target.value)}
                options={[
                  { label: '静态数据', value: 'static' },
                  { label: '动态（JavaScript）', value: 'dynamic' },
                ]}
              />
            </Form.Item>
            <Form.Item
              label={c.requestBodyMode === 'dynamic' ? 'JavaScript 代码' : '替换后的请求体'}
              validateStatus={dynamicScriptError ? 'error' : ''}
              help={dynamicScriptError ?? (c.requestBodyMode === 'dynamic' ? '需定义 modifyRequestBody(args) 并返回最终请求体' : '命中后会直接替换原始请求 body')}
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
          </Space>,
        }]}
        style={{ marginBottom: 12 }}
      />;
    })}
    <Button
      type="dashed"
      style={{ marginTop: 12, width: '100%', height: 40, background: 'transparent' }}
      icon={<PlusOutlined />}
      onClick={() => setWorkingRule({ ...workingRule, conditions: [...workingRule.conditions, createDefaultCondition()] })}
    >
      添加新条件配置
    </Button>
    <TestRuleDrawer
      open={testDrawerOpen}
      testUrl={testUrl}
      testResult={testResult}
      onClose={() => setTestDrawerOpen(false)}
      onTest={() => setTestResult(simulateRuleEffect(testUrl, [workingRule], currentGroupEnabled, { includeDisabled: true }))}
      onTestUrlChange={setTestUrl}
    />
    <Modal open={filterModal.open} title="过滤条件" onCancel={() => setFilterModal({ open: false })} onOk={() => setFilterModal({ open: false })}>
      {activeCondition && <Form layout="vertical">
        <Form.Item label="页面域名"><Input value={activeCondition.filter.pageDomain} onChange={(e) => updateCondition(activeCondition.id, { filter: { ...activeCondition.filter, pageDomain: e.target.value } })} /></Form.Item>
        <Form.Item label="资源类型"><Select value={activeCondition.filter.resourceType} options={RESOURCE_TYPE_OPTIONS as never} onChange={(v) => updateCondition(activeCondition.id, { filter: { ...activeCondition.filter, resourceType: v } })} /></Form.Item>
        <Form.Item label="请求方法"><Select value={activeCondition.filter.requestMethod} options={REQUEST_METHOD_OPTIONS as never} onChange={(v) => updateCondition(activeCondition.id, { filter: { ...activeCondition.filter, requestMethod: v } })} /></Form.Item>
      </Form>}
    </Modal>
  </div>;
}
