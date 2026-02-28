import React from 'react';
import { useDroppable } from '@dnd-kit/core';
import type { GroupDropData } from '../types';

export default function GroupEmptyDropZone({ groupId }: { groupId: string }) {
  const { setNodeRef, isOver } = useDroppable({
    id: `group-empty-drop:${groupId}`,
    data: { type: 'group', groupId } as GroupDropData,
  });

  return (
    <div
      ref={setNodeRef}
      className={`group-empty-drop-zone${isOver ? ' group-empty-drop-zone-active' : ''}`}
    >
      当前分组暂无规则
    </div>
  );
}
