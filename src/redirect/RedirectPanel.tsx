import React, { useEffect, useMemo, useRef, useState } from 'react';
import {
  App,
  Button,
  Dropdown,
  Input,
  Modal,
  Popconfirm,
  Select,
  Space,
  Switch,
  Typography,
} from 'antd';
import {
  DeleteOutlined,
  DownloadOutlined,
  EditOutlined,
  EllipsisOutlined,
  PlusOutlined,
  UploadOutlined,
} from '@ant-design/icons';
import './index.css';
import {
  DEFAULT_GROUP_ID,
  DEFAULT_GROUP_NAME,
  REDIRECT_ENABLED_KEY,
  REDIRECT_GROUPS_KEY,
  REDIRECT_RULES_KEY,
} from './constants';
import { genId, isRuleEffectivelyEnabled, normalizeGroups, normalizeRules, simulateRedirect } from './rule-utils';
import type { MatchMode, MatchTarget, RedirectGroup, RedirectRule } from './types';

const MATCH_TARGET_OPTIONS: { label: string; value: MatchTarget }[] = [
  { label: 'URL', value: 'url' },
  { label: 'Host', value: 'host' },
];

const MATCH_MODE_OPTIONS: { label: string; value: MatchMode }[] = [
  { label: '等于', value: 'equals' },
  { label: '包含', value: 'contains' },
  { label: '通配符', value: 'wildcard' },
  { label: '正则', value: 'regex' },
];

