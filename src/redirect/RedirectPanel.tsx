import React, { useEffect, useMemo, useState } from 'react';
import {
  App,
  AutoComplete,
  Button,
  Collapse,
  Drawer,
  Dropdown,
  Form,
  Input,
  Modal,
  Radio,
  Select,
  Space,
  Switch,
  Table,
  Tag,
  Tooltip,
  Typography,
} from 'antd';
import {
  ArrowLeftOutlined,
  EditOutlined,
  EllipsisOutlined,
  FilterOutlined,
  PlusOutlined,
  RightOutlined,
} from '@ant-design/icons';
import {
  DEFAULT_GROUP_ID,
  DEFAULT_GROUP_NAME,
  MATCH_MODE_OPTIONS,
  MATCH_TARGET_OPTIONS,
  REDIRECT_ENABLED_KEY,
  REDIRECT_GROUPS_KEY,
  REDIRECT_RULES_KEY,
  REQUEST_METHOD_OPTIONS,
  RESOURCE_TYPE_OPTIONS,
} from './constants';
import { createDefaultCondition, genId, normalizeGroups, normalizeRules, simulateRedirect } from './rule-utils';
import type { RedirectCondition, RedirectGroup, RedirectRule } from './types';
import './index.css';

type PageState = { type: 'list' } | { type: 'detail'; ruleId: string };

