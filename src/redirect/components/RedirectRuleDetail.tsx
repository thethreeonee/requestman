import React, { useMemo, useState } from 'react';
import {
  Button,
  Collapse,
  Drawer,
  Dropdown,
  Form,
  Input,
  Modal,
  Popconfirm,
  Radio,
  Select,
  Space,
  Switch,
  Typography,
} from 'antd';
import {
  ArrowLeftOutlined,
  DeleteOutlined,
  EditOutlined,
  EllipsisOutlined,
  FilterOutlined,
  PlusOutlined,
} from '@ant-design/icons';
import { MATCH_MODE_OPTIONS, MATCH_TARGET_OPTIONS, REQUEST_METHOD_OPTIONS, RESOURCE_TYPE_OPTIONS } from '../constants';
import { createDefaultCondition, genId, simulateRedirect } from '../rule-utils';
import type { RedirectCondition, RedirectGroup, RedirectRule } from '../types';

type Props = {
  groups: RedirectGroup[];
  workingRule: RedirectRule;
  originalRule: RedirectRule | null;
  setWorkingRule: React.Dispatch<React.SetStateAction<RedirectRule | null>>;
  setRules: React.Dispatch<React.SetStateAction<RedirectRule[]>>;
  onBack: () => void;
  saveDetailRule: () => void;
  setPageToList: () => void;
  messageApi: { warning: (content: string) => void };
};

export default function RedirectRuleDetail({
  groups,
  workingRule,
  originalRule,
  setWorkingRule,
  setRules,
  onBack,
  saveDetailRule,
  setPageToList,
  messageApi,
}: Props) {
  const [editRuleName, setEditRuleName] = useState(false);
  const [testDrawerOpen, setTestDrawerOpen] = useState(false);
  const [testUrl, setTestUrl] = useState('');
  const [testResult, setTestResult] = useState('');
  const [filterModal, setFilterModal] = useState<{ open: boolean; conditionId?: string }>({ open: false });

  const dirty = originalRule && JSON.stringify(workingRule) !== JSON.stringify(originalRule);
  const currentGroupEnabled = useMemo(() => new Map(groups.map((g) => [g.id, g.enabled])), [groups]);

  const updateCondition = (conditionId: string, patch: Partial<RedirectCondition>) => {
    setWorkingRule((prev) => (prev
      ? { ...prev, conditions: prev.conditions.map((c) => (c.id === conditionId ? { ...c, ...patch } : c)) }
      : prev));
  };

  const removeCondition = (conditionId: string) => {
    if (workingRule.conditions.length <= 1) return messageApi.warning('至少保留一条条件配置');
    setWorkingRule({ ...workingRule, conditions: workingRule.conditions.filter((c) => c.id !== conditionId) });
  };

  const activeCondition = workingRule.conditions.find((c) => c.id === filterModal.conditionId);

  return <div>
    <div className="detail-header">
      <Button type="text" icon={<ArrowLeftOutlined />} onClick={onBack}>返回</Button>
      <Space>
        <Typography.Text>启用规则</Typography.Text>
        <Switch checked={workingRule.enabled} onChange={(v) => setWorkingRule({ ...workingRule, enabled: v })} />
        <Dropdown menu={{ items: [
          { key: 'copy', label: '复制', onClick: () => setWorkingRule({ ...workingRule, id: genId(), name: `${workingRule.name} 副本` }) },
          { key: 'delete', label: '删除', danger: true, onClick: () => Modal.confirm({ title: '确认删除规则？', okButtonProps: { danger: true }, onOk: () => { setRules((prev) => prev.filter((r) => r.id !== workingRule.id)); setPageToList(); } }) },
        ] }}><Button icon={<EllipsisOutlined />} /></Dropdown>
        <Select
          value={workingRule.groupId}
          style={{ width: 220 }}
          options={groups.map((g) => ({ value: g.id, label: `规则组：${g.name}` }))}
          onChange={(v) => setWorkingRule({ ...workingRule, groupId: v })}
          placeholder="规则组：请选择"
        />
        <Button onClick={() => setTestDrawerOpen(true)}>测试</Button>
        <Button type="primary" onClick={saveDetailRule}>{dirty ? '* 保存规则' : '保存规则'}</Button>
      </Space>
    </div>
    <Space align="center" style={{ marginBottom: 16 }}>
      {editRuleName ? <Input value={workingRule.name} onChange={(e) => setWorkingRule({ ...workingRule, name: e.target.value })} onBlur={() => setEditRuleName(false)} /> : <Typography.Title level={4} style={{ margin: 0 }}>{workingRule.name}</Typography.Title>}
      <Button type="text" icon={<EditOutlined />} onClick={() => setEditRuleName(true)} />
    </Space>
    {workingRule.conditions.map((c) => (
      <Collapse
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
            <Space.Compact style={{ width: '100%' }}>
              <Select value={c.matchTarget} options={MATCH_TARGET_OPTIONS as never} style={{ width: 90 }} onChange={(v) => updateCondition(c.id, { matchTarget: v })} />
              <Select value={c.matchMode} options={MATCH_MODE_OPTIONS as never} style={{ width: 110 }} onChange={(v) => updateCondition(c.id, { matchMode: v })} />
              <Input style={{ flex: 1, minWidth: 0 }} value={c.expression} onChange={(e) => updateCondition(c.id, { expression: e.target.value })} />
              <Button icon={<FilterOutlined />} onClick={() => setFilterModal({ open: true, conditionId: c.id })} />
            </Space.Compact>
            <Radio.Group value={c.redirectType} onChange={(e) => updateCondition(c.id, { redirectType: e.target.value })}><Radio value="url">另一个URL</Radio><Radio value="file">本地文件</Radio></Radio.Group>
            <Input value={c.redirectTarget} onChange={(e) => updateCondition(c.id, { redirectTarget: e.target.value })} placeholder="重定向目标" />
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
      添加新条件配置
    </Button>
    <Drawer title="测试规则" placement="bottom" open={testDrawerOpen} height={260} onClose={() => setTestDrawerOpen(false)}>
      <Space.Compact style={{ width: '100%' }}>
        <Input value={testUrl} onChange={(e) => setTestUrl(e.target.value)} placeholder="输入测试URL" />
        <Button onClick={() => {
          const res = simulateRedirect(testUrl, [workingRule], currentGroupEnabled);
          setTestResult(res.ok ? `命中：${res.matchedRule.name} -> ${res.redirectedUrl}` : res.reason);
        }}>测试</Button>
      </Space.Compact>
      <div style={{ marginTop: 12 }}>{testResult}</div>
    </Drawer>
    <Modal open={filterModal.open} title="过滤条件" onCancel={() => setFilterModal({ open: false })} onOk={() => setFilterModal({ open: false })}>
      {activeCondition && <Form layout="vertical">
        <Form.Item label="页面域名"><Input value={activeCondition.filter.pageDomain} onChange={(e) => updateCondition(activeCondition.id, { filter: { ...activeCondition.filter, pageDomain: e.target.value } })} /></Form.Item>
        <Form.Item label="资源类型"><Select value={activeCondition.filter.resourceType} options={RESOURCE_TYPE_OPTIONS as never} onChange={(v) => updateCondition(activeCondition.id, { filter: { ...activeCondition.filter, resourceType: v } })} /></Form.Item>
        <Form.Item label="请求方法"><Select value={activeCondition.filter.requestMethod} options={REQUEST_METHOD_OPTIONS as never} onChange={(v) => updateCondition(activeCondition.id, { filter: { ...activeCondition.filter, requestMethod: v } })} /></Form.Item>
      </Form>}
    </Modal>
  </div>;
}
