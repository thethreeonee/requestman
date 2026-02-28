import { useEffect, useMemo, useState } from 'react';
import {
  DndContext,
  PointerSensor,
  closestCenter,
  useSensor,
  useSensors
} from '@dnd-kit/core';
import {
  SortableContext,
  arrayMove,
  verticalListSortingStrategy,
  useSortable
} from '@dnd-kit/sortable';
import { CSS } from '@dnd-kit/utilities';
import {
  App as AntApp,
  Button,
  Card,
  Checkbox,
  ConfigProvider,
  Input,
  Popconfirm,
  Select,
  Space,
  Typography
} from 'antd';

import { createGroup, createRule } from '../redirect/config';
import { sendRedirectMessage } from '../redirect/messaging';

export function App() {
  const [groups, setGroups] = useState([]);
  const [loaded, setLoaded] = useState(false);

  const sensors = useSensors(useSensor(PointerSensor, { activationConstraint: { distance: 4 } }));

  useEffect(() => {
    (async () => {
      const response = await sendRedirectMessage({ type: 'redirect:getConfig' });
      if (response?.ok && response.config?.groups) {
        setGroups(response.config.groups);
      }
      setLoaded(true);
    })();
  }, []);

  useEffect(() => {
    if (!loaded) return;
    sendRedirectMessage({ type: 'redirect:saveConfig', config: { groups } });
  }, [groups, loaded]);

  const groupIds = useMemo(() => groups.map((group) => group.id), [groups]);

  const updateGroup = (groupId, updater) => {
    setGroups((prev) => prev.map((g) => (g.id === groupId ? updater(g) : g)));
  };

  const onDragEnd = ({ active, over }) => {
    if (!over || active.id === over.id) return;

    const activeType = String(active.id).split(':')[0];

    if (activeType === 'group') {
      const oldIndex = groups.findIndex((g) => `group:${g.id}` === active.id);
      const newIndex = groups.findIndex((g) => `group:${g.id}` === over.id);
      if (oldIndex >= 0 && newIndex >= 0) {
        setGroups((prev) => arrayMove(prev, oldIndex, newIndex));
      }
      return;
    }

    if (activeType === 'rule') {
      const [fromGroupId, ruleId] = String(active.id).replace('rule:', '').split('/');
      const overStr = String(over.id);
      let toGroupId = fromGroupId;
      let targetRuleId = null;

      if (overStr.startsWith('rule:')) {
        const payload = overStr.replace('rule:', '').split('/');
        toGroupId = payload[0];
        targetRuleId = payload[1];
      }
      if (overStr.startsWith('group:')) {
        toGroupId = overStr.replace('group:', '');
      }

      setGroups((prev) => {
        const next = structuredClone(prev);
        const fromGroup = next.find((g) => g.id === fromGroupId);
        const toGroup = next.find((g) => g.id === toGroupId);
        if (!fromGroup || !toGroup) return prev;

        const fromIndex = fromGroup.rules.findIndex((r) => r.id === ruleId);
        if (fromIndex < 0) return prev;

        const [moved] = fromGroup.rules.splice(fromIndex, 1);

        if (targetRuleId) {
          const toIndex = toGroup.rules.findIndex((r) => r.id === targetRuleId);
          if (toIndex >= 0) {
            toGroup.rules.splice(toIndex, 0, moved);
          } else {
            toGroup.rules.push(moved);
          }
        } else {
          toGroup.rules.push(moved);
        }

        return next;
      });
    }
  };

  return (
    <ConfigProvider>
      <AntApp>
        <div className="container">
          <div className="header">
            <Typography.Title level={4}>请求重定向规则</Typography.Title>
            <Button onClick={() => setGroups((prev) => [...prev, createGroup(prev.length)])} type="primary">
              + 新建规则组
            </Button>
          </div>

          <DndContext sensors={sensors} collisionDetection={closestCenter} onDragEnd={onDragEnd}>
            <SortableContext items={groupIds.map((id) => `group:${id}`)} strategy={verticalListSortingStrategy}>
              <Space direction="vertical" style={{ width: '100%' }} size={12}>
                {groups.map((group) => (
                  <GroupCard key={group.id} group={group} updateGroup={updateGroup} setGroups={setGroups} />
                ))}
              </Space>
            </SortableContext>
          </DndContext>
        </div>
      </AntApp>
    </ConfigProvider>
  );
}