export default function RedirectPanel() {
  const { message } = App.useApp();
  const [groups, setGroups] = useState<RedirectGroup[]>([]);
  const [rules, setRules] = useState<RedirectRule[]>([]);
  const [redirectEnabled, setRedirectEnabled] = useState(true);
  const [rulesLoaded, setRulesLoaded] = useState(false);
  const [collapsedGroupIds, setCollapsedGroupIds] = useState<string[]>([]);
  const [groupModal, setGroupModal] = useState<{ open: boolean; mode: 'create' | 'rename' | 'move'; groupId?: string; ruleId?: string }>({ open: false, mode: 'create' });
  const [groupInput, setGroupInput] = useState('');
  const [page, setPage] = useState<PageState>({ type: 'list' });
  const [editRuleName, setEditRuleName] = useState(false);
  const [workingRule, setWorkingRule] = useState<RedirectRule | null>(null);
  const [originalRule, setOriginalRule] = useState<RedirectRule | null>(null);
  const [testDrawerOpen, setTestDrawerOpen] = useState(false);
  const [testUrl, setTestUrl] = useState('');
  const [testResult, setTestResult] = useState('');
  const [filterModal, setFilterModal] = useState<{ open: boolean; conditionId?: string }>({ open: false });

  useEffect(() => {
    chrome.storage.local.get([REDIRECT_RULES_KEY, REDIRECT_ENABLED_KEY, REDIRECT_GROUPS_KEY], (res) => {
      const normalizedGroups = normalizeGroups(res?.[REDIRECT_GROUPS_KEY]);
      const groupIds = new Set(normalizedGroups.map((g) => g.id));
      setGroups(normalizedGroups);
      setRules(normalizeRules(res?.[REDIRECT_RULES_KEY], groupIds, normalizedGroups[0]?.id ?? DEFAULT_GROUP_ID));
      setRedirectEnabled(res?.[REDIRECT_ENABLED_KEY] !== false);
      setRulesLoaded(true);
    });
  }, []);

  useEffect(() => {
    if (!rulesLoaded) return;
    chrome.storage.local.set({ [REDIRECT_GROUPS_KEY]: groups, [REDIRECT_RULES_KEY]: rules, [REDIRECT_ENABLED_KEY]: redirectEnabled });
    chrome.runtime.sendMessage({ type: 'redirectRules/apply', groups, rules, enabled: redirectEnabled });
  }, [groups, rules, redirectEnabled, rulesLoaded]);

  const groupNameMap = useMemo(() => new Map(groups.map((g) => [g.id, g.name])), [groups]);
  const groupsOptions = groups.map((g) => ({ value: g.name }));

  const openRuleDetail = (ruleId: string) => {
    const found = rules.find((r) => r.id === ruleId);
    if (!found) return;
    setWorkingRule(JSON.parse(JSON.stringify(found)));
    setOriginalRule(JSON.parse(JSON.stringify(found)));
    setEditRuleName(false);
    setPage({ type: 'detail', ruleId });
  };

  const createRule = () => {
    const groupId = groups[0]?.id;
    if (!groupId) return;
    const newRule: RedirectRule = { id: genId(), name: `新建规则 ${rules.length + 1}`, enabled: true, groupId, conditions: [createDefaultCondition()] };
    setRules((prev) => [newRule, ...prev]);
    openRuleDetail(newRule.id);
  };

  const onBack = () => {
    if (!workingRule || !originalRule) return setPage({ type: 'list' });
    if (JSON.stringify(workingRule) !== JSON.stringify(originalRule)) {
      Modal.confirm({
        title: '存在未保存修改',
        content: '修改不会被保存，确认返回吗？',
        onOk: () => setPage({ type: 'list' }),
      });
      return;
    }
    setPage({ type: 'list' });
  };

  const saveDetailRule = () => {
    if (!workingRule) return;
    const invalid = workingRule.conditions.some((c) => !c.expression.trim() || !c.redirectTarget.trim());
    if (invalid) return message.warning('还有条件配置未输入完整');
    setRules((prev) => prev.map((r) => (r.id === workingRule.id ? workingRule : r)));
    setOriginalRule(JSON.parse(JSON.stringify(workingRule)));
    message.success('规则已保存');
  };

  const moveRuleToGroup = () => {
    if (!groupModal.ruleId) return;
    const name = groupInput.trim();
    if (!name) return;
    let target = groups.find((g) => g.name === name);
    if (!target) {
      target = { id: genId(), name, enabled: true };
      setGroups((prev) => [...prev, target!]);
    }
    setRules((prev) => prev.map((r) => (r.id === groupModal.ruleId ? { ...r, groupId: target!.id } : r)));
    setGroupModal({ open: false, mode: 'create' });
    setGroupInput('');
  };

  const confirmGroupModal = () => {
    if (groupModal.mode === 'move') return moveRuleToGroup();
    const name = groupInput.trim();
    if (!name) return;
    if (groupModal.mode === 'create') setGroups((prev) => [{ id: genId(), name, enabled: true }, ...prev]);
    if (groupModal.mode === 'rename' && groupModal.groupId) setGroups((prev) => prev.map((g) => (g.id === groupModal.groupId ? { ...g, name } : g)));
    setGroupModal({ open: false, mode: 'create' });
    setGroupInput('');
  };

  const deleteGroup = (groupId: string) => {
    Modal.confirm({ title: '确认删除该规则组？', okButtonProps: { danger: true }, onOk: () => {
      setGroups((prev) => prev.filter((g) => g.id !== groupId));
      setRules((prev) => prev.filter((r) => r.groupId !== groupId));
    } });
  };

  const duplicateGroup = (groupId: string) => {
    const group = groups.find((g) => g.id === groupId);
    if (!group) return;
    const newGroupId = genId();
    setGroups((prev) => {
      const idx = prev.findIndex((g) => g.id === groupId);
      const cp = { ...group, id: newGroupId, name: `${group.name} 副本` };
      const next = [...prev]; next.splice(idx + 1, 0, cp); return next;
    });
    setRules((prev) => {
      const selected = prev.filter((r) => r.groupId === groupId).map((r) => ({ ...r, id: genId(), groupId: newGroupId, name: `${r.name} 副本` }));
      return [...prev, ...selected];
    });
  };

  const tableData = groups.flatMap((group) => {
    const groupRow = { key: `group-${group.id}`, rowType: 'group' as const, group };
    if (collapsedGroupIds.includes(group.id)) return [groupRow];
    const children = rules.filter((r) => r.groupId === group.id).map((rule) => ({ key: `rule-${rule.id}`, rowType: 'rule' as const, rule, group }));
    return [groupRow, ...children];
  });

  const currentGroupEnabled = useMemo(() => new Map(groups.map((g) => [g.id, g.enabled])), [groups]);

  if (page.type === 'detail' && workingRule) {
    const dirty = originalRule && JSON.stringify(workingRule) !== JSON.stringify(originalRule);
    const updateCondition = (conditionId: string, patch: Partial<RedirectCondition>) => {
      setWorkingRule((prev) => prev ? { ...prev, conditions: prev.conditions.map((c) => (c.id === conditionId ? { ...c, ...patch } : c)) } : prev);
    };
    const openFilter = (conditionId: string) => setFilterModal({ open: true, conditionId });
    const removeCondition = (conditionId: string) => {
      if (workingRule.conditions.length <= 1) return message.warning('至少保留一条条件配置');
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
            { key: 'delete', label: '删除', danger: true, onClick: () => Modal.confirm({ title: '确认删除规则？', okButtonProps: { danger: true }, onOk: () => { setRules((prev) => prev.filter((r) => r.id !== workingRule.id)); setPage({ type: 'list' }); } }) },
          ] }}><Button type="text" icon={<EllipsisOutlined />} /></Dropdown>
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
      {workingRule.conditions.map((c, index) => (
        <Collapse
          key={c.id}
          defaultActiveKey={[c.id]}
          items={[{
            key: c.id,
            label: `如果请求 ${index + 1}`,
            extra: <Button type="text" danger onClick={(e) => { e.stopPropagation(); removeCondition(c.id); }}>删除</Button>,
            children: <Space direction="vertical" style={{ width: '100%' }}>
              <Input addonBefore={<Space><Select value={c.matchTarget} options={MATCH_TARGET_OPTIONS as never} style={{ width: 90 }} onChange={(v) => updateCondition(c.id, { matchTarget: v })} /><Select value={c.matchMode} options={MATCH_MODE_OPTIONS as never} style={{ width: 110 }} onChange={(v) => updateCondition(c.id, { matchMode: v })} /></Space>} value={c.expression} onChange={(e) => updateCondition(c.id, { expression: e.target.value })} addonAfter={<Button type="text" icon={<FilterOutlined />} onClick={() => openFilter(c.id)} />} />
              <Radio.Group value={c.redirectType} onChange={(e) => updateCondition(c.id, { redirectType: e.target.value })}><Radio value="url">另一个URL</Radio><Radio value="file">本地文件</Radio></Radio.Group>
              <Input value={c.redirectTarget} onChange={(e) => updateCondition(c.id, { redirectTarget: e.target.value })} placeholder="重定向目标" />
            </Space>,
          }]}
          style={{ marginBottom: 12 }}
        />
      ))}
      <Button style={{ marginTop: 12 }} icon={<PlusOutlined />} onClick={() => setWorkingRule({ ...workingRule, conditions: [...workingRule.conditions, createDefaultCondition()] })}>添加新条件配置</Button>
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

  return <div>
    <div className="detail-header">
      <Space><Typography.Title level={4} style={{ margin: 0 }}>重定向请求</Typography.Title><Switch checked={redirectEnabled} onChange={setRedirectEnabled} /></Space>
      <Space><Button onClick={() => { setGroupModal({ open: true, mode: 'create' }); setGroupInput(''); }}>新建规则组</Button><Button type="primary" onClick={createRule}>新建规则</Button></Space>
    </div>
    <Table
      pagination={false}
      dataSource={tableData}
      rowKey="key"
      columns={[
        { title: '规则', dataIndex: 'rule', render: (_, row: any) => row.rowType === 'group' ? <Space><Button type="text" className="group-collapse-btn" onClick={() => setCollapsedGroupIds((prev) => prev.includes(row.group.id) ? prev.filter((id) => id !== row.group.id) : [...prev, row.group.id])}><RightOutlined className={collapsedGroupIds.includes(row.group.id) ? '' : 'expanded'} /></Button><Typography.Text strong>{row.group.name}</Typography.Text></Space> : <Button type="link" style={{ marginLeft: 32, paddingInline: 0 }} onClick={() => openRuleDetail(row.rule.id)}>{row.rule.name}</Button> },
        { title: '类型', render: (_, row: any) => row.rowType === 'group' ? '-' : <Tag>重定向请求</Tag> },
        { title: '状态', render: (_, row: any) => row.rowType === 'group' ? <Switch checked={row.group.enabled} disabled={!redirectEnabled} onChange={(v) => setGroups((prev) => prev.map((g) => g.id === row.group.id ? { ...g, enabled: v } : g))} /> : <Switch checked={row.rule.enabled} disabled={!redirectEnabled || !currentGroupEnabled.get(row.rule.groupId)} onChange={(v) => setRules((prev) => prev.map((r) => r.id === row.rule.id ? { ...r, enabled: v } : r))} /> },
        { title: '操作', render: (_, row: any) => row.rowType === 'group' ? <Dropdown menu={{ items: [
          { key: 'rename', label: '重命名', onClick: () => { setGroupModal({ open: true, mode: 'rename', groupId: row.group.id }); setGroupInput(row.group.name); } },
          { key: 'copy', label: '复制', onClick: () => duplicateGroup(row.group.id) },
          { key: 'delete', label: '删除', danger: true, onClick: () => deleteGroup(row.group.id) },
        ] }}><Button type="text" icon={<EllipsisOutlined />} /></Dropdown> : <Dropdown menu={{ items: [
          { key: 'move', label: '修改规则组', onClick: () => { setGroupModal({ open: true, mode: 'move', ruleId: row.rule.id }); setGroupInput(groupNameMap.get(row.rule.groupId) ?? ''); } },
          { key: 'copy', label: '复制', onClick: () => setRules((prev) => { const idx = prev.findIndex((r) => r.id === row.rule.id); const next = [...prev]; next.splice(idx + 1, 0, { ...row.rule, id: genId(), name: `${row.rule.name} 副本` }); return next; }) },
          { key: 'delete', label: '删除', danger: true, onClick: () => Modal.confirm({ title: '确认删除规则？', okButtonProps: { danger: true }, onOk: () => setRules((prev) => prev.filter((r) => r.id !== row.rule.id)) }) },
        ] }}><Button type="text" icon={<EllipsisOutlined />} /></Dropdown> },
      ]}
    />
    <Modal open={groupModal.open} title={groupModal.mode === 'create' ? '新建规则组' : groupModal.mode === 'rename' ? '重命名规则组' : '修改规则组'} onCancel={() => setGroupModal({ open: false, mode: 'create' })} onOk={confirmGroupModal}>
      {groupModal.mode === 'move' ? <AutoComplete options={groupsOptions} value={groupInput} onChange={setGroupInput} placeholder="请选择或输入新规则组" /> : <Input value={groupInput} onChange={(e) => setGroupInput(e.target.value)} placeholder="请输入名称" />}
    </Modal>
  </div>;
}