function RedirectPanel() {
  const { message } = App.useApp();
  const [groups, setGroups] = useState<RedirectGroup[]>([]);
  const [rules, setRules] = useState<RedirectRule[]>([]);
  const [newGroupName, setNewGroupName] = useState('');
  const [createGroupModalOpen, setCreateGroupModalOpen] = useState(false);
  const [editGroupModalOpen, setEditGroupModalOpen] = useState(false);
  const [editingGroupId, setEditingGroupId] = useState<string | null>(null);
  const [editingGroupName, setEditingGroupName] = useState('');
  const [redirectEnabled, setRedirectEnabled] = useState(true);
  const [rulesLoaded, setRulesLoaded] = useState(false);
  const [testUrl, setTestUrl] = useState('');
  const [testTrigger, setTestTrigger] = useState(0);
  const [highlightedRuleId, setHighlightedRuleId] = useState<string | null>(null);
  const applySourceRef = useRef<'init' | 'input' | 'non_input' | 'add' | 'group_toggle'>('init');
  const highlightTimerRef = useRef<number | null>(null);
  const listScrollRef = useRef<HTMLDivElement | null>(null);
  const importInputRef = useRef<HTMLInputElement | null>(null);

  useEffect(() => {
    chrome.storage.local.get([REDIRECT_RULES_KEY, REDIRECT_ENABLED_KEY, REDIRECT_GROUPS_KEY], (res) => {
      const normalizedGroups = normalizeGroups(res?.[REDIRECT_GROUPS_KEY]);
      const groupIds = new Set(normalizedGroups.map((g) => g.id));
      const fallbackGroupId = normalizedGroups[0]?.id ?? DEFAULT_GROUP_ID;
      setGroups(normalizedGroups);
      setRules(normalizeRules(res?.[REDIRECT_RULES_KEY], groupIds, fallbackGroupId));
      setRedirectEnabled(res?.[REDIRECT_ENABLED_KEY] !== false);
      setRulesLoaded(true);
    });
  }, []);

  const addRule = (groupId: string) => {
    applySourceRef.current = 'add';
    setRules((prev) => [{
      id: genId(),
      enabled: true,
      groupId,
      matchTarget: 'url',
      matchMode: 'contains',
      expression: '',
      redirectUrl: '',
    }, ...prev]);
  };

  const updateRule = <K extends keyof RedirectRule>(id: string, key: K, value: RedirectRule[K]) => {
    setRules((prev) => prev.map((r) => (r.id === id ? { ...r, [key]: value } : r)));
  };

  const removeRule = (id: string) => {
    applySourceRef.current = 'non_input';
    setRules((prev) => prev.filter((r) => r.id !== id));
    message.success('已删除规则');
  };

  const duplicateRule = (id: string) => {
    applySourceRef.current = 'non_input';
    setRules((prev) => {
      const idx = prev.findIndex((r) => r.id === id);
      if (idx < 0) return prev;
      const next = [...prev];
      next.splice(idx + 1, 0, { ...next[idx], id: genId() });
      return next;
    });
    message.success('已复制规则');
  };

  const createGroup = () => {
    const name = newGroupName.trim();
    if (!name) {
      message.warning('请输入分组名称');
      return false;
    }
    applySourceRef.current = 'non_input';
    const next: RedirectGroup = { id: genId(), name, enabled: true };
    setGroups((prev) => [next, ...prev]);
    setNewGroupName('');
    message.success(`已创建分组：${name}`);
    return true;
  };

  const toggleGroupEnabled = (id: string, enabled: boolean) => {
    applySourceRef.current = 'group_toggle';
    const groupName = groups.find((g) => g.id === id)?.name || '未命名分组';
    setGroups((prev) => prev.map((g) => (g.id === id ? { ...g, enabled } : g)));
    enabled ? message.success(`已开启分组：${groupName}`) : message.warning(`已关闭分组：${groupName}`);
  };

  const removeGroup = (groupId: string) => {
    const groupName = groups.find((g) => g.id === groupId)?.name || '未命名分组';
    applySourceRef.current = 'non_input';
    setGroups((prev) => {
      const next = prev.filter((g) => g.id !== groupId);
      if (next.length > 0) return next;
      return [{ id: DEFAULT_GROUP_ID, name: DEFAULT_GROUP_NAME, enabled: true }];
    });
    setRules((prev) => prev.filter((r) => r.groupId !== groupId));
    message.success(`已删除分组：${groupName}`);
  };

  const openEditGroupModal = (groupId: string) => {
    const group = groups.find((g) => g.id === groupId);
    if (!group) return;
    setEditingGroupId(groupId);
    setEditingGroupName(group.name);
    setEditGroupModalOpen(true);
  };

  const submitEditGroupName = () => {
    if (!editingGroupId) return false;
    const nextName = editingGroupName.trim();
    if (!nextName) {
      message.warning('请输入分组名称');
      return false;
    }
    applySourceRef.current = 'non_input';
    setGroups((prev) => prev.map((g) => (g.id === editingGroupId ? { ...g, name: nextName } : g)));
    setEditGroupModalOpen(false);
    setEditingGroupId(null);
    setEditingGroupName('');
    message.success(`已更新分组名称为：${nextName}`);
    return true;
  };

  const exportRules = () => {
    try {
      const grouped = groups.map((g) => ({
        id: g.id,
        name: g.name,
        enabled: g.enabled,
        rules: rules.filter((r) => r.groupId === g.id),
      }));
      const payload = { version: 2, enabled: redirectEnabled, groups: grouped };
      const blob = new Blob([JSON.stringify(payload, null, 2)], { type: 'application/json;charset=utf-8' });
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = `asap-redirect-rules-${new Date().toISOString().slice(0, 19).replace(/:/g, '-')}.json`;
      document.body.appendChild(a);
      a.click();
      a.remove();
      URL.revokeObjectURL(url);
      message.success('导出成功');
    } catch (err) {
      message.error(`导出失败: ${String((err as Error)?.message || err)}`);
    }
  };

  const importRulesFromFile = async (file: File) => {
    try {
      const text = await file.text();
      const parsed = JSON.parse(text) as unknown;
      let importedGroups = groups;
      let importedRules: RedirectRule[] = [];
      let importedEnabled = redirectEnabled;

      if (Array.isArray(parsed)) {
        const groupIds = new Set(importedGroups.map((g) => g.id));
        importedRules = normalizeRules(parsed, groupIds, importedGroups[0]?.id ?? DEFAULT_GROUP_ID);
      } else if (parsed && typeof parsed === 'object') {
        const obj = parsed as Record<string, unknown>;
        const groupedInput = Array.isArray(obj.groups) ? obj.groups : [];
        const hasNestedRules = groupedInput.some(
          (it) => it && typeof it === 'object' && Array.isArray((it as Record<string, unknown>).rules),
        );

        if (hasNestedRules) {
          importedGroups = normalizeGroups(
            groupedInput.map((it) => {
              const x = (it && typeof it === 'object' ? it : {}) as Record<string, unknown>;
              return { id: x.id, name: x.name, enabled: x.enabled };
            }),
          );
          const flatRules: unknown[] = [];
          for (const g of groupedInput) {
            if (!g || typeof g !== 'object') continue;
            const gx = g as Record<string, unknown>;
            if (!Array.isArray(gx.rules) || typeof gx.id !== 'string') continue;
            for (const r of gx.rules) {
              if (!r || typeof r !== 'object') continue;
              flatRules.push({ ...(r as Record<string, unknown>), groupId: gx.id });
            }
          }
          const groupIds = new Set(importedGroups.map((g) => g.id));
          importedRules = normalizeRules(flatRules, groupIds, importedGroups[0]?.id ?? DEFAULT_GROUP_ID);
        } else {
          importedGroups = normalizeGroups(obj.groups);
          const groupIds = new Set(importedGroups.map((g) => g.id));
          importedRules = normalizeRules(obj.rules, groupIds, importedGroups[0]?.id ?? DEFAULT_GROUP_ID);
        }
        if (typeof obj.enabled === 'boolean') importedEnabled = obj.enabled;
      } else {
        throw new Error('文件内容格式不正确');
      }

      applySourceRef.current = 'non_input';
      setGroups(importedGroups);
      setRules(importedRules);
      setRedirectEnabled(importedEnabled);
      message.success(`导入成功，共 ${importedRules.length} 条规则`);
    } catch (err) {
      message.error(`导入失败: ${String((err as Error)?.message || err)}`);
    } finally {
      if (importInputRef.current) importInputRef.current.value = '';
    }
  };

  const persistRules = (nextGroups: RedirectGroup[], nextRules: RedirectRule[], enabled: boolean) => {
    chrome.storage.local.set(
      { [REDIRECT_GROUPS_KEY]: nextGroups, [REDIRECT_RULES_KEY]: nextRules, [REDIRECT_ENABLED_KEY]: enabled },
      () => {
        chrome.runtime.sendMessage({ type: 'redirectRules/apply', groups: nextGroups, rules: nextRules, enabled }, () => {
          if (chrome.runtime.lastError) {
            message.error(`应用失败: ${chrome.runtime.lastError.message}`);
          }
        });
      },
    );
  };

  useEffect(() => {
    if (!rulesLoaded) return;
    const timer = window.setTimeout(() => {
      persistRules(groups, rules, redirectEnabled);
      applySourceRef.current = 'input';
    }, 100);
    return () => window.clearTimeout(timer);
  }, [groups, rules, redirectEnabled, rulesLoaded]);

  const groupEnabledMap = useMemo(() => new Map(groups.map((g) => [g.id, g.enabled] as const)), [groups]);
  const groupNameMap = useMemo(() => new Map(groups.map((g) => [g.id, g.name] as const)), [groups]);

  const rulesByGroup = useMemo(() => {
    const m = new Map<string, RedirectRule[]>();
    for (const g of groups) m.set(g.id, []);
    for (const rule of rules) {
      const list = m.get(rule.groupId);
      if (list) list.push(rule);
    }
    return m;
  }, [groups, rules]);

  const invalidCount = useMemo(
    () => rules.filter((r) => !r.expression.trim() || !r.redirectUrl.trim() || !groups.find((g) => g.id === r.groupId)).length,
    [groups, rules],
  );

  const testResult = useMemo(() => {
    if (testTrigger === 0) return null;
    const t = testUrl.trim();
    if (!t) return null;
    return simulateRedirect(t, rules, groupEnabledMap);
  }, [groupEnabledMap, rules, testTrigger, testUrl]);

  useEffect(() => {
    if (!testResult?.ok) return;
    const ruleId = testResult.matchedRule.id;
    setHighlightedRuleId(ruleId);

    if (highlightTimerRef.current != null) window.clearTimeout(highlightTimerRef.current);
    highlightTimerRef.current = window.setTimeout(() => {
      setHighlightedRuleId((cur) => (cur === ruleId ? null : cur));
    }, 2000);

    const container = listScrollRef.current;
    if (!container) return;
    const target = container.querySelector(`[data-rule-id="${ruleId}"]`) as HTMLDivElement | null;
    if (!target) return;
    target.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
  }, [testResult]);

  const actionsMenu = {
    items: [
      { key: 'import', label: '导入配置', icon: <UploadOutlined /> },
      { key: 'export', label: '导出配置', icon: <DownloadOutlined /> },
    ],
    onClick: ({ key }: { key: string }) => {
      if (key === 'import') {
        Modal.confirm({
          title: '确认导入配置？',
          content: '导入后将覆盖当前所有分组和规则配置，此操作不可撤销。',
          okText: '确认导入',
          cancelText: '取消',
          okButtonProps: { danger: true },
          onOk: () => importInputRef.current?.click(),
        });
        return;
      }
      if (key === 'export') exportRules();
    },
  };

  return (
    <div style={{ width: '100vw', height: '100vh', boxSizing: 'border-box', display: 'flex', flexDirection: 'column' }}>
      <div style={{ flex: 1, minHeight: 0, padding: 12, boxSizing: 'border-box' }}>
        <div style={{ height: '100%', display: 'flex', flexDirection: 'column', minHeight: 0 }}>
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 8 }}>
            <Space size={8}>
              <Typography.Title level={5} style={{ margin: 0 }}>请求重定向规则</Typography.Title>
              <Switch
                checked={redirectEnabled}
                onChange={(checked) => {
                  applySourceRef.current = 'non_input';
                  setRedirectEnabled(checked);
                  checked ? message.success('已开启重定向') : message.warning('已关闭重定向');
                }}
              />
            </Space>
            <Space size={8}>
              <Dropdown menu={actionsMenu} trigger={['hover']}>
                <Button icon={<EllipsisOutlined />} />
              </Dropdown>
              <Button type="primary" icon={<PlusOutlined />} onClick={() => setCreateGroupModalOpen(true)}>创建分组</Button>
            </Space>
          </div>

          <Modal
            title="创建分组"
            open={createGroupModalOpen}
            onCancel={() => setCreateGroupModalOpen(false)}
            onOk={() => { if (createGroup()) setCreateGroupModalOpen(false); }}
            okText="创建"
            cancelText="取消"
            destroyOnClose
          >
            <Input value={newGroupName} placeholder="请输入分组名称" onChange={(e) => setNewGroupName(e.target.value)} />
          </Modal>

          <Modal
            title="编辑分组"
            open={editGroupModalOpen}
            onCancel={() => {
              setEditGroupModalOpen(false);
              setEditingGroupId(null);
              setEditingGroupName('');
            }}
            onOk={() => { submitEditGroupName(); }}
            okText="保存"
            cancelText="取消"
            destroyOnClose
          >
            <Input value={editingGroupName} placeholder="请输入新的分组名称" onChange={(e) => setEditingGroupName(e.target.value)} />
          </Modal>

          <input
            ref={importInputRef}
            type="file"
            accept=".json,application/json"
            style={{ display: 'none' }}
            onChange={(e) => {
              const file = e.target.files?.[0];
              if (!file) return;
              void importRulesFromFile(file);
            }}
          />

          <Typography.Paragraph type="secondary" style={{ marginTop: 0 }}>
            简化为卡片编辑模式：每个分组下直接编辑规则，不再使用表格。
          </Typography.Paragraph>

          <div ref={listScrollRef} style={{ flex: 1, minHeight: 0, overflow: 'auto' }}>
            {groups.map((group) => {
              const groupRules = rulesByGroup.get(group.id) ?? [];
              const activeCount = groupRules.filter((rule) => isRuleEffectivelyEnabled(rule, groupEnabledMap)).length;
              return (
                <div key={group.id} className="simple-group-card">
                  <div className="simple-group-head">
                    <Space>
                      <Typography.Text strong>{group.name}</Typography.Text>
                      <Typography.Text type="secondary">{activeCount}/{groupRules.length} 启用</Typography.Text>
                    </Space>
                    <Space>
                      <Switch checked={group.enabled && redirectEnabled} onChange={(checked) => toggleGroupEnabled(group.id, checked)} />
                      <Button size="small" icon={<EditOutlined />} onClick={() => openEditGroupModal(group.id)}>
                        编辑
                      </Button>
                      <Popconfirm title="删除分组？" description="该分组下规则会一并删除" onConfirm={() => removeGroup(group.id)}>
                        <Button size="small" danger icon={<DeleteOutlined />}>删除</Button>
                      </Popconfirm>
                      <Button size="small" type="primary" onClick={() => addRule(group.id)}>新增规则</Button>
                    </Space>
                  </div>

                  <Space direction="vertical" size={8} style={{ width: '100%', marginTop: 8 }}>
                    {groupRules.length === 0 ? (
                      <Typography.Text type="secondary">暂无规则，点击“新增规则”开始配置。</Typography.Text>
                    ) : (
                      groupRules.map((rule) => (
                        <div
                          key={rule.id}
                          data-rule-id={rule.id}
                          className={`simple-rule-card ${highlightedRuleId === rule.id ? 'simple-rule-card-highlighted' : ''}`}
                        >
                          <Space direction="vertical" size={6} style={{ width: '100%' }}>
                            <Space wrap>
                              <Switch
                                size="small"
                                checked={rule.enabled && group.enabled && redirectEnabled}
                                onChange={(checked) => {
                                  applySourceRef.current = 'non_input';
                                  updateRule(rule.id, 'enabled', checked);
                                }}
                              />
                              <Select
                                size="small"
                                style={{ width: 100 }}
                                value={rule.matchTarget}
                                options={MATCH_TARGET_OPTIONS}
                                onChange={(value) => {
                                  applySourceRef.current = 'non_input';
                                  updateRule(rule.id, 'matchTarget', value);
                                }}
                              />
                              <Select
                                size="small"
                                style={{ width: 100 }}
                                value={rule.matchMode}
                                options={MATCH_MODE_OPTIONS}
                                onChange={(value) => {
                                  applySourceRef.current = 'non_input';
                                  updateRule(rule.id, 'matchMode', value);
                                }}
                              />
                              <Select
                                size="small"
                                style={{ width: 160 }}
                                value={rule.groupId}
                                options={groups.map((g) => ({ label: g.name, value: g.id }))}
                                onChange={(value) => {
                                  applySourceRef.current = 'non_input';
                                  updateRule(rule.id, 'groupId', value);
                                }}
                              />
                              <Button size="small" onClick={() => duplicateRule(rule.id)}>复制</Button>
                              <Popconfirm title="删除规则？" onConfirm={() => removeRule(rule.id)}>
                                <Button size="small" danger>删除</Button>
                              </Popconfirm>
                            </Space>
                            <Input
                              size="small"
                              value={rule.expression}
                              placeholder="匹配表达式"
                              onChange={(e) => {
                                applySourceRef.current = 'input';
                                updateRule(rule.id, 'expression', e.target.value);
                              }}
                            />
                            <Input
                              size="small"
                              value={rule.redirectUrl}
                              placeholder="重定向 URL"
                              onChange={(e) => {
                                applySourceRef.current = 'input';
                                updateRule(rule.id, 'redirectUrl', e.target.value);
                              }}
                            />
                          </Space>
                        </div>
                      ))
                    )}
                  </Space>
                </div>
              );
            })}
          </div>

          <div style={{ marginTop: 10 }}>
            <Typography.Text type={invalidCount ? 'warning' : 'secondary'}>
              {invalidCount
                ? `有 ${invalidCount} 条规则缺少表达式或目标 URL，请先补全。`
                : '提示：正则模式使用 RE2 语法（Chrome DNR），重定向目标支持 $1/$2... 捕获组。'}
            </Typography.Text>
          </div>
        </div>
      </div>

      <div style={{ flex: '0 0 auto', padding: 12, boxSizing: 'border-box', background: '#eef6ff', borderTop: '1px solid #dbeafe' }}>
        <Typography.Title level={5} style={{ margin: '0 0 8px 0' }}>规则测试</Typography.Title>
        <Space direction="vertical" size={8} style={{ width: '100%' }}>
          <Input
            value={testUrl}
            placeholder="输入实际 URL，点击右侧按钮测试匹配"
            onChange={(e) => setTestUrl(e.target.value)}
            onPressEnter={() => setTestTrigger((n) => n + 1)}
            addonAfter={<Button size="small" type="link" style={{ paddingInline: 0, height: 22 }} onClick={() => setTestTrigger((n) => n + 1)}>测试</Button>}
          />
          {testResult ? (
            testResult.ok ? (
              <Space direction="vertical" size={4}>
                <Typography.Text>
                  命中规则：第 {testResult.matchedIndex + 1} 条（
                  {testResult.matchedRule.matchTarget}/{testResult.matchedRule.matchMode}）
                </Typography.Text>
                <Typography.Text type="secondary">所属分组：{groupNameMap.get(testResult.matchedRule.groupId) || '未知分组'}</Typography.Text>
                <Typography.Text type="secondary">匹配表达式：{testResult.matchedRule.expression}</Typography.Text>
                <Typography.Text copyable={{ text: testResult.redirectedUrl }}>重定向后：{testResult.redirectedUrl}</Typography.Text>
              </Space>
            ) : (
              <Typography.Text type="secondary">{testResult.reason}</Typography.Text>
            )
          ) : (
            <Typography.Text type="secondary">输入 URL 后点击“测试”</Typography.Text>
          )}
        </Space>
      </div>
    </div>
  );
}

export default RedirectPanel;