function GroupCard({ group, updateGroup, setGroups }) {
  const { attributes, listeners, setNodeRef, transform, transition } = useSortable({ id: `group:${group.id}` });

  return (
    <Card
      ref={setNodeRef}
      style={{ transform: CSS.Transform.toString(transform), transition }}
      title={
        <Space>
          <span className="drag-handle" {...attributes} {...listeners}>
            ☰
          </span>
          <Input
            value={group.name}
            onChange={(e) => updateGroup(group.id, (g) => ({ ...g, name: e.target.value }))}
            placeholder="规则组名称"
          />
          <Checkbox
            checked={group.enabled}
            onChange={(e) => updateGroup(group.id, (g) => ({ ...g, enabled: e.target.checked }))}
          >
            组启用
          </Checkbox>
        </Space>
      }
      extra={
        <Space>
          <Button onClick={() => updateGroup(group.id, (g) => ({ ...g, rules: [...g.rules, createRule()] }))}>+ 规则</Button>
          <Popconfirm
            title={`确定删除规则组「${group.name}」吗？`}
            onConfirm={() => setGroups((prev) => prev.filter((g) => g.id !== group.id))}
          >
            <Button danger>删除组</Button>
          </Popconfirm>
        </Space>
      }
    >
      <SortableContext items={group.rules.map((rule) => `rule:${group.id}/${rule.id}`)} strategy={verticalListSortingStrategy}>
        <Space direction="vertical" style={{ width: '100%' }}>
          {group.rules.map((rule) => (
            <RuleItem
              key={rule.id}
              group={group}
              rule={rule}
              onChange={(nextRule) =>
                updateGroup(group.id, (g) => ({ ...g, rules: g.rules.map((r) => (r.id === rule.id ? nextRule : r)) }))
              }
              onDelete={() =>
                updateGroup(group.id, (g) => ({ ...g, rules: g.rules.filter((r) => r.id !== rule.id) }))
              }
            />
          ))}
        </Space>
      </SortableContext>
    </Card>
  );
}

function RuleItem({ group, rule, onChange, onDelete }) {
  const { attributes, listeners, setNodeRef, transform, transition } = useSortable({
    id: `rule:${group.id}/${rule.id}`
  });

  return (
    <Card ref={setNodeRef} size="small" style={{ transform: CSS.Transform.toString(transform), transition }}>
      <Space direction="vertical" style={{ width: '100%' }}>
        <Space wrap>
          <span className="drag-handle" {...attributes} {...listeners}>
            ↕
          </span>
          <Checkbox checked={rule.enabled} disabled={!group.enabled} onChange={(e) => onChange({ ...rule, enabled: e.target.checked })}>
            启用
          </Checkbox>
          <Select
            value={rule.scope}
            options={[{ value: 'url', label: '整个 URL' }, { value: 'host', label: '仅 Host' }]}
            onChange={(value) => onChange({ ...rule, scope: value })}
            style={{ width: 120 }}
          />
          <Select
            value={rule.matchType}
            options={[
              { value: 'contains', label: '包含' },
              { value: 'equals', label: '等于' },
              { value: 'regex', label: '正则' },
              { value: 'wildcard', label: '通配符' }
            ]}
            onChange={(value) => onChange({ ...rule, matchType: value })}
            style={{ width: 120 }}
          />
        </Space>
        <Input
          value={rule.pattern}
          onChange={(e) => onChange({ ...rule, pattern: e.target.value })}
          placeholder="匹配规则，例如 api.example.com 或 ^https://a\.com/(.*)$"
        />
        <Space.Compact style={{ width: '100%' }}>
          <Input
            value={rule.redirectTo}
            onChange={(e) => onChange({ ...rule, redirectTo: e.target.value })}
            placeholder="重定向目标，正则模式支持 $1、$2 ..."
          />
          <Popconfirm title="确定删除这条规则吗？" onConfirm={onDelete}>
            <Button danger>删除</Button>
          </Popconfirm>
        </Space.Compact>
      </Space>
    </Card>
  );
}

