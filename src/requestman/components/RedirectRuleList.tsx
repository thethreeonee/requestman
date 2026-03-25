import React from 'react';
import { ChevronsUpDown } from 'lucide-react';
import {
  Button,
  Input,
  Modal,
  Switch,
  Tooltip,
  Typography,
} from '.';
import {
  Accordion,
  AccordionItem,
  AccordionTrigger,
  AccordionContent,
} from '@/components/animate-ui/components/radix/accordion';
import {
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/animate-ui/components/radix/dialog';
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuGroup,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from '@/components/animate-ui/components/radix/dropdown-menu';
import { Copy } from '@/components/animate-ui/icons/copy';
import { t } from '../i18n';
import { MessageSquareMore } from '@/components/animate-ui/icons/message-square-more';
import { Trash2 } from '@/components/animate-ui/icons/trash-2';
import type {
  RequestmanDropdownMenuBaseItem,
  RequestmanDropdownMenuItem,
} from '../dropdown-menu-types';
import {
  DeleteOutlined,
  EllipsisOutlined,
} from '../icons';
import { Binary } from '@/components/animate-ui/icons/binary';
import { Blend } from '@/components/animate-ui/icons/blend';
import { CircleX } from '@/components/animate-ui/icons/circle-x';
import { CircuitBoard } from '@/components/animate-ui/icons/circuit-board';
import { Gauge } from '@/components/animate-ui/icons/gauge';
import { GalleryVertical } from '@/components/animate-ui/icons/gallery-vertical';
import { GalleryVerticalEnd as GalleryHorizontalEnd } from '@/components/animate-ui/icons/gallery-horizontal-end';
import { LayoutDashboard } from '@/components/animate-ui/icons/layout-dashboard';
import { RULE_TYPE_LABEL_MAP } from '../constants';
import { Orbit } from '@/components/animate-ui/icons/orbit';
import { Route } from '@/components/animate-ui/icons/route';
import { User } from '@/components/animate-ui/icons/user';
import GroupDropdownSelect from './GroupDropdownSelect';
import { genId } from '../rule-utils';
import type { RedirectGroup, RedirectRule } from '../types';

type GroupModalState = { open: boolean; mode: 'create' | 'rename' | 'move'; groupId?: string; ruleId?: string };

type Props = {
  groups: RedirectGroup[];
  rules: RedirectRule[];
  redirectEnabled: boolean;
  collapsedGroupIds: string[];
  groupModal: GroupModalState;
  groupInput: string;
  setCollapsedGroupIds: React.Dispatch<React.SetStateAction<string[]>>;
  setGroupModal: React.Dispatch<React.SetStateAction<GroupModalState>>;
  setGroupInput: React.Dispatch<React.SetStateAction<string>>;
  createRule: (ruleType: RedirectRule['type']) => void;
  openRuleDetail: (ruleId: string) => void;
  duplicateGroup: (groupId: string) => void;
  deleteGroup: (groupId: string) => void;
  confirmGroupModal: () => void;
  setRules: React.Dispatch<React.SetStateAction<RedirectRule[]>>;
  setGroups: React.Dispatch<React.SetStateAction<RedirectGroup[]>>;
  messageApi: {
    success: (content: string) => void;
    warning: (content: string) => void;
  };
};

type DragState = { ruleId: string; groupId: string };
type PointerDragState = DragState & {
  pointerId: number;
  startX: number;
  startY: number;
  clientX: number;
  clientY: number;
  previewOffsetX: number;
  previewOffsetY: number;
  isDragging: boolean;
};
type DropState = { targetRuleId: string; position: 'before' | 'after' };
const POINTER_DRAG_THRESHOLD = 4;

function getRuleEffectiveHint(redirectEnabled: boolean, groupEnabled: boolean, ruleEnabled: boolean) {
  if (!redirectEnabled) return t('总开关关闭，当前规则不会生效', 'Master switch is off. This rule will not take effect.');
  if (!groupEnabled) return t('规则组已关闭，当前规则不会生效', 'Group is off. This rule will not take effect.');
  if (!ruleEnabled) return t('规则已关闭，不会生效', 'Rule is off and will not take effect.');
  return t('规则已开启，当前规则会生效', 'Rule is on and will take effect.');
}

function renderRuleMenuGroupLabel(title: string) {
  return (
    <span className="rule-menu-group-title">
      <span className="rule-menu-group-title__text">{title}</span>
      <span className="rule-menu-group-title__line" />
    </span>
  );
}

function renderDropdownMenuItem(item: RequestmanDropdownMenuBaseItem, index: number, keyPrefix: string) {
  return (
    <DropdownMenuItem
      key={item.key ?? `${keyPrefix}-item-${index}`}
      disabled={item.disabled}
      variant={item.danger ? 'destructive' : 'default'}
      onMouseEnter={item.onMouseEnter}
      onMouseLeave={item.onMouseLeave}
      onSelect={() => item.onClick?.()}
    >
      {item.icon}
      {item.label}
    </DropdownMenuItem>
  );
}

function renderDropdownMenuItems(items: RequestmanDropdownMenuItem[], keyPrefix: string) {
  return items.map((item, index) => {
    if (item.type === 'divider') {
      return <DropdownMenuSeparator key={item.key ?? `${keyPrefix}-divider-${index}`} />;
    }
    if (item.type === 'group') {
      return (
        <DropdownMenuGroup key={item.key ?? `${keyPrefix}-group-${index}`}>
          <DropdownMenuLabel className="rule-menu-group-label">{item.label}</DropdownMenuLabel>
          {(item.children ?? []).map((child, childIndex) => renderDropdownMenuItem(child, childIndex, `${keyPrefix}-group-${index}`))}
        </DropdownMenuGroup>
      );
    }
    return renderDropdownMenuItem(item, index, keyPrefix);
  });
}

function moveRuleWithinGroup(
  rules: RedirectRule[],
  draggedRuleId: string,
  targetRuleId: string,
  position: 'before' | 'after',
) {
  if (draggedRuleId === targetRuleId) return rules;
  const draggedRule = rules.find((rule) => rule.id === draggedRuleId);
  const targetRule = rules.find((rule) => rule.id === targetRuleId);
  if (!draggedRule || !targetRule || draggedRule.groupId !== targetRule.groupId) return rules;

  const groupRules = rules.filter((rule) => rule.groupId === draggedRule.groupId);
  const fromIndex = groupRules.findIndex((rule) => rule.id === draggedRuleId);
  const targetIndex = groupRules.findIndex((rule) => rule.id === targetRuleId);
  if (fromIndex === -1 || targetIndex === -1) return rules;

  const reorderedGroupRules = [...groupRules];
  const [movedRule] = reorderedGroupRules.splice(fromIndex, 1);
  const insertIndex = targetIndex + (position === 'after' ? 1 : 0) - (fromIndex < targetIndex ? 1 : 0);
  reorderedGroupRules.splice(insertIndex, 0, movedRule);

  let groupRuleIndex = 0;
  return rules.map((rule) => (
    rule.groupId === draggedRule.groupId
      ? reorderedGroupRules[groupRuleIndex++]
      : rule
  ));
}

function normalizeDropState(
  rules: RedirectRule[],
  draggedRuleId: string,
  targetRuleId: string,
  position: 'before' | 'after',
): DropState {
  if (position === 'before') return { targetRuleId, position };
  const targetRule = rules.find((rule) => rule.id === targetRuleId);
  if (!targetRule) return { targetRuleId, position };
  const groupRules = rules.filter((rule) => rule.groupId === targetRule.groupId);
  const targetIndex = groupRules.findIndex((rule) => rule.id === targetRuleId);
  const nextRule = groupRules[targetIndex + 1];
  if (!nextRule || nextRule.id === draggedRuleId) return { targetRuleId, position: 'after' };
  return { targetRuleId: nextRule.id, position: 'before' };
}

function isInteractiveDragTarget(target: EventTarget | null, ignoredElement?: Element | null) {
  if (!(target instanceof Element)) return false;
  const interactiveElement = target.closest([
    'button',
    'a',
    'input',
    'textarea',
    'select',
    'label',
    '[role="button"]',
    '[data-no-drag="true"]',
    '.aui-btn',
    '.aui-input',
    '.aui-select',
    '[data-slot="switch"]',
    '[data-slot="dropdown-menu-content"]',
    '[data-slot="dropdown-menu-trigger"]',
    '.aui-collapse-header',
    '.aui-collapse-trigger',
  ].join(','));
  return Boolean(interactiveElement && interactiveElement !== ignoredElement);
}

const RULE_TYPE_ICON_COMPONENT_MAP: Record<RedirectRule['type'], React.ComponentType<{ size?: number; animate?: boolean }>> = {
  redirect_request: Route,
  rewrite_string: CircuitBoard,
  query_params: Orbit,
  modify_request_body: LayoutDashboard,
  modify_response_body: Binary,
  modify_headers: Blend,
  user_agent: User,
  cancel_request: CircleX,
  request_delay: Gauge,
};

function renderRuleTypeIcon(type: RedirectRule['type'], animate = false) {
  const IconComponent = RULE_TYPE_ICON_COMPONENT_MAP[type];
  return <IconComponent size={14} animate={animate} />;
}

export default function RedirectRuleList({
  groups,
  rules,
  redirectEnabled,
  collapsedGroupIds,
  groupModal,
  groupInput,
  setCollapsedGroupIds,
  setGroupModal,
  setGroupInput,
  createRule,
  openRuleDetail,
  duplicateGroup,
  deleteGroup,
  confirmGroupModal,
  setRules,
  setGroups,
  messageApi,
}: Props) {
  const listWrapperRef = React.useRef<HTMLDivElement | null>(null);
  const [hoveredAction, setHoveredAction] = React.useState<'group' | 'rule' | null>(null);
  const [hoveredMenuAction, setHoveredMenuAction] = React.useState<string | null>(null);
  const [hoveredRuleId, setHoveredRuleId] = React.useState<string | null>(null);
  const [hoveredCreateRuleType, setHoveredCreateRuleType] = React.useState<RedirectRule['type'] | null>(null);
  const [dragState, setDragState] = React.useState<DragState | null>(null);
  const [pointerDragState, setPointerDragState] = React.useState<PointerDragState | null>(null);
  const [dropState, setDropState] = React.useState<DropState | null>(null);
  const pointerDragStateRef = React.useRef<PointerDragState | null>(null);
  const dropStateRef = React.useRef<DropState | null>(null);

  const currentGroupEnabled = new Map(groups.map((g) => [g.id, g.enabled]));
  const groupsOptions = groups.map((g) => ({ value: g.id, label: g.name }));
  const groupRuleMap = React.useMemo(
    () => new Map(groups.map((group) => [group.id, rules.filter((rule) => rule.groupId === group.id)])),
    [groups, rules],
  );
  const expandedGroupIds = React.useMemo(
    () => groups.map((group) => group.id).filter((groupId) => !collapsedGroupIds.includes(groupId)),
    [collapsedGroupIds, groups],
  );
  const activePreviewRule = React.useMemo(
    () => rules.find((rule) => rule.id === pointerDragState?.ruleId) ?? null,
    [pointerDragState?.ruleId, rules],
  );
  const isGroupDialogOpen = groupModal.open;
  const groupDialogTitle = groupModal.mode === 'create'
    ? t('新建规则组', 'Create group')
    : groupModal.mode === 'rename'
      ? t('重命名规则组', 'Rename group')
      : t('修改规则组', 'Change group');

  const setPointerDragStateWithRef = React.useCallback((value: React.SetStateAction<PointerDragState | null>) => {
    setPointerDragState((prev) => {
      const next = typeof value === 'function'
        ? (value as (prev: PointerDragState | null) => PointerDragState | null)(prev)
        : value;
      pointerDragStateRef.current = next;
      return next;
    });
  }, []);

  const setDropStateWithRef = React.useCallback((value: React.SetStateAction<DropState | null>) => {
    setDropState((prev) => {
      const next = typeof value === 'function'
        ? (value as (prev: DropState | null) => DropState | null)(prev)
        : value;
      dropStateRef.current = next;
      return next;
    });
  }, []);

  const handleExpandedGroupsChange = (nextActiveKeys: string[] | string | undefined) => {
    const nextExpandedGroupIds = Array.isArray(nextActiveKeys)
      ? nextActiveKeys.map(String)
      : nextActiveKeys == null
        ? []
        : [String(nextActiveKeys)];
    const nextExpandedSet = new Set(nextExpandedGroupIds);
    setCollapsedGroupIds(groups.map((group) => group.id).filter((groupId) => !nextExpandedSet.has(groupId)));
  };

  const handleGroupEnabledChange = (group: RedirectGroup, value: boolean) => {
    setGroups((prev) => prev.map((g) => g.id === group.id ? { ...g, enabled: value } : g));
    messageApi.success(value ? t(`规则组「${group.name}」已开启`, `Group "${group.name}" enabled.`) : t(`规则组「${group.name}」已关闭`, `Group "${group.name}" disabled.`));
  };

  const handleRuleEnabledChange = (rule: RedirectRule, value: boolean) => {
    setRules((prev) => prev.map((r) => r.id === rule.id ? { ...r, enabled: value } : r));
    if (value) {
      messageApi.success(t(`规则「${rule.name}」已开启`, `Rule "${rule.name}" enabled.`));
      return;
    }
    messageApi.warning(t(`规则「${rule.name}」已关闭`, `Rule "${rule.name}" disabled.`));
  };

  const clearDragState = () => {
    setDragState(null);
    setPointerDragStateWithRef(null);
    setDropStateWithRef(null);
  };

  const updatePointerDropTarget = React.useCallback((clientX: number, clientY: number, activeDrag: DragState) => {
    const hoveredElement = document.elementFromPoint(clientX, clientY);
    const rowElement = hoveredElement?.closest<HTMLElement>('[data-row-type][data-group-id]');
    const hoveredGroupId = rowElement?.dataset.groupId;
    const hoveredRowType = rowElement?.dataset.rowType;
    const hoveredRuleId = rowElement?.dataset.ruleId;

    if (!rowElement || !hoveredGroupId) {
      setDropStateWithRef(null);
      return;
    }

    if (hoveredRowType === 'rule' && hoveredGroupId === activeDrag.groupId && hoveredRuleId && hoveredRuleId !== activeDrag.ruleId) {
      const { top, height } = rowElement.getBoundingClientRect();
      const position = clientY - top < height / 2 ? 'before' : 'after';
      const nextDropState = normalizeDropState(rules, activeDrag.ruleId, hoveredRuleId, position);
      setDropStateWithRef((prev) => (
        prev?.targetRuleId === nextDropState.targetRuleId && prev.position === nextDropState.position
          ? prev
          : nextDropState
      ));
      return;
    }

    setDropStateWithRef(null);
  }, [rules, setDropStateWithRef]);

  React.useEffect(() => {
    if (!pointerDragState) return undefined;

    const handlePointerMove = (event: PointerEvent) => {
      const activeDrag = pointerDragStateRef.current;
      if (!activeDrag || event.pointerId !== activeDrag.pointerId) return;

      const movedEnough = activeDrag.isDragging || (
        Math.abs(event.clientX - activeDrag.startX) >= POINTER_DRAG_THRESHOLD ||
        Math.abs(event.clientY - activeDrag.startY) >= POINTER_DRAG_THRESHOLD
      );

      const nextDragState = { ...activeDrag, clientX: event.clientX, clientY: event.clientY, isDragging: movedEnough };
      pointerDragStateRef.current = nextDragState;
      setPointerDragState(nextDragState);

      if (!movedEnough) return;

      if (!dragState) {
        setDragState({ ruleId: activeDrag.ruleId, groupId: activeDrag.groupId });
      }

      event.preventDefault();
      updatePointerDropTarget(event.clientX, event.clientY, activeDrag);
    };

    const finishPointerDrag = (pointerId: number) => {
      const activeDrag = pointerDragStateRef.current;
      if (!activeDrag || pointerId !== activeDrag.pointerId) return;

      if (activeDrag.isDragging) {
        const currentDropState = dropStateRef.current;

        if (currentDropState) {
          setRules((prev) => moveRuleWithinGroup(prev, activeDrag.ruleId, currentDropState.targetRuleId, currentDropState.position));
          messageApi.success(t('规则排序已更新', 'Rule order updated'));
        }
      }

      clearDragState();
    };

    const handlePointerUp = (event: PointerEvent) => {
      finishPointerDrag(event.pointerId);
    };

    const handlePointerCancel = (event: PointerEvent) => {
      finishPointerDrag(event.pointerId);
    };

    window.addEventListener('pointermove', handlePointerMove, { passive: false });
    window.addEventListener('pointerup', handlePointerUp);
    window.addEventListener('pointercancel', handlePointerCancel);
    return () => {
      window.removeEventListener('pointermove', handlePointerMove);
      window.removeEventListener('pointerup', handlePointerUp);
      window.removeEventListener('pointercancel', handlePointerCancel);
    };
  }, [dragState, messageApi, pointerDragState, setRules, setPointerDragStateWithRef, updatePointerDropTarget]);

  React.useEffect(() => {
    if (!dragState) return undefined;
    document.body.classList.add('rule-pointer-dragging');
    return () => {
      document.body.classList.remove('rule-pointer-dragging');
    };
  }, [dragState]);

  const handleRulePointerDown = (event: React.PointerEvent<HTMLButtonElement>, rule: RedirectRule) => {
    if (event.button !== 0 || isInteractiveDragTarget(event.target, event.currentTarget)) return;
    const rowElement = event.currentTarget.closest<HTMLElement>('.rule-item-row');
    if (!rowElement) return;
    const rowRect = rowElement.getBoundingClientRect();
    setPointerDragStateWithRef({
      pointerId: event.pointerId,
      ruleId: rule.id,
      groupId: rule.groupId,
      startX: event.clientX,
      startY: event.clientY,
      clientX: event.clientX,
      clientY: event.clientY,
      previewOffsetX: event.clientX - rowRect.left,
      previewOffsetY: event.clientY - rowRect.top,
      isDragging: false,
    });
  };

  const renderRuleRow = (rule: RedirectRule) => {
    const groupEnabled = currentGroupEnabled.get(rule.groupId) !== false;
    const classNames = ['rule-item-row'];
    if (dragState?.ruleId === rule.id) classNames.push('dragging-rule-row');
    if (dropState?.targetRuleId === rule.id) classNames.push(dropState.position === 'before' ? 'drop-before-row' : 'drop-after-row');

    return (
      <div
        key={rule.id}
        className={classNames.join(' ')}
        data-group-id={rule.groupId}
        data-row-type="rule"
        data-rule-id={rule.id}
        onMouseEnter={() => setHoveredRuleId(rule.id)}
        onMouseLeave={() => setHoveredRuleId((current) => (current === rule.id ? null : current))}
      >
        <button
          type="button"
          className="rule-item-row__drag-handle"
          aria-label={t('拖拽排序', 'Drag to reorder')}
          onPointerDown={(event) => handleRulePointerDown(event, rule)}
        >
          <ChevronsUpDown size={13} />
        </button>
        <div className="rule-item-row__type-icon" aria-hidden="true">
          {renderRuleTypeIcon(rule.type, hoveredRuleId === rule.id)}
        </div>
        <div className="rule-item-row__name">
          <Button type="link" className="rule-name-link" style={{ paddingInline: 0 }} onClick={() => openRuleDetail(rule.id)}>
            {rule.name}
          </Button>
        </div>
        <div className="rule-item-row__spacer" />
        <div className="rule-item-row__status">
          <Tooltip title={getRuleEffectiveHint(redirectEnabled, groupEnabled, rule.enabled)}>
            <Switch
              className="rules-compact-switch"
              pressedWidth={14}
              checked={rule.enabled}
              disabled={!redirectEnabled || !groupEnabled}
              onChange={(value: boolean) => handleRuleEnabledChange(rule, value)}
            />
          </Tooltip>
        </div>
        <div className="rule-item-row__actions" data-no-drag="true">
          {(() => {
            const moveKey = `rule:${rule.id}:move`;
            const copyKey = `rule:${rule.id}:copy`;
            const deleteKey = `rule:${rule.id}:delete`;
            const ruleMenuItems: RequestmanDropdownMenuItem[] = [
              {
                key: 'move',
                label: t('修改规则组', 'Change group'),
                icon: <GalleryHorizontalEnd size={14} animate={hoveredMenuAction === moveKey} />,
                onMouseEnter: () => setHoveredMenuAction(moveKey),
                onMouseLeave: () => setHoveredMenuAction((current) => (current === moveKey ? null : current)),
                onClick: () => { setGroupModal({ open: true, mode: 'move', ruleId: rule.id }); setGroupInput(rule.groupId); },
              },
              {
                key: 'copy',
                label: t('复制', 'Duplicate'),
                icon: <Copy size={14} animate={hoveredMenuAction === copyKey} />,
                onMouseEnter: () => setHoveredMenuAction(copyKey),
                onMouseLeave: () => setHoveredMenuAction((current) => (current === copyKey ? null : current)),
                onClick: () => {
                  setRules((prev) => {
                    const idx = prev.findIndex((item) => item.id === rule.id);
                    const next = [...prev];
                    next.splice(idx + 1, 0, { ...rule, id: genId(), name: `${rule.name} ${t('副本', 'Copy')}` });
                    return next;
                  });
                  messageApi.success(t(`规则「${rule.name}」已复制`, `Rule "${rule.name}" duplicated.`));
                },
              },
              {
                key: 'delete',
                label: t('删除', 'Delete'),
                icon: <Trash2 size={14} animate={hoveredMenuAction === deleteKey} />,
                danger: true,
                onMouseEnter: () => setHoveredMenuAction(deleteKey),
                onMouseLeave: () => setHoveredMenuAction((current) => (current === deleteKey ? null : current)),
                onClick: () => Modal.confirm({
                  title: t('确认删除规则？', 'Delete this rule?'),
                  okButtonProps: { danger: true },
                  onOk: () => {
                    setRules((prev) => prev.filter((item) => item.id !== rule.id));
                    messageApi.warning(t(`规则「${rule.name}」已删除`, `Rule "${rule.name}" deleted.`));
                  },
                }),
              },
            ];
            return (
              <DropdownMenu>
                <DropdownMenuTrigger asChild>
                  <span>
                    <Button type="text" size="icon-sm" icon={<EllipsisOutlined />} />
                  </span>
                </DropdownMenuTrigger>
                <DropdownMenuContent align="end" sideOffset={6}>
                  {renderDropdownMenuItems(ruleMenuItems, `rule-${rule.id}`)}
                </DropdownMenuContent>
              </DropdownMenu>
            );
          })()}
        </div>
      </div>
    );
  };

  return <div className="rules-sidebar">
    {pointerDragState?.isDragging && activePreviewRule ? (
      <div
        className="rule-drag-preview"
        style={{
          top: pointerDragState.clientY - pointerDragState.previewOffsetY,
          left: pointerDragState.clientX - pointerDragState.previewOffsetX,
        }}
      >
        <div className="rule-drag-preview__row">
          <div className="rule-item-row__drag-handle" aria-hidden="true">
            <ChevronsUpDown size={13} />
          </div>
          <div className="rule-item-row__type-icon" aria-hidden="true">
            {renderRuleTypeIcon(activePreviewRule.type)}
          </div>
          <div className="rule-item-row__name">
            <Typography.Text strong>{activePreviewRule.name}</Typography.Text>
          </div>
          <div className="rule-item-row__spacer" />
          <div className="rule-item-row__status">
            <Typography.Text type="secondary">{activePreviewRule.enabled ? t('已开启', 'On') : t('已关闭', 'Off')}</Typography.Text>
          </div>
          <div className="rule-item-row__actions">
            <EllipsisOutlined />
          </div>
        </div>
      </div>
    ) : null}
    <div className="rules-list-accordion-scroll">
      <div className="rules-list-accordion" ref={listWrapperRef}>
        <Accordion type="multiple" value={expandedGroupIds} onValueChange={handleExpandedGroupsChange}>
          {groups.map((group) => {
            const groupRules = groupRuleMap.get(group.id) ?? [];
            return (
              <AccordionItem key={group.id} value={group.id}>
                <div className="rule-group-accordion-header">
                  <AccordionTrigger className="rule-group-accordion-trigger">
                    <div className="rule-group-header" data-group-id={group.id} data-row-type="group">
                      <div className="rule-group-header__title">
                        <span className="rule-group-header__title-text" style={{ fontWeight: 600 }}>{group.name}</span>
                      </div>
                    </div>
                  </AccordionTrigger>
                  <div className="rule-group-header__actions" data-no-drag="true">
                    <span className="rule-group-header__count" aria-label={t(`当前分组共 ${groupRules.length} 条规则`, `${groupRules.length} rules in this group`)}>
                      <span className="rule-group-header__count-bracket" aria-hidden="true" />
                      <span className="rule-group-header__count-value">{groupRules.length}</span>
                      <span className="rule-group-header__count-bracket rule-group-header__count-bracket--right" aria-hidden="true" />
                    </span>
                    <Tooltip title={redirectEnabled ? (group.enabled ? t('规则组已开启，组内规则可生效', 'Group is enabled. Rules in this group can take effect.') : t('规则组已关闭，组内规则不会生效', 'Group is disabled. Rules in this group will not take effect.')) : t('总开关关闭，组内规则不会生效', 'Master switch is off. Rules in this group will not take effect.')}>
                      <span className="rule-group-header__switch">
                        <Switch
                          className="rules-compact-switch"
                          pressedWidth={14}
                          checked={group.enabled}
                          disabled={!redirectEnabled}
                          onChange={(value: boolean) => handleGroupEnabledChange(group, value)}
                        />
                      </span>
                    </Tooltip>
                    {(() => {
                      const renameKey = `group:${group.id}:rename`;
                      const copyKey = `group:${group.id}:copy`;
                      const deleteKey = `group:${group.id}:delete`;
                      const groupMenuItems: RequestmanDropdownMenuItem[] = [
                        {
                          key: 'rename',
                          label: t('重命名', 'Rename'),
                          icon: <MessageSquareMore size={14} animate={hoveredMenuAction === renameKey} />,
                          onMouseEnter: () => setHoveredMenuAction(renameKey),
                          onMouseLeave: () => setHoveredMenuAction((current) => (current === renameKey ? null : current)),
                          onClick: () => { setGroupModal({ open: true, mode: 'rename', groupId: group.id }); setGroupInput(group.name); },
                        },
                        {
                          key: 'copy',
                          label: t('复制', 'Duplicate'),
                          icon: <Copy size={14} animate={hoveredMenuAction === copyKey} />,
                          onMouseEnter: () => setHoveredMenuAction(copyKey),
                          onMouseLeave: () => setHoveredMenuAction((current) => (current === copyKey ? null : current)),
                          onClick: () => duplicateGroup(group.id),
                        },
                        {
                          key: 'delete',
                          label: t('删除', 'Delete'),
                          icon: <Trash2 size={14} animate={hoveredMenuAction === deleteKey} />,
                          danger: true,
                          onMouseEnter: () => setHoveredMenuAction(deleteKey),
                          onMouseLeave: () => setHoveredMenuAction((current) => (current === deleteKey ? null : current)),
                          onClick: () => deleteGroup(group.id),
                        },
                      ];
                      return (
                        <DropdownMenu>
                          <DropdownMenuTrigger asChild>
                            <span>
                              <Button type="text" size="icon-sm" icon={<EllipsisOutlined />} />
                            </span>
                          </DropdownMenuTrigger>
                          <DropdownMenuContent align="end" sideOffset={6}>
                            {renderDropdownMenuItems(groupMenuItems, `group-${group.id}`)}
                          </DropdownMenuContent>
                        </DropdownMenu>
                      );
                    })()}
                  </div>
                </div>
                <AccordionContent keepRendered>
                  <div className="rule-group-panel" data-group-id={group.id} data-row-type="group">
                    <div className="rule-group-body" data-group-id={group.id} data-row-type="group">
                      {groupRules.length > 0
                        ? groupRules.map(renderRuleRow)
                        : (
                          <div className="rule-item-row__empty" data-group-id={group.id} data-row-type="group">
                            <Typography.Text type="secondary">{t('该规则组暂无规则', 'No rules in this group')}</Typography.Text>
                          </div>
                        )}
                    </div>
                  </div>
                </AccordionContent>
              </AccordionItem>
            );
          })}
        </Accordion>
      </div>
    </div>
    <div className="sidebar-header sidebar-actions">
      <div className="sidebar-actions__group">
        <Tooltip title={t('新建规则组', 'Create group')}>
          <Button
            size="icon"
            type="secondary"
            icon={<GalleryHorizontalEnd size={16} animate={hoveredAction === 'group'} />}
            aria-label={t('新建规则组', 'Create group')}
            onMouseEnter={() => setHoveredAction('group')}
            onMouseLeave={() => setHoveredAction((current) => (current === 'group' ? null : current))}
            onClick={() => { setGroupModal({ open: true, mode: 'create' }); setGroupInput(''); }}
          />
        </Tooltip>
      </div>
      <div className="sidebar-actions__rule">
        <DropdownMenu>
          <DropdownMenuTrigger asChild>
            <span className="sidebar-actions__trigger">
              <Button
                type="primary"
                className="sidebar-actions__button"
                icon={<GalleryVertical size={16} animate={hoveredAction === 'rule'} />}
                onMouseEnter={() => setHoveredAction('rule')}
                onMouseLeave={() => setHoveredAction((current) => (current === 'rule' ? null : current))}
              >
                {t('新建规则', 'New rule')}
              </Button>
            </span>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end" sideOffset={6} style={{ minWidth: 320 }}>
            {renderDropdownMenuItems([
              {
                key: 'url_rewrites_group',
                type: 'group',
                label: renderRuleMenuGroupLabel('URL Rewrites'),
                children: [
                  {
                    key: 'redirect_request',
                    icon: renderRuleTypeIcon('redirect_request', hoveredCreateRuleType === 'redirect_request'),
                    label: RULE_TYPE_LABEL_MAP.redirect_request,
                    onMouseEnter: () => setHoveredCreateRuleType('redirect_request'),
                    onMouseLeave: () => setHoveredCreateRuleType((current) => (current === 'redirect_request' ? null : current)),
                    onClick: () => createRule('redirect_request'),
                  },
                  {
                    key: 'rewrite_string',
                    icon: renderRuleTypeIcon('rewrite_string', hoveredCreateRuleType === 'rewrite_string'),
                    label: RULE_TYPE_LABEL_MAP.rewrite_string,
                    onMouseEnter: () => setHoveredCreateRuleType('rewrite_string'),
                    onMouseLeave: () => setHoveredCreateRuleType((current) => (current === 'rewrite_string' ? null : current)),
                    onClick: () => createRule('rewrite_string'),
                  },
                  {
                    key: 'query_params',
                    icon: renderRuleTypeIcon('query_params', hoveredCreateRuleType === 'query_params'),
                    label: RULE_TYPE_LABEL_MAP.query_params,
                    onMouseEnter: () => setHoveredCreateRuleType('query_params'),
                    onMouseLeave: () => setHoveredCreateRuleType((current) => (current === 'query_params' ? null : current)),
                    onClick: () => createRule('query_params'),
                  },
                ],
              },
              {
                key: 'api_mocking_group',
                type: 'group',
                label: renderRuleMenuGroupLabel('API Mocking'),
                children: [
                  {
                    key: 'modify_request_body',
                    icon: renderRuleTypeIcon('modify_request_body', hoveredCreateRuleType === 'modify_request_body'),
                    label: RULE_TYPE_LABEL_MAP.modify_request_body,
                    onMouseEnter: () => setHoveredCreateRuleType('modify_request_body'),
                    onMouseLeave: () => setHoveredCreateRuleType((current) => (current === 'modify_request_body' ? null : current)),
                    onClick: () => createRule('modify_request_body'),
                  },
                  {
                    key: 'modify_response_body',
                    icon: renderRuleTypeIcon('modify_response_body', hoveredCreateRuleType === 'modify_response_body'),
                    label: RULE_TYPE_LABEL_MAP.modify_response_body,
                    onMouseEnter: () => setHoveredCreateRuleType('modify_response_body'),
                    onMouseLeave: () => setHoveredCreateRuleType((current) => (current === 'modify_response_body' ? null : current)),
                    onClick: () => createRule('modify_response_body'),
                  },
                ],
              },
              {
                key: 'headers_group',
                type: 'group',
                label: renderRuleMenuGroupLabel('Headers'),
                children: [
                  {
                    key: 'modify_headers',
                    icon: renderRuleTypeIcon('modify_headers', hoveredCreateRuleType === 'modify_headers'),
                    label: RULE_TYPE_LABEL_MAP.modify_headers,
                    onMouseEnter: () => setHoveredCreateRuleType('modify_headers'),
                    onMouseLeave: () => setHoveredCreateRuleType((current) => (current === 'modify_headers' ? null : current)),
                    onClick: () => createRule('modify_headers'),
                  },
                  {
                    key: 'user_agent',
                    icon: renderRuleTypeIcon('user_agent', hoveredCreateRuleType === 'user_agent'),
                    label: RULE_TYPE_LABEL_MAP.user_agent,
                    onMouseEnter: () => setHoveredCreateRuleType('user_agent'),
                    onMouseLeave: () => setHoveredCreateRuleType((current) => (current === 'user_agent' ? null : current)),
                    onClick: () => createRule('user_agent'),
                  },
                ],
              },
              {
                key: 'others_group',
                type: 'group',
                label: renderRuleMenuGroupLabel('Others'),
                children: [
                  {
                    key: 'cancel_request',
                    icon: renderRuleTypeIcon('cancel_request', hoveredCreateRuleType === 'cancel_request'),
                    label: RULE_TYPE_LABEL_MAP.cancel_request,
                    onMouseEnter: () => setHoveredCreateRuleType('cancel_request'),
                    onMouseLeave: () => setHoveredCreateRuleType((current) => (current === 'cancel_request' ? null : current)),
                    onClick: () => createRule('cancel_request'),
                  },
                  {
                    key: 'request_delay',
                    icon: renderRuleTypeIcon('request_delay', hoveredCreateRuleType === 'request_delay'),
                    label: RULE_TYPE_LABEL_MAP.request_delay,
                    onMouseEnter: () => setHoveredCreateRuleType('request_delay'),
                    onMouseLeave: () => setHoveredCreateRuleType((current) => (current === 'request_delay' ? null : current)),
                    onClick: () => createRule('request_delay'),
                  },
                ],
              },
            ], 'create-rule')}
          </DropdownMenuContent>
        </DropdownMenu>
      </div>
    </div>
    <Dialog open={isGroupDialogOpen} onOpenChange={(open) => { if (!open) setGroupModal({ open: false, mode: 'create' }); }}>
      <DialogContent showCloseButton>
        <DialogHeader>
          <DialogTitle>{groupDialogTitle}</DialogTitle>
        </DialogHeader>
        {groupModal.mode === 'move' ? (
          <GroupDropdownSelect
            style={{ width: '100%' }}
            options={groupsOptions}
            value={groupInput}
            onChange={setGroupInput}
            placeholder={t('请选择规则组', 'Select a group')}
          />
        ) : (
          <Input value={groupInput} onChange={(e) => setGroupInput(e.target.value)} placeholder={t('请输入名称', 'Enter name')} />
        )}
        <DialogFooter>
          <Button onClick={() => setGroupModal({ open: false, mode: 'create' })}>Cancel</Button>
          <Button type="primary" onClick={confirmGroupModal}>OK</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  </div>;
}
