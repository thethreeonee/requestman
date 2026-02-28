import type { CollisionDetection } from '@dnd-kit/core';
import { pointerWithin, rectIntersection } from '@dnd-kit/core';
import { arrayMove } from '@dnd-kit/sortable';
import type { DragData, RedirectRule } from './types';

export const ruleDropCollisionDetection: CollisionDetection = (args) => {
  const pointerHits = pointerWithin(args);
  if (pointerHits.length > 0) return pointerHits;
  return rectIntersection(args);
};

export function moveRuleToGroup(
  list: RedirectRule[],
  groupOrder: string[],
  activeId: string,
  targetGroupId: string,
  overRuleId?: string,
) {
  const activeIndex = list.findIndex((r) => r.id === activeId);
  if (activeIndex < 0) return list;

  const activeRule = list[activeIndex];
  const withoutActive = list.filter((r) => r.id !== activeId);

  const insertIndex = (() => {
    if (overRuleId) {
      const idx = withoutActive.findIndex((r) => r.id === overRuleId);
      if (idx >= 0) return idx;
    }

    for (let i = withoutActive.length - 1; i >= 0; i -= 1) {
      if (withoutActive[i].groupId === targetGroupId) return i + 1;
    }

    const targetGroupIndex = groupOrder.findIndex((id) => id === targetGroupId);
    if (targetGroupIndex >= 0) {
      const laterGroups = new Set(groupOrder.slice(targetGroupIndex + 1));
      if (laterGroups.size > 0) {
        const nextIndex = withoutActive.findIndex((r) => laterGroups.has(r.groupId));
        if (nextIndex >= 0) return nextIndex;
      }
    }

    return withoutActive.length;
  })();

  const movedRule: RedirectRule = { ...activeRule, groupId: targetGroupId };
  const next = [...withoutActive];
  next.splice(insertIndex, 0, movedRule);
  return next;
}

export function reorderRulesInGroup(
  list: RedirectRule[],
  groupId: string,
  activeId: string,
  overId: string,
) {
  const inGroup = list.filter((r) => r.groupId === groupId);
  const oldIndex = inGroup.findIndex((r) => r.id === activeId);
  const newIndex = inGroup.findIndex((r) => r.id === overId);
  if (oldIndex < 0 || newIndex < 0 || oldIndex === newIndex) return list;
  const moved = arrayMove(inGroup, oldIndex, newIndex);
  let cursor = 0;
  return list.map((r) => {
    if (r.groupId !== groupId) return r;
    const next = moved[cursor];
    cursor += 1;
    return next;
  });
}

export function projectRulesByDragTarget(
  list: RedirectRule[],
  groupOrder: string[],
  activeId: string,
  overId: string,
  overData: DragData,
) {
  const activeRule = list.find((r) => r.id === activeId);
  if (!activeRule) return list;

  if (overData.type === 'rule') {
    if (activeId === overId) return list;
    if (activeRule.groupId === overData.groupId) {
      return reorderRulesInGroup(list, overData.groupId, activeId, overId);
    }
    return moveRuleToGroup(list, groupOrder, activeId, overData.groupId, overId);
  }

  if (activeRule.groupId === overData.groupId) return list;
  return moveRuleToGroup(list, groupOrder, activeId, overData.groupId);
}
